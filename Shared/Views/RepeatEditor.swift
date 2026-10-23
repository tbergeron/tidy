import SwiftUI

/// Custom repeat rule, the same options as Reminders' Custom repeat: frequency + interval, weekdays,
/// days of the month or "on the first/…/last <day>", months, and an end.
struct RepeatEditor: View {
    let clock: Clock
    let save: (Recurrence) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var frequency: Recurrence.Frequency
    @State private var interval: Int
    @State private var weekdays: Set<Int>
    @State private var monthMode: MonthMode
    @State private var monthDays: Set<Int>
    @State private var months: Set<Int>
    @State private var yearlyOnThe: Bool
    @State private var ordinal: Int
    @State private var ordinalDay: OrdinalDay
    @State private var endMode: EndMode
    @State private var endDate: Date
    @State private var endCount: Int

    enum MonthMode: Hashable { case each, onThe }
    enum EndMode: Hashable { case never, date, count }
    /// 1…7 = Sunday…Saturday, then the Reminders groups.
    enum OrdinalDay: Hashable {
        case weekday(Int), day, weekdayGroup, weekendDay
        var days: [Int] {
            switch self {
            case .weekday(let d): [d]
            case .day: Array(1...7)
            case .weekdayGroup: Array(2...6)
            case .weekendDay: [1, 7]
            }
        }
    }

