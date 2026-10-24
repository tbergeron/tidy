import SwiftUI
import UIKit

/// The Mac card as a sheet. Text commits after 1 s idle and when the sheet closes; Cancel puts back everything
/// changed since it opened (the Mac's Esc). Only keys changed against `base` are written (R11).
/// New-reminder mode: nothing is saved until it closes with a title; "Next" saves and starts another.
struct ReminderEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @Environment(\.dismiss) private var dismiss
    @State private var base: Reminder
    @State private var draft: Reminder
    @State private var titleDates = TitleDetection()
    @State private var showDate = false
    @State private var showCustomRepeat = false
    @State private var confirmClearRepeat = false
    @State private var confirmRepeatReplace: PendingRepeat?
    @State private var discarded = false
    @FocusState private var notesFocused: Bool
    private struct PendingRepeat { var recurrence: Recurrence? }
    private let isNew: Bool
    private let original: Reminder

    init(reminder: Reminder) {
        _base = State(initialValue: reminder)
        _draft = State(initialValue: reminder)
        original = reminder
        isNew = false
    }

    init(newReminder: Reminder) {
        _base = State(initialValue: newReminder)
        _draft = State(initialValue: newReminder)
        original = newReminder
        isNew = true
    }

    private var list: RList? { store.list(draft.listID) }
    private var locked: Bool { list?.readOnly == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        if !isNew {
                            CheckBox(done: draft.isCompleted, color: list.map { Color($0.color) } ?? .secondary) {
                                store.toggleComplete([draft.id], undo: um)
                            }
                        }
                        HighlightTextField(text: $draft.title, placeholder: "New Reminder",
                                           highlights: titleDates.detection?.ranges ?? [], focusOnAppear: isNew,
                                           onSubmit: { notesFocused = true })
                    }
                    if let d = titleDates.detection {
                        DetectionChip(detection: d, clock: store.clock) { titleDates.ignore(&draft) }
                    }
                    TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }), axis: .vertical)
                        .lineLimit(2...10)
                        .foregroundStyle(.secondary)
                        .focused($notesFocused)
                }

                Section {
                    Button { showDate = true } label: {
                        LabeledContent {
                            Text(draft.due.map { Display.dueFull($0, clock: store.clock) } ?? "None")
                                .foregroundStyle(draft.due.map { Display.duePill($0, clock: store.clock).overdue } == true ? .red : .secondary)
                        } label: { Label("Date", systemImage: "calendar") }
                    }
                    .tint(.primary)
                    repeatRow
                    if store.showPriorities {
                        Picker(selection: Binding(get: { Priority(raw: draft.priority) }, set: { draft.priority = $0.raw; commit() })) {
                            ForEach(Priority.allCases.reversed(), id: \.self) { Text($0.label).tag($0) }
                        } label: { Label("Priority", systemImage: "exclamationmark") }
                    }
                    Picker(selection: Binding(get: { draft.listID }, set: { setList($0) })) {
                        ForEach(store.orderedListIDs.compactMap(store.list).filter { !$0.readOnly }) { l in
                            Text(l.title).tag(l.id)
                        }
                    } label: { Label("List", systemImage: "list.bullet") }
                    if !isNew && store.bridgeReadable {
                        Toggle(isOn: Binding(get: { draft.extras?.urgent == true }, set: { store.setUrgent([draft.id], $0, undo: um) })) {
                            Label("Urgent", systemImage: "alarm")
                        }
                        .disabled(!store.canSetUrgent(draft))
                    }
                }

                let kids = store.children(of: draft.id)
                if !kids.isEmpty {
                    Section("Subtasks") {
                        ForEach(kids) { k in
                            HStack(spacing: 12) {
                                CheckBox(done: k.isCompleted, round: true) { store.toggleComplete([k.id], undo: um) }
                                Text(k.title).foregroundStyle(k.isCompleted ? .secondary : .primary)
                            }
                        }
                    }
                }

                if hasChips {
                    Section { Chips(reminder: draft) }
                }

                if !isNew {
                    Section {
                        Button("Open in Reminders", systemImage: "arrow.up.forward.app") { store.openInReminders(reminder: draft.id) }
                        Button("Delete Reminder", systemImage: "trash", role: .destructive) {
                            dismiss()
                            store.requestDelete([draft.id], undo: um)
                        }
                    }
                }
            }
            .disabled(locked)
            .navigationTitle(isNew ? "New Reminder" : "Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { close() }
                        .disabled(isNew && draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if isNew {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Next", systemImage: "arrow.turn.down.left") { finishNew(); store.startCompose() }
                            .labelStyle(.titleAndIcon)
                            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents(isNew ? [.large] : [.medium, .large])
        .sheet(isPresented: $showDate, onDismiss: commit) {   // one write per date-picker session
            NavigationStack {
                DatePanel(due: Binding(get: { draft.due }, set: { setDue($0) }), clock: store.clock) { showDate = false }
                    .navigationTitle("Date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { showDate = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCustomRepeat) {
            RepeatEditor(recurrence: draft.recurrence, due: draft.due.flatMap { Due.date($0, clock: store.clock) },
                         clock: store.clock) { chooseRepeat($0) }
                .presentationDetents([.large])
        }
        .onAppear {
            if isNew { store.composeFinisher = { finishNew() } } else { store.commitOpenCard = { commit() } }
            store.cancelOpenCard = { cancel() }
        }
        .onDisappear {
            store.cancelOpenCard = nil
            if isNew { store.composeFinisher = nil; finishNew(); return }
            store.commitOpenCard = nil
            if store.snap.reminders[base.id] == nil {
                // Deleted on another device (or here) while open: keep typed text instead of dropping it.
                if !Edits.diff(base: base, draft: draft).isEmpty && store.pendingDeletes[base.id] == nil { store.orphanedDraft = draft }
            } else {
                commit()
            }
        }
        .onChange(of: draft.title) { titleDates.update(&draft, original: original, isNew: isNew, clock: store.clock) }
        .task(id: draft.title + "\u{0}" + (draft.notes ?? "")) {
            guard !isNew else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { commit() }
        }
        .onChange(of: store.snap.reminders[base.id]) { _, fresh in
            guard !isNew, let fresh else { return }
            (base, draft) = Edits.rebase(base: base, draft: draft, fresh: fresh)
        }
        .confirmationDialog("Clearing the date also stops the repeat.", isPresented: $confirmClearRepeat) {
            Button("Clear Date and Repeat", role: .destructive) {
                draft.due = nil
                draft.recurrence = nil
                showDate = false
                commit()
            }
        } message: {
            Text(store.bridgeReadable ? "Repeating reminders need a date." : "Repeating reminders need a date. If this repeat is Hourly (set in Reminders), it will be removed.")
        }
        .confirmationDialog("Replace the current repeat?", isPresented: Binding(
            get: { confirmRepeatReplace != nil }, set: { if !$0 { confirmRepeatReplace = nil } })
        ) {
            Button("Replace") { if let p = confirmRepeatReplace { applyRepeat(p.recurrence) } }
        } message: {
            Text("Private features are off, so an Hourly repeat set in Reminders can't be detected. It would be replaced.")
        }
    }

    @ViewBuilder private var repeatRow: some View {
        if draft.extras?.hourly == true {
            LabeledContent { Text("Hourly (edit in Reminders)").foregroundStyle(.secondary) } label: { Label("Repeat", systemImage: "repeat") }
        } else {
            let current = RepeatPreset(draft.recurrence, due: draft.due, clock: store.clock)
            Menu {
                ForEach(RepeatPreset.allCases.filter { $0 != .custom }, id: \.self) { p in
                    Toggle(p.rawValue, isOn: Binding(get: { current == p }, set: { _ in chooseRepeat(p.recurrence()) }))
                }
                Divider()
                Button("Custom…") { showCustomRepeat = true }
            } label: {
                LabeledContent {
                    Text(RecurrenceMap.describe(draft.recurrence, due: draft.due, clock: store.clock) ?? "Never").foregroundStyle(.secondary)
                } label: { Label("Repeat", systemImage: "repeat") }
            }
            .tint(.primary)
        }
    }

    private var hasChips: Bool {
        let x = draft.extras
        return !(x?.tags.isEmpty ?? true) || !(x?.urls.isEmpty ?? true) || !(x?.images.isEmpty ?? true)
            || !(x?.earlyAlerts.isEmpty ?? true) || draft.alarms.contains { $0.location != nil }
    }

    private func setList(_ id: String) {
        if isNew { draft.listID = id } else { commit(); store.move([draft.id], toList: id, undo: um) }   // asks first when needed
    }

    /// R7: in public-only mode an existing rule might be Hourly (EventKit can't see it); ask before replacing it.
    private func chooseRepeat(_ r: Recurrence?) {
        if !store.bridgeReadable && base.recurrence != nil && r != base.recurrence { confirmRepeatReplace = PendingRepeat(recurrence: r) }
        else { applyRepeat(r) }
    }

    private func applyRepeat(_ r: Recurrence?) {
        if r != nil && draft.due == nil { draft.due = Due.components(store.clock.today, allDay: true, timeZone: nil, clock: store.clock) }
        draft.recurrence = r
        commit()
    }

    /// Updates the draft only; the date sheet commits once when it closes.
    private func setDue(_ c: DateComponents?) {
        if c == nil && draft.isRepeating {
            if draft.extras?.hourly == true { store.banner = "This reminder repeats hourly — clear its date in Reminders." }
            else { confirmClearRepeat = true }
            return
        }
        draft.due = c
    }

    /// Cancel: put back everything changed since the sheet opened. A new reminder is discarded.
    private func cancel() {
        if isNew { discarded = true; store.composing = nil; return }
        titleDates.reset()
        var restore = original
        restore.isCompleted = draft.isCompleted
        restore.completionDate = draft.completionDate
        restore.extras = draft.extras
        draft = restore
        commit()
        store.editingID = nil
    }

    private func close() {
        if isNew { finishNew() } else { store.editingID = nil }
    }

    private func finishNew() {
        guard !discarded else { return }
        store.finishCompose(titleDates.outgoing(draft), undo: um)
    }

    private func commit() {
        guard !isNew, !locked, store.snap.reminders[base.id] != nil else { return }
        let id = base.id
        let out = titleDates.outgoing(draft)
        store.commitCard(draft: out, base: base, undo: um) {
            if let stored = store.snap.reminders[id] { base = stored; draft.listID = stored.listID }
        }
        base = out
    }
}

/// "Pick a Date…" (context menu, swipe, selection bar): one write when the sheet closes, same date for every id.
struct DueSheet: View {
    let ids: [String]
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            DuePopover(ids: ids)
                .navigationTitle("Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { store.datePicker = nil } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Title field that tints the detected date words while you type (SwiftUI's TextField can't style ranges).
struct HighlightTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var highlights: [NSRange]
    var focusOnAppear = false
    var onSubmit: () -> Void = {}

    private static let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize + 2, weight: .semibold)
    private static let tint = UIColor.tintColor.withAlphaComponent(0.25)

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.font = Self.font
        f.placeholder = placeholder
        f.returnKeyType = .next
        f.delegate = context.coordinator
        f.text = text
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusOnAppear { DispatchQueue.main.async { f.becomeFirstResponder() } }
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        if f.text != text { f.text = text }
        paint(f)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func paint(_ f: UITextField) {
        guard f.markedTextRange == nil else { return }   // don't disturb IME composition
        let s = f.text ?? ""
        let length = (s as NSString).length
        let plain: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: UIColor.label]
        let attributed = NSMutableAttributedString(string: s, attributes: plain)
        for r in highlights where NSMaxRange(r) <= length { attributed.addAttribute(.backgroundColor, value: Self.tint, range: r) }
        guard f.attributedText != attributed else { return }
        let selection = f.selectedTextRange
        f.attributedText = attributed
        f.selectedTextRange = selection
        f.typingAttributes = plain
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: HighlightTextField
        init(_ parent: HighlightTextField) { self.parent = parent }

        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }

        func textFieldShouldReturn(_ f: UITextField) -> Bool { parent.onSubmit(); return false }
    }
}

struct MoveSheet: View {
    let ids: [String]
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List(matches) { l in
                Button { move(to: l.id) } label: {
                    HStack(spacing: 12) {
                        Circle().fill(Color(l.color)).frame(width: 10, height: 10)
                        Text(l.title).foregroundStyle(.primary)
                        Spacer()
                        if store.snap.accounts.count > 1 { Text(l.accountTitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .searchable(text: $filter, prompt: "List name")
            .navigationTitle(ids.count == 1 ? "Move Reminder" : "Move \(ids.count) Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var matches: [RList] {
        let all = store.orderedListIDs.compactMap(store.list).filter { !$0.readOnly }
        return filter.isEmpty ? all : all.filter { $0.title.localizedStandardContains(filter) }
    }

    private func move(to listID: String) {
        store.move(ids, toList: listID, undo: um)   // asks first across accounts / for lossy shared-list copies
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
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Image(systemName: "list.bullet.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.white, Color(color))
                        Spacer()
                    }
                    TextField("List Name", text: $title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(RGBA.palette, id: \.self) { c in
                            Circle().fill(Color(c)).frame(width: 36, height: 36)
                                .overlay(Circle().strokeBorder(.primary.opacity(c == color ? 0.5 : 0), lineWidth: 3).padding(-5))
                                .onTapGesture { color = c }
                                .accessibilityAddTraits(c == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                if list == nil && store.snap.accounts.count > 1 {
                    Picker("Account", selection: $accountID) {
                        ForEach(store.snap.accounts) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
            }
            .navigationTitle(list == nil ? "New List" : "List Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(list == nil ? "Create" : "Save", systemImage: "checkmark") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = list?.title ?? ""
                color = list?.color ?? color
                accountID = list?.accountID ?? store.snap.defaultListID.flatMap { store.list($0)?.accountID }
            }
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
