import SwiftUI

struct AppCommands: Commands {
    let store: Store
    private var um: UndoManager? { Platform.undoManager }
    private var ids: [String] { Array(store.selection) }
    private var none: Bool { store.selection.isEmpty }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Reminder") { store.startCompose() }.keyboardShortcut("n")
            Button("New List…") { store.showNewList = true }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { NotificationCenter.default.post(name: .tidyFocusSearch, object: nil) }.keyboardShortcut("f")
        }
        CommandMenu("Reminder") {
            Button("Show Details") { store.editingID = store.selection.first }.keyboardShortcut("i").disabled(store.selection.count != 1)
            Button("Mark as Completed") { store.toggleComplete(ids, undo: um) }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(none)
            Menu("Priority") {
                ForEach(Priority.allCases.reversed(), id: \.self) { p in
                    Button(p.label) { store.setPriority(ids, p, undo: um) }
                }
            }.disabled(none)
            Button("Move to…") { store.showMoveSheet = true }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(none)
            Divider()
            Button("Open in Reminders") { if let id = ids.first { store.openInReminders(reminder: id) } }.disabled(store.selection.count != 1)
            Button("Delete") { store.requestDelete(ids, undo: um) }.disabled(none)
        }
        CommandMenu("Date") {
            Button("Today") { reschedule { _ in store.clock.today } }.keyboardShortcut("t")
            Button("Tomorrow") { reschedule { Due.tomorrow($0) } }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("This Weekend") { reschedule { Due.thisWeekend($0) } }.keyboardShortcut("k")
            Button("Next Week") { reschedule { Due.nextWeek($0) } }.keyboardShortcut("k", modifiers: [.command, .option])
            Divider()
            Button("Move All Overdue to Today…") { store.requestMoveOverdueToToday() }.keyboardShortcut("t", modifiers: [.command, .control])
            Button("Clear Date") { store.setDue(ids, { _ in nil }, undo: um) }.disabled(none)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Completed") { store.toggleShowCompleted() }.keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!store.showCompletedApplies)
            Button("Group Today by Time") { store.groupByTime.toggle() }
            Divider()
            ForEach(Array(store.shortcutDestinations.prefix(9).enumerated()), id: \.offset) { i, d in
                Button(store.title(d)) { store.destination = d }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
        }
    }

    private func reschedule(_ day: @escaping (Clock) -> Date) {
        guard !none else { return }
        let target = day(store.clock)
        store.setDue(ids, { Due.moving($0.due, toDay: target, clock: store.clock) }, undo: um)
    }
}

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    #if os(macOS)
    static let badgeTitle = "Dock badge"
    #else
    static let badgeTitle = "App icon badge"
    #endif
    var body: some View {
        @Bindable var store = store
        Form {
            Picker(Self.badgeTitle, selection: $store.badgeMode) {
                Text("Overdue and due today").tag(Store.BadgeMode.overdueAndToday)
                Text("Overdue only").tag(Store.BadgeMode.overdue)
                Text("Off").tag(Store.BadgeMode.off)
            }
            Toggle("Group Today by time of day", isOn: $store.groupByTime)
            Picker("Load completed reminders from the last", selection: $store.completedWindowDays) {
                ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
            }
            .onChange(of: store.completedWindowDays) { store.scheduleReload() }
            HiddenFromScheduleSection()
        }
        .formStyle(.grouped)
    }
}

/// Settings: reminders hidden from Today, each with a button to put it back.
struct HiddenFromScheduleSection: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    #if os(macOS)
    private static let hint = "None. Right-click a reminder and choose Hide from Schedule."
    #else
    private static let hint = "None. Touch and hold a reminder and choose Hide from Schedule."
    #endif

    var body: some View {
        let rs = store.hiddenFromSchedule.compactMap { store.snap.reminders[$0] }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        Section("Hidden from Schedule") {
            if rs.isEmpty { Text(Self.hint).foregroundStyle(.secondary) }
            ForEach(rs) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title.isEmpty ? "Untitled" : r.title)
                        if let l = store.list(r.listID) { Text(l.title).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Show in Schedule") { store.setHiddenFromSchedule([r.id], false, undo: um) }
                }
            }
        }
    }
}
