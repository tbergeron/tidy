import Foundation

/// Finds dates, times and repeats written in a reminder title ("Do dishes tonight", "Pay rent every month on the 1st",
/// "Call mom tomorrow at 5pm") and turns them into a due date + recurrence. Deterministic and English-only.
/// Day-level phrases land at 9:00 (tonight 21:00, this evening 18:00, this afternoon 15:00); "today" alone is all-day.
enum NaturalDate {
    struct Detection: Equatable {
        var ranges: [NSRange]          // in the original title (UTF-16), for highlighting
        var due: DateComponents?
        var recurrence: Recurrence?
        var hourly = false             // "every hour": detected, but EventKit can't write hourly repeats
        var cleanedTitle: String       // the title without the detected words
        /// Identity of what was matched (to tell a new detection from the same one re-parsed).
        var key: String
    }

    static func parse(_ title: String, clock: Clock) -> Detection? {
        var p = Parser(text: title, clock: clock)
        return p.run()
    }

    // MARK: - Vocabulary

    static let weekdayNames: [(pattern: String, day: Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
    ]
    static let weekdayAbbrev: [(pattern: String, day: Int)] = [
        ("sun", 1), ("mon", 2), ("tues?", 3), ("wed", 4), ("thu(?:rs?)?", 5), ("fri", 6), ("sat", 7),
    ]
    static let months = ["jan(?:uary)?", "feb(?:ruary)?", "mar(?:ch)?", "apr(?:il)?", "may", "june?", "july?", "aug(?:ust)?",
                         "sep(?:t(?:ember)?)?", "oct(?:ober)?", "nov(?:ember)?", "dec(?:ember)?"]
    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
        "a couple of": 2, "a couple": 2, "couple of": 2, "a few": 3, "few": 3, "other": 2,
    ]
    static let number = #"(\d+|other|a couple(?: of)?|couple of|a few|few|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty)"#

    static func value(_ s: String) -> Int? { Int(s) ?? numberWords[s.lowercased()] }
}

private struct Parser {
    let text: String
    let clock: Clock
    let ns: NSString
    var taken: [NSRange] = []

    init(text: String, clock: Clock) {
        self.text = text
        self.clock = clock
        ns = text as NSString
    }

    // Parsed pieces
    var recurrence: Recurrence?
    var hourly = false
    var recurrenceTime: (Int, Int)?          // every morning → 9:00 …
    var day: Date?                            // start of a day
    var dayTime: (Int, Int)?                  // default time that came with the day phrase (nil = all-day if no time)
    var exact: Date?                          // in 20 minutes / in 2 hours
    var time: (Int, Int)?                     // explicit time
    var dayIsToday = false                    // "today": all-day unless a time is given

    mutating func run() -> NaturalDate.Detection? {
        matchRecurrence()
        matchRelative()
        matchAbsolute()
        matchTime()
        guard !taken.isEmpty else { return nil }

        var due: DateComponents?
        if let exact {
            due = Due.components(exact, allDay: false, timeZone: nil, clock: clock)
        } else if day != nil || time != nil || recurrence != nil || hourly {
            let t = time ?? dayTime ?? recurrenceTime
            var d = day ?? firstOccurrence(time: t ?? (23, 59))   // no time: today still counts
            if day == nil, recurrence == nil, let t, at(d, t) <= clock.now {   // a bare time already past → tomorrow
                d = clock.cal.date(byAdding: .day, value: 1, to: d)!
            }
            if let t {
                due = Due.components(at(d, t), allDay: false, timeZone: nil, clock: clock)
            } else if dayIsToday || recurrence != nil {
                due = Due.components(d, allDay: true, timeZone: nil, clock: clock)
            } else {
                due = Due.components(at(d, (9, 0)), allDay: false, timeZone: nil, clock: clock)
            }
        }

        let sorted = taken.sorted { $0.location < $1.location }
        let key = sorted.map { ns.substring(with: $0).lowercased() }.joined(separator: "|")
        return NaturalDate.Detection(ranges: sorted, due: due, recurrence: hourly ? nil : recurrence, hourly: hourly,
                                     cleanedTitle: cleaned(sorted), key: key)
    }

