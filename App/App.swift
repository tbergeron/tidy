import SwiftUI

@main
struct TickTickRemindersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onAppear { delegate.store = store; store.start() }
        }
        .commands { AppCommands(store: store) }

        Settings {
            SettingsView().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?

    /// The open card, the draft, queued ops and pending deletes (R9) are all saved before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.drain()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct AppCommands: Commands {
    let store: Store
    private var um: UndoManager? { NSApp.keyWindow?.undoManager }
    private var ids: [String] { Array(store.selection) }
    private var none: Bool { store.selection.isEmpty }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Reminder") { store.startCompose() }.keyboardShortcut("n")
            Button("New List…") { store.showNewList = true }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Reminder") {
            Button("Show Info") { store.editingID = store.selection.first }.keyboardShortcut("i").disabled(store.selection.count != 1)
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

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 520, height: 420)
    }
}

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Dock badge", selection: $store.badgeMode) {
                Text("Overdue and due today").tag(Store.BadgeMode.overdueAndToday)
                Text("Overdue only").tag(Store.BadgeMode.overdue)
                Text("Off").tag(Store.BadgeMode.off)
            }
            Toggle("Group Today by time of day", isOn: $store.groupByTime)
            Picker("Load completed reminders from the last", selection: $store.completedWindowDays) {
                ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
            }
            .onChange(of: store.completedWindowDays) { store.scheduleReload() }
        }
        .formStyle(.grouped)
    }
}
