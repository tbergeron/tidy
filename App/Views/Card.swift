import SwiftUI

/// Things-style inline editor. Text commits after 1 s idle and on close; discrete controls commit at once.
/// Only keys changed against `base` are written (R11).
struct CardView: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var base: Reminder
    @State private var draft: Reminder
    @State private var showDate = false
    @State private var confirmRepeatReplace: PendingRepeat?
    @State private var showCustomRepeat = false
    private struct PendingRepeat { var recurrence: Recurrence? }
    @State private var confirmClearRepeat = false
    @FocusState private var focus: Field?
    private enum Field { case title, notes }
    /// New-reminder mode (+ / ⌘N): edits a draft only; the reminder is created when the card closes with a title.
    private let isNew: Bool
    /// The reminder as it was when the card opened; Esc restores it (edits are saved as you go).
    private let original: Reminder
    @State private var discarded = false
    /// Date/repeat typed in the title ("tonight", "every day"…), applied to the draft.
    @State private var titleDates = TitleDetection()

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CheckBox(done: draft.isCompleted, color: list.map { Color($0.color) } ?? .secondary) {
                    store.toggleComplete([draft.id], undo: um)
                }
                .disabled(isNew)
                HighlightField(text: $draft.title, placeholder: "New Reminder",
                               font: .systemFont(ofSize: 15, weight: .semibold),
                               highlights: titleDates.detection?.ranges ?? [], focusOnAppear: true,
                               onSubmit: { focus = .notes }, onEscape: cancel)
            }
            if let d = titleDates.detection {
                DetectionChip(detection: d, clock: store.clock) { titleDates.ignore(&draft) }.padding(.leading, 23)
            }
            TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1...12)
                .focused($focus, equals: .notes)
                .onSubmit { close(); store.startCompose() }   // Return chains to the next new reminder; ⌥Return is a new line
                .padding(.leading, 23)

            let kids = store.children(of: draft.id)
            if !kids.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(kids) { k in
                        HStack(spacing: 8) {
                            CheckBox(done: k.isCompleted, round: true) { store.toggleComplete([k.id], undo: um) }
                            Text(k.title).foregroundStyle(k.isCompleted ? .secondary : .primary)
                        }
                    }
                }
                .padding(.leading, 23)
            }

            Chips(reminder: draft).padding(.leading, 23)

            HStack(spacing: 14) {
                Spacer()
                Button { showDate = true } label: { Image(systemName: "calendar") }
                    .help("Date (⌘S)").keyboardShortcut("s")
                    .popover(isPresented: $showDate, arrowEdge: .bottom) {
                        DatePanel(due: Binding(get: { draft.due }, set: { setDue($0) }), clock: store.clock) { showDate = false }
                    }
                    .onChange(of: showDate) { _, open in if !open { commit() } }   // one write per popover session
                repeatMenu
                if store.showPriorities {
                    Menu {
                        ForEach(Priority.allCases.reversed(), id: \.self) { p in
                            Button(p.label) { draft.priority = p.raw; commit() }
                        }
                    } label: { Image(systemName: "exclamationmark") }
                        .menuIndicator(.hidden).fixedSize().help("Priority")
                }
                Menu {
                    ForEach(store.orderedListIDs.compactMap(store.list).filter { !$0.readOnly }) { l in
                        Button(l.title) {
                            if isNew { draft.listID = l.id } else { commit(); store.move([draft.id], toList: l.id, undo: um) }   // asks first across accounts
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet")
                        if let list { Text(list.title).lineLimit(1) }
                    }
                }
                    .menuIndicator(.hidden).fixedSize().help("List")
                Menu {
                    if isNew {
                        Button("Discard", role: .destructive) { discarded = true; store.composing = nil }
                    } else {
                        Button("Open in Reminders") { store.openInReminders(reminder: draft.id) }
                        Button("Delete", role: .destructive) { store.requestDelete([draft.id], undo: um) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize()
                Button("", action: close).keyboardShortcut(.return, modifiers: .command).hidden().frame(width: 0)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .disabled(locked)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
        .padding(.vertical, 6)
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
        .onExitCommand(perform: cancel)
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

    @ViewBuilder private var repeatMenu: some View {
        if draft.extras?.hourly == true {
            Image(systemName: "repeat").help("Hourly repeat — edit in Reminders")
        } else {
            let current = RepeatPreset(draft.recurrence, due: draft.due, clock: store.clock)
            Menu {
                ForEach(RepeatPreset.allCases.filter { $0 != .custom }, id: \.self) { p in
                    Toggle(p.rawValue, isOn: Binding(get: { current == p }, set: { _ in chooseRepeat(p.recurrence()) }))
                }
                Divider()
                if current == .custom, let text = RecurrenceMap.describe(draft.recurrence, due: draft.due, clock: store.clock) {
                    Toggle(text, isOn: Binding(get: { true }, set: { _ in showCustomRepeat = true }))
                }
                Button("Custom…") { showCustomRepeat = true }
            } label: { Image(systemName: "repeat") }
                .menuIndicator(.hidden).fixedSize().help("Repeat")
                .sheet(isPresented: $showCustomRepeat) {
                    RepeatEditor(recurrence: draft.recurrence, due: draft.due.flatMap { Due.date($0, clock: store.clock) },
                                 clock: store.clock) { chooseRepeat($0) }
                }
        }
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

    /// Updates the draft only; the popover commits once when it closes.
    private func setDue(_ c: DateComponents?) {
        if c == nil && draft.isRepeating {
            // EventKit needs a date for a repeat (R7). Hourly can't be rewritten, so send the user to Reminders.
            if draft.extras?.hourly == true { store.banner = "This reminder repeats hourly — clear its date in Reminders." }
            else { confirmClearRepeat = true }
            return
        }
        draft.due = c
    }

    /// Esc: put back everything changed since the card opened, then close. A new reminder is discarded.
    /// Completion stays as is (it's its own action, undoable with ⌘Z; a repeating one has already advanced).
    private func cancel() {
        if isNew { discarded = true; store.composing = nil; return }
        titleDates.reset()
        var restore = original
        restore.isCompleted = draft.isCompleted
        restore.completionDate = draft.completionDate
        restore.extras = draft.extras
        draft = restore
        commit()   // writes only the keys that differ from what's saved now
        store.editingID = nil
    }

    private func close() {
        if isNew { finishNew() } else { store.editingID = nil }
    }

    private func finishNew() {
        guard !discarded else { return }
        store.finishCompose(outgoing, undo: um)
    }

    /// What gets saved: the draft, with the detected date words taken out of the title.
    private var outgoing: Reminder { titleDates.outgoing(draft) }

    private func commit() {
        guard !isNew, !locked, store.snap.reminders[base.id] != nil else { return }
        let id = base.id
        let out = outgoing
        store.commitCard(draft: out, base: base, undo: um) {
            // Failed: fall back to what's stored, so the user's text is retried on the next commit.
            if let stored = store.snap.reminders[id] { base = stored; draft.listID = stored.listID }
        }
        base = out   // the field keeps the typed words; the saved title is clean
    }
}

