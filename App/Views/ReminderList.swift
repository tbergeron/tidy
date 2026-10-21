import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let ttrItems = UTType(exportedAs: "com.ticktickreminders.items") }

/// Drag payload: only IDs, never EventKit objects.
struct DragItems: Codable, Transferable {
    var reminderIDs: [String]
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .ttrItems) }
}

struct ReminderListView: View {
    let destination: Destination
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        @Bindable var store = store
        let sections = store.sections(destination)
        let draftSection = draftHost(sections)

        List(selection: $store.selection) {
            ListHeader(destination: destination)
                .selectionDisabled()
                .listRowSeparator(.hidden)

            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        Group {
                            if store.editingID == row.id {
                                CardView(reminder: row.reminder)
                            } else {
                                ReminderRow(row: row, showList: section.kind != .list(row.reminder.listID) && !isListView)
                                    .draggable(DragItems(reminderIDs: dragIDs(row.id)))
                            }
                        }
                        .listRowSeparator(.hidden)
                    }
                    if store.draft != nil && section.id == draftSection {
                        DraftRow().listRowSeparator(.hidden).selectionDisabled()
                    }
                } header: {
                    if !section.title.isEmpty { SectionHeader(section: section) }
                }
            }
            if store.draft != nil && draftSection == nil {
                Section { DraftRow().listRowSeparator(.hidden).selectionDisabled() }
            }
            if sections.allSatisfy({ $0.rows.isEmpty }) && store.draft == nil && store.loaded {
                Text(store.search.isEmpty ? "No Reminders" : "No Results")
                    .font(.title3).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .selectionDisabled().listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.visible)
        .contextMenu(forSelectionType: String.self) { ids in
            ReminderMenu(ids: Array(ids))
        } primaryAction: { ids in
            if ids.count == 1 { store.draft = nil; store.editingID = ids.first }
        }
        .onDeleteCommand { store.requestDelete(Array(store.selection), undo: um) }
        .onKeyPress(.space) {
            guard store.editingID == nil, store.draft == nil else { return .ignored }
            store.startDraft(); return .handled
        }
        .onKeyPress(.return) {
            guard store.editingID == nil, store.draft == nil, store.selection.count == 1 else { return .ignored }
            store.editingID = store.selection.first; return .handled
        }
        .onKeyPress(.escape) {
            guard store.editingID != nil else { return .ignored }
            store.editingID = nil; return .handled
        }
        .onChange(of: store.selection) { _, new in
            if let e = store.editingID, !new.contains(e) { store.editingID = nil }
        }
        .onChange(of: Set(sections.flatMap { $0.rows.map(\.id) })) { _, visible in
            // Rows that left the view (filtered, completed, moved) can't stay selected or open.
            store.selection.formIntersection(visible)
            if let e = store.editingID, !visible.contains(e) { store.editingID = nil }
        }
        .toolbar {
            ToolbarItem {
                Button { store.startDraft() } label: { Label("New Reminder", systemImage: "plus") }
                    .disabled(!store.canCreate)
            }
            ToolbarItem {
                Menu {
                    ViewOptions(destination: destination)
                } label: { Label("View", systemImage: "ellipsis.circle") }
            }
        }
        .navigationTitle(store.title(destination))
    }

    private var isListView: Bool { if case .list = destination { true } else { false } }

    /// The section that receives the draft row: the target list's section in grouped views, else the first plain one.
    private func draftHost(_ sections: [Store.RowSection]) -> String? {
        let target = store.draft?.listID ?? store.snap.defaultListID
        if let s = sections.first(where: { $0.kind == .list(target ?? "") }) { return s.id }
        return sections.first { s in
            if case .list = s.kind { return false }
            return ![.overdue, .completed].contains(s.kind)
        }?.id
    }
    private func dragIDs(_ id: String) -> [String] { store.selection.contains(id) ? Array(store.selection) : [id] }
}

private struct ListHeader: View {
    let destination: Destination
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.title(destination))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(titleColor)
            let tags = Array(Set(store.tagsInView(destination)).union(store.tagFilter)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if case .tag = destination {} else if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TagChip(name: "All", on: store.tagFilter.isEmpty) { store.tagFilter = [] }
                        ForEach(tags, id: \.self) { t in
                            TagChip(name: t, on: store.tagFilter.contains(t)) {
                                // Click = only this tag; ⌘-click adds (AND), like Things.
                                if NSEvent.modifierFlags.contains(.command) {
                                    if store.tagFilter.contains(t) { store.tagFilter.remove(t) } else { store.tagFilter.insert(t) }
                                } else {
                                    store.tagFilter = store.tagFilter == [t] ? [] : [t]
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8).padding(.bottom, 4)
    }

    private var titleColor: Color {
        if case .list(let id) = destination, let l = store.list(id) { return Color(l.color) }
        return .primary
    }
}

private struct TagChip: View {
    let name: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(name).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)))
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(section.kind == .overdue ? Color.red : section.kind == .completed ? .secondary : Color.accentColor)
            if section.kind == .overdue && !section.rows.isEmpty {
                Spacer()
                Button("Move All to Today") { store.moveOverdueToToday(undo: um) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.vertical, 2)
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
        .dropDestination(for: DragItems.self) { items, _ in
            let ids = items.flatMap(\.reminderIDs)
            switch section.kind {
            case .day(let day):
                store.setDue(ids, { Due.moving($0.due, toDay: day, clock: store.clock) }, undo: um)
                return true
            case .list(let lid):
                store.move(ids, toList: lid, undo: um)
                return true
            default:
                return false
            }
        } isTargeted: { targeted = $0 }
    }
}

