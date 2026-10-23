import SwiftUI
import UniformTypeIdentifiers

struct ReminderListView: View {
    let destination: Destination
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var store = store
        let sections = store.sections(destination)
        let draftSection = draftHost(sections)
        let firstTitled = sections.first { !$0.title.isEmpty }?.id

        List(selection: $store.selection) {
            ListHeader(destination: destination)
                .selectionDisabled()
                .listRowSeparator(.hidden)

            ForEach(sections) { section in
                Section {
                    // The first heading is a plain row: a section header at the very top would be pinned
                    // to the toolbar before you scroll. Later headers pin as you scroll past them.
                    if section.id == firstTitled {
                        SectionHeader(section: section).selectionDisabled().listRowSeparator(.hidden)
                    }
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
                        .moveDrop(section.kind, store: store, undo: um)
                    }
                    if section.id == draftSection { newRows }
                } header: {
                    if !section.title.isEmpty && section.id != firstTitled { SectionHeader(section: section) }
                }
            }
            if draftSection == nil && (store.draft != nil || store.composing != nil) {
                Section { newRows }
            }
            if sections.allSatisfy({ $0.rows.isEmpty }) && store.draft == nil && store.composing == nil && store.loaded {
                Text(store.search.isEmpty ? "No Reminders" : "No Results")
                    .font(.title3).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .selectionDisabled().listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .background(ListDropFix(rows: sections.reduce(0) { $0 + $1.rows.count + 1 }))
        .focused($listFocused)
        // Keep keyboard focus on the list so Return / Space / ⌫ work without clicking first.
        .onAppear { listFocused = true }
        .onChange(of: destination) { listFocused = true }
        .onChange(of: store.editingID == nil && store.composing == nil && store.draft == nil) { _, idle in if idle { listFocused = true } }
        .scrollContentBackground(.visible)
        .contextMenu(forSelectionType: String.self) { ids in
            // Anchor for popovers: the topmost selected row as shown.
            ReminderMenu(ids: Array(ids), anchor: sections.flatMap(\.rows).first { ids.contains($0.id) }?.id)
        } primaryAction: { ids in
            if ids.count == 1 { store.draft = nil; store.editingID = ids.first }
        }
        .onDeleteCommand { store.requestDelete(Array(store.selection), undo: um) }
        // List shortcuts only when nothing is being typed (card, new-reminder card, draft row, search, renames).
        .onKeyPress(.space) {
            guard !isTyping else { return .ignored }
            store.startDraft(); return .handled
        }
        .onKeyPress(.return) {
            guard !isTyping else { return .ignored }
            if store.selection.isEmpty { store.startCompose(); return .handled }   // nothing selected: new reminder
            guard store.selection.count == 1 else { return .ignored }
            store.editingID = store.selection.first; return .handled
        }
        .onKeyPress(.escape) {
            guard let cancel = store.cancelOpenCard else { return .ignored }
            cancel(); return .handled   // same as Esc inside the card: revert and close
        }
        .onChange(of: store.selection) { _, new in
            if !new.isEmpty { store.composeFinisher?() }   // clicking another reminder closes (saves) the new one
            if let e = store.editingID, !new.contains(e) { store.editingID = nil }
        }
        .onChange(of: Set(sections.flatMap { $0.rows.map(\.id) })) { _, visible in
            // Rows that left the view (filtered, completed, moved) can't stay selected or open.
            store.selection.formIntersection(visible)
            if let e = store.editingID, !visible.contains(e) { store.editingID = nil }
        }
        .toolbar {
            ToolbarItem {
                Button { store.startCompose() } label: { Label("New Reminder", systemImage: "plus") }
                    .disabled(!store.canCreate)
            }
            ToolbarItem {
                Menu {
                    ViewOptions(destination: destination)
                } label: { Label("View", systemImage: "ellipsis.circle") }
            }
            ToolbarItem {
                SearchField(text: $store.search).frame(width: 180)
            }
        }
        .navigationTitle(store.title(destination))
    }

