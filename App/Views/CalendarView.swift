import SwiftUI

/// Day / week / month calendar of reminders (by due date) plus read-only Calendar events.
struct CalendarView: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var mode = Mode.week

    enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }

    var body: some View {
        @Bindable var store = store
        Group {
            switch mode {
            case .day: TimeGrid(days: [store.clock.cal.startOfDay(for: store.calendarAnchor)])
            case .week: TimeGrid(days: CalendarLayout.week(containing: store.calendarAnchor, clock: store.clock))
            case .month: MonthGrid(days: CalendarLayout.month(containing: store.calendarAnchor, clock: store.clock))
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Today") { store.calendarAnchor = store.clock.today }
                Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            ToolbarItem {
                Picker("View", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                if store.eventAuth == .fullAccess {
                    CalendarsMenu()
                } else {
                    Button { Task { await store.requestEventAccess() } } label: { Label("Show Events", systemImage: "calendar.badge.plus") }
                        .help("Show Calendar events (read-only)")
                }
            }
        }
        .background {   // ⌥⌘1/2/3 switch modes
            ForEach(Array(Mode.allCases.enumerated()), id: \.offset) { i, m in
                Button("") { mode = m }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option]).hidden()
            }
        }
        .inspector(isPresented: Binding(get: { store.editingID != nil }, set: { if !$0 { store.editingID = nil } })) {
            if let id = store.editingID, let r = store.snap.reminders[id] {
                ScrollView { CardView(reminder: r).id(id).padding(10) }
                    .inspectorColumnWidth(min: 280, ideal: 320)
            }
        }
        .onChange(of: store.calendarAnchor) { store.scheduleReload() }
    }

    private var title: String {
        let a = store.calendarAnchor
        return switch mode {
        case .day: a.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week, .month: a.formatted(.dateTime.month(.wide).year())
        }
    }

    private func step(_ n: Int) {
        let unit: Calendar.Component = switch mode { case .day: .day; case .week: .weekOfYear; case .month: .month }
        store.calendarAnchor = store.clock.cal.date(byAdding: unit, value: n, to: store.calendarAnchor) ?? store.calendarAnchor
    }
}

// MARK: - Time grid (day/week)

private struct TimeGrid: View {
    let days: [Date]
    static let hourHeight: CGFloat = 44
    static let gutter: CGFloat = 46
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutter, height: 1)   // Color.clear is height-flexible otherwise
                ForEach(days, id: \.self) { d in
                    let isToday = store.clock.cal.isDate(d, inSameDayAs: store.clock.now)
                    VStack(spacing: 0) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        Text(d.formatted(.dateTime.day())).font(.title3.weight(isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.red : .primary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: Self.gutter, alignment: .trailing).padding(.trailing, 4)
                ForEach(days, id: \.self) { AllDayCell(day: $0).frame(maxWidth: .infinity) }
            }
            .frame(minHeight: 28)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(h == 0 ? "" : store.clock.cal.date(bySettingHour: h, minute: 0, second: 0, of: store.clock.today)!
                                .formatted(.dateTime.hour()))
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: Self.gutter - 4, height: Self.hourHeight, alignment: .topTrailing)
                                .offset(y: -6)
                        }
                    }
                    .padding(.trailing, 4)
                    ForEach(days, id: \.self) { DayColumn(day: $0).frame(maxWidth: .infinity) }
                }
                .frame(height: 24 * Self.hourHeight)
            }
            .defaultScrollAnchor(UnitPoint(x: 0, y: 7.5 / 24))
        }
    }
}

private struct AllDayCell: View {
    let day: Date
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.eventsOn(day).filter(\.isAllDay)) { EventPill(event: $0) }
            ForEach(store.remindersOn(day).filter { $0.due.map(Due.isAllDay) == true }) { ReminderPill(reminder: $0) }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
        .padding(2)
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear)
        .overlay(alignment: .leading) { Divider() }
        .dropDestination(for: DragItems.self) { items, _ in
            // Into the all-day lane = date-only (R2 removes the due-time alarm).
            store.setDue(items.flatMap(\.reminderIDs), { _ in Due.components(day, allDay: true, timeZone: nil, clock: store.clock) }, undo: um)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct DayColumn: View {
    let day: Date
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var targeted = false

    var body: some View {
        let h = TimeGrid.hourHeight
        let events = store.eventsOn(day).filter { !$0.isAllDay }
        let reminders = store.remindersOn(day).filter { $0.due.map(Due.isAllDay) == false }
        let start = store.clock.cal.startOfDay(for: day)
        let remStart: (Reminder) -> Date = { $0.due.flatMap { Due.date($0, clock: store.clock) } ?? start }
        let items = events.map { (id: $0.id, start: max($0.start, start), end: min($0.end, start.addingTimeInterval(86400))) }
            + reminders.map { (id: $0.id, start: remStart($0), end: remStart($0).addingTimeInterval(30 * 60)) }   // ponytail: reminders are instants, drawn 30 min tall
        let cols = CalendarLayout.columns(items)

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(0..<24, id: \.self) { i in
                    Rectangle().fill(.separator).frame(height: 0.5).offset(y: CGFloat(i) * h)
                }
                ForEach(items, id: \.id) { item in
                    let c = cols[item.id] ?? (0, 1)
                    let w = geo.size.width / CGFloat(c.of)
                    let y = CGFloat(CalendarLayout.wallHours(item.start, on: day, clock: store.clock)) * h   // wall clock: DST-safe
                    let height = max(18, CGFloat(item.end.timeIntervalSince(item.start) / 3600) * h - 1)
                    Group {
                        if let e = events.first(where: { $0.id == item.id }) { EventBlock(event: e) }
                        else if let r = reminders.first(where: { $0.id == item.id }) { ReminderPill(reminder: r, block: true) }
                    }
                    .frame(width: w - 2, height: height, alignment: .topLeading)
                    .offset(x: CGFloat(c.col) * w + 1, y: y)
                }
                if store.clock.cal.isDate(day, inSameDayAs: store.clock.now) {
                    Rectangle().fill(.red).frame(height: 1.5)
                        .offset(y: CGFloat(CalendarLayout.wallHours(store.clock.now, on: day, clock: store.clock)) * h)
                }
            }
            .frame(width: geo.size.width, height: 24 * h, alignment: .topLeading)
            .contentShape(.rect)
            .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
            .overlay(alignment: .leading) { Divider() }
            .onTapGesture(count: 2, coordinateSpace: .local) { p in
                let t = CalendarLayout.dropTime(y: p.y, hourHeight: h, day: day, clock: store.clock)
                store.create(title: "New Reminder", listID: nil, due: Due.components(t, allDay: false, timeZone: nil, clock: store.clock), undo: um, open: true)
            }
            .dropDestination(for: DragItems.self) { items, location in
                // Into a time slot = timed (R2 adds/shifts the alarm). 15-minute snap.
                let t = CalendarLayout.dropTime(y: location.y, hourHeight: h, day: day, clock: store.clock)
                store.setDue(items.flatMap(\.reminderIDs), { r in Due.components(t, allDay: false, timeZone: r.due?.timeZone, clock: store.clock) }, undo: um)
                return true
            } isTargeted: { targeted = $0 }
        }
        .frame(height: 24 * h)
    }
}

