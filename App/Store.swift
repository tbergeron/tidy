import AppKit
import EventKit
import Observation

/// UI-facing model. Holds the latest Snapshot from Backend; every write goes Backend → fresh values → here.
/// No optimistic layer except hiding pending deletes and keeping just-completed rows visible briefly.
@MainActor @Observable
final class Store {
    let backend = Backend()

    var auth = EKEventStore.authorizationStatus(for: .reminder)
    var snap = Snapshot() { didSet { updateBadge() } }
    var loaded = false
    var clock = Clock.current { didSet { updateBadge() } }

    var destination: Destination = .today {
        didSet {
            guard oldValue != destination else { return }
            composeFinisher?()
            flushDraft()
            selection = []
            editingID = nil
            datePicker = nil
            tagFilter = []
            scheduleReload()
        }
    }
    var selection: Set<String> = []
    var editingID: String? { didSet { if editingID != nil { composeFinisher?() } } }
    var draft: Draft?
    var composing: Reminder?               // the full card for a new reminder (+ / ⌘N); saved when it closes
    @ObservationIgnored var composeFinisher: (() -> Void)?
    var search = ""
    var tagFilter: Set<String> = []
    var banner: String?
    var showNewList = false
    var showMoveSheet = false
    var confirmDeleteIDs: [String]?
    var listToEdit: RList?
    var listToDelete: RList?
    var datePicker: (anchor: String, ids: [String])?   // "Pick a Date…": popover on the anchor row
    var listDeleteCount: Int?
    var pendingCrossMove: (ids: [String], listID: String)?
    var orphanedDraft: Reminder?           // card text whose reminder was deleted elsewhere
    @ObservationIgnored var commitOpenCard: (() -> Void)?
    @ObservationIgnored var cancelOpenCard: (() -> Void)?

    private(set) var pendingDeletes: [String: Date] = [:] { didSet { updateBadge() } }
    private(set) var justCompleted: Set<String> = []