    private var isListView: Bool { if case .list = destination { true } else { false } }

    private var isTyping: Bool {
        NSApp.keyWindow?.firstResponder is NSText   // a text field's field editor
            || store.editingID != nil || store.composing != nil || store.draft != nil
    }

    /// The quick one-line draft (Space) or the full new-reminder card (+ / ⌘N).
    @ViewBuilder private var newRows: some View {
        if let c = store.composing {
            CardView(newReminder: c).id(c.id).listRowSeparator(.hidden).selectionDisabled()
        } else if store.draft != nil {
            DraftRow().listRowSeparator(.hidden).selectionDisabled()
        }
    }

    /// The section that receives the draft row: the target list's section in grouped views, else the first plain one.
    private func draftHost(_ sections: [Store.RowSection]) -> String? {
        let target = store.composing?.listID ?? store.draft?.listID ?? store.snap.defaultListID
        if let s = sections.first(where: { $0.kind == .list(target ?? "") }) { return s.id }
        return sections.first { s in
            if case .list = s.kind { return false }
            return ![.overdue, .completed].contains(s.kind)
        }?.id
    }
    private func dragIDs(_ id: String) -> [String] { store.selection.contains(id) ? Array(store.selection) : [id] }
}

/// Tag filter bar for the view (the title itself is in the window toolbar).
private struct ListHeader: View {
    let destination: Destination
    @Environment(Store.self) private var store

    var body: some View {
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
            .padding(.vertical, 4)
        }
    }
}

/// Small text button with a hover highlight (and the pointing-hand cursor).
private struct HoverButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(hover ? Color.accentColor : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(hover ? Color.accentColor.opacity(0.15) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.12), value: hover)
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
                HoverButton("Move All to Today") { store.requestMoveOverdueToToday() }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)   // the whole heading row is the drop target
        .contentShape(Rectangle())
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
        .moveDrop(section.kind, store: store, undo: um) { targeted = $0 }
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
            if row.depth == 0, case let kids = store.children(of: r.id), !kids.isEmpty {
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
        .popover(isPresented: Binding(get: { store.datePicker?.anchor == r.id }, set: { if !$0 { store.datePicker = nil } }),
                 arrowEdge: .trailing) {
            DuePopover(ids: store.datePicker?.ids ?? [r.id])
        }
    }

    private func toggleCollapsed(_ id: String) {
        if store.collapsed.contains(id) { store.collapsed.remove(id) } else { store.collapsed.insert(id) }
    }
}

/// Inline create row: Return creates and starts the next one; Esc cancels when empty.
private struct DraftRow: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        let text = store.draft?.text ?? ""
        let detection = NaturalDate.parse(text, clock: store.clock)
        HStack(spacing: 8) {
            CheckBox(done: false) {}.disabled(true)
            HighlightField(text: Binding(get: { store.draft?.text ?? "" }, set: { store.draft?.text = $0 }),
                           placeholder: "New Reminder", font: .systemFont(ofSize: NSFont.systemFontSize),
                           highlights: detection?.ranges ?? [], focusOnAppear: true,
                           onSubmit: { commit(keepGoing: true) }, onEscape: { commit(keepGoing: false) },
                           onEndEditing: { commit(keepGoing: false) })
            if let detection {
                DetectionChip(detection: detection, clock: store.clock) {}.fixedSize()
            }
        }
        .padding(.vertical, 4)
    }

    private func commit(keepGoing: Bool) {
        guard let d = store.draft else { return }
        if !d.text.trimmingCharacters(in: .whitespaces).isEmpty {
            store.createParsed(d.text, listID: d.listID, due: d.due, undo: um)
        }
        store.draft = keepGoing && !d.text.isEmpty ? Store.Draft(listID: d.listID, due: d.due) : nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(list == nil ? "New List" : "List Info").font(.headline)
            TextField("Name", text: $title).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(RGBA.palette, id: \.self) { c in
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
