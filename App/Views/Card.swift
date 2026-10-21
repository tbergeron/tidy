import SwiftUI

/// Things-style inline editor. Text commits after 1 s idle and on close; discrete controls commit at once.
/// Only keys changed against `base` are written (R11).
struct CardView: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var base: Reminder
    @State private var draft: Reminder
    @State private var showDate = false
    @State private var confirmRepeatReplace: RepeatPreset?
    @State private var confirmClearRepeat = false
    @FocusState private var focus: Field?
    private enum Field { case title, notes }
    /// New-reminder mode (+ / ⌘N): edits a draft only; the reminder is created when the card closes with a title.
    private let isNew: Bool
    @State private var discarded = false

    init(reminder: Reminder) {
        _base = State(initialValue: reminder)
        _draft = State(initialValue: reminder)
        isNew = false
    }

    init(newReminder: Reminder) {
        _base = State(initialValue: newReminder)
        _draft = State(initialValue: newReminder)
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
                TextField("New Reminder", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .notes }
            }
            TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1...12)
                .focused($focus, equals: .notes)
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
                Menu {
                    ForEach(Priority.allCases.reversed(), id: \.self) { p in
                        Button(p.label) { draft.priority = p.raw; commit() }
                    }
                } label: { Image(systemName: "exclamationmark") }
                    .menuIndicator(.hidden).fixedSize().help("Priority")
                Menu {
                    ForEach(store.orderedListIDs.compactMap(store.list).filter { !$0.readOnly }) { l in
                        Button(l.title) {
                            if isNew { draft.listID = l.id } else { commit(); store.move([draft.id], toList: l.id, undo: um) }   // asks first across accounts
                        }
                    }
                } label: { Image(systemName: "list.bullet") }
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
            focus = .title
            if isNew { store.composeFinisher = { finishNew() } } else { store.commitOpenCard = { commit() } }
        }
        .onDisappear {
            if isNew { store.composeFinisher = nil; finishNew(); return }
            store.commitOpenCard = nil
            if store.snap.reminders[base.id] == nil {
                // Deleted on another device (or here) while open: keep typed text instead of dropping it.
                if !Edits.diff(base: base, draft: draft).isEmpty && store.pendingDeletes[base.id] == nil { store.orphanedDraft = draft }
            } else {
                commit()
            }
        }
        .onExitCommand(perform: close)
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
            Button("Replace") { if let p = confirmRepeatReplace { applyRepeat(p) } }
        } message: {
            Text("Private features are off, so an Hourly repeat set in Reminders can't be detected. It would be replaced.")
        }
    }

    @ViewBuilder private var repeatMenu: some View {
        if draft.extras?.hourly == true {
            Image(systemName: "repeat").help("Hourly repeat — edit in Reminders")
        } else {
            Menu {
                ForEach(RepeatPreset.allCases.filter { $0 != .custom }, id: \.self) { p in
                    Button(p.rawValue) {
                        // R7: in public-only mode an existing rule might be Hourly; ask before replacing it.
                        if !store.bridgeReadable && base.recurrence != nil && p.recurrence() != base.recurrence { confirmRepeatReplace = p } else { applyRepeat(p) }
                    }
                }
            } label: { Image(systemName: "repeat") }
                .menuIndicator(.hidden).fixedSize().help("Repeat")
        }
    }

    private func applyRepeat(_ p: RepeatPreset) {
        let r = p.recurrence()
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

    private func close() {
        if isNew { finishNew() } else { store.editingID = nil }
    }

    private func finishNew() {
        guard !discarded else { return }
        store.finishCompose(draft, undo: um)
    }

    private func commit() {
        guard !isNew, !locked, store.snap.reminders[base.id] != nil else { return }
        let id = base.id
        store.commitCard(draft: draft, base: base, undo: um) {
            // Failed: fall back to what's stored, so the user's text is retried on the next commit.
            if let stored = store.snap.reminders[id] { base = stored; draft.listID = stored.listID }
        }
        base = draft
    }
}

/// Summary chips for what's set (read-only for bridge-only data until M3).
private struct Chips: View {
    let reminder: Reminder
    @Environment(Store.self) private var store

    var body: some View {
        let r = reminder, x = r.extras
        let items: [String] = [
            r.due.map { Display.duePill($0, clock: store.clock).text },
            RecurrenceMap.describe(r.recurrence, hourly: x?.hourly == true).map { "Repeats " + $0.lowercased() },
            (x?.earlyAlerts ?? []).first.map { earlyText($0) },
            x?.urgent == true ? "Urgent" : nil,
            r.alarms.compactMap(\.location).first.map { ($0.leaving ? "Leaving: " : "Arriving: ") + $0.title },
        ].compactMap { $0 }
        if !items.isEmpty || !(x?.tags.isEmpty ?? true) || !(x?.urls.isEmpty ?? true) || !(x?.images.isEmpty ?? true) {
            FlowRow {
                ForEach(x?.tags ?? [], id: \.self) { Text("#" + $0).chip() }
                ForEach(items, id: \.self) { Text($0).chip() }
                ForEach(x?.urls ?? [], id: \.self) { u in
                    Link(destination: u) { Label(u.host() ?? u.absoluteString, systemImage: "link").chip() }
                }
                ForEach(Array((x?.images ?? []).enumerated()), id: \.offset) { _, img in
                    Button { store.openInReminders(reminder: r.id) } label: {
                        Label("\(img.width)×\(img.height)", systemImage: "photo").chip()
                    }.buttonStyle(.plain).help("Images open in Reminders")
                }
            }
        }
    }

    private func earlyText(_ a: EarlyAlert) -> String {
        let units = ["minute", "hour", "day", "week", "month"]
        let n = abs(a.count), u = units.indices.contains(a.unit) ? units[a.unit] : "?"
        return "Early: \(n) \(u)\(n == 1 ? "" : "s") before"
    }
}

private extension View {
    func chip() -> some View {
        font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

/// Minimal wrapping row for chips.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