// MARK: - Month

private struct MonthGrid: View {
    let days: [Date]
    @Environment(Store.self) private var store
    @State private var expanded: Set<Date> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) {
                    Text($0.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(days, id: \.self) { MonthCell(day: $0, expanded: $expanded) }
                }
            }
        }
    }
}

private struct MonthCell: View {
    let day: Date
    @Binding var expanded: Set<Date>
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var targeted = false

    var body: some View {
        let inMonth = store.clock.cal.isDate(day, equalTo: store.calendarAnchor, toGranularity: .month)
        let isToday = store.clock.cal.isDate(day, inSameDayAs: store.clock.now)
        let events = store.eventsOn(day)
        let reminders = store.remindersOn(day)
        let total = events.count + reminders.count
        let limit = expanded.contains(day) ? .max : 3
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? AnyShapeStyle(Color.red) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            ForEach(events.prefix(limit)) { EventPill(event: $0) }
            ForEach(reminders.prefix(max(0, limit - events.count))) { ReminderPill(reminder: $0) }
            if total > limit {
                Button("+\(total - limit) more") { expanded.insert(day) }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(4)
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear)
        .overlay { Rectangle().strokeBorder(.separator, lineWidth: 0.5) }
        .contentShape(.rect)
        .dropDestination(for: DragItems.self) { items, _ in
            // Month cell = new date, same time of day.
            store.setDue(items.flatMap(\.reminderIDs), { Due.moving($0.due, toDay: day, clock: store.clock) }, undo: um)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Items

private struct ReminderPill: View {
    let reminder: Reminder
    var block = false
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        let color = store.list(reminder.listID).map { Color($0.color) } ?? .accentColor
        let overdue = Smart.isOverdue(reminder, store.clock)
        HStack(alignment: .top, spacing: 4) {
            CheckBox(done: reminder.isCompleted, round: true, color: color) { store.toggleComplete([reminder.id], undo: um) }
                .scaleEffect(0.85)
            Text(reminder.title).font(.caption).lineLimit(block ? 2 : 1)
                .foregroundStyle(overdue ? Color.red : .primary)
                .strikethrough(reminder.isCompleted)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: block ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(store.editingID == reminder.id ? Color.accentColor : .clear) }
        .contentShape(.rect)
        .onTapGesture { store.selection = [reminder.id]; store.editingID = reminder.id }
        .draggable(DragItems(reminderIDs: [reminder.id]))
    }
}

private struct EventPill: View {
    let event: CalEvent
    var body: some View {
        Text(event.title).font(.caption).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(event.color).opacity(0.25)))
            .help("\(event.title) — \(event.calendarTitle) (read-only)")
    }
}

private struct EventBlock: View {
    let event: CalEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(event.title).font(.caption.weight(.medium)).lineLimit(2)
            Text(event.start.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(event.color).opacity(0.22)))
        .overlay(alignment: .leading) { Rectangle().fill(Color(event.color)).frame(width: 2) }
        .help("\(event.title) — \(event.calendarTitle) (read-only)")
    }
}

/// Which event calendars appear (per account, like Calendar.app's list).
private struct CalendarsMenu: View {
    @Environment(Store.self) private var store

    var body: some View {
        Menu {
            let groups = Dictionary(grouping: store.snap.eventCalendars, by: \.account)
            ForEach(groups.keys.sorted(), id: \.self) { account in
                Section(account) {
                    ForEach(groups[account] ?? []) { c in
                        Toggle(isOn: Binding(
                            get: { !store.hiddenEventCalendars.contains(c.id) },
                            set: { if $0 { store.hiddenEventCalendars.remove(c.id) } else { store.hiddenEventCalendars.insert(c.id) } })
                        ) {
                            Label { Text(c.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(c.color)) }
                        }
                    }
                }
            }
            Divider()
            Button("Show All") { store.hiddenEventCalendars = [] }
            Button("Hide All") { store.hiddenEventCalendars = Set(store.snap.eventCalendars.map(\.id)) }
        } label: {
            Label("Calendars", systemImage: "calendar.badge.checkmark")
        }
        .help("Choose which calendars to show")
    }
}