struct ReminderRow: View {
    let row: Store.Row
    let showList: Bool
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        let r = row.reminder
        let done = r.isCompleted || store.justCompleted.contains(r.id)
        let list = store.list(r.listID)
        HStack(spacing: 8) {
            CheckBox(done: done, round: row.depth > 0, color: list.map { Color($0.color) } ?? .secondary) {
                store.toggleComplete([r.id], undo: um)
            }
            .disabled(list?.readOnly == true)
            if Priority(raw: r.priority) != .none {
                Text(Priority(raw: r.priority).marks).font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title.isEmpty ? "New Reminder" : r.title)
                    .lineLimit(1)
                    .foregroundStyle(done ? .secondary : .primary)
                    .strikethrough(done, color: .secondary)
                if showList, let p = r.parentID, let parent = store.snap.reminders[p] {
                    Text(parent.title).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if !store.children(of: r.id).isEmpty, row.depth == 0 {
                let kids = store.children(of: r.id)
                Button { toggleCollapsed(r.id) } label: {
                    Image(systemName: store.collapsed.contains(r.id) ? "chevron.right" : "chevron.down").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                Text("\(kids.filter(\.isCompleted).count)/\(kids.count)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Metadata(reminder: r, showList: showList)
        }
        .padding(.leading, CGFloat(row.depth) * 24)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: done ? "Mark as Not Completed" : "Complete") { store.toggleComplete([r.id], undo: um) }
    }

    private func toggleCollapsed(_ id: String) {
        if store.collapsed.contains(id) { store.collapsed.remove(id) } else { store.collapsed.insert(id) }
    }
}

/// Trailing grey metadata, Things-style.
struct Metadata: View {
    let reminder: Reminder
    let showList: Bool
    @Environment(Store.self) private var store

    var body: some View {
        let r = reminder, x = r.extras
        HStack(spacing: 6) {
            ForEach(x?.tags ?? [], id: \.self) { t in
                Text(t).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().strokeBorder(.secondary.opacity(0.5)))
            }
            Group {
                if r.isRepeating { Image(systemName: "repeat") }
                if r.alarms.contains(where: { $0.location != nil }) { Image(systemName: "location") }
                if !(r.notes ?? "").isEmpty { Image(systemName: "note.text") }
                if !(x?.urls.isEmpty ?? true) { Image(systemName: "link") }
                if !(x?.images.isEmpty ?? true) { Image(systemName: "photo") }
                if x?.urgent == true { Image(systemName: "alarm.fill").foregroundStyle(.red) }
                if x?.flagged == true { Image(systemName: "flag.fill").foregroundStyle(.orange) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let due = r.due {
                let pill = Display.duePill(due, clock: store.clock)
                Text(pill.text).font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.12)))
                    .foregroundStyle(pill.overdue && !r.isCompleted ? Color.red : .secondary)
            }
            if showList, let l = store.list(r.listID) {
                HStack(spacing: 4) {
                    Circle().fill(Color(l.color)).frame(width: 6, height: 6)
                    Text(l.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct CheckBox: View {
    let done: Bool
    var round = false
    var color: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: round ? 8 : 4)
                    .strokeBorder(done ? color : .secondary.opacity(0.6), lineWidth: 1.2)
                    .background(RoundedRectangle(cornerRadius: round ? 8 : 4).fill(done ? color : .clear))
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: round ? 13 : 15, height: round ? 13 : 15)
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: done)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Completed" : "Not completed")
    }
}

/// Inline create row: Return creates and starts the next one; Esc cancels when empty.
private struct DraftRow: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            CheckBox(done: false) {}.disabled(true)
            TextField("New Reminder", text: Binding(get: { store.draft?.text ?? "" }, set: { store.draft?.text = $0 }))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit(keepGoing: true) }
                .onExitCommand { commit(keepGoing: false) }
        }
        .padding(.vertical, 4)
        .onAppear { focused = true }
        .onChange(of: focused) { _, f in if !f { commit(keepGoing: false) } }
    }

    private func commit(keepGoing: Bool) {
        guard let d = store.draft else { return }
        if !d.text.trimmingCharacters(in: .whitespaces).isEmpty {
            store.create(title: d.text, listID: d.listID, due: d.due, undo: um)
        }
        store.draft = keepGoing && !d.text.isEmpty ? Store.Draft(listID: d.listID, due: d.due) : nil
        if keepGoing && store.draft != nil { focused = true }
    }
}

