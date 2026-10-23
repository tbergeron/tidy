import SwiftUI

/// One view's reminders: sections like the Mac (Overdue/Today buckets, days, list sections, lists in smart views).
/// Tap opens the editor sheet; swipe completes / dates / deletes; Select for multi-select actions.
struct ListScreen: View {
    let destination: Destination
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var editMode: EditMode = .inactive
    @State private var toast: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        let sections = store.sections(destination)
        List(selection: $store.selection) {
            TagBar(destination: destination)
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        Row(row: row, showList: section.kind != .list(row.reminder.listID) && !isListView)
                            .draggable(DragItems(reminderIDs: dragIDs(row.id)))
                            .moveDrop(section.kind, store: store, undo: um)
                    }
                } header: {
                    if !section.title.isEmpty { SectionHeader(section: section) }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .overlay {
            if store.loaded && sections.allSatisfy({ $0.rows.isEmpty }) {
                if store.search.isEmpty {
                    ContentUnavailableView("No Reminders", systemImage: "checkmark.circle", description: Text("Tap + to add one."))
                } else {
                    ContentUnavailableView.search(text: store.search)
                }
            }
        }
        .searchable(text: $store.search, prompt: "Search all reminders")
        .searchFocused($searchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .tidyFocusSearch)) { _ in searchFocused = true }   // ⌘F on iPad
        .refreshable { await store.refresh() }
        .navigationTitle(store.title(destination))
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { withAnimation { editMode = .inactive; store.selection = [] } }
                }
                ToolbarItemGroup(placement: .bottomBar) { SelectionActions() }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select Reminders", systemImage: "checkmark.circle") { withAnimation { editMode = .active } }
                        Divider()
                        ViewOptions(destination: destination)
                    } label: { Label("More", systemImage: "ellipsis") }
                }
                // iOS 26+ bottom bar: search field, then "+".
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { NewReminderButton() }
            }
        }
        .overlay(alignment: .bottom) { UndoToast(text: $toast) }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { note in
            // iOS has no ⌘Z: offer Undo for the actions that remove or move things out of view.
            guard let u = note.object as? UndoManager, u === um, u.canUndo,
                  ["Delete", "Complete", "Move", "Reschedule", "Hide from Today"].contains(u.undoActionName) else { return }
            toast = u.undoActionName
        }
        .onChange(of: Set(sections.flatMap { $0.rows.map(\.id) })) { _, visible in
            store.selection.formIntersection(visible)
        }
    }

    private var isListView: Bool { if case .list = destination { true } else { false } }
    private func dragIDs(_ id: String) -> [String] { store.selection.contains(id) ? Array(store.selection) : [id] }
}

/// A Things-style row: checkbox, title (with priority marks), metadata underneath.
private struct Row: View {
    let row: Store.Row
    let showList: Bool
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @Environment(\.editMode) private var editMode

