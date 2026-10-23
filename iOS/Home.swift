import SwiftUI

/// iPad: sidebar + list side by side. iPhone: Home (smart lists and lists) pushing a list.
struct MainView: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The sidebar's selection. Nil on iPhone while Home is showing; mirrors `store.destination` otherwise.
    @State private var selected: Destination?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Home(selection: $selected)
        } detail: {
            NavigationStack {
                if let d = selected ?? (sizeClass == .regular ? store.destination : nil) {
                    ListScreen(destination: d)
                }
            }
        }
        .overlay(alignment: .bottom) { BannerView().padding(.bottom, 60) }
        .onAppear {   // the app opens on Today (on iPhone, pushed over Home)
            store.destination = .today
            selected = .today
        }
        .onChange(of: selected) { _, d in if let d { store.destination = d } }
        .onChange(of: store.destination) { _, d in if selected != nil || sizeClass == .regular { selected = d } }
        .onChange(of: store.openToday) { selected = .today }
        .onChange(of: store.loaded, initial: true) { _, loaded in if loaded { store.noteWindowShown() } }
        .sheet(isPresented: $store.showNewList) { ListEditor(list: nil) }
        .sheet(item: $store.listToEdit) { ListEditor(list: $0) }
        .sheet(isPresented: $store.showMoveSheet) { MoveSheet(ids: Array(store.selection)) }
        // Swiping the new-reminder sheet away saves it (like clicking outside the Mac card); Cancel discards.
        .sheet(item: Binding(get: { store.composing }, set: { if $0 == nil { store.composeFinisher?(); store.composing = nil } })) {
            ReminderEditor(newReminder: $0).id($0.id)
        }
        .sheet(item: Binding(get: { store.editingID.flatMap { store.snap.reminders[$0] } },
                             set: { if $0 == nil { store.editingID = nil } })) { ReminderEditor(reminder: $0) }
        .sheet(isPresented: Binding(get: { store.datePicker != nil }, set: { if !$0 { store.datePicker = nil } })) {
            DueSheet(ids: store.datePicker?.ids ?? [])
        }
        .storeDialogs()
    }
}

/// Smart lists, pinned lists, lists (with groups) and tags. Things' home screen, Reminders' data.
struct Home: View {
    @Binding var selection: Destination?
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @State private var showSettings = false
    @State private var showReorder = false

    static let style: [Destination: (String, Color)] = [
        .today: ("star.fill", .yellow), .scheduled: ("calendar", .red), .all: ("tray.fill", .gray),
        .flagged: ("flag.fill", .orange), .completed: ("checkmark.circle.fill", .green),
        .assigned: ("person.crop.circle.fill", .teal), .urgent: ("alarm.fill", .red),
    ]

    var body: some View {
        @Bindable var store = store
        List(selection: $selection) {
            Section {
                let smart = store.orderedSmart.filter { store.isAvailable($0) && !store.hiddenSmartLists.contains(store.title($0)) }
                ForEach(smart, id: \.self) { d in
                    let title = store.title(d), (icon, color) = Self.style[d] ?? ("list.bullet", .gray)
                    NavigationLink(value: d) {
                        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
                            .badge(store.count(d) ?? 0)
                    }
                    .contextMenu { Button("Hide “\(title)”", systemImage: "eye.slash") { store.hiddenSmartLists.insert(title) } }
                }
            }

            if !store.pinnedLists.isEmpty {
                Section("Pinned") { ForEach(store.pinnedLists) { ListRow(list: $0) } }
            }

            ForEach(store.sidebarAccounts) { acc in
                Section(store.sidebarAccounts.count > 1 ? acc.account.title : "Lists") {
                    let entries = acc.entries.filter { if case .list(let l) = $0 { !(store.bridgeReadable && l.isPinned) } else { true } }
                    ForEach(entries) { entry in
                        switch entry {
                        case .list(let l):
                            ListRow(list: l)
                        case .group(let g, let lists):
                            DisclosureGroup(isExpanded: expanded(g.id)) {
                                ForEach(lists) { ListRow(list: $0) }
                            } label: {
                                NavigationLink(value: Destination.group(g.id)) {
                                    Label(g.name, systemImage: "folder").fontWeight(.semibold)
                                        .badge(store.count(.group(g.id)) ?? 0)
                                }
                            }
                        }
                    }
                }
            }

            let tags = store.allTags
            if store.bridgeReadable && !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.name) { t in
                        NavigationLink(value: Destination.tag(t.name)) {
                            Label("#" + t.name, systemImage: "number").badge(t.count)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tidy")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showReorder = true } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
            }
            ToolbarItem(placement: .bottomBar) {
                Button { store.showNewList = true } label: { Label("New List", systemImage: "plus.circle") }
                    .labelStyle(.titleAndIcon)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { NewReminderButton() }
        }
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showReorder) { ReorderSheet() }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !store.collapsed.contains(id) },
                set: { if $0 { store.collapsed.remove(id) } else { store.collapsed.insert(id) } })
    }
}

