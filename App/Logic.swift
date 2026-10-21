import EventKit
import Foundation

// Pure functions. Everything that depends on "now" or the user's calendar takes a Clock.

struct Clock: Sendable {
    var now: Date
    var cal: Calendar            // Gregorian, user's time zone / first weekday

    static var current: Clock {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.locale = .current
        cal.firstWeekday = Calendar.current.firstWeekday
        return Clock(now: Date(), cal: cal)
    }
    var today: Date { cal.startOfDay(for: now) }
}

// MARK: - Due dates (R3)

enum Due {
    static let gregorian = Calendar(identifier: .gregorian)

    /// Date-only → floating {y,m,d}. Timed → {y,m,d,h,min} in `timeZone` (existing zone, else current).
    static func components(_ date: Date, allDay: Bool, timeZone: TimeZone?, clock: Clock = .current) -> DateComponents {
        var cal = gregorian
        cal.timeZone = allDay ? clock.cal.timeZone : (timeZone ?? clock.cal.timeZone)
        var c = cal.dateComponents(allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: date)
        c.calendar = gregorian
        c.timeZone = allDay ? nil : cal.timeZone
        return c
    }

    static func isAllDay(_ c: DateComponents) -> Bool { c.hour == nil }

    /// Resolves with Gregorian and (tz ?? current). All-day resolves to local midnight.
    static func date(_ c: DateComponents, clock: Clock = .current) -> Date? {
        var cal = gregorian
        cal.timeZone = c.timeZone ?? clock.cal.timeZone
        var plain = DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
        if isAllDay(c) { plain.hour = 0; plain.minute = 0 }
        return cal.date(from: plain)
    }

    /// Local start of the due day (bucketing).
    static func day(_ c: DateComponents, clock: Clock) -> Date? {
        guard let d = date(c, clock: clock) else { return nil }
        return clock.cal.startOfDay(for: d)
    }

    /// Same calendar day, keeping the time of `c` if it has one.
    static func moving(_ c: DateComponents?, toDay day: Date, clock: Clock) -> DateComponents {
        guard let c, !isAllDay(c) else { return components(day, allDay: true, timeZone: nil, clock: clock) }
        var parts = clock.cal.dateComponents([.year, .month, .day], from: day)
        parts.hour = c.hour; parts.minute = c.minute
        let d = clock.cal.date(from: parts) ?? day
        return components(d, allDay: false, timeZone: c.timeZone, clock: clock)
    }

    // Reminders' "Mark Due Date As" targets.
    static func tomorrow(_ clock: Clock) -> Date { clock.cal.date(byAdding: .day, value: 1, to: clock.today)! }
    /// Next Saturday strictly after today. ponytail: verify against Reminders' ⌘K on a Friday (S-check in SPIKES.md).
    static func thisWeekend(_ clock: Clock) -> Date {
        clock.cal.nextDate(after: clock.today, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!
    }
    /// First day of next week (respects firstWeekday).
    static func nextWeek(_ clock: Clock) -> Date {
        clock.cal.nextDate(after: clock.today, matching: DateComponents(weekday: clock.cal.firstWeekday), matchingPolicy: .nextTime)!
    }
}

// MARK: - Alarms (R2)

enum AlarmPlan {
    static func near(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) <= 60 }

    /// New absolute (non-location) alarm dates after changing the due date from `old` to `new`.
    static func shifted(_ absolutes: [Date], from old: DateComponents?, to new: DateComponents?, clock: Clock) -> [Date] {
        guard old != new else { return absolutes }
        let o = old.flatMap { Due.date($0, clock: clock) }, n = new.flatMap { Due.date($0, clock: clock) }
        let oTimed = old.map { !Due.isAllDay($0) } ?? false, nTimed = new.map { !Due.isAllDay($0) } ?? false
        func addingDue(_ list: [Date]) -> [Date] {
            guard nTimed, let n, !list.contains(where: { near($0, n) }) else { return list }
            return list + [n]
        }
        switch (o, n) {
        case (nil, nil): return absolutes
        case (nil, _): return addingDue(absolutes)
        case (let o?, nil): return absolutes.filter { !(oTimed && near($0, o)) }
        case (let o?, let n?):
            if oTimed && nTimed { return absolutes.map { $0.addingTimeInterval(n.timeIntervalSince(o)) } }
            let days = clock.cal.dateComponents([.day], from: clock.cal.startOfDay(for: o), to: clock.cal.startOfDay(for: n)).day ?? 0
            let kept = oTimed ? absolutes.filter { !near($0, o) } : absolutes
            return addingDue(kept.map { clock.cal.date(byAdding: .day, value: days, to: $0)! })
        }
    }
}