struct ReminderMenu: View {
    let ids: [String]
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        let one = ids.count == 1 ? store.snap.reminders[ids[0]] : nil
        let locked = ids.allSatisfy(store.locked)
        Button(one?.isCompleted == true ? "Mark as Not Completed" : "Mark as Completed") { store.toggleComplete(ids, undo: um) }
            .disabled(locked)
        Menu("Priority") {
            ForEach(Priority.allCases.reversed(), id: \.self) { p in Button(p.label) { store.setPriority(ids, p, undo: um) } }
        }
        .disabled(locked)
        Menu("Due") {
            Button("Today") { due(store.clock.today) }
            Button("Tomorrow") { due(Due.tomorrow(store.clock)) }
            Button("This Weekend") { due(Due.thisWeekend(store.clock)) }
            Button("Next Week") { due(Due.nextWeek(store.clock)) }
            Divider()
            Button("Clear") { store.setDue(ids, { _ in nil }, undo: um) }
        }
        .disabled(locked)
        Button("Move to…") { store.selection = Set(ids); store.showMoveSheet = true }.disabled(locked)
        if let one {
            Divider()
            Button("Show Info") { store.editingID = one.id }
            Button("Open in Reminders") { store.openInReminders(reminder: one.id) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("x-apple-reminderkit://REMCDReminder/\(one.id)", forType: .string)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.requestDelete(ids, undo: um) }.disabled(locked)
    }

    private func due(_ day: Date) { store.setDue(ids, { Due.moving($0.due, toDay: day, clock: store.clock) }, undo: um) }
}

private struct ViewOptions: View {
    let destination: Destination
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        if destination == .today { Toggle("Group by Time", isOn: $store.groupByTime) }
        if case .list(let id) = destination {
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

struct MoveSheet: View {
    let ids: [String]
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move \(ids.count == 1 ? "Reminder" : "\(ids.count) Reminders")").font(.headline)
            TextField("Type a list name", text: $filter).textFieldStyle(.roundedBorder)
                .onSubmit { if let first = matches.first { move(to: first.id) } }
            List(matches) { l in
                Button { move(to: l.id) } label: {
                    HStack {
                        Circle().fill(Color(l.color)).frame(width: 8, height: 8)
                        Text(l.title)
                        Spacer()
                        Text(l.accountTitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var matches: [RList] {
        let all = store.orderedListIDs.compactMap(store.list).filter { !$0.readOnly }
        return filter.isEmpty ? all : all.filter { $0.title.localizedStandardContains(filter) }
    }

    private func move(to listID: String) {
        store.move(ids, toList: listID, undo: um)   // asks first when it crosses accounts
        dismiss()
    }
}

struct ListEditor: View {
    let list: RList?
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var color = RGBA(r: 0, g: 0.48, b: 1)
    @State private var accountID: String?

    /// Reminders' palette.
    static let palette: [RGBA] = [
        RGBA(r: 1, g: 0.23, b: 0.19), RGBA(r: 1, g: 0.58, b: 0), RGBA(r: 1, g: 0.8, b: 0), RGBA(r: 0.2, g: 0.78, b: 0.35),
        RGBA(r: 0.35, g: 0.78, b: 0.98), RGBA(r: 0, g: 0.48, b: 1), RGBA(r: 0.35, g: 0.34, b: 0.84), RGBA(r: 1, g: 0.18, b: 0.33),
        RGBA(r: 0.69, g: 0.32, b: 0.87), RGBA(r: 0.64, g: 0.52, b: 0.37), RGBA(r: 0.56, g: 0.56, b: 0.58), RGBA(r: 0.85, g: 0.65, b: 0.6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(list == nil ? "New List" : "List Info").font(.headline)
            TextField("Name", text: $title).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(Self.palette, id: \.self) { c in
                    Circle().fill(Color(c)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.primary.opacity(c == color ? 0.8 : 0), lineWidth: 2))
                        .onTapGesture { color = c }
                }
            }
            if list == nil && store.snap.accounts.count > 1 {
                Picker("Account", selection: $accountID) {
                    ForEach(store.snap.accounts) { Text($0.title).tag(Optional($0.id)) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(list == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            title = list?.title ?? ""
            color = list?.color ?? color
            accountID = list?.accountID ?? store.snap.defaultListID.flatMap { store.list($0)?.accountID }
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if let list {
            store.updateList(list.id, title: t != list.title ? t : nil, color: color != list.color ? color : nil, undo: um)
        } else {
            store.createList(title: t, color: color, accountID: accountID)
        }
        dismiss()
    }
}