    // MARK: Matching helpers

    /// First case-insensitive whole-word match that doesn't overlap something already taken.
    mutating func find(_ pattern: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\w])"# + pattern + #"(?![\w])"#, options: [.caseInsensitive]) else { return nil }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                taken.append(m.range)
                return m
            }
        }
        return nil
    }

    func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
        guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: i)).lowercased()
    }

    func at(_ day: Date, _ t: (Int, Int)) -> Date {
        clock.cal.date(bySettingHour: t.0, minute: t.1, second: 0, of: clock.cal.startOfDay(for: day)) ?? day
    }
    func plus(_ c: Calendar.Component, _ n: Int, _ from: Date? = nil) -> Date {
        clock.cal.date(byAdding: c, value: n, to: from ?? clock.today)!
    }
    /// The next given weekday strictly after today.
    func next(weekday: Int) -> Date {
        clock.cal.nextDate(after: clock.today, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)!
    }

    // MARK: Repeats

    mutating func matchRecurrence() {
        let units = #"(minute|min|hour|hr|day|week|month|year)s?"#
        if let m = find(#"(?:every|each)\s+(?:"# + NaturalDate.number + #"\s+)?"# + units) {
            let n = group(m, 1).flatMap(NaturalDate.value) ?? 1
            setRecurrence(unit: group(m, 2) ?? "day", interval: n)
            return
        }
        if let m = find(#"(daily|weekly|monthly|yearly|annually|hourly)"#) {
            let unit = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year", "annually": "year", "hourly": "hour"]
            setRecurrence(unit: unit[group(m, 1) ?? ""] ?? "day", interval: 1)
            return
        }
        if let m = find(#"(?:every|each)\s+(weekday|weekend)s?"#) {
            let days = group(m, 1) == "weekday" ? Array(2...6) : [1, 7]
            recurrence = Recurrence(frequency: .weekly, weekdays: days.map { .init(day: $0) })
            return
        }
        if let m = find(#"(?:every|each)\s+(morning|afternoon|evening|night)"#) {
            recurrence = Recurrence(frequency: .daily)
            recurrenceTime = ["morning": (9, 0), "afternoon": (15, 0), "evening": (18, 0), "night": (21, 0)][group(m, 1) ?? ""]
            return
        }
        let names = (NaturalDate.weekdayNames + NaturalDate.weekdayAbbrev).map(\.pattern).joined(separator: "|")
        let one = "(?:\(names))s?"
        if let m = find(#"(?:every|each)\s+("# + one + #"(?:\s*(?:,|and|&|,\s*and)\s*"# + one + ")*)") {
            let list = group(m, 1) ?? ""
            var days: [Int] = []
            for (pattern, d) in NaturalDate.weekdayNames + NaturalDate.weekdayAbbrev {
                if list.range(of: #"(?<![\w])"# + pattern + #"s?(?![\w])"#, options: [.regularExpression, .caseInsensitive]) != nil, !days.contains(d) {
                    days.append(d)
                }
            }
            recurrence = Recurrence(frequency: .weekly, weekdays: days.sorted().map { .init(day: $0) })
        }
    }

    mutating func setRecurrence(unit: String, interval: Int) {
        switch unit {
        case "minute", "min", "hour", "hr": hourly = true
        case "week": recurrence = Recurrence(frequency: .weekly, interval: interval)
        case "month": recurrence = Recurrence(frequency: .monthly, interval: interval)
        case "year": recurrence = Recurrence(frequency: .yearly, interval: interval)
        default: recurrence = Recurrence(frequency: .daily, interval: interval)
        }
    }

    /// First due date of a repeat with no explicit day: today if the time hasn't passed (and the weekday fits), else the next fit.
    func firstOccurrence(time t: (Int, Int)) -> Date {
        let days = Set(recurrence?.weekdays.map(\.day) ?? [])
        for offset in 0..<8 {
            let d = plus(.day, offset)
            let fitsDay = days.isEmpty || days.contains(clock.cal.component(.weekday, from: d))
            if fitsDay && (offset > 0 || at(d, t) > clock.now || recurrence == nil) { return d }
        }
        return clock.today
    }

    // MARK: Relative days

    mutating func matchRelative() {
        if day != nil || exact != nil { return }
        if find(#"(?:the\s+)?day\s+after\s+tomorrow"#) != nil { day = plus(.day, 2); return }
        if let m = find(#"(?:tomorrow|tmrw|tmr)(?:\s+(morning|afternoon|evening|night))?"#) {
            day = plus(.day, 1)
            dayTime = partOfDay(group(m, 1)) ?? (9, 0)
            return
        }
        if find(#"tonight"#) != nil { day = clock.today; dayTime = (21, 0); return }
        if let m = find(#"this\s+(morning|afternoon|evening)"#) { day = clock.today; dayTime = partOfDay(group(m, 1)); return }
        if find(#"today"#) != nil { day = clock.today; dayIsToday = true; return }
        if let m = find(#"(this|next)\s+weekend"#) {
            let saturday = next(weekday: 7)
            day = group(m, 1) == "next" ? plus(.day, 7, saturday) : saturday
            dayTime = (9, 0)
            return
        }
        if let m = find(#"next\s+(week|month|year)"#) {
            day = ["week": plus(.day, 7), "month": plus(.month, 1), "year": plus(.year, 1)][group(m, 1) ?? "week"]
            dayTime = (9, 0)
            return
        }
        let units = #"(minute|min|m|hour|hr|h|day|d|week|wk|w|month|mo|year|yr|y)s?"#
        if let m = find(#"in\s+(half\s+an?\s+hour|"# + NaturalDate.number + #"\s*"# + units + ")") {
            if group(m, 1)?.hasPrefix("half") == true { exact = clock.now.addingTimeInterval(1800); return }
            applyOffset(n: group(m, 2).flatMap(NaturalDate.value) ?? 1, unit: group(m, 3) ?? "d")
            return
        }
        if let m = find(NaturalDate.number + #"\s+(day|week|month|year)s?\s+from\s+now"#) {
            applyOffset(n: group(m, 1).flatMap(NaturalDate.value) ?? 1, unit: group(m, 2) ?? "d")
            return
        }
        for (pattern, d) in NaturalDate.weekdayNames {
            if find(#"(?:(?:on|this|next)\s+)?"# + pattern) != nil { day = next(weekday: d); dayTime = (9, 0); return }
        }
        for (pattern, d) in NaturalDate.weekdayAbbrev {
            if find(#"(?:on|this|next)\s+"# + pattern + #"\.?"#) != nil { day = next(weekday: d); dayTime = (9, 0); return }
        }
    }

    mutating func applyOffset(n: Int, unit: String) {
        switch unit {
        case "minute", "min", "m": exact = clock.now.addingTimeInterval(Double(n) * 60)
        case "hour", "hr", "h": exact = clock.now.addingTimeInterval(Double(n) * 3600)
        case "week", "wk", "w": day = plus(.day, 7 * n); dayTime = (9, 0)
        case "month", "mo": day = plus(.month, n); dayTime = (9, 0)
        case "year", "yr", "y": day = plus(.year, n); dayTime = (9, 0)
        default: day = plus(.day, n); dayTime = (9, 0)
        }
    }

    func partOfDay(_ s: String?) -> (Int, Int)? {
        ["morning": (9, 0), "afternoon": (15, 0), "evening": (18, 0), "night": (21, 0)][s ?? ""]
    }

    // MARK: Absolute dates

    mutating func matchAbsolute() {
        if day != nil || exact != nil { return }
        let months = NaturalDate.months.enumerated().map { "(\($0.element))" }.joined(separator: "|")
        // "oct 28", "October 28th, 2027"
        if let m = find(#"(?:on\s+)?(?:"# + months + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#) {
            let month = (1...12).first { m.range(at: $0).location != NSNotFound } ?? 1
            set(month: month, day: Int(group(m, 13) ?? "") ?? 1, year: group(m, 14).flatMap { Int($0) })
            return
        }
        // "28 oct", "28th of October 2027"
        if let m = find(#"(?:on\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(?:"# + months + #")(?:,?\s+(\d{4}))?"#) {
            let month = (2...13).first { m.range(at: $0).location != NSNotFound }.map { $0 - 1 } ?? 1
            set(month: month, day: Int(group(m, 1) ?? "") ?? 1, year: group(m, 14).flatMap { Int($0) })
            return
        }
        // "10/28", "10/28/2027" (month first)
        if let m = find(#"(?:on\s+)?(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?"#),
           let mo = Int(group(m, 1) ?? ""), let d = Int(group(m, 2) ?? ""), (1...12).contains(mo), (1...31).contains(d) {
            var y = group(m, 3).flatMap { Int($0) }
            if let yy = y, yy < 100 { y = 2000 + yy }
            set(month: mo, day: d, year: y)
            return
        }
        // "on the 15th"
        if let m = find(#"on\s+the\s+(\d{1,2})(?:st|nd|rd|th)"#), let d = Int(group(m, 1) ?? ""), (1...31).contains(d) {
            var c = clock.cal.dateComponents([.year, .month], from: clock.today)
            c.day = d
            var date = clock.cal.date(from: c) ?? clock.today
            if date < clock.today { date = plus(.month, 1, date) }
            day = date
            dayTime = (9, 0)
        }
    }

    mutating func set(month: Int, day d: Int, year: Int?) {
        let thisYear = clock.cal.component(.year, from: clock.today)
        var date = clock.cal.date(from: DateComponents(year: year ?? thisYear, month: month, day: d)) ?? clock.today
        if year == nil, date < clock.today { date = clock.cal.date(byAdding: .year, value: 1, to: date) ?? date }
        day = date
        dayTime = (9, 0)
    }

    // MARK: Times

    mutating func matchTime() {
        if exact != nil { return }
        if let m = find(#"(?:at\s+|@\s*)?(noon|midday|midnight)"#) {
            time = group(m, 1) == "midnight" ? (0, 0) : (12, 0)
            return
        }
        // "5pm", "5:30 pm", "9a" (a single a/p only when attached, so "2 apples" / "2 a day" don't match)
        if let m = find(#"(?:at\s+|@\s*)?(\d{1,2})(?::(\d{2}))?(?:\s*(a\.m\.|p\.m\.|am|pm)|(a|p))"#),
           var h = Int(group(m, 1) ?? ""), h <= 12 {
            let pm = (group(m, 3) ?? group(m, 4))?.hasPrefix("p") == true
            if h == 12 { h = pm ? 12 : 0 } else if pm { h += 12 }
            time = (h, Int(group(m, 2) ?? "") ?? 0)
            return
        }
        if let m = find(#"(?:at\s+|@\s*)(\d{1,2})(?::(\d{2}))?"#) ?? find(#"(\d{1,2}):(\d{2})"#),
           var h = Int(group(m, 1) ?? ""), h < 24 {
            let minute = Int(group(m, 2) ?? "") ?? 0
            if h >= 1 && h <= 7 && group(m, 2) == nil { h += 12 }   // "at 5" means 5 PM
            time = (h, minute)
            return
        }
        if let m = find(#"(?:in\s+the\s+(morning|afternoon|evening)|at\s+(night))"#) {
            time = partOfDay(group(m, 1) ?? group(m, 2))
        }
    }

    // MARK: Cleaned title

    func cleaned(_ ranges: [NSRange]) -> String {
        var out = text as NSString
        for r in ranges.reversed() { out = out.replacingCharacters(in: r, with: " ") as NSString }
        var s = (out as String).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // Connectors left dangling at the end ("Call mom at", "Pay rent on", "Meeting -").
        s = s.replacingOccurrences(of: #"(?i)(?:\s+(?:at|on|by|due|for|from|until|,|-|–))+\s*$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "?!.)\"'"))))
    }
}
