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

    /// Same local day as `day`, keeping the time of `c` as shown on this Mac; stays in the item's own zone.
    static func moving(_ c: DateComponents?, toDay day: Date, clock: Clock) -> DateComponents {
        guard let c, !isAllDay(c) else { return components(day, allDay: true, timeZone: nil, clock: clock) }
        let shown = date(c, clock: clock).map { clock.cal.dateComponents([.hour, .minute], from: $0) }
        var parts = clock.cal.dateComponents([.year, .month, .day], from: day)
        parts.hour = shown?.hour ?? c.hour
        parts.minute = shown?.minute ?? c.minute
        return components(clock.cal.date(from: parts) ?? day, allDay: false, timeZone: c.timeZone, clock: clock)
    }

    /// Same due as far as Reminders is concerned (ignores the calendar/zone objects EK hands back).
    static func same(_ a: DateComponents?, _ b: DateComponents?, clock: Clock = .current) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return isAllDay(a) == isAllDay(b) && date(a, clock: clock) == date(b, clock: clock)
                && (isAllDay(a) || a.timeZone?.identifier == b.timeZone?.identifier)
        default: return false
        }
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

/// Quick times for the reminder context menu's Due submenu.
enum DuePreset: CaseIterable, Sendable {
    case todayMorning, thisEvening, tomorrowMorning, inAWeek

    func date(_ clock: Clock) -> Date {
        let (days, hour) = switch self {
        case .todayMorning: (0, 9)
        case .thisEvening: (0, 18)
        case .tomorrowMorning: (1, 9)
        case .inAWeek: (7, 9)
        }
        let day = clock.cal.date(byAdding: .day, value: days, to: clock.today)!
        return clock.cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!   // wall clock: DST-safe
    }

    var name: String {
        switch self {
        case .todayMorning: "Today"
        case .thisEvening: "This Evening"
        case .tomorrowMorning: "Tomorrow"
        case .inAWeek: "Next Week"
        }
    }

