import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name { static let tidyFocusSearch = Notification.Name("tidyFocusSearch") }   // ⌘F

extension UTType { static let ttrItems = UTType(exportedAs: "com.tidyreminders.items") }

/// Drag payload: only IDs, never EventKit objects.
struct DragItems: Codable, Transferable {
    var reminderIDs: [String]
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .ttrItems) }
}

extension View {
    /// Only a list's heading and rows take drops (moving the reminders to that list); day and time headings don't.
    @ViewBuilder func moveDrop(_ kind: Store.RowSection.Kind, store: Store, undo um: UndoManager?,
                               targeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        if case .list(let lid) = kind {
            dropDestination(for: DragItems.self) { items, _ in
                store.move(items.flatMap(\.reminderIDs), toList: lid, undo: um)
                return true
            } isTargeted: { targeted($0) }
        } else {
            self
        }
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
                Text(t).font(.caption).lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 1)
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
                    .lineLimit(1).fixedSize()   // in a narrow window the title truncates, not the date
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.12)))
                    .foregroundStyle(pill.overdue && !r.isCompleted ? Color.red : .secondary)
                    .help(Display.dueFull(due, clock: store.clock))
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
            // The empty box is only an outline, and a plain button is hit-tested on what it draws, so only the 1 pt
            // border took clicks (the rest selected the row). Make the whole box plus a margin clickable.
            .contentShape(Rectangle().inset(by: -5))
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: done)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Completed" : "Not completed")
    }
}

/// Things-style project pie.
struct ProgressPie: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1.5)
            PieSlice(fraction: fraction).fill(color).padding(3)
        }
        .frame(width: 14, height: 14)
    }
}

struct PieSlice: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(fraction, 1)), clockwise: false)
        p.closeSubpath()
        return p
    }
}

extension Color {
    init(_ c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

/// Summary chips for what's set (read-only for bridge-only data until M3).
struct Chips: View {
    let reminder: Reminder
    @Environment(Store.self) private var store

    var body: some View {
        let r = reminder, x = r.extras
        let items: [String] = [
            RecurrenceMap.describe(r.recurrence, hourly: x?.hourly == true, due: r.due, clock: store.clock).map { "Repeats " + $0.prefix(1).lowercased() + $0.dropFirst() },
            (x?.earlyAlerts ?? []).first.map { earlyText($0) },
            x?.urgent == true ? "Urgent" : nil,
            r.alarms.compactMap(\.location).first.map { ($0.leaving ? "Leaving: " : "Arriving: ") + $0.title },
        ].compactMap { $0 }
        if r.due != nil || !items.isEmpty || !(x?.tags.isEmpty ?? true) || !(x?.urls.isEmpty ?? true) || !(x?.images.isEmpty ?? true) {
            FlowRow {
                ForEach(x?.tags ?? [], id: \.self) { Text("#" + $0).chip() }
                if let due = r.due {
                    Text(Display.duePill(due, clock: store.clock).text).chip().help(Display.dueFull(due, clock: store.clock))
                }
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

extension View {
    func chip() -> some View {
        font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

/// Minimal wrapping row for chips.
struct FlowRow: Layout {
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

/// The chip under a title showing what was detected, with ✕ to ignore it.
struct DetectionChip: View {
    let detection: NaturalDate.Detection
    let clock: Clock
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text(text).lineLimit(1)
            if detection.hourly {
                Text("· hourly repeats need Reminders").foregroundStyle(.orange).lineLimit(1)
            }
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Ignore — keep the words in the title")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }

    private var text: String {
        [detection.due.map { Display.duePill($0, clock: clock).text },
         RecurrenceMap.describe(detection.recurrence, due: detection.due, clock: clock).map { "Repeats " + $0.prefix(1).lowercased() + $0.dropFirst() }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
