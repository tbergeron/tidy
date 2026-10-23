import AppKit
import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    private static let style: [Destination: (String, Color)] = [
        .today: ("star.fill", .yellow), .scheduled: ("calendar", .red), .all: ("tray.fill", .gray),
        .flagged: ("flag.fill", .orange), .completed: ("checkmark.circle.fill", .green),
        .assigned: ("person.crop.circle.fill", .teal), .urgent: ("alarm.fill", .red),
    ]

    var body: some View {
        let selection = Binding<Destination?>(get: { store.destination }, set: { if let d = $0 { store.destination = d } })
        List(selection: selection) {
            Section {
                let smart = store.orderedSmart.filter { store.isAvailable($0) && !store.hiddenSmartLists.contains(store.title($0)) }
                ForEach(smart, id: \.self) { d in
                    let title = store.title(d), (icon, color) = Self.style[d] ?? ("list.bullet", .gray)
                    Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
                        .badge(store.count(d) ?? 0)
                        .tag(d)
                        .dropDestination(for: DragItems.self) { items, _ -> Bool in drop(items, on: d) }
                        .contextMenu { Button("Hide “\(title)”") { store.hiddenSmartLists.insert(title) } }
                }
                .onMove { from, to in store.reorder(smart.map(store.title), from: from, to: to, in: &store.smartOrder) }
            }

            if !store.pinnedLists.isEmpty {
                Section("Pinned") { ForEach(store.pinnedLists) { ListRow(list: $0) } }
            }

            ForEach(store.sidebarAccounts) { acc in
                Section(store.sidebarAccounts.count > 1 ? acc.account.title : "Lists") {
                    // Pinned lists already appear in the Pinned section.
                    let entries = acc.entries.filter { if case .list(let l) = $0 { !(store.bridgeReadable && l.isPinned) } else { true } }
                    ForEach(entries) { entry in
                        switch entry {
                        case .list(let l):
                            ListRow(list: l)
                        case .group(let g, let lists):
                            DisclosureGroup(isExpanded: expanded(g.id)) {
                                ForEach(lists) { ListRow(list: $0) }
                                    .onMove { from, to in store.reorder(lists.map(\.id), from: from, to: to, in: &store.sidebarOrder) }
                            } label: {
                                Label(g.name, systemImage: "folder").fontWeight(.semibold)
                                    .badge(store.count(.group(g.id)) ?? 0)
                                    .tag(Destination.group(g.id))
                            }
                        }
                    }
                    .onMove { from, to in store.reorder(entries.map(\.id), from: from, to: to, in: &store.sidebarOrder) }
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
        .background(ListDropFix(rows: store.sidebarAccounts.count + store.orderedSmart.count + store.snap.lists.count))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { store.showNewList = true } label: { Label("New List", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
            .background(.bar)   // list rows scroll underneath; without a background they showed through
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
            Button("Hide List") { store.hiddenLists.insert(list.id) }
            Divider()
            Button("Delete List…", role: .destructive) { store.prepareListDelete(list) }.disabled(list.immutable)
        }
    }

    /// completed ÷ total over the loaded window. ponytail: completed reminders older than the window aren't counted.
    private var progress: Double { store.progress(list.id) }
}

/// A row's `dropDestination` registers twice: on the List's table (which highlights the row and runs the action)
/// and on a view SwiftUI lays over the row's content, which takes the drag there without highlighting.
/// This unregisters those inner views on ordinary rows (again after scrolling brings in new cells) so the table
/// handles the whole row.
/// ponytail: relies on SwiftUI's AppKit view layout; if it changes, drops still work, only the highlight gap returns.
struct ListDropFix: NSViewRepresentable {
    let rows: Int   // re-runs when rows come and go

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(near: v) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private weak var table: NSView?
        private var observer: NSObjectProtocol?

        func attach(near probe: NSView) {
            guard let root = probe.window?.contentView else { return }
            let x = probe.convert(probe.bounds, to: nil).midX
            // The probe's List: the narrowest table under it (the detail list's scroll view runs under the sidebar).
            let frames = Self.views(root).compactMap { v -> (NSView, CGRect)? in
                guard v is NSTableView, let sv = v.enclosingScrollView else { return nil }
                return (v, sv.convert(sv.bounds, to: nil))
            }
            guard let t = frames.filter({ $0.1.minX <= x && x <= $0.1.maxX }).min(by: { $0.1.width < $1.1.width })?.0 else { return }
            if t !== table, let clip = t.enclosingScrollView?.contentView {
                table = t
                if let observer { NotificationCenter.default.removeObserver(observer) }
                clip.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.unregisterInner() } }
                }
            }
            unregisterInner()
        }

        /// Section headings are group rows, which the table doesn't take drops on, so they keep their own target.
        private func unregisterInner() {
            guard let table = table as? NSTableView else { return }
            for r in 0..<table.numberOfRows {
                guard let row = table.rowView(atRow: r, makeIfNecessary: false), !row.isGroupRowStyle else { continue }
                for v in Self.views(row) where String(describing: type(of: v)).contains("DraggingDestination") && !v.registeredDraggedTypes.isEmpty {
                    v.unregisterDraggedTypes()
                }
            }
        }

        private static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    }
}