    /// Trailing detail in the date panel: "9:00 AM", "Thu 9:00 AM", "Oct 28, 9:00 AM".
    func detail(_ clock: Clock) -> String {
        let d = date(clock), tz = clock.cal.timeZone
        let time = d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz))
        switch self {
        case .todayMorning, .thisEvening: return time
        case .tomorrowMorning: return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated)) + " " + time
        case .inAWeek: return d.formatted(Date.FormatStyle(timeZone: tz).month(.abbreviated).day()) + ", " + time
        }
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
        guard c.hour != nil, let d = Due.date(c, clock: clock) else { return .allDay }
        let h = clock.cal.component(.hour, from: d)   // local hour, even for items in another zone
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

    /// `due` lets a rule that spells out the due date's own weekday/day (as Reminders.app writes "Weekly")
    /// still count as the plain preset.
    init(_ r: Recurrence?, due: DateComponents? = nil, clock: Clock = .current) {
        guard var r else { self = .never; return }
        r.end = nil
        if let d = due.flatMap({ Due.date($0, clock: clock) }) {
            let c = clock.cal.dateComponents([.weekday, .day, .month], from: d)
            if r.frequency == .weekly, r.weekdays == [.init(day: c.weekday ?? 0)] { r.weekdays = [] }
            if r.frequency == .monthly || r.frequency == .yearly, r.monthDays == [c.day ?? 0], r.weekdays.isEmpty { r.monthDays = [] }
            if r.frequency == .yearly, r.months == [c.month ?? 0] { r.months = [] }
        }
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

    /// "Weekdays", "Every 2 days", "Every month on the last weekday", "Every week on Mon, Wed, 5 times"…
    static func describe(_ r: Recurrence?, hourly: Bool = false, due: DateComponents? = nil, clock: Clock = .current) -> String? {
        if hourly { return "Hourly" }
        guard let r else { return nil }
        let p = RepeatPreset(r, due: due, clock: clock)
        var text = p == .custom || p == .never ? phrase(r, clock: clock) : p.rawValue
        switch r.end {
        case .date(let d): text += ", until " + d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: clock.cal.timeZone))
        case .count(let n): text += n == 1 ? ", once" : ", \(n) times"
        case nil: break
        }
        return text
    }

    static func phrase(_ r: Recurrence, clock: Clock) -> String {
        let unit = ["day", "week", "month", "year"][r.frequency.rawValue]
        var s = r.interval <= 1 ? "Every \(unit)" : "Every \(r.interval) \(unit)s"
        switch r.frequency {
        case .daily: break
        case .weekly: if !r.weekdays.isEmpty { s += " on " + weekdayList(r.weekdays.map(\.day), clock: clock) }
        case .monthly: s += onClause(r, clock: clock)
        case .yearly:
            if !r.months.isEmpty { s += " in " + r.months.sorted().map { clock.cal.shortMonthSymbols[$0 - 1] }.joined(separator: ", ") }
            s += onClause(r, clock: clock)
        }
        return s
    }

    static let ordinals = [1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", -1: "last"]

    private static func onClause(_ r: Recurrence, clock: Clock) -> String {
        if !r.monthDays.isEmpty {
            let f = NumberFormatter()
            f.numberStyle = .ordinal
            return " on the " + r.monthDays.sorted { ($0 < 0 ? 99 : $0) < ($1 < 0 ? 99 : $1) }
                .map { $0 == -1 ? "last day" : (f.string(from: NSNumber(value: $0)) ?? "\($0)") }.joined(separator: ", ")
        }
        guard !r.weekdays.isEmpty else { return "" }
        if let pos = r.setPositions.first {
            return " on the \(ordinals[pos] ?? "\(pos)th") \(dayGroup(Set(r.weekdays.map(\.day)), clock: clock))"
        }
        if r.weekdays.count == 1, let w = r.weekdays.first, w.week != 0 {
            return " on the \(ordinals[w.week] ?? "\(w.week)th") \(weekdayNames(clock)[w.day - 1])"
        }
        return " on " + weekdayList(r.weekdays.map(\.day), clock: clock)
    }

    /// "day", "weekday", "weekend day", or a weekday name.
    static func dayGroup(_ days: Set<Int>, clock: Clock) -> String {
        if days.count == 7 { return "day" }
        if days == Set(2...6) { return "weekday" }
        if days == [1, 7] { return "weekend day" }
        return days.sorted().map { weekdayNames(clock)[$0 - 1] }.joined(separator: ", ")
    }

    /// Full weekday names ("Tuesday") in the user's language.
    static func weekdayNames(_ clock: Clock) -> [String] {
        let f = DateFormatter()
        f.locale = .current
        return f.weekdaySymbols
    }

    private static func weekdayList(_ days: [Int], clock: Clock) -> String {
        let set = Set(days)
        if set == Set(2...6) { return "weekdays" }
        if set == [1, 7] { return "weekends" }
        let order = (0..<7).map { (clock.cal.firstWeekday - 1 + $0) % 7 + 1 }
        return order.filter(set.contains).map { clock.cal.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
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
        if !Due.same(draft.due, base.due) { e.due = .some(draft.due) }
        if draft.recurrence != base.recurrence { e.recurrence = .some(draft.recurrence) }
        let loc: (Reminder) -> LocationAlarm? = { $0.alarms.compactMap(\.location).first }
        if loc(draft) != loc(base) { e.location = .some(loc(draft)) }
        if draft.listID != base.listID { e.listID = draft.listID }
        return e
    }

    /// `e` without the keys named by `conflicts(…)`.
    static func removing(_ keys: [String], from e: ReminderEdit) -> ReminderEdit {
        var e = e
        for k in keys {
            switch k {
            case "title": e.title = nil
            case "notes": e.notes = nil
            case "priority": e.priority = nil
            case "date": e.due = nil
            case "repeat": e.recurrence = nil
            case "list": e.listID = nil
            default: break
            }
        }
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
        if e.priority != nil, Priority(raw: fresh.priority) != Priority(raw: base.priority) { out.append("priority") }
        if e.due != nil, !Due.same(fresh.due, base.due) { out.append("date") }
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

// MARK: - Weeks

enum CalendarLayout {
    static func week(containing d: Date, clock: Clock) -> [Date] {
        let start = clock.cal.dateInterval(of: .weekOfYear, for: d)?.start ?? clock.cal.startOfDay(for: d)
        return (0..<7).map { clock.cal.date(byAdding: .day, value: $0, to: start)! }
    }
}
