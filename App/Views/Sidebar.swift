import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    private static let smart: [(Destination, String, String, Color)] = [
        (.today, "Today", "star.fill", .yellow),
        (.scheduled, "Scheduled", "calendar", .red),
        (.all, "All", "tray.fill", .gray),
        (.flagged, "Flagged", "flag.fill", .orange),
        (.completed, "Completed", "checkmark.circle.fill", .green),
        (.assigned, "Assigned to Me", "person.crop.circle.fill", .teal),
        (.urgent, "Urgent", "alarm.fill", .red),
        (.calendar, "Calendar", "calendar.day.timeline.left", .blue),
    ]

    var body: some View {
        let selection = Binding<Destination?>(get: { store.destination }, set: { if let d = $0 { store.destination = d } })
        List(selection: selection) {
            Section {
                ForEach(Self.smart.filter { store.isAvailable($0.0) && !store.hiddenSmartLists.contains($0.1) }, id: \.0) { d, title, icon, color in
                    Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
                        .badge(store.count(d) ?? 0)
                        .tag(d)
                        .dropDestination(for: DragItems.self) { items, _ -> Bool in drop(items, on: d) }
                        .contextMenu { Button("Hide “\(title)”") { store.hiddenSmartLists.insert(title) } }
                }
                if !store.hiddenSmartLists.isEmpty {
                    Menu("Show Hidden") {
                        ForEach(store.hiddenSmartLists.sorted(), id: \.self) { t in Button(t) { store.hiddenSmartLists.remove(t) } }
                    }
                    .menuStyle(.borderlessButton).foregroundStyle(.secondary).font(.caption)
                }
            }

            if !store.pinnedLists.isEmpty {
                Section("Pinned") { ForEach(store.pinnedLists) { ListRow(list: $0) } }
            }

            ForEach(store.sidebarAccounts) { acc in
                Section(store.sidebarAccounts.count > 1 ? acc.account.title : "Lists") {
                    // Pinned lists already appear in the Pinned section.
                    ForEach(acc.entries.filter { if case .list(let l) = $0 { !(store.bridgeReadable && l.isPinned) } else { true } }) { entry in
                        switch entry {
                        case .list(let l):
                            ListRow(list: l)
                        case .group(let g, let lists):
                            DisclosureGroup(isExpanded: expanded(g.id)) {
                                ForEach(lists) { ListRow(list: $0) }
                            } label: {
                                Label(g.name, systemImage: "folder").fontWeight(.semibold)
                                    .badge(store.count(.group(g.id)) ?? 0)
                                    .tag(Destination.group(g.id))
                            }
                        }
                    }
                }
            }

            let tags = store.allTags
            if store.bridgeReadable && !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.name) { t in
                        Label("#" + t.name, systemImage: "number").labelStyle(.titleOnly)
                            .badge(t.count)
                            .tag(Destination.tag(t.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { store.showNewList = true } label: { Label("New List", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !store.collapsed.contains(id) },
                set: { if $0 { store.collapsed.remove(id) } else { store.collapsed.insert(id) } })
    }

    private func drop(_ items: [DragItems], on d: Destination) -> Bool {
        let ids = items.flatMap(\.reminderIDs)
        switch d {
        case .today:
            store.setDue(ids, { Due.moving($0.due, toDay: store.clock.today, clock: store.clock) }, undo: um)
            return true
        default:
            return false   // Flagged / tags become drop targets with the bridge writes (M3).
        }
    }
}

struct ListRow: View {
    let list: RList
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(list.title)
                if list.isShared { Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.secondary) }
            }
        } icon: {
            if let e = list.emblem, e.unicodeScalars.first?.properties.isEmoji == true, e.count == 1 {
                Text(e)
            } else {
                ProgressPie(fraction: progress, color: Color(list.color))
            }
        }
        .badge(store.count(.list(list.id)) ?? 0)
        .tag(Destination.list(list.id))
        .dropDestination(for: DragItems.self) { items, _ in
            guard !list.readOnly else { return false }
            store.move(items.flatMap(\.reminderIDs), toList: list.id, undo: um)
            return true
        }
        .contextMenu {
            Button("Rename / Color…") { store.listToEdit = list }.disabled(list.immutable)
            Button(store.showCompleted.contains(list.id) ? "Hide Completed" : "Show Completed") {
                if store.showCompleted.contains(list.id) { store.showCompleted.remove(list.id) } else { store.showCompleted.insert(list.id) }
            }
            Button("Open in Reminders") { store.openInReminders(list: list.id) }
            Divider()
            Button("Delete List…", role: .destructive) { store.prepareListDelete(list) }.disabled(list.immutable)
        }
    }

    /// completed ÷ total over the loaded window. ponytail: completed reminders older than the window aren't counted.
    private var progress: Double {
        let rs = store.live.filter { $0.listID == list.id }
        guard !rs.isEmpty else { return 0 }
        return Double(rs.filter(\.isCompleted).count) / Double(rs.count)
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