    // Preferences (app-local; never Reminders data)
    var groupByTime = UserDefaults.standard.object(forKey: "todayGroupByTime") as? Bool ?? true {
        didSet { UserDefaults.standard.set(groupByTime, forKey: "todayGroupByTime") }
    }
    var showCompleted = Set(UserDefaults.standard.stringArray(forKey: "showCompleted") ?? []) {
        didSet { UserDefaults.standard.set(Array(showCompleted), forKey: "showCompleted") }
    }
    var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }
    var hiddenSmartLists = Set(UserDefaults.standard.stringArray(forKey: "hiddenSmartLists") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenSmartLists), forKey: "hiddenSmartLists") }
    }
    var bridgeEnabled = UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled"); scheduleReload() }
    }
    var completedWindowDays = 30 { didSet { scheduleReload() } }

    /// Dock badge, like Reminders' "Badge Count": overdue, optionally plus due today.
    enum BadgeMode: String, CaseIterable { case overdueAndToday, overdue, off }
    var badgeMode = BadgeMode(rawValue: UserDefaults.standard.string(forKey: "badgeMode") ?? "") ?? .overdueAndToday {
        didSet { UserDefaults.standard.set(badgeMode.rawValue, forKey: "badgeMode"); updateBadge() }
    }


    struct Draft: Equatable { var listID: String?; var due: DateComponents?; var text = "" }

    private var reloadTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?

    // MARK: Lifecycle

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = .current; self?.scheduleReload() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.auth == .fullAccess else { return }
                Task { await self.backend.refreshSources() }
                self.scheduleReload()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = .current; self?.scheduleReload() }
        })
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = .current }
        }
        if auth == .fullAccess { scheduleReload(delay: 0) }
    }

    func requestAccess() async {
        do { _ = try await backend.requestReminderAccess() } catch { fail(error) }
        auth = EKEventStore.authorizationStatus(for: .reminder)
        if auth == .fullAccess { await reload() }
    }

    func scheduleReload(delay: Double = 0.3) {
        reloadTask?.cancel()
        reloadTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        guard auth == .fullAccess else { return }
        let since = clock.cal.date(byAdding: .day, value: -completedWindowDays, to: clock.today) ?? .distantPast
        do {
            snap = try await backend.load(completedSince: since, sectionsFor: viewedListID,
                                          useBridge: bridgeEnabled)
            loaded = true
            switch destination {   // the viewed list/group was deleted elsewhere
            case .list(let id) where list(id) == nil, .group(let id) where !snap.groups.contains(where: { $0.id == id }):
                destination = .today
            default: break
            }
            if let id = editingID, snap.reminders[id] == nil { editingID = nil }
        } catch {
            fail(error)
        }
    }

    var badgeCount: Int {
        guard auth == .fullAccess else { return 0 }
        switch badgeMode {
        case .off: return 0
        case .overdue: return live.filter { Smart.isOverdue($0, clock) }.count
        case .overdueAndToday: return live.filter { Smart.inToday($0, clock) }.count   // == the Today count
        }
    }

    private func updateBadge() {
        let n = badgeCount
        let label = n > 0 ? "\(n)" : nil
        let tile = NSApplication.shared.dockTile
        if tile.badgeLabel != label { tile.badgeLabel = label }
    }

    /// Ops run one after another so their effects (and undos) apply in order.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = tail
        tail = Task { await prev?.value; await op() }
    }

    func fail(_ error: Error) { banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    func fail(_ message: String) { banner = message }

    private func merge(_ r: Reminder, replacing oldID: String? = nil) {
        var r = r
        if r.extras == nil { r.extras = snap.reminders[oldID ?? r.id]?.extras }
        if let oldID, oldID != r.id {
            snap.reminders[oldID] = nil
            if selection.remove(oldID) != nil { selection.insert(r.id) }
            if editingID == oldID { editingID = r.id }
        }
        snap.reminders[r.id] = r
    }

    // MARK: Derived data

    var viewedListID: String? { if case .list(let id) = destination { id } else { nil } }
    var bridgeReadable: Bool { bridgeEnabled && snap.bridge.readOK }

    func list(_ id: String) -> RList? { snap.lists.first { $0.id == id } }
    func account(_ id: String) -> Account? { snap.accounts.first { $0.id == id } }
    func supports(_ cap: String) -> Bool { bridgeReadable && snap.accounts.contains { $0.caps.contains(cap) } }

    /// Reminders that are not pending deletion.
    var live: [Reminder] { snap.reminders.values.filter { pendingDeletes[$0.id] == nil } }

    func children(of id: String) -> [Reminder] { live.filter { $0.parentID == id } }

    func isAssignedToMe(_ r: Reminder) -> Bool {
        guard let a = r.extras?.assigneeID, let me = list(r.listID)?.currentUserParticipantID else { return false }
        return a.caseInsensitiveCompare(me) == .orderedSame
    }

    // Sidebar
    struct SidebarAccount: Identifiable { let account: Account; var entries: [SidebarEntry]; var id: String { account.id } }
    enum SidebarEntry: Identifiable {
        case list(RList), group(RGroup, [RList])
        var id: String { switch self { case .list(let l): l.id; case .group(let g, _): g.id } }
    }

    var sidebarAccounts: [SidebarAccount] {
        snap.accounts.compactMap { a in
            let lists = snap.lists.filter { $0.accountID == a.id }
            guard !lists.isEmpty else { return nil }
            let groups = snap.groups.filter { $0.accountID == a.id }
            var entries: [SidebarEntry] = lists.filter { l in l.groupID == nil || !groups.contains { $0.id == l.groupID } }.map { .list($0) }
            entries += groups.map { g in .group(g, lists.filter { $0.groupID == g.id }.sorted(by: Self.titleOrder)) }
            let order = Dictionary(a.listOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { x, _ in x })
            entries.sort {
                switch (order[$0.id], order[$1.id]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return Self.entryTitle($0).localizedStandardCompare(Self.entryTitle($1)) == .orderedAscending
                }
            }
            return SidebarAccount(account: a, entries: entries)
        }
    }
    private static func entryTitle(_ e: SidebarEntry) -> String { switch e { case .list(let l): l.title; case .group(let g, _): g.name } }
    private static func titleOrder(_ a: RList, _ b: RList) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }

    var pinnedLists: [RList] { bridgeReadable ? snap.lists.filter(\.isPinned) : [] }

    var allTags: [(name: String, count: Int)] {
        var counts: [String: (String, Int)] = [:]
        for r in live where !r.isCompleted {
            for t in r.extras?.tags ?? [] { counts[t.lowercased(), default: (t, 0)].1 += 1 }
        }
        return counts.values.map { (name: $0.0, count: $0.1) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func count(_ d: Destination) -> Int? {
        let open = live.filter { !$0.isCompleted }
        switch d {
        case .today: return open.filter { Smart.inToday($0, clock) }.count
        case .scheduled: return open.filter { $0.due != nil }.count
        case .all: return open.count
        case .flagged: return open.filter { $0.extras?.flagged == true }.count
        case .urgent: return open.filter { $0.extras?.urgent == true }.count
        case .assigned: return open.filter(isAssignedToMe).count
        case .list(let id): return open.filter { $0.listID == id }.count
        case .group(let id): return open.filter { list($0.listID)?.groupID == id }.count
        case .tag(let t): return open.filter { $0.extras?.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } == true }.count
        case .completed: return nil
        }
    }

    func isAvailable(_ d: Destination) -> Bool {
        switch d {
        case .flagged: supports("supportsFlagged")
        case .urgent: supports("supportsUrgentAlarm")
        case .assigned: supports("supportsAssignments") && snap.lists.contains(where: \.isShared)
        default: true
        }
    }

    // List contents
    struct Row: Identifiable, Hashable { let reminder: Reminder; let depth: Int; var id: String { reminder.id } }
    struct RowSection: Identifiable {
        enum Kind: Hashable { case plain, overdue, day(Date), today(TodayBucket), list(String), section(String), completed }
        let id: String
        var title: String
        var kind: Kind
        var rows: [Row]
    }

    func title(_ d: Destination) -> String {
        switch d {
        case .today: "Today"
        case .scheduled: "Scheduled"
        case .all: "All"
        case .flagged: "Flagged"
        case .completed: "Completed"
        case .assigned: "Assigned to Me"
        case .urgent: "Urgent"
        case .list(let id): list(id)?.title ?? ""
        case .group(let id): snap.groups.first { $0.id == id }?.name ?? ""
        case .tag(let t): "#" + t
        }
    }

    /// Tags present in the current view (for the tag filter bar).
    func tagsInView(_ d: Destination) -> [String] {
        let rs = candidates(d, includeCompleted: false)
        var seen: [String: String] = [:]
        for r in rs { for t in r.extras?.tags ?? [] { seen[t.lowercased()] = seen[t.lowercased()] ?? t } }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func candidates(_ d: Destination, includeCompleted: Bool) -> [Reminder] {
        live.filter { r in
            let visibleCompletion = includeCompleted || !r.isCompleted || justCompleted.contains(r.id)
            switch d {
            case .today: return (!r.isCompleted || justCompleted.contains(r.id)) && (Smart.inToday(r, clock) || justCompleted.contains(r.id) && r.due != nil)
            case .scheduled: return (!r.isCompleted || justCompleted.contains(r.id)) && r.due != nil
            case .all: return visibleCompletion
            case .flagged: return visibleCompletion && r.extras?.flagged == true
            case .urgent: return visibleCompletion && r.extras?.urgent == true
            case .assigned: return visibleCompletion && isAssignedToMe(r)
            case .completed: return r.isCompleted
            case .list(let id): return r.listID == id && visibleCompletion
            case .group(let id): return list(r.listID)?.groupID == id && visibleCompletion
            case .tag(let t): return visibleCompletion && r.extras?.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } == true
            }
        }
    }

    func sections(_ d: Destination) -> [RowSection] {
        var rs = candidates(d, includeCompleted: false)
        if !search.isEmpty { rs = rs.filter { Display.matches($0, query: search, listTitle: list($0.listID)?.title ?? "") } }
        if !tagFilter.isEmpty {
            rs = rs.filter { r in tagFilter.allSatisfy { t in r.extras?.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } == true } }
        }
        let flat: ([Reminder]) -> [Row] = { Sorting.smart($0, clock: self.clock).map { Row(reminder: $0, depth: 0) } }

        switch d {
        case .today:
            let buckets = Dictionary(grouping: rs) { Smart.todayBucket($0, clock, groupByTime: groupByTime) }
            let order: [TodayBucket] = groupByTime ? [.overdue, .allDay, .morning, .afternoon, .tonight] : [.overdue, .today]
            return order.compactMap { b in
                guard let items = buckets[b], !items.isEmpty || (groupByTime && b != .overdue) else { return nil }
                return RowSection(id: "today-\(b.rawValue)", title: b.title, kind: b == .overdue ? .overdue : .today(b), rows: flat(items))
            }
        case .scheduled:
            // Just-completed rows stay in their day for the 1.5 s they remain visible.
            let groups = Dictionary(grouping: rs) { r -> ScheduledBucket in
                var x = r
                x.isCompleted = false
                return Smart.scheduledBucket(x, clock) ?? .overdue
            }
            let keys = Set(groups.keys).union(Smart.scheduledDays(clock)).sorted()
            return keys.map { k in
                let items = groups[k] ?? []
                switch k {
                case .overdue: return RowSection(id: "overdue", title: "Overdue", kind: .overdue, rows: flat(items))
                case .day(let day): return RowSection(id: "day-\(day.timeIntervalSince1970)", title: dayTitle(day), kind: .day(day), rows: flat(items))
                case .month(let m): return RowSection(id: "month-\(m.timeIntervalSince1970)", title: m.formatted(.dateTime.month(.wide).year()), kind: .plain, rows: flat(items))
                }
            }.filter { !$0.rows.isEmpty || $0.kind != .overdue }
        case .completed:
            let byDay = Dictionary(grouping: rs) { clock.cal.startOfDay(for: $0.completionDate ?? .distantPast) }
            return byDay.keys.sorted(by: >).map { day in
                let items = byDay[day]!.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                return RowSection(id: "done-\(day.timeIntervalSince1970)", title: day == .distantPast ? "Earlier" : dayTitle(day), kind: .plain, rows: items.map { Row(reminder: $0, depth: 0) })
            }
        case .list(let id):
            var out: [RowSection] = []
            let l = list(id)
            let sorted = Sorting.sorted(rs, style: l?.sortingStyle, manual: l?.manualOrder ?? [], clock: clock)
            let secs = snap.sections[id] ?? []
            let sectionOf: (Reminder) -> String? = { r in
                // Subtasks follow their parent's section.
                let key = r.parentID.flatMap { p in sorted.contains { $0.id == p } ? p : nil } ?? r.id
                return self.snap.sectionOf[key].flatMap { s in secs.contains { $0.id == s } ? s : nil }
            }
            let unsectioned = sorted.filter { sectionOf($0) == nil }
            out.append(RowSection(id: "list-\(id)", title: "", kind: .plain, rows: nested(unsectioned)))
            for s in secs {
                out.append(RowSection(id: s.id, title: s.name, kind: .section(s.id), rows: nested(sorted.filter { sectionOf($0) == s.id })))
            }
            if showCompleted.contains(id) {
                let done = live.filter { $0.listID == id && $0.isCompleted && !justCompleted.contains($0.id) }
                    .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                if !done.isEmpty { out.append(RowSection(id: "completed-\(id)", title: "Completed", kind: .completed, rows: done.map { Row(reminder: $0, depth: 0) })) }
            }
            return out
        case .all, .flagged, .urgent, .assigned, .group, .tag:
            let byList = Dictionary(grouping: rs, by: \.listID)
            return orderedListIDs.compactMap { lid in
                guard let items = byList[lid], !items.isEmpty, let l = list(lid) else { return nil }
                let sorted = Sorting.sorted(items, style: l.sortingStyle, manual: l.manualOrder, clock: clock)
                return RowSection(id: "list-\(lid)", title: l.title, kind: .list(lid), rows: nested(sorted))
            }
        }
    }

    /// Lists in sidebar order.
    var orderedListIDs: [String] {
        sidebarAccounts.flatMap { $0.entries.flatMap { e -> [String] in
            switch e { case .list(let l): [l.id]; case .group(_, let ls): ls.map(\.id) }
        } }
    }

    /// Parents followed by their (sorted) subtasks; orphans are top level. One level, like Reminders.
    private func nested(_ sorted: [Reminder]) -> [Row] {
        let ids = Set(sorted.map(\.id))
        var kids: [String: [Reminder]] = [:]
        for r in sorted { if let p = r.parentID, ids.contains(p) { kids[p, default: []].append(r) } }
        var out: [Row] = []
        for r in sorted where r.parentID.map({ !ids.contains($0) }) ?? true {
            out.append(Row(reminder: r, depth: 0))
            // An open card shows its own checklist, so its subtasks aren't drawn twice.
            if !collapsed.contains(r.id) && r.id != editingID { out += (kids[r.id] ?? []).map { Row(reminder: $0, depth: 1) } }
        }
        return out
    }

    func dayTitle(_ day: Date) -> String {
        let days = clock.cal.dateComponents([.day], from: clock.today, to: day).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    /// Where a reminder created from this view goes, and with which attributes.
    func newReminderTarget(_ d: Destination) -> (listID: String?, due: DateComponents?) {
        switch d {
        case .list(let id): (id, nil)
        case .group(let id): (orderedListIDs.first { list($0)?.groupID == id }, nil)
        case .today, .scheduled: (nil, Due.components(clock.today, allDay: true, timeZone: nil, clock: clock))
        default: (nil, nil)
        }
    }

    // MARK: Reminder ops

    /// Payload is read when undo runs, so the op can replace the provisional inverse with real pre-write values.
    final class UndoToken {
        var edits: [(String, ReminderEdit)] = []
        var guards: [String: Reminder] = [:]
        var ids: [String] = []
    }
    /// UndoManager holds targets unowned, so tokens must outlive their actions. ponytail: never pruned (a few bytes each).
    private var undoTokens: [UndoToken] = []
    private func newToken() -> UndoToken { let t = UndoToken(); undoTokens.append(t); return t }

    func locked(_ id: String) -> Bool { snap.reminders[id].flatMap { list($0.listID) }?.readOnly == true }

    /// The one edit path: per-item ReminderEdit. Undo = inverse edits for the same keys, applied only where the
    /// value is still what we wrote (`guards`), so undo never clobbers a newer change from another device (R11).
    func applyEdits(_ items: [(String, ReminderEdit)], name: String, undo um: UndoManager?,
                    bases: [String: Reminder] = [:], guards: [String: Reminder] = [:], undoable: Bool = true,
                    onFailure: (@MainActor () -> Void)? = nil) {
        let befores = items.compactMap { id, e in snap.reminders[id].map { ($0, e) } }
            .filter { !$0.1.isEmpty && !locked($0.0.id) }
        guard !befores.isEmpty else { return }
        let token = newToken()
        token.edits = befores.map { b, e in (b.id, Edits.diff(base: Edits.applied(e, to: b), draft: b)) }
        token.guards = Dictionary(befores.map { b, e in (b.id, Edits.applied(e, to: b)) }, uniquingKeysWith: { a, _ in a })
        let completesRepeating = befores.contains { $0.0.isRepeating && $0.1.isCompleted == true }
        if undoable && !completesRepeating {   // R1: completing a repeating reminder advances it; no undo
            um?.registerUndo(withTarget: token) { t in self.applyEdits(t.edits, name: name, undo: um, guards: t.guards) }
            um?.setActionName(name)
        }
        enqueue {
            var errors: [Error] = [], conflicts: [String] = []
            var edits: [(String, ReminderEdit)] = [], wrote: [String: Reminder] = [:]
            for (b, e) in befores {
                do {
                    let (r, before, c) = try await self.backend.apply(e, to: b.id, base: bases[b.id], onlyIfStill: guards[b.id])
                    self.merge(r, replacing: b.id)
                    conflicts += c
                    edits.append((r.id, Edits.diff(base: r, draft: before)))
                    wrote[r.id] = r
                } catch {
                    errors.append(error)
                }
            }
            token.edits = edits
            token.guards = wrote
            if let first = errors.first {
                self.fail(errors.count > 1 ? "\(errors.count) changes failed: \(first.localizedDescription)" : first.localizedDescription)
                if edits.isEmpty { um?.removeAllActions(withTarget: token) }
                onFailure?()
            } else if !conflicts.isEmpty {
                self.banner = "Replaced a change made on another device (\(Set(conflicts).sorted().joined(separator: ", "))). Undo restores it."
            }
        }
    }

    func commitCard(draft: Reminder, base: Reminder, undo um: UndoManager?, onFailure: (@MainActor () -> Void)? = nil) {
        let e = Edits.diff(base: base, draft: draft)
        guard !e.isEmpty else { return }
        // An hourly rule can't be expressed in EventKit, so an undo would write Daily instead.
        applyEdits([(base.id, e)], name: "Edit", undo: um, bases: [base.id: base],
                   undoable: !(base.extras?.hourly == true && e.recurrence != nil), onFailure: onFailure)
    }

    private var completing: Set<String> = []

    func toggleComplete(_ ids: [String], undo um: UndoManager?) {
        // R1 guard: a repeating reminder that was just completed has already advanced; a second click would complete the next one.
        let rs = ids.compactMap { snap.reminders[$0] }
            .filter { !locked($0.id) && !($0.isRepeating && (completing.contains($0.id) || justCompleted.contains($0.id))) }
        guard let first = rs.first else { return }
        let done = !first.isCompleted
        var targets = rs.filter { $0.isCompleted != done }
        // Completing a non-repeating parent completes its open subtasks too (Reminders behaviour).
        if done {
            for p in targets where !p.isRepeating {
                targets += children(of: p.id).filter { !$0.isCompleted && !targets.contains($0) }
            }
            justCompleted.formUnion(targets.map(\.id))
            let keep = targets.map(\.id)
            Task { try? await Task.sleep(for: .seconds(1.5)); justCompleted.subtract(keep) }
        }
        let reps = targets.filter(\.isRepeating).map(\.id)
        completing.formUnion(reps)
        applyEdits(targets.map { ($0.id, ReminderEdit(isCompleted: done)) }, name: done ? "Complete" : "Uncomplete", undo: um)
        if !reps.isEmpty { enqueue { self.completing.subtract(reps) } }
    }

    func setDue(_ ids: [String], _ make: (Reminder) -> DateComponents?, undo um: UndoManager?) {
        // Clearing the date of a repeating reminder is refused by EventKit (R7); the card asks first instead.
        let items = ids.compactMap { id in snap.reminders[id].map { (id, make($0), $0.isRepeating) } }
        if items.contains(where: { $0.1 == nil && $0.2 }) { fail(AppError.needsDueForRepeat) }
        applyEdits(items.filter { !($0.1 == nil && $0.2) }.map { ($0.0, ReminderEdit(due: .some($0.1))) }, name: "Reschedule", undo: um)
    }

    func setPriority(_ ids: [String], _ p: Priority, undo um: UndoManager?) {
        applyEdits(ids.map { ($0, ReminderEdit(priority: p.raw)) }, name: "Priority", undo: um)
    }

    /// A move to another account is a copy in EventKit (new IDs; tags, subtasks, attachments don't follow),
    /// so it's confirmed, refused for subtask trees, and not undoable (R8).
    func move(_ ids: [String], toList listID: String, undo um: UndoManager?, confirmed: Bool = false) {
        guard let target = list(listID), !target.readOnly else { return }
        let rs = ids.compactMap { snap.reminders[$0] }.filter { $0.listID != listID && !locked($0.id) }
        let cross = rs.filter { list($0.listID)?.accountID != target.accountID }
        if !cross.isEmpty {
            if cross.contains(where: { !children(of: $0.id).isEmpty || $0.parentID != nil }) {
                fail("Reminders with subtasks can't move to another account. Use Open in Reminders.")
                return
            }
            guard confirmed else { pendingCrossMove = (rs.map(\.id), listID); return }
        }
        let crossIDs = Set(cross.map(\.id))
        applyEdits(rs.filter { !crossIDs.contains($0.id) }.map { ($0.id, ReminderEdit(listID: listID)) }, name: "Move", undo: um)
        applyEdits(cross.map { ($0.id, ReminderEdit(listID: listID)) }, name: "Move", undo: um, undoable: false)
    }

    func create(title: String, listID: String?, due: DateComponents?, undo um: UndoManager?, open: Bool = false) {
        create(ReminderEdit(title: title.trimmingCharacters(in: .whitespacesAndNewlines), due: .some(due)), listID: listID, undo: um, open: open)
    }

    func create(_ edit: ReminderEdit, listID: String?, undo um: UndoManager?, open: Bool = false) {
        guard !(edit.title ?? "").isEmpty else { return }
        // Registered now (so the undo stack keeps its order); the id is filled in once the create ran.
        let token = newToken()
        um?.registerUndo(withTarget: token) { t in
            if t.ids.isEmpty { self.enqueue { self.delete(t.ids, undo: um) } } else { self.delete(t.ids, undo: um) }
        }
        um?.setActionName("New Reminder")
        enqueue {
            do {
                let r = try await self.backend.create(edit, listID: listID)
                self.merge(r)
                token.ids = [r.id]
                if open { self.selection = [r.id]; self.editingID = r.id }
            } catch {
                self.fail(error)
                um?.removeAllActions(withTarget: token)
            }
        }
    }

    /// Hidden at once; really removed after 8 s or on quit, so undo is free inside the window (R9).
    func delete(_ ids: [String], undo um: UndoManager?) {
        var all = ids.filter { snap.reminders[$0] != nil && pendingDeletes[$0] == nil && !locked($0) }
        for id in all { all += children(of: id).map(\.id).filter { !all.contains($0) } }   // subtasks go with the parent
        guard !all.isEmpty else { return }
        let now = Date()
        for id in all { pendingDeletes[id] = now }
        selection.subtract(all)
        if let e = editingID, all.contains(e) { editingID = nil }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in self.undelete(all, undo: um) }
        um?.setActionName("Delete")
        flushTask?.cancel()
        flushTask = Task { try? await Task.sleep(for: .seconds(8)); await flushDeletes(olderThan: 8) }
    }

    private var flushing: Set<String> = []

    private func undelete(_ ids: [String], undo um: UndoManager?) {
        let still = ids.filter { pendingDeletes[$0] != nil && !flushing.contains($0) }
        still.forEach { pendingDeletes[$0] = nil }
        if still.count < ids.count {
            banner = "Some reminders were already deleted. Recover them from Recently Deleted in Reminders."
        }
        guard !still.isEmpty else { return }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in self.delete(still, undo: um) }
    }

    func flushDeletes(olderThan age: TimeInterval = 0) async {
        let now = Date()
        // Children first, so a parent never disappears before its subtasks.
        let due = pendingDeletes.filter { now.timeIntervalSince($0.value) >= age && !flushing.contains($0.key) }.map(\.key)
            .sorted { (snap.reminders[$0]?.parentID != nil ? 0 : 1) < (snap.reminders[$1]?.parentID != nil ? 0 : 1) }
        guard !due.isEmpty else { return }
        flushing.formUnion(due)
        let failed = await backend.delete(due)
        flushing.subtract(due)
        for id in due {
            pendingDeletes[id] = nil
            if !failed.contains(id) { snap.reminders[id] = nil }
        }
        if !failed.isEmpty { fail("Couldn't delete \(failed.count) reminder(s).") }
        if !pendingDeletes.isEmpty {
            flushTask = Task { try? await Task.sleep(for: .seconds(8)); await flushDeletes(olderThan: 8) }
        }
    }

    /// Every delete is confirmed first (the dialog is in MainView).
    func requestDelete(_ ids: [String], undo um: UndoManager?) {
        let ids = ids.filter { !locked($0) && snap.reminders[$0] != nil && pendingDeletes[$0] == nil }
        if !ids.isEmpty { confirmDeleteIDs = ids }
    }

    /// Title, message and button for the delete confirmation.
    func deleteConfirmation(_ ids: [String]) -> (title: String, message: String, button: String) {
        let rs = ids.compactMap { snap.reminders[$0] }
        let subtasks = Set(rs.flatMap { children(of: $0.id).map(\.id) }).subtracting(ids).count
        let title = rs.count == 1 ? "Delete “\(rs[0].title.isEmpty ? "New Reminder" : rs[0].title)”?" : "Delete \(rs.count) reminders?"
        var notes: [String] = []
        if subtasks > 0 { notes.append(subtasks == 1 ? "Its subtask is deleted too." : "Their \(subtasks) subtasks are deleted too.") }
        if rs.contains(where: \.isRepeating) { notes.append("Repeating reminders are deleted with all future occurrences.") }
        notes.append("You can undo with ⌘Z, or recover it later from Recently Deleted in Reminders.")
        return (title, notes.joined(separator: " "), rs.contains(where: \.isRepeating) ? "Delete All Occurrences" : "Delete")
    }

    func moveOverdueToToday(undo um: UndoManager?) {
        let ids = live.filter { !$0.isCompleted && ($0.due.flatMap { Due.day($0, clock: clock) } ?? .distantFuture) < clock.today }.map(\.id)
        setDue(ids, { Due.moving($0.due, toDay: self.clock.today, clock: self.clock) }, undo: um)
    }

    /// New reminders can only be created where they'll stay visible and writable.
    var canCreate: Bool {
        switch destination {
        case .completed, .flagged, .urgent, .assigned, .tag: return false
        default:
            let t = newReminderTarget(destination)
            return list(t.listID ?? snap.defaultListID ?? "")?.readOnly != true
        }
    }

    func startDraft() {
        guard canCreate else { return }
        composeFinisher?()
        flushDraft()
        let t = newReminderTarget(destination)
        editingID = nil
        draft = Draft(listID: t.listID, due: t.due)
    }

    /// + / ⌘N: the full card for a new reminder, dated today. Nothing is written until it closes with a title.
    func startCompose() {
        guard canCreate else { return }
        composeFinisher?()
        flushDraft()
        editingID = nil
        let t = newReminderTarget(destination)
        composing = Reminder(id: "NEW-" + UUID().uuidString, listID: t.listID ?? snap.defaultListID ?? "", title: "",
                             isCompleted: false, priority: 0,
                             due: Due.components(clock.today, allDay: true, timeZone: nil, clock: clock), alarms: [])
    }

    /// Creates the composed reminder (if it got a title) and closes the card. Safe to call twice.
    func finishCompose(_ d: Reminder, undo um: UndoManager?) {
        guard composing?.id == d.id else { return }
        composing = nil
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let notes = (d.notes ?? "").isEmpty ? nil : d.notes
        create(ReminderEdit(title: title, notes: notes.map { .some($0) }, priority: d.priority == 0 ? nil : d.priority,
                            due: .some(d.due), recurrence: d.recurrence.map { .some($0) },
                            location: d.alarms.compactMap(\.location).first.map { .some($0) }),
               listID: list(d.listID) != nil ? d.listID : nil, undo: um)
    }

    /// Days with open reminders (dots in the date picker).
    var dueDays: Set<Date> {
        Set(live.lazy.filter { !$0.isCompleted }.compactMap { $0.due.flatMap { Due.day($0, clock: self.clock) } })
    }

    /// Saves typed draft text (if any) and closes the draft row.
    func flushDraft() {
        guard let d = draft else { return }
        draft = nil
        create(title: d.text, listID: d.listID, due: d.due, undo: NSApp.keyWindow?.undoManager)
    }

    /// Quit: commit the open card and draft, finish queued ops, flush pending deletes.
    func drain() async {
        commitOpenCard?()
        composeFinisher?()
        flushDraft()
        await tail?.value
        await flushDeletes()
    }

    func saveOrphanedDraft(undo um: UndoManager?) {
        guard let o = orphanedDraft else { return }
        orphanedDraft = nil
        create(ReminderEdit(title: o.title.isEmpty ? "Untitled" : o.title, notes: .some(o.notes), due: .some(o.due)),
               listID: list(o.listID) != nil ? o.listID : nil, undo: um)
    }

    var showCompletedApplies: Bool { if case .list = destination { true } else { false } }

    func toggleShowCompleted() {
        let key: String
        switch destination {
        case .list(let id): key = id
        default: return
        }
        if showCompleted.contains(key) { showCompleted.remove(key) } else { showCompleted.insert(key) }
    }

    /// ⌘1…9: visible smart lists, then pinned lists (Reminders maps ⌘1…9 to pinned items).
    var shortcutDestinations: [Destination] {
        let smart: [Destination] = [.today, .scheduled, .all, .flagged, .completed, .assigned, .urgent]
        return smart.filter { isAvailable($0) && !hiddenSmartLists.contains(title($0)) } + pinnedLists.map { .list($0.id) }
    }

    // MARK: List ops

    func createList(title: String, color: RGBA, accountID: String?) {
        enqueue {
            do {
                let id = try await self.backend.createList(title: title, color: color, accountID: accountID)
                await self.reload()
                self.destination = .list(id)
            } catch { self.fail(error) }
        }
    }

    func updateList(_ id: String, title: String? = nil, color: RGBA? = nil, undo um: UndoManager?) {
        guard let old = list(id) else { return }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in
            self.updateList(id, title: title == nil ? nil : old.title, color: color == nil ? nil : old.color, undo: um)
        }
        um?.setActionName(title != nil ? "Rename List" : "Change Color")
        enqueue {
            do { try await self.backend.updateList(id, title: title, color: color); await self.reload() }
            catch { self.fail(error); um?.removeAllActions(withTarget: token) }
        }
    }

    /// Shows the delete confirmation with the real count (completed reminders included).
    func prepareListDelete(_ l: RList) {
        listDeleteCount = nil
        listToDelete = l
        Task { listDeleteCount = try? await backend.reminderCount(inList: l.id) }
    }

    /// With a target, every reminder (completed too) is moved first and the list is kept if any move fails;
    /// otherwise EventKit deletes the reminders with the list. Not undoable — confirmed with counts instead (R10).
    func deleteList(_ id: String, moveRemindersTo target: String?) {
        enqueue {
            do {
                try await self.backend.deleteList(id, moveTo: target)
                if self.destination == .list(id) { self.destination = .today }
            } catch { self.fail(error) }
            await self.reload()
        }
    }

    // MARK: Open in Reminders

    func openInReminders(reminder id: String) {
        NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")!)
    }
    func openInReminders(list id: String) {
        NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://REMCDList/\(id)")!)
    }
}