struct ListRow: View {
    let list: RList
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        NavigationLink(value: Destination.list(list.id)) {
            Label {
                HStack(spacing: 4) {
                    Text(list.title)
                    if list.isShared { Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.secondary) }
                }
            } icon: {
                if let e = list.emblem, e.unicodeScalars.first?.properties.isEmoji == true, e.count == 1 {
                    Text(e)
                } else {
                    ProgressPie(fraction: store.progress(list.id), color: Color(list.color))
                }
            }
            .badge(store.count(.list(list.id)) ?? 0)
        }
        .dropDestination(for: DragItems.self) { items, _ in   // iPad: drag reminders onto a list
            guard !list.readOnly else { return false }
            store.move(items.flatMap(\.reminderIDs), toList: list.id, undo: um)
            return true
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.prepareListDelete(list) } label: { Label("Delete", systemImage: "trash") }
                .disabled(list.immutable)
            Button { store.listToEdit = list } label: { Label("Info", systemImage: "info.circle") }.tint(.blue)
        }
        .contextMenu {
            Button("Rename / Color…", systemImage: "pencil") { store.listToEdit = list }.disabled(list.immutable)
            Button(store.showCompleted.contains(list.id) ? "Hide Completed" : "Show Completed", systemImage: "checkmark.circle") {
                if store.showCompleted.contains(list.id) { store.showCompleted.remove(list.id) } else { store.showCompleted.insert(list.id) }
            }
            Button("Open in Reminders", systemImage: "arrow.up.forward.app") { store.openInReminders(list: list.id) }
            Button("Hide List", systemImage: "eye.slash") { store.hiddenLists.insert(list.id) }
            Divider()
            Button("Delete List…", systemImage: "trash", role: .destructive) { store.prepareListDelete(list) }.disabled(list.immutable)
        }
    }
}

/// "+" for a new reminder in the current view: the accent-tinted glass button at the end of the bottom toolbar.
struct NewReminderButton: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button { store.startCompose() } label: { Label("New Reminder", systemImage: "plus") }
            .buttonStyle(.glassProminent)
            .disabled(!store.canCreate)
    }
}

/// Reordering the sidebar, one group of rows at a time. A single-section List: dragging to the top of a section
/// in Home's multi-section List was reported as a move across sections and scrambled the order.
struct ReorderSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "smart"   // "smart" or an account ID

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                if scope == "smart" {
                    let smart = store.orderedSmart.filter { store.isAvailable($0) && !store.hiddenSmartLists.contains(store.title($0)) }
                    ForEach(smart, id: \.self) { d in
                        let (icon, color) = Home.style[d] ?? ("list.bullet", .gray)
                        Label { Text(store.title(d)) } icon: { Image(systemName: icon).foregroundStyle(color) }
                    }
                    .onMove { from, to in store.reorder(smart.map(store.title), from: from, to: to, in: &store.smartOrder) }
                } else if let acc = store.sidebarAccounts.first(where: { $0.id == scope }) {
                    let entries = acc.entries.filter { if case .list(let l) = $0 { !(store.bridgeReadable && l.isPinned) } else { true } }
                    ForEach(entries) { e in
                        switch e {
                        case .list(let l): Label { Text(l.title) } icon: { ProgressPie(fraction: store.progress(l.id), color: Color(l.color)) }
                        case .group(let g, _): Label(g.name, systemImage: "folder").fontWeight(.semibold)
                        }
                    }
                    .onMove { from, to in store.reorder(entries.map(\.id), from: from, to: to, in: &store.sidebarOrder) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .safeAreaInset(edge: .top) {
                Picker("Reorder", selection: $scope) {
                    Text("Smart Lists").tag("smart")
                    ForEach(store.sidebarAccounts) { a in
                        Text(store.sidebarAccounts.count > 1 ? a.account.title : "Lists").tag(a.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .onAppear { if let a = store.sidebarAccounts.first { scope = a.id } }   // lists first; Smart Lists one tap away
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Settings: badge, Today grouping, completed window, visible smart lists and lists, diagnostics.
struct SettingsScreen: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Picker(GeneralSettings.badgeTitle, selection: $store.badgeMode) {
                        Text("Overdue and due today").tag(Store.BadgeMode.overdueAndToday)
                        Text("Overdue only").tag(Store.BadgeMode.overdue)
                        Text("Off").tag(Store.BadgeMode.off)
                    }
                    Toggle("Group Today by time of day", isOn: $store.groupByTime)
                    Picker("Completed reminders", selection: $store.completedWindowDays) {
                        ForEach([7, 30, 90, 365], id: \.self) { Text("Last \($0) days").tag($0) }
                    }
                }
                HiddenFromTodaySection()
                Section("Smart Lists") {
                    ForEach(Store.smartDestinations.filter(store.isAvailable), id: \.self) { d in
                        let t = store.title(d)
                        Toggle(t, isOn: Binding(get: { !store.hiddenSmartLists.contains(t) },
                                                set: { if $0 { store.hiddenSmartLists.remove(t) } else { store.hiddenSmartLists.insert(t) } }))
                    }
                }
                Section("Lists") {
                    ForEach(store.snap.lists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { l in
                        Toggle(l.title, isOn: Binding(get: { !store.hiddenLists.contains(l.id) },
                                                      set: { if $0 { store.hiddenLists.remove(l.id) } else { store.hiddenLists.insert(l.id) } }))
                    }
                }
                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView().navigationTitle("Diagnostics") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
        }
    }
}
