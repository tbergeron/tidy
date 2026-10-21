import CoreLocation
import EventKit
import os

let perfLog = Logger(subsystem: "com.tidyreminders", category: "perf")
func perfMS(_ since: ContinuousClock.Instant) -> String { String(format: "%.0f ms", (ContinuousClock.now - since) / .milliseconds(1)) }

/// Owns the single EKEventStore and the private bridge. Every EventKit / ReminderKit object stays here;
/// only Sendable values leave. Runs on its own serial queue and never suspends inside a method,
/// so it is not re-entrant (fetches block this queue, not the cooperative pool).
actor Backend {
    private let queue = DispatchSerialQueue(label: "ttr.backend")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private lazy var ek: EKEventStore = {   // created on first use, on this actor's queue (not main)
        let t = ContinuousClock.now
        let s = EKEventStore()
        perfLog.debug("EKEventStore(): \(perfMS(t), privacy: .public)")
        return s
    }()
    private var bridge: TTRBridge?
    private var bridgeTried = false
    private var bridgeReport: [String] = []

    // MARK: Access

    func requestReminderAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { c in
            ek.requestFullAccessToReminders { granted, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: granted) }
            }
        }
    }

    func refreshSources() { ek.refreshSourcesIfNecessary() }

    // MARK: Load

    func load(completedSince: Date, sectionsFor listID: String?, useBridge: Bool) throws -> Snapshot {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw AppError.notAuthorized }
        var snap = Snapshot(completedSince: completedSince)
        var t = ContinuousClock.now

        let calendars = ek.calendars(for: .reminder)
        snap.defaultListID = ek.defaultCalendarForNewReminders()?.calendarIdentifier.uppercased()
        var accounts: [String: Account] = [:]
        snap.lists = calendars.map { c in
            let sourceID = c.source?.sourceIdentifier.uppercased() ?? ""
            if accounts[sourceID] == nil { accounts[sourceID] = Account(id: sourceID, title: c.source?.title ?? "") }
            return RList(id: c.calendarIdentifier.uppercased(), title: c.title, color: RGBA(c.cgColor),
                         accountID: sourceID, accountTitle: c.source?.title ?? "",
                         readOnly: !c.allowsContentModifications, immutable: c.isImmutable)
        }
        snap.accounts = accounts.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        perfLog.debug("lists: \(perfMS(t), privacy: .public) (\(snap.lists.count))"); t = .now
        // Both fetches run at once.
        let fetched = try fetchAll([ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil),
                                    ek.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: nil, calendars: nil)])
        perfLog.debug("fetch: \(perfMS(t), privacy: .public) (\(fetched[0].count) open, \(fetched[1].count) completed)"); t = .now
        for r in fetched.joined() { snap.reminders[r.id] = r }

        if useBridge { mergeBridge(into: &snap, sectionsFor: listID) }
        perfLog.notice("bridge: \(perfMS(t), privacy: .public)")
        snap.bridge.report = bridgeReport + snap.bridge.report

        return snap
    }

    /// Fresh values (with extras) for specific reminders, after a write.
    func reminders(_ ids: [String], useBridge: Bool) -> [Reminder] {
        var out = ids.compactMap { (ek.calendarItem(withIdentifier: $0) as? EKReminder).flatMap(Self.map) }
        if useBridge, let bridge, let infos = try? bridge.reminders(withIDs: out.map(\.id)) {
            let byID = Dictionary(infos.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
            for i in out.indices { out[i].extras = byID[out[i].id].map(Self.extras) }
        }
        return out
    }

    private func fetch(_ predicate: NSPredicate) throws -> [Reminder] { try fetchAll([predicate])[0] }

    /// Runs the fetches concurrently and waits for all of them (30 s cap).
    private func fetchAll(_ predicates: [NSPredicate]) throws -> [[Reminder]] {
        let boxes = predicates.map { _ in OSAllocatedUnfairLock<[Reminder]?>(initialState: nil) }
        let group = DispatchGroup()
        var tokens: [Any] = []
        for (i, p) in predicates.enumerated() {
            group.enter()
            let box = boxes[i]
            // Map to Sendable values on EventKit's queue; EKReminder never leaves the callback.
            tokens.append(ek.fetchReminders(matching: p) { @Sendable rems in
                let mapped = rems.map { $0.compactMap(Backend.map) }
                box.withLock { $0 = mapped }
                group.leave()
            })
        }
        if group.wait(timeout: .now() + 30) == .timedOut {
            tokens.forEach(ek.cancelFetchRequest)   // the completion is never called after cancel
            throw AppError.timeout
        }
        return try boxes.map {
            guard let out = $0.withLock({ $0 }) else { throw AppError.eventKit("Couldn't read Reminders.") }
            return out
        }
    }

    static func map(_ r: EKReminder) -> Reminder? {
        guard let cal = r.calendar else { return nil }   // orphaned
        return Reminder(
            id: r.calendarItemIdentifier.uppercased(), externalID: r.calendarItemExternalIdentifier,
            listID: cal.calendarIdentifier.uppercased(), title: r.title ?? "", notes: r.notes,
            isCompleted: r.isCompleted, completionDate: r.completionDate, priority: r.priority,
            due: r.dueDateComponents, alarms: (r.alarms ?? []).map(alarm),
            recurrence: r.recurrenceRules?.first.map(RecurrenceMap.recurrence),
            created: r.creationDate, modified: r.lastModifiedDate)
    }

    private static func alarm(_ a: EKAlarm) -> Alarm {
        var loc: LocationAlarm?
        if let s = a.structuredLocation {
            loc = LocationAlarm(title: s.title ?? "", latitude: s.geoLocation?.coordinate.latitude ?? 0,
                                longitude: s.geoLocation?.coordinate.longitude ?? 0, radius: s.radius,
                                leaving: a.proximity == .leave)
        }
        return Alarm(absolute: a.absoluteDate, relative: a.absoluteDate == nil && loc == nil ? a.relativeOffset : nil, location: loc)
    }

    // MARK: Private bridge (reads)

    private func mergeBridge(into snap: inout Snapshot, sectionsFor listID: String?) {
        if !bridgeTried {
            bridgeTried = true
            let report = NSMutableArray()
            bridge = TTRBridge(eventStore: ek, report: report)
            bridgeReport = report.compactMap { $0 as? String }
        }
        guard let bridge else { return }
        snap.bridge.loaded = true
        do {
            var t = ContinuousClock.now
            let accounts = try bridge.accounts()
            perfLog.debug("  bridge accounts: \(perfMS(t), privacy: .public)"); t = .now
            for a in accounts {
                guard let i = snap.accounts.firstIndex(where: { $0.id == a.identifier }) else { continue }
                snap.accounts[i].caps = a.capabilities
                snap.accounts[i].listOrder = a.listOrder
            }
            let infos = try bridge.lists()
            perfLog.debug("  bridge lists: \(perfMS(t), privacy: .public)"); t = .now
            let listIndex = Dictionary(snap.lists.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            for info in infos {
                if info.isGroup {
                    snap.groups.append(RGroup(id: info.identifier, name: info.name, accountID: info.accountID))
                } else if let i = listIndex[info.identifier] {
                    snap.lists[i].groupID = info.parentID
                    snap.lists[i].emblem = info.emoji ?? info.emblem
                    snap.lists[i].isPinned = info.isPinned
                    snap.lists[i].sortingStyle = info.sortingStyle
                    snap.lists[i].isGroceries = info.isGroceries
                    snap.lists[i].isShared = info.isShared
                    snap.lists[i].manualOrder = info.manualOrder
                    snap.lists[i].currentUserParticipantID = info.currentUserParticipantID
                }
            }
            let ids = Array(snap.reminders.keys)
            for start in stride(from: 0, to: ids.count, by: 500) {
                for info in try bridge.reminders(withIDs: Array(ids[start..<min(start + 500, ids.count)])) {
                    snap.reminders[info.identifier]?.extras = Self.extras(info)
                }
            }
            perfLog.debug("  bridge reminders: \(perfMS(t), privacy: .public)"); t = .now
            if let listID {
                snap.sections[listID] = try bridge.sections(inList: listID).map { RSection(id: $0.identifier, name: $0.name) }
                if snap.sections[listID]?.isEmpty == false {
                    let inList = snap.reminders.values.filter { $0.listID == listID }.map(\.id)
                    snap.sectionOf = try bridge.sectionIDs(forReminders: inList)
                }
            }
            perfLog.debug("  bridge sections: \(perfMS(t), privacy: .public)")
            snap.bridge.readOK = true
        } catch {
            snap.bridge.report.append("read failed: \(error.localizedDescription)")
            snap.bridge.readOK = false
        }
    }

    private static func extras(_ i: TTRReminderInfo) -> Extras {
        Extras(tags: i.tags, flagged: i.flagged, urgent: i.urgent, parentID: i.parentID, urls: i.urls,
               images: i.images.map { ImageInfo(width: ($0[0] as? NSNumber)?.intValue ?? 0, height: ($0[1] as? NSNumber)?.intValue ?? 0, uti: $0[2] as? String) },
               earlyAlerts: i.earlyAlerts.map { EarlyAlert(unit: $0[0].intValue, count: $0[1].intValue) },
               assigneeID: i.assigneeID, hourly: i.hourly)
    }

    // MARK: Reminder writes (public EventKit)

    /// Applies only the keys present in `edit` (R11).
    /// - base: what the user started from; keys another device changed since are reported as conflicts (still written).
    /// - onlyIfStill: for undo — keys whose current value is no longer what we wrote are skipped.
    /// Returns the saved reminder, the record just before the write, and the conflicts.
    func apply(_ edit: ReminderEdit, to id: String, base: Reminder?, onlyIfStill: Reminder? = nil) throws
        -> (Reminder, before: Reminder, conflicts: [String]) {
        guard let r = ek.calendarItem(withIdentifier: id) as? EKReminder, let fresh = Self.map(r) else { throw AppError.notFound }
        var edit = edit
        if let guardValue = onlyIfStill { edit = Edits.removing(Edits.conflicts(edit, base: guardValue, fresh: fresh), from: edit) }
        let conflicts = base.map { Edits.conflicts(edit, base: $0, fresh: fresh) } ?? []
        try write(edit, to: r)
        return (Self.map(r) ?? fresh, fresh, conflicts)
    }

    func create(_ edit: ReminderEdit, listID: String?) throws -> Reminder {
        let r = EKReminder(eventStore: ek)
        guard let cal = listID.flatMap({ ek.calendar(withIdentifier: $0) }) ?? ek.defaultCalendarForNewReminders() else {
            throw AppError.noAccount
        }
        r.calendar = cal
        r.title = ""
        var e = edit
        e.listID = nil
        try write(e, to: r)
        guard let out = Self.map(r) else { throw AppError.notFound }
        return out
    }

    /// Each reminder is its own commit so one rejected item doesn't fail the batch.
    func setCompleted(_ ids: [String], _ done: Bool) -> (updated: [Reminder], failed: [String]) {
        var updated: [Reminder] = [], failed: [String] = []
        for id in ids {
            guard let r = ek.calendarItem(withIdentifier: id) as? EKReminder else { failed.append(id); continue }
            do { try write(ReminderEdit(isCompleted: done), to: r); if let m = Self.map(r) { updated.append(m) } } catch { failed.append(id) }
        }
        return (updated, failed)
    }

    func delete(_ ids: [String]) -> [String] {
        var failed: [String] = []
        for id in ids {
            guard let r = ek.calendarItem(withIdentifier: id) as? EKReminder else { continue }   // already gone
            do { try ek.remove(r, commit: true) } catch { r.rollback(); failed.append(id) }
        }
        return failed
    }

    private func write(_ e: ReminderEdit, to r: EKReminder) throws {
        // Validate everything before mutating, so a refusal never leaves a half-edited object behind.
        if let cal = r.calendar, !cal.allowsContentModifications { throw AppError.readOnly }
        let newDue: DateComponents? = if let d = e.due { d } else { r.dueDateComponents }
        let repeats = e.recurrence.map { $0 != nil } ?? r.hasRecurrenceRules
        if repeats && newDue == nil { throw AppError.needsDueForRepeat }
        var target: EKCalendar?
        if let l = e.listID, l != r.calendar?.calendarIdentifier.uppercased() {
            guard let cal = ek.calendar(withIdentifier: l) else { throw AppError.notFound }
            guard cal.allowsContentModifications else { throw AppError.readOnly }
            target = cal
        }

        if let t = e.title, t != r.title { r.title = t }
        if let n = e.notes, n != r.notes { r.notes = n }          // only when changed: notes writes flatten rich text
        if let p = e.priority, Priority(raw: p) != Priority(raw: r.priority) { r.priority = Priority(raw: p).raw }
        if let d = e.due, !Due.same(d, r.dueDateComponents) {
            let absolute = (r.alarms ?? []).filter { $0.absoluteDate != nil && $0.structuredLocation == nil }
            let old = absolute.compactMap(\.absoluteDate)
            let new = AlarmPlan.shifted(old, from: r.dueDateComponents, to: d, clock: .current)
            r.dueDateComponents = d
            if new != old {   // never assign `alarms` wholesale (keeps vehicle/location/relative alarms)
                absolute.forEach(r.removeAlarm)
                new.forEach { r.addAlarm(EKAlarm(absoluteDate: $0)) }
            }
        }
        if let rec = e.recurrence {   // only when the user changed the repeat picker (R7)
            if let rec { r.recurrenceRules = [RecurrenceMap.rule(rec)] } else if r.hasRecurrenceRules { r.recurrenceRules = nil }
        }
        if let loc = e.location {
            (r.alarms ?? []).filter { $0.structuredLocation != nil }.forEach(r.removeAlarm)
            if let loc {
                let s = EKStructuredLocation(title: loc.title)
                s.geoLocation = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                s.radius = loc.radius
                let a = EKAlarm()
                a.structuredLocation = s
                a.proximity = loc.leaving ? .leave : .enter
                r.addAlarm(a)
            }
        }
        if let c = e.isCompleted, c != r.isCompleted { r.isCompleted = c }
        if let target { r.calendar = target }

        guard r.hasChanges || r.isNew else { return }
        do {
            try ek.save(r, commit: true)
        } catch {
            r.rollback()
            throw Self.mapError(error)
        }
    }

    static func mapError(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == "com.apple.reminderkit", ns.code == -3002 { return AppError.moveRejected }
        guard ns.domain == EKErrorDomain else { return AppError.eventKit(ns.localizedDescription) }
        switch EKError.Code(rawValue: ns.code) {
        case .calendarReadOnly, .calendarIsImmutable, .sourceDoesNotAllowCalendarAddDelete,
             .calendarDoesNotAllowReminders, .sourceDoesNotAllowReminders: return AppError.readOnly
        case .recurringReminderRequiresDueDate: return AppError.needsDueForRepeat
        case .structuredLocationsNotSupported, .reminderLocationsNotSupported, .alarmProximityNotSupported:
            return AppError.unsupported("location reminders")
        case .eventStoreNotAuthorized: return AppError.notAuthorized
        default: return AppError.eventKit(ns.localizedDescription)
        }
    }

    /// Sections of one list (and which reminders are in them), for opening a list without a full reload.
    func sections(inList listID: String, reminderIDs: [String]) -> (sections: [RSection], sectionOf: [String: String])? {
        guard let bridge, let infos = try? bridge.sections(inList: listID) else { return nil }
        let sections = infos.map { RSection(id: $0.identifier, name: $0.name) }
        let of = sections.isEmpty ? [:] : ((try? bridge.sectionIDs(forReminders: reminderIDs)) ?? [:])
        return (sections, of)
    }

    // MARK: Private writes

    /// Reminders' "Mark as Urgent" through the bridge (verified by read-back inside the bridge).
    func setUrgent(_ urgent: Bool, ids: [String]) -> (updated: [Reminder], failures: [String]) {
        guard let bridge else { return ([], ["Private features are off."]) }
        var failures: [String] = []
        for id in ids {
            do { try bridge.setUrgent(urgent, reminder: id) } catch { failures.append(error.localizedDescription) }
        }
        return (reminders(ids, useBridge: true), failures)
    }

    // MARK: Lists

    func createList(title: String, color: RGBA, accountID: String?) throws -> String {
        let c = EKCalendar(for: .reminder, eventStore: ek)
        c.title = title
        c.cgColor = color.cgColor
        let sources = ek.sources.filter { !$0.calendars(for: .reminder).isEmpty }
        guard let source = sources.first(where: { $0.sourceIdentifier.uppercased() == accountID })
                ?? ek.defaultCalendarForNewReminders()?.source ?? sources.first else { throw AppError.noAccount }
        c.source = source
        do { try ek.saveCalendar(c, commit: true) } catch { throw Self.mapError(error) }
        return c.calendarIdentifier.uppercased()
    }

    func updateList(_ id: String, title: String?, color: RGBA?) throws {
        guard let c = ek.calendar(withIdentifier: id) else { throw AppError.notFound }
        guard !c.isImmutable else { throw AppError.readOnly }
        if let title, title != c.title { c.title = title }
        if let color { c.cgColor = color.cgColor }
        do { try ek.saveCalendar(c, commit: true) } catch { c.rollback(); throw Self.mapError(error) }
    }

    /// Every reminder in the list, completed ones included (the delete dialog's count).
    func reminderCount(inList id: String) throws -> Int {
        guard let c = ek.calendar(withIdentifier: id) else { return 0 }
        return try fetch(ek.predicateForReminders(in: [c])).count
    }

    /// Deletes the list AND all its reminders (EventKit cascades). With `moveTo`, every reminder (completed
    /// included) is moved first; if any move fails the list is kept. Callers confirm with counts first.
    func deleteList(_ id: String, moveTo target: String? = nil) throws {
        guard let c = ek.calendar(withIdentifier: id) else { return }
        if let target {
            let all = try fetch(ek.predicateForReminders(in: [c]))
            var failed = 0
            for r in all {   // a parent with subtasks is refused (-3002) → counted as failed, list kept
                do { _ = try apply(ReminderEdit(listID: target), to: r.id, base: nil) } catch { failed += 1 }
            }
            if failed > 0 { throw AppError.eventKit("Moved \(all.count - failed) of \(all.count) reminders; the list was kept.") }
        }
        do { try ek.removeCalendar(c, commit: true) } catch { throw Self.mapError(error) }
    }
}

extension RGBA {
    init(_ cg: CGColor?) {
        let srgb = cg?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let c = srgb?.components ?? [0.5, 0.5, 0.5, 1]
        self.init(r: Double(c[0]), g: Double(c.count > 2 ? c[1] : c[0]), b: Double(c.count > 2 ? c[2] : c[0]), a: Double(c.last ?? 1))
    }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