    init(recurrence r: Recurrence?, due: Date?, clock: Clock, save: @escaping (Recurrence) -> Void) {
        self.clock = clock
        self.save = save
        let r = r ?? Recurrence(frequency: .daily)
        let d = due ?? clock.now
        let dueWeekday = clock.cal.component(.weekday, from: d)
        _frequency = State(initialValue: r.frequency)
        _interval = State(initialValue: max(1, r.interval))
        _weekdays = State(initialValue: Set(r.frequency == .weekly && !r.weekdays.isEmpty ? r.weekdays.map(\.day) : [dueWeekday]))
        let onThe = !r.weekdays.isEmpty && r.frequency != .weekly
        _monthMode = State(initialValue: onThe ? .onThe : .each)
        _yearlyOnThe = State(initialValue: onThe && r.frequency == .yearly)
        _monthDays = State(initialValue: Set(r.monthDays.isEmpty ? [clock.cal.component(.day, from: d)] : r.monthDays))
        _months = State(initialValue: Set(r.months.isEmpty ? [clock.cal.component(.month, from: d)] : r.months))
        let days = Set(r.weekdays.map(\.day))
        let group: OrdinalDay = days.count == 7 ? .day : days == Set(2...6) ? .weekdayGroup : days == [1, 7] ? .weekendDay
            : .weekday(r.weekdays.first?.day ?? dueWeekday)
        _ordinalDay = State(initialValue: onThe ? group : .weekday(dueWeekday))
        _ordinal = State(initialValue: r.setPositions.first ?? r.weekdays.first.map { $0.week == 0 ? 1 : $0.week } ?? 1)
        switch r.end {
        case .date(let e): _endMode = State(initialValue: .date); _endDate = State(initialValue: e); _endCount = State(initialValue: 5)
        case .count(let n): _endMode = State(initialValue: .count); _endDate = State(initialValue: d); _endCount = State(initialValue: n)
        case nil:
            _endMode = State(initialValue: .never)
            _endDate = State(initialValue: clock.cal.date(byAdding: .month, value: 1, to: d) ?? d)
            _endCount = State(initialValue: 5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Repeat").font(.headline)

            HStack(spacing: 8) {
                Text("Every")
                TextField("", value: $interval, format: .number)
                    .frame(width: 44).multilineTextAlignment(.trailing)
                    .onChange(of: interval) { if interval < 1 { interval = 1 } }
                Stepper("", value: $interval, in: 1...999).labelsHidden()
                Picker("", selection: $frequency) {
                    ForEach(Recurrence.Frequency.allCases, id: \.self) { f in
                        Text((["day", "week", "month", "year"][f.rawValue]) + (interval == 1 ? "" : "s")).tag(f)
                    }
                }
                .labelsHidden().fixedSize()
            }

            switch frequency {
            case .daily: EmptyView()
            case .weekly: weekdayRow
            case .monthly: monthly
            case .yearly: yearly
            }

            Divider()
            HStack(spacing: 8) {
                Text("End")
                Picker("", selection: $endMode) {
                    Text("Never").tag(EndMode.never)
                    Text("On Date").tag(EndMode.date)
                    Text("After").tag(EndMode.count)
                }
                .labelsHidden().fixedSize()
                switch endMode {
                case .never: EmptyView()
                case .date: DatePicker("", selection: $endDate, displayedComponents: .date).labelsHidden().fixedSize()
                case .count:
                    TextField("", value: $endCount, format: .number).frame(width: 44).multilineTextAlignment(.trailing)
                    Stepper("", value: $endCount, in: 1...999).labelsHidden()
                    Text(endCount == 1 ? "time" : "times")
                }
            }

            Text(RecurrenceMap.describe(result, clock: clock) ?? "")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save(result); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    // MARK: Sections

    private var weekdayRow: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { d in
                toggleChip(clock.cal.veryShortStandaloneWeekdaySymbols[d - 1], on: weekdays.contains(d), width: 30) {
                    if weekdays.contains(d) { if weekdays.count > 1 { weekdays.remove(d) } } else { weekdays.insert(d) }
                }
                .help(RecurrenceMap.weekdayNames(clock)[d - 1])
            }
        }
    }

    private var monthly: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $monthMode) {
                Text("Each").tag(MonthMode.each)
                Text("On the…").tag(MonthMode.onThe)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if monthMode == .each { dayGrid } else { onTheRow }
        }
    }

    private var yearly: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(1...12, id: \.self) { m in
                    toggleChip(clock.cal.shortMonthSymbols[m - 1], on: months.contains(m), width: nil) {
                        if months.contains(m) { if months.count > 1 { months.remove(m) } } else { months.insert(m) }
                    }
                }
            }
            Toggle("On the…", isOn: $yearlyOnThe)
            if yearlyOnThe { onTheRow }
        }
    }

    private var dayGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), alignment: .leading, spacing: 4) {
                ForEach(1...31, id: \.self) { d in dayChip(d, "\(d)", width: 34) }
            }
            dayChip(-1, "Last day", width: 80)
        }
    }

    private var onTheRow: some View {
        HStack(spacing: 8) {
            Text("On the")
            Picker("", selection: $ordinal) {
                ForEach([1, 2, 3, 4, 5, -1], id: \.self) { Text(RecurrenceMap.ordinals[$0] ?? "").tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("", selection: $ordinalDay) {
                ForEach(orderedWeekdays, id: \.self) { Text(RecurrenceMap.weekdayNames(clock)[$0 - 1]).tag(OrdinalDay.weekday($0)) }
                Divider()
                Text("day").tag(OrdinalDay.day)
                Text("weekday").tag(OrdinalDay.weekdayGroup)
                Text("weekend day").tag(OrdinalDay.weekendDay)
            }
            .labelsHidden().fixedSize()
        }
    }

    private func dayChip(_ d: Int, _ title: String, width: CGFloat) -> some View {
        toggleChip(title, on: monthDays.contains(d), width: width) {
            if monthDays.contains(d) { if monthDays.count > 1 { monthDays.remove(d) } } else { monthDays.insert(d) }
        }
    }

    private func toggleChip(_ title: String, on: Bool, width: CGFloat?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: width, height: 26).frame(maxWidth: width == nil ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var orderedWeekdays: [Int] { (0..<7).map { (clock.cal.firstWeekday - 1 + $0) % 7 + 1 } }

    // MARK: Result

    var result: Recurrence {
        var r = Recurrence(frequency: frequency, interval: max(1, interval))
        func applyOnThe() {
            let days = ordinalDay.days
            if days.count == 1 { r.weekdays = [.init(day: days[0], week: ordinal)] }
            else { r.weekdays = days.map { .init(day: $0) }; r.setPositions = [ordinal] }
        }
        switch frequency {
        case .daily: break
        case .weekly: r.weekdays = weekdays.sorted().map { .init(day: $0) }
        case .monthly: if monthMode == .each { r.monthDays = monthDays.sorted() } else { applyOnThe() }
        case .yearly:
            r.months = months.sorted()
            if yearlyOnThe { applyOnThe() }
        }
        switch endMode {
        case .never: break
        case .date: r.end = .date(clock.cal.startOfDay(for: endDate))
        case .count: r.end = .count(max(1, endCount))
        }
        return r
    }
}
