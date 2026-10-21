import SwiftUI

/// The date picker used by the card and the context menu: presets on the left, month grid + time on the right.
/// Its size never changes while open (a growing popover gets re-placed by AppKit and jumps across the screen).
/// Edits `due` only; callers write once when the popover closes.
struct DatePanel: View {
    @Binding var due: DateComponents?
    let clock: Clock
    let close: () -> Void
    @Environment(Store.self) private var store
    @State private var month: Date

    init(due: Binding<DateComponents?>, clock: Clock, close: @escaping () -> Void) {
        _due = due
        self.clock = clock
        self.close = close
        _month = State(initialValue: due.wrappedValue.flatMap { Due.date($0, clock: clock) } ?? clock.now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(DuePreset.allCases, id: \.self) { p in
                    PanelRow(icon: p.symbol, tint: p.tint, title: p.name, detail: p.detail(clock),
                             checked: Due.same(due, preset(p), clock: clock)) {
                        due = preset(p)
                        close()
                    }
                }
                PanelRow(icon: "xmark.circle.fill", tint: .red, title: "Remove Date", detail: nil, checked: false) {
                    due = nil
                    close()
                }
                .disabled(due == nil)
                .opacity(due == nil ? 0.4 : 1)
                Spacer(minLength: 0)
                Text(due.map { Display.duePill($0, clock: clock).text } ?? "No date")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(due == nil ? .tertiary : .secondary)
                    .padding(.horizontal, 8).padding(.bottom, 4)
            }
            .padding(6)
            .frame(width: 268)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                MonthGridPicker(selection: due.flatMap { Due.day($0, clock: clock) }, month: $month,
                                clock: clock, marked: store.dueDays) { day in
                    due = Due.moving(due, toDay: day, clock: clock)
                }
                TimeRow(due: $due, clock: clock)
                HStack {
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 272)
        }
        .fixedSize(horizontal: false, vertical: true)
        .focusEffectDisabled()   // no focus ring on Today when the popover opens
    }

    private func preset(_ p: DuePreset) -> DateComponents {
        Due.components(p.date(clock), allDay: false, timeZone: due?.timeZone, clock: clock)
    }
}

extension DuePreset {
    var symbol: String {
        switch self {
        case .todayMorning: "sun.max.fill"
        case .thisEvening: "moon.fill"
        case .tomorrowMorning: "sunrise.fill"
        case .inAWeek: "calendar.badge.clock"
        }
    }
    var tint: Color {
        switch self {
        case .todayMorning: .yellow
        case .thisEvening: .indigo
        case .tomorrowMorning: .orange
        case .inAWeek: .teal
        }
    }
}

/// One menu-like row: icon, title, trailing detail, hover highlight.
private struct PanelRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?
    let checked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 12)
                if let detail { Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize() }
                if checked { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Six-week month grid: today in accent, selection filled, a dot on days that already have reminders.
struct MonthGridPicker: View {
    let selection: Date?
    @Binding var month: Date
    let clock: Clock
    let marked: Set<Date>
    let pick: (Date) -> Void

    var body: some View {
        let start = CalendarLayout.week(containing: clock.cal.dateInterval(of: .month, for: month)?.start ?? month, clock: clock)[0]
        let days = (0..<42).map { clock.cal.date(byAdding: .day, value: $0, to: start)! }
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .semibold))
                Spacer()
                Group {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                    Button { month = clock.now } label: { Circle().frame(width: 6, height: 6).frame(width: 22, height: 22) }
                        .help("Today")
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { d in
                    DayCell(day: d, clock: clock,
                            inMonth: clock.cal.isDate(d, equalTo: month, toGranularity: .month),
                            selected: selection.map { clock.cal.isDate($0, inSameDayAs: d) } ?? false,
                            marked: marked.contains(d)) { pick(d) }
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let s = clock.cal.veryShortStandaloneWeekdaySymbols
        let first = clock.cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private func step(_ n: Int) {
        withAnimation(.snappy(duration: 0.2)) {
            month = clock.cal.date(byAdding: .month, value: n, to: month) ?? month
        }
    }
}

private struct DayCell: View {
    let day: Date
    let clock: Clock
    let inMonth: Bool
    let selected: Bool
    let marked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let isToday = clock.cal.isDate(day, inSameDayAs: clock.now)
        let past = day < clock.today
        Button(action: action) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 12, weight: isToday || selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.white)
                                 : isToday ? AnyShapeStyle(Color.accentColor)
                                 : !inMonth || past ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background {
                    if selected { Circle().fill(Color.accentColor) }
                    else if isToday { Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1) }
                    else if hover { Circle().fill(Color.primary.opacity(0.08)) }
                }
                .overlay(alignment: .bottom) {
                    if marked && !selected { Circle().fill(Color.secondary).frame(width: 3, height: 3).padding(.bottom, 3) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Add Time" or a time field with quick chips; removing the time makes the date all-day again.
private struct TimeRow: View {
    @Binding var due: DateComponents?
    let clock: Clock
    private static let quickHours = [9, 12, 15, 18, 21]

    var body: some View {
        let timed = due.map { !Due.isAllDay($0) } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 18)
                if timed {
                    DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                    Spacer()
                    Button { setTime(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove time")
                } else {
                    Text("No time — pick one below").foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .frame(height: 22)
            HStack(spacing: 5) {
                ForEach(Self.quickHours, id: \.self) { h in
                    let selected = timed && (due.flatMap { Due.date($0, clock: clock) }.map {
                        clock.cal.component(.hour, from: $0) == h && clock.cal.component(.minute, from: $0) == 0
                    } ?? false)
                    Button { setTime(h) } label: {
                        Text(label(h)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var day: Date { due.flatMap { Due.date($0, clock: clock) }.map { clock.cal.startOfDay(for: $0) } ?? clock.today }

    private var time: Binding<Date> {
        Binding(
            get: { due.flatMap { Due.date($0, clock: clock) } ?? clock.now },
            set: { new in
                let hm = clock.cal.dateComponents([.hour, .minute], from: new)
                let d = clock.cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: day) ?? new
                due = Due.components(d, allDay: false, timeZone: due?.timeZone, clock: clock)
            })
    }

    private func setTime(_ hour: Int?) {
        guard let hour else { due = Due.components(day, allDay: true, timeZone: nil, clock: clock); return }
        let d = clock.cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        due = Due.components(d, allDay: false, timeZone: due?.timeZone, clock: clock)
    }

    private func label(_ h: Int) -> String {
        (clock.cal.date(bySettingHour: h, minute: 0, second: 0, of: clock.today) ?? clock.today)
            .formatted(Date.FormatStyle(timeZone: clock.cal.timeZone).hour())
    }
}
