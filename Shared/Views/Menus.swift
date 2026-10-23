import SwiftUI

struct ReminderMenu: View {
    let ids: [String]
    var anchor: String?
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        items.labelStyle(.titleAndIcon)   // macOS menus drop SF Symbols unless asked to show them
    }

    @ViewBuilder private var items: some View {
        let one = ids.count == 1 ? store.snap.reminders[ids[0]] : nil
        let locked = ids.allSatisfy(store.locked)
        let rs = ids.compactMap { store.snap.reminders[$0] }
        Button(one?.isCompleted == true ? "Mark as Not Completed" : "Mark as Completed",
               systemImage: one?.isCompleted == true ? "circle" : "checkmark.circle") { store.toggleComplete(ids, undo: um) }
            .disabled(locked)
        Menu("Due", systemImage: "calendar") {
            ForEach(DuePreset.allCases, id: \.self) { p in
                Button(p.name, systemImage: p.symbol) {
                    let d = p.date(store.clock)
                    store.setDue(ids, { Due.components(d, allDay: false, timeZone: $0.due?.timeZone, clock: store.clock) }, undo: um)
                }
            }
            Divider()
            Button("Pick a Date…", systemImage: "calendar.badge.plus") {
                guard let a = anchor ?? ids.first else { return }
                if store.editingID == a { store.editingID = nil }   // the popover anchors on the row, not the open card
                store.datePicker = (a, ids)
            }
            Button("Remove Date", systemImage: "xmark.circle") { store.setDue(ids, { _ in nil }, undo: um) }
        }
        .disabled(locked)
        if store.bridgeReadable {
            let urgent = !rs.isEmpty && rs.allSatisfy { $0.extras?.urgent == true }
            Button(urgent ? "Remove Urgent" : "Mark as Urgent", systemImage: urgent ? "alarm.waves.left.and.right.fill" : "alarm.waves.left.and.right") {
                store.setUrgent(ids, !urgent, undo: um)
            }
            .disabled(!rs.contains(where: store.canSetUrgent))
            .help("Needs a date with a time")
        }
        Menu("Priority", systemImage: "exclamationmark") {
            ForEach(Priority.allCases.reversed(), id: \.self) { p in
                Toggle(p.label, isOn: Binding(get: { one.map { Priority(raw: $0.priority) == p } ?? false },
                                              set: { _ in store.setPriority(ids, p, undo: um) }))
            }
        }
        .disabled(locked)
        Button("Move to…", systemImage: "folder") { store.selection = Set(ids); store.showMoveSheet = true }.disabled(locked)
        let hidden = !ids.isEmpty && ids.allSatisfy(store.hiddenFromSchedule.contains)
        Button(hidden ? "Show in Schedule" : "Hide from Schedule", systemImage: hidden ? "eye" : "eye.slash") {
            store.setHiddenFromSchedule(ids, !hidden, undo: um)
        }
        if let one {
            Divider()
            Button("Show Info", systemImage: "info.circle") { store.editingID = one.id }
            Button("Open in Reminders", systemImage: "arrow.up.forward.app") { store.openInReminders(reminder: one.id) }
            Button("Copy Link", systemImage: "link") { Platform.copy("x-apple-reminderkit://REMCDReminder/\(one.id)") }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { store.requestDelete(ids, undo: um) }.disabled(locked)
    }
}

/// "Pick a Date…" from the context menu. One write when it closes; applies the same date to every selected reminder.
struct DuePopover: View {
    let ids: [String]
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var initial: DateComponents?
    @State private var due: DateComponents?

    var body: some View {
        DatePanel(due: $due, clock: store.clock) { store.datePicker = nil }
            .onAppear {
                initial = ids.first.flatMap { store.snap.reminders[$0]?.due }
                due = initial
            }
            .onDisappear {
                guard !Due.same(due, initial, clock: store.clock) else { return }
                let picked = due
                store.setDue(ids, { _ in picked }, undo: um)
            }
    }
}

struct ViewOptions: View {
    let destination: Destination
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        if destination == .today { Toggle("Group by Time", isOn: $store.groupByTime) }
        Menu("Smart Lists") {
            ForEach(Store.smartDestinations.filter(store.isAvailable), id: \.self) { d in
                let t = store.title(d)
                Toggle(t, isOn: Binding(get: { !store.hiddenSmartLists.contains(t) },
                                        set: { if $0 { store.hiddenSmartLists.remove(t) } else { store.hiddenSmartLists.insert(t) } }))
            }
        }
        Menu("Lists") {
            ForEach(store.snap.lists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { l in
                Toggle(l.title, isOn: Binding(get: { !store.hiddenLists.contains(l.id) },
                                              set: { if $0 { store.hiddenLists.remove(l.id) } else { store.hiddenLists.insert(l.id) } }))
            }
            if !store.hiddenLists.isEmpty {
                Divider()
                Button("Show All Lists") { store.hiddenLists = [] }
            }
        }
        if case .list(let id) = destination {
            Divider()
            Toggle("Show Completed", isOn: Binding(get: { store.showCompleted.contains(id) },
                                                   set: { if $0 { store.showCompleted.insert(id) } else { store.showCompleted.remove(id) } }))
            if let l = store.list(id), let style = l.sortingStyle {
                Text("Sorted: " + (Sorting.styles.first { $0.value == style }?.label ?? style)).foregroundStyle(.secondary)
            }
            Divider()
            Button("Open in Reminders") { store.openInReminders(list: id) }
        }
    }
}