// MARK: - Priority (R4)

enum Priority: Int, CaseIterable, Sendable {
    case none, low, medium, high
    init(raw: Int) {
        switch raw {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
    var raw: Int { [0, 9, 5, 1][rawValue] }
    var marks: String { String(repeating: "!", count: rawValue) }
    var label: String { ["None", "Low", "Medium", "High"][rawValue] }
}

// MARK: - Smart lists

enum TodayBucket: Int, Comparable, CaseIterable, Sendable {
    case overdue, today, allDay, morning, afternoon, tonight
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var title: String { ["Overdue", "Today", "All-Day", "Morning", "Afternoon", "Tonight"][rawValue] }
    /// Time set when dropping into a Group-by-Time section (Reminders' 9/15/18 convention).
    var dropHour: Int? { [nil, nil, nil, 9, 15, 18][rawValue] }
}

enum ScheduledBucket: Hashable, Comparable, Sendable {
    case overdue, day(Date), month(Date)
    static func < (a: Self, b: Self) -> Bool { a.sortKey < b.sortKey }
    private var sortKey: Date {
        switch self { case .overdue: .distantPast; case .day(let d), .month(let d): d }
    }
}

enum Smart {
    static func isOverdue(_ r: Reminder, _ clock: Clock) -> Bool {
        guard !r.isCompleted, let c = r.due else { return false }
        if Due.isAllDay(c) { return (Due.day(c, clock: clock) ?? .distantFuture) < clock.today }
        return (Due.date(c, clock: clock) ?? .distantFuture) < clock.now
    }

    /// Today = due today plus everything overdue.
    static func inToday(_ r: Reminder, _ clock: Clock) -> Bool {
        guard !r.isCompleted, let c = r.due, let day = Due.day(c, clock: clock) else { return false }
        return day <= clock.today
    }

    static func todayBucket(_ r: Reminder, _ clock: Clock, groupByTime: Bool) -> TodayBucket {
        guard let c = r.due, let day = Due.day(c, clock: clock) else { return .today }
        if day < clock.today { return .overdue }
        guard groupByTime else { return .today }
        guard let h = c.hour else { return .allDay }
        return h < 12 ? .morning : h < 17 ? .afternoon : .tonight
    }

    static func scheduledBucket(_ r: Reminder, _ clock: Clock) -> ScheduledBucket? {
        guard !r.isCompleted, let c = r.due, let day = Due.day(c, clock: clock) else { return nil }
        if day < clock.today { return .overdue }
        let days = clock.cal.dateComponents([.day], from: clock.today, to: day).day ?? 0
        if days < 7 { return .day(day) }
        let m = clock.cal.dateComponents([.year, .month], from: day)
        return .month(clock.cal.date(from: m)!)
    }

    /// The always-visible day sections in Scheduled (drop targets): today … today+6.
    static func scheduledDays(_ clock: Clock) -> [ScheduledBucket] {
        (0..<7).map { .day(clock.cal.date(byAdding: .day, value: $0, to: clock.today)!) }
    }
}

// MARK: - Sorting

enum Sorting {
    /// Reminders' sortingStyle strings (REMSortingStyle* values; confirmed by dlsym at runtime).
    static let styles: [(value: String, label: String)] = [
        ("manual", "Manual"), ("displayDate_asc", "Due Date (Oldest First)"), ("displayDate_desc", "Due Date (Newest First)"),
        ("creationDate_asc", "Creation Date (Oldest First)"), ("creationDate_desc", "Creation Date (Newest First)"),
        ("priority_desc", "Priority (Highest First)"), ("priority_asc", "Priority (Lowest First)"),
        ("title_asc", "Title (A–Z)"), ("title_desc", "Title (Z–A)"),
    ]

    static func sorted(_ rs: [Reminder], style: String?, manual: [String], clock: Clock) -> [Reminder] {
        let created: (Reminder, Reminder) -> Bool = { ($0.created ?? .distantPast, $0.id) < ($1.created ?? .distantPast, $1.id) }
        let dueKey: (Reminder) -> Date = { r in r.due.flatMap { Due.date($0, clock: clock) } ?? .distantFuture }
        let rank: (Reminder) -> Int = { Priority(raw: $0.priority).rawValue }
        switch style ?? "manual" {
        case "displayDate_asc": return rs.sorted { (dueKey($0), $0.id) < (dueKey($1), $1.id) }
        case "displayDate_desc":
            let k: (Reminder) -> Date = { $0.due == nil ? .distantPast : dueKey($0) }   // undated last
            return rs.sorted { k($0) != k($1) ? k($0) > k($1) : $0.id < $1.id }
        case "creationDate_asc": return rs.sorted(by: created)
        case "creationDate_desc": return rs.sorted { created($1, $0) }
        case "priority_desc": return rs.sorted { (rank($0), $1.id) > (rank($1), $0.id) }
        case "priority_asc": return rs.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
        case "title_asc": return rs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "title_desc": return rs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        default:
            // Manual / default: Reminders' manual order, then reminders not yet merged into it by (created, id).
            let index = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return rs.sorted {
                switch (index[$0.id], index[$1.id]) {
                case let (a?, b?): a < b
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): created($0, $1)
                }
            }
        }
    }

    /// Smart lists: due date, then priority (high first), then title.
    static func smart(_ rs: [Reminder], clock: Clock) -> [Reminder] {
        rs.sorted {
            let a = $0.due.flatMap { Due.date($0, clock: clock) } ?? .distantFuture
            let b = $1.due.flatMap { Due.date($0, clock: clock) } ?? .distantFuture
            if a != b { return a < b }
            let pa = Priority(raw: $0.priority).rawValue, pb = Priority(raw: $1.priority).rawValue
            if pa != pb { return pa > pb }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

// MARK: - Recurrence ↔ EKRecurrenceRule

enum RepeatPreset: String, CaseIterable, Sendable {
    case never = "Never", daily = "Daily", weekdays = "Weekdays", weekends = "Weekends", weekly = "Weekly"
    case biweekly = "Biweekly", monthly = "Monthly", every3Months = "Every 3 Months", every6Months = "Every 6 Months"
    case yearly = "Yearly", custom = "Custom"

    func recurrence() -> Recurrence? {
        switch self {
        case .never, .custom: nil
        case .daily: Recurrence(frequency: .daily)
        case .weekdays: Recurrence(frequency: .weekly, weekdays: (2...6).map { .init(day: $0) })
        case .weekends: Recurrence(frequency: .weekly, weekdays: [.init(day: 1), .init(day: 7)])
        case .weekly: Recurrence(frequency: .weekly)
        case .biweekly: Recurrence(frequency: .weekly, interval: 2)
        case .monthly: Recurrence(frequency: .monthly)
        case .every3Months: Recurrence(frequency: .monthly, interval: 3)
        case .every6Months: Recurrence(frequency: .monthly, interval: 6)
        case .yearly: Recurrence(frequency: .yearly)
        }
    }

    init(_ r: Recurrence?) {
        guard var r else { self = .never; return }
        r.end = nil
        self = Self.allCases.first { $0.recurrence() == r } ?? .custom
    }
}

enum RecurrenceMap {
    static func rule(_ r: Recurrence) -> EKRecurrenceRule {
        let end: EKRecurrenceEnd? = switch r.end {
        case .date(let d): EKRecurrenceEnd(end: d)
        case .count(let n): EKRecurrenceEnd(occurrenceCount: max(1, n))
        case nil: nil
        }
        let freq: EKRecurrenceFrequency = [.daily, .weekly, .monthly, .yearly][r.frequency.rawValue]
        return EKRecurrenceRule(
            recurrenceWith: freq, interval: max(1, r.interval),
            daysOfTheWeek: r.weekdays.isEmpty ? nil : r.weekdays.map {
                // weekNumber must be 0 for weekly rules (EK raises otherwise).
                EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0.day)!, weekNumber: r.frequency == .weekly ? 0 : $0.week)
            },
            daysOfTheMonth: r.monthDays.isEmpty ? nil : r.monthDays.map { NSNumber(value: $0) },
            monthsOfTheYear: r.months.isEmpty ? nil : r.months.map { NSNumber(value: $0) },
            weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: r.setPositions.isEmpty ? nil : r.setPositions.map { NSNumber(value: $0) },
            end: end)
    }

    static func recurrence(_ rule: EKRecurrenceRule) -> Recurrence {
        let freq: Recurrence.Frequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        @unknown default: .daily
        }
        var end: Recurrence.End?
        if let e = rule.recurrenceEnd { end = e.endDate.map { .date($0) } ?? (e.occurrenceCount > 0 ? .count(e.occurrenceCount) : nil) }
        return Recurrence(
            frequency: freq, interval: rule.interval,
            weekdays: (rule.daysOfTheWeek ?? []).map { .init(day: $0.dayOfTheWeek.rawValue, week: $0.weekNumber) },
            monthDays: (rule.daysOfTheMonth ?? []).map(\.intValue),
            months: (rule.monthsOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            end: end)
    }

    static func describe(_ r: Recurrence?, hourly: Bool = false) -> String? {
        if hourly { return "Hourly" }
        guard let r else { return nil }
        let p = RepeatPreset(r)
        if p != .custom {
            return r.end == nil ? p.rawValue : "\(p.rawValue), until…"
        }
        let unit = ["day", "week", "month", "year"][r.frequency.rawValue]
        return r.interval == 1 ? "Every \(unit)" : "Every \(r.interval) \(unit)s"
    }
}

// MARK: - Edits (R11 base-diff)

enum Edits {
    /// Keys the user changed between the card's base snapshot and the draft.
    static func diff(base: Reminder, draft: Reminder) -> ReminderEdit {
        var e = ReminderEdit()
        if draft.title != base.title { e.title = draft.title }
        if (draft.notes ?? "") != (base.notes ?? "") { e.notes = .some(draft.notes?.isEmpty == true ? nil : draft.notes) }
        if draft.isCompleted != base.isCompleted { e.isCompleted = draft.isCompleted }
        if Priority(raw: draft.priority) != Priority(raw: base.priority) { e.priority = draft.priority }
        if draft.due != base.due { e.due = .some(draft.due) }
        if draft.recurrence != base.recurrence { e.recurrence = .some(draft.recurrence) }
        let loc: (Reminder) -> LocationAlarm? = { $0.alarms.compactMap(\.location).first }
        if loc(draft) != loc(base) { e.location = .some(loc(draft)) }
        if draft.listID != base.listID { e.listID = draft.listID }
        return e
    }

    /// The value a reminder will have after `e` (used to build undo inverses).
    static func applied(_ e: ReminderEdit, to r: Reminder) -> Reminder {
        var r = r
        if let t = e.title { r.title = t }
        if let n = e.notes { r.notes = n }
        if let c = e.isCompleted { r.isCompleted = c }
        if let p = e.priority { r.priority = Priority(raw: p).raw }
        if let d = e.due { r.due = d }
        if let rec = e.recurrence { r.recurrence = rec }
        if let loc = e.location {
            r.alarms.removeAll { $0.location != nil }
            if let loc { r.alarms.append(Alarm(location: loc)) }
        }
        if let l = e.listID { r.listID = l }
        return r
    }

    /// Edited keys whose fresh value no longer equals the base: another device changed them meanwhile.
    static func conflicts(_ e: ReminderEdit, base: Reminder, fresh: Reminder) -> [String] {
        var out: [String] = []
        if e.title != nil, fresh.title != base.title { out.append("title") }
        if e.notes != nil, (fresh.notes ?? "") != (base.notes ?? "") { out.append("notes") }
        if e.priority != nil, fresh.priority != base.priority { out.append("priority") }
        if e.due != nil, fresh.due != base.due { out.append("date") }
        if e.recurrence != nil, fresh.recurrence != base.recurrence { out.append("repeat") }
        if e.listID != nil, fresh.listID != base.listID { out.append("list") }
        return out
    }

    /// Takes another device's changes into an open card for keys the user hasn't touched (R11).
    static func rebase(base: Reminder, draft: Reminder, fresh: Reminder) -> (base: Reminder, draft: Reminder) {
        var b = base, d = draft
        func adopt<T: Equatable>(_ kp: WritableKeyPath<Reminder, T>) {
            if d[keyPath: kp] == b[keyPath: kp] { d[keyPath: kp] = fresh[keyPath: kp]; b[keyPath: kp] = fresh[keyPath: kp] }
        }
        adopt(\.title); adopt(\.notes); adopt(\.isCompleted); adopt(\.priority); adopt(\.due)
        adopt(\.recurrence); adopt(\.alarms); adopt(\.listID)
        b.extras = fresh.extras; d.extras = fresh.extras
        b.completionDate = fresh.completionDate; d.completionDate = fresh.completionDate
        b.modified = fresh.modified; d.modified = fresh.modified
        return (b, d)
    }

    /// Case-insensitive tag delta; never adds duplicates.
    static func tagDelta(base: [String], edited: [String]) -> (add: [String], remove: [String]) {
        let b = Set(base.map { $0.lowercased() }), d = Set(edited.map { $0.lowercased() })
        var seen = Set<String>()
        let add = edited.filter { !b.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        let remove = base.filter { !d.contains($0.lowercased()) }
        return (add, remove)
    }
}

// MARK: - Display

enum Display {
    static func duePill(_ c: DateComponents, clock: Clock) -> (text: String, overdue: Bool) {
        guard let d = Due.date(c, clock: clock), let day = Due.day(c, clock: clock) else { return ("", false) }
        let days = clock.cal.dateComponents([.day], from: clock.today, to: day).day ?? 0
        let dayText: String
        switch days {
        case 0: dayText = "Today"
        case 1: dayText = "Tomorrow"
        case -1: dayText = "Yesterday"
        case 2...6: dayText = d.formatted(.dateTime.weekday(.abbreviated))
        default:
            let sameYear = clock.cal.component(.year, from: d) == clock.cal.component(.year, from: clock.now)
            dayText = sameYear ? d.formatted(.dateTime.month(.abbreviated).day()) : d.formatted(.dateTime.month(.abbreviated).day().year())
        }
        let time = Due.isAllDay(c) ? "" : " " + d.formatted(date: .omitted, time: .shortened)
        let r = Reminder(id: "", listID: "", title: "", isCompleted: false, priority: 0, due: c, alarms: [])
        return (dayText + time, Smart.isOverdue(r, clock))
    }

    static func matches(_ r: Reminder, query: String, listTitle: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return r.title.localizedStandardContains(q) || (r.notes ?? "").localizedStandardContains(q)
            || listTitle.localizedStandardContains(q) || (r.extras?.tags ?? []).contains { $0.localizedStandardContains(q) }
    }
}

// MARK: - Calendar layout

enum CalendarLayout {
    /// Time for a drop at `y` points into a day column, snapped to 15 minutes.
    static func dropTime(y: CGFloat, hourHeight: CGFloat, day: Date, clock: Clock) -> Date {
        let minutes = max(0, min(24 * 60 - 15, Int((y / hourHeight * 60 / 15).rounded()) * 15))
        return clock.cal.date(byAdding: .minute, value: minutes, to: clock.cal.startOfDay(for: day))!
    }

    /// Side-by-side columns for overlapping items: id → (column, columns in its overlap cluster).
    static func columns(_ items: [(id: String, start: Date, end: Date)]) -> [String: (col: Int, of: Int)] {
        var out: [String: (col: Int, of: Int)] = [:]
        var cluster: [(id: String, col: Int)] = []
        var colEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            for c in cluster { out[c.id] = (c.col, colEnds.count) }
            cluster = []; colEnds = []
        }
        for item in items.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if item.start >= clusterEnd { flush() }
            let col = colEnds.firstIndex { $0 <= item.start } ?? colEnds.count
            if col == colEnds.count { colEnds.append(item.end) } else { colEnds[col] = item.end }
            cluster.append((item.id, col))
            clusterEnd = max(clusterEnd, item.end)
        }
        flush()
        return out
    }

    static func week(containing d: Date, clock: Clock) -> [Date] {
        let start = clock.cal.dateInterval(of: .weekOfYear, for: d)?.start ?? clock.cal.startOfDay(for: d)
        return (0..<7).map { clock.cal.date(byAdding: .day, value: $0, to: start)! }
    }

    /// Whole weeks covering the month of `d`.
    static func month(containing d: Date, clock: Clock) -> [Date] {
        guard let m = clock.cal.dateInterval(of: .month, for: d) else { return [] }
        var day = week(containing: m.start, clock: clock)[0]
        var out: [Date] = []
        while day < m.end || out.count % 7 != 0 {
            out.append(day)
            day = clock.cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }
}