    var body: some View {
        let r = row.reminder
        let done = r.isCompleted || store.justCompleted.contains(r.id)
        let list = store.list(r.listID)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            CheckBox(done: done, round: row.depth > 0, color: list.map { Color($0.color) } ?? .secondary) {
                store.toggleComplete([r.id], undo: um)
            }
            .disabled(list?.readOnly == true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if Priority(raw: r.priority) != .none {
                        Text(Priority(raw: r.priority).marks).fontWeight(.bold).foregroundStyle(.orange)
                    }
                    Text(r.title.isEmpty ? "New Reminder" : r.title)
                        .lineLimit(2)
                        .foregroundStyle(done ? .secondary : .primary)
                        .strikethrough(done, color: .secondary)
                }
                if showList, let p = r.parentID, let parent = store.snap.reminders[p] {
                    Text(parent.title).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                if hasMetadata(r) {
                    Metadata(reminder: r, showList: showList).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if row.depth == 0, case let kids = store.children(of: r.id), !kids.isEmpty {
                Button { toggleCollapsed(r.id) } label: {
                    HStack(spacing: 3) {
                        Text("\(kids.filter(\.isCompleted).count)/\(kids.count)")
                        Image(systemName: store.collapsed.contains(r.id) ? "chevron.right" : "chevron.down")
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 28)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { if editMode?.wrappedValue.isEditing != true { store.editingID = r.id } }
        .swipeActions(edge: .leading) {
            Button { store.toggleComplete([r.id], undo: um) } label: {
                Label(done ? "Not Completed" : "Complete", systemImage: done ? "circle" : "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.requestDelete([r.id], undo: um) } label: { Label("Delete", systemImage: "trash") }
            Button { store.datePicker = (r.id, [r.id]) } label: { Label("Date", systemImage: "calendar") }.tint(.orange)
        }
        .contextMenu { ReminderMenu(ids: [r.id], anchor: r.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: done ? "Mark as Not Completed" : "Complete") { store.toggleComplete([r.id], undo: um) }
    }

    private func hasMetadata(_ r: Reminder) -> Bool {
        let x = r.extras
        return r.due != nil || r.isRepeating || showList || !(r.notes ?? "").isEmpty || !(x?.tags.isEmpty ?? true)
            || x?.flagged == true || x?.urgent == true || !(x?.urls.isEmpty ?? true) || !(x?.images.isEmpty ?? true)
            || r.alarms.contains { $0.location != nil }
    }

    private func toggleCollapsed(_ id: String) {
        if store.collapsed.contains(id) { store.collapsed.remove(id) } else { store.collapsed.insert(id) }
    }
}

private struct SectionHeader: View {
    let section: Store.RowSection
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var targeted = false

    var body: some View {
        HStack {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(section.kind == .overdue ? Color.red : section.kind == .completed ? .secondary : Color.accentColor)
            Spacer()
            if section.kind == .overdue && !section.rows.isEmpty {
                Button("Move All to Today") { store.requestMoveOverdueToToday() }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
        .moveDrop(section.kind, store: store, undo: um) { targeted = $0 }
    }
}

/// Tags used in this view; tap filters to one tag (tap again to clear).
private struct TagBar: View {
    let destination: Destination
    @Environment(Store.self) private var store

    var body: some View {
        let tags = Array(Set(store.tagsInView(destination)).union(store.tagFilter)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if case .tag = destination {} else if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", on: store.tagFilter.isEmpty) { store.tagFilter = [] }
                    ForEach(tags, id: \.self) { t in
                        chip("#" + t, on: store.tagFilter.contains(t)) { store.tagFilter = store.tagFilter == [t] ? [] : [t] }
                    }
                }
                .padding(.horizontal, 2)
            }
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }

    private func chip(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(name, action: action)
            .font(.subheadline)
            .buttonStyle(.glass)
            .tint(on ? .accentColor : nil)
            .controlSize(.small)
    }
}

/// Bottom bar while selecting: complete, date, move, delete.
private struct SelectionActions: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        let ids = Array(store.selection)
        Button { store.toggleComplete(ids, undo: um) } label: { Label("Complete", systemImage: "checkmark.circle") }
            .disabled(ids.isEmpty)
        Spacer()
        Menu {
            ForEach(DuePreset.allCases, id: \.self) { p in
                Button(p.name, systemImage: p.symbol) {
                    let d = p.date(store.clock)
                    store.setDue(ids, { Due.components(d, allDay: false, timeZone: $0.due?.timeZone, clock: store.clock) }, undo: um)
                }
            }
            Divider()
            Button("Pick a Date…", systemImage: "calendar.badge.plus") { if let a = ids.first { store.datePicker = (a, ids) } }
            Button("Remove Date", systemImage: "xmark.circle") { store.setDue(ids, { _ in nil }, undo: um) }
        } label: { Label("Date", systemImage: "calendar") }
            .disabled(ids.isEmpty)
        Spacer()
        Button { store.showMoveSheet = true } label: { Label("Move", systemImage: "folder") }
            .disabled(ids.isEmpty)
        Spacer()
        Button(role: .destructive) { store.requestDelete(ids, undo: um) } label: { Label("Delete", systemImage: "trash") }
            .disabled(ids.isEmpty)
    }
}

/// "Deleted · Undo" for a few seconds after a delete, completion, move or reschedule.
private struct UndoToast: View {
    @Binding var text: String?
    @Environment(\.undoManager) private var um

    var body: some View {
        if let t = text {
            HStack(spacing: 14) {
                Text(Self.past[t] ?? t).font(.subheadline.weight(.medium))
                Button("Undo") { um?.undo(); text = nil }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.bottom, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: t) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { if text == t { text = nil } }
            }
        }
    }

    private static let past = ["Delete": "Deleted", "Complete": "Completed", "Move": "Moved", "Reschedule": "Rescheduled",
                               "Hide from Today": "Hidden from Today"]
}
