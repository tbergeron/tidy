import AppKit
import EventKit
import Observation

/// UI-facing model. Holds the latest Snapshot from Backend; every write goes Backend → fresh values → here.
/// No optimistic layer except hiding pending deletes and keeping just-completed rows visible briefly.
@MainActor @Observable
final class Store {
    let backend = Backend()

    var auth = EKEventStore.authorizationStatus(for: .reminder)
    var snap = Snapshot() { didSet { if !sectionsOnlyChange { rebuildIndex() } } }
    /// Set while only section metadata changes, which doesn't affect counts or lookups.
    @ObservationIgnored private var sectionsOnlyChange = false
    var loaded = false
    var clock = Clock.current { didSet { rebuildIndex() } }

    var destination: Destination = .today {
        didSet {
            guard oldValue != destination else { return }
            composeFinisher?()
            flushDraft()
            selection = []
            editingID = nil
            datePicker = nil
            tagFilter = []
            // Smart lists render from the loaded snapshot; a list only needs its sections.
            if case .list(let id) = destination { refreshSections(id) }
        }
    }
    var selection: Set<String> = []
    var editingID: String? { didSet { if editingID != nil { composeFinisher?() } } }
    var draft: Draft?
    var composing: Reminder?               // the full card for a new reminder (+ / ⌘N); saved when it closes
    @ObservationIgnored var composeFinisher: (() -> Void)?
    var search = ""
    var tagFilter: Set<String> = []
    var banner: String?
    var showNewList = false
    var showMoveSheet = false
    var confirmDeleteIDs: [String]?
    var confirmMoveOverdue = false
    var listToEdit: RList?
    var listToDelete: RList?
    var datePicker: (anchor: String, ids: [String])?   // "Pick a Date…": popover on the anchor row
    var listDeleteCount: Int?
    var pendingCrossMove: (ids: [String], listID: String, title: String, message: String)?
    var orphanedDraft: Reminder?           // card text whose reminder was deleted elsewhere
    @ObservationIgnored var commitOpenCard: (() -> Void)?
    @ObservationIgnored var cancelOpenCard: (() -> Void)?

    private(set) var pendingDeletes: [String: Date] = [:] { didSet { rebuildIndex() } }
    private(set) var justCompleted: Set<String> = []

    // Preferences (app-local; never Reminders data)
    var groupByTime = UserDefaults.standard.object(forKey: "todayGroupByTime") as? Bool ?? true {
        didSet { UserDefaults.standard.set(groupByTime, forKey: "todayGroupByTime") }
    }
    var showCompleted = Set(UserDefaults.standard.stringArray(forKey: "showCompleted") ?? []) {
        didSet { UserDefaults.standard.set(Array(showCompleted), forKey: "showCompleted") }
    }
    var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }
    /// Lists hidden from the sidebar and from every smart list, count and the badge (app-local).
    var hiddenLists = Set(UserDefaults.standard.stringArray(forKey: "hiddenLists") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(hiddenLists), forKey: "hiddenLists")
            rebuildIndex()
            if case .list(let id) = destination, hiddenLists.contains(id) { destination = .today }
        }
    }
    /// Sidebar order chosen by dragging (app-local): smart-list titles, and list/group IDs.
    var smartOrder = UserDefaults.standard.stringArray(forKey: "smartOrder") ?? [] {
        didSet { UserDefaults.standard.set(smartOrder, forKey: "smartOrder") }
    }
    var sidebarOrder = UserDefaults.standard.stringArray(forKey: "sidebarOrder") ?? [] {
        didSet { UserDefaults.standard.set(sidebarOrder, forKey: "sidebarOrder") }
    }

    static let smartDestinations: [Destination] = [.today, .scheduled, .all, .flagged, .completed, .assigned, .urgent]

    /// Smart lists in the user's order (unknown ones keep their default place at the end).
    var orderedSmart: [Destination] {
        Self.smartDestinations.enumerated().sorted { a, b in
            (smartOrder.firstIndex(of: title(a.element)) ?? 100 + a.offset) < (smartOrder.firstIndex(of: title(b.element)) ?? 100 + b.offset)
        }.map(\.element)
    }

    /// Drag-reorder within the visible items; hidden / filtered-out ones keep their relative place after them.
    func reorder(_ visible: [String], from: IndexSet, to: Int, in order: inout [String]) {
        var moved = visible
        moved.move(fromOffsets: from, toOffset: to)
        order = moved + order.filter { !moved.contains($0) }
    }

    var hiddenSmartLists = Set(UserDefaults.standard.stringArray(forKey: "hiddenSmartLists") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenSmartLists), forKey: "hiddenSmartLists") }
    }
    var bridgeEnabled = UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled"); scheduleReload() }
    }
    var completedWindowDays = 30 { didSet { scheduleReload() } }

    /// Dock badge, like Reminders' "Badge Count": overdue, optionally plus due today.
    enum BadgeMode: String, CaseIterable { case overdueAndToday, overdue, off }
    var badgeMode = BadgeMode(rawValue: UserDefaults.standard.string(forKey: "badgeMode") ?? "") ?? .overdueAndToday {
        didSet { UserDefaults.standard.set(badgeMode.rawValue, forKey: "badgeMode"); updateBadge() }
    }


    struct Draft: Equatable { var listID: String?; var due: DateComponents?; var text = "" }

    private var reloadTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?

    // MARK: Lifecycle

    /// Launch: show the last data at once and start the real load before the window even exists.
    init() {
        guard auth == .fullAccess else { return }
        // The cache is decoded off the main thread; it's only used if the real load hasn't landed yet.
        Task.detached(priority: .userInitiated) { [weak self] in
            let t = ContinuousClock.now
            guard let cached = SnapshotCache.load() else { return }
            perfLog.notice("cache: \(cached.reminders.count) reminders in \(perfMS(t), privacy: .public)")
            await MainActor.run {
                guard let self, !self.loaded else { return }
                self.snap = cached
                self.loaded = true
            }
        }
        scheduleReload(delay: 0)
    }

    private var started = false

    /// Observers and the minute timer — once per app run, however many times the root view appears.
    func start() {
        guard !started else { return }
        started = true
        perfLog.debug("start(): \(perfMS(self.launched), privacy: .public) after Store init")
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = .current; self?.scheduleReload() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.auth == .fullAccess else { return }
                // Asks EventKit to sync; if anything changed it posts EKEventStoreChanged, which reloads.
                Task { await self.backend.refreshSources() }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = .current; self?.scheduleReload() }
        })
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = .current }
        }
    }

    func requestAccess() async {
        do { _ = try await backend.requestReminderAccess() } catch { fail(error) }
        auth = EKEventStore.authorizationStatus(for: .reminder)
        if auth == .fullAccess { await reload() }
    }

    func scheduleReload(delay: Double = 0.3) {
        reloadTask?.cancel()
        reloadTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private let launched = ContinuousClock.now
    @ObservationIgnored private var loggedFirstFrame = false

    /// Logs once: time from process start until the window first shows reminders.
    func noteWindowShown() {
        guard !loggedFirstFrame, loaded else { return }
        loggedFirstFrame = true
        perfLog.notice("window usable: \(String(format: "%.0f ms", processAge() * 1000), privacy: .public) after process start")
    }

    private var loadLoop: Task<Void, Never>?
    private var reloadAgain = false

    /// At most one load runs; requests during it collapse into a single follow-up load.
    /// Callers wait until the data includes everything requested before their call.
    func reload() async {
        guard auth == .fullAccess else { return }
        if let loop = loadLoop {
            reloadAgain = true
            await loop.value
            return
        }
        let loop = Task {
            repeat {
                reloadAgain = false
                await loadOnce()
            } while reloadAgain
            loadLoop = nil
        }
        loadLoop = loop
        await loop.value
    }

    /// Re-reads one list's sections when it's opened (they're already shown from the last fetch).
    private func refreshSections(_ listID: String) {
        guard bridgeReadable else { return }
        Task { await fetchSections([listID]) }
    }

    @ObservationIgnored private var sectionsTask: Task<Void, Never>?

    /// Sections of the given lists, one actor call per list so writes can run in between, published once
    /// with no index rebuild (sections don't change counts or lookups).
    private func fetchSections(_ listIDs: [String]) async {
        let t = ContinuousClock.now
        let byList = Dictionary(grouping: live, by: \.listID)
        var sections: [String: [RSection]] = [:], of: [String: String] = [:]
        for id in listIDs {
            guard !Task.isCancelled else { return }
            guard let r = await backend.sections(inList: id, reminderIDs: Backend.needsSection(byList[id] ?? [])) else { continue }
            sections[id] = r.sections
            of.merge(r.sectionOf) { _, b in b }
        }
        guard !sections.isEmpty, !Task.isCancelled else { return }
        perfLog.notice("sections for \(listIDs.count) lists: \(perfMS(t), privacy: .public)")
        var s = snap
        s.sectionOf = s.sectionOf.filter { k, _ in s.reminders[k].map { sections[$0.listID] == nil } ?? false }
            .merging(of) { _, b in b }
        s.sections.merge(sections) { _, b in b }
        sectionsOnlyChange = true
        snap = s
        sectionsOnlyChange = false
    }

    private func loadOnce() async {
        let t = ContinuousClock.now
        perfLog.debug("reload begins: \(perfMS(self.launched), privacy: .public) after Store init")
        let since = clock.cal.date(byAdding: .day, value: -completedWindowDays, to: clock.today) ?? .distantPast
        do {
            var fresh = try await backend.load(completedSince: since, useBridge: bridgeEnabled)
            if fresh.bridge.readOK {   // keep showing the last sections until the refresh below replaces them
                fresh.sections = snap.sections
                fresh.sectionOf = snap.sectionOf
            }
            snap = fresh
            perfLog.notice("reload: \(perfMS(t), privacy: .public); since launch: \(perfMS(self.launched), privacy: .public)")
            loaded = true
            // Every list's sections in the background (viewed list first), so opening a list shows its headers
            // at once; the cache is saved after, so the next launch has them too.
            sectionsTask?.cancel()
            let lists = snap.lists.map(\.id).sorted { $0 == viewedListID && $1 != viewedListID }
            sectionsTask = Task {
                if bridgeReadable { await fetchSections(lists) }
                guard !Task.isCancelled else { return }
                let saved = snap
                Task.detached(priority: .utility) { SnapshotCache.save(saved) }
            }
            switch destination {   // the viewed list/group was deleted elsewhere
            case .list(let id) where list(id) == nil, .group(let id) where !snap.groups.contains(where: { $0.id == id }):
                destination = .today
            default: break
            }
            if let id = editingID, snap.reminders[id] == nil { editingID = nil }
        } catch {
            fail(error)
        }
    }

    /// Lookups rebuilt once per data change (snapshot, pending deletes, hidden lists, clock) instead of per render.
    struct Index {
        var live: [Reminder] = []
        var shown: [Reminder] = []
        var children: [String: [Reminder]] = [:]
        var openByList: [String: Int] = [:]
        var loadedByList: [String: Int] = [:]
        var doneByList: [String: Int] = [:]
        var smartCounts: [Destination: Int] = [:]
        var overdue = 0
        var tags: [(name: String, count: Int)] = []
    }
    private(set) var index = Index()

    private func rebuildIndex() {
        var x = Index()
        x.live = snap.reminders.values.filter { pendingDeletes[$0.id] == nil }
        x.shown = x.live.filter { !hiddenLists.contains($0.listID) }
        var tagCounts: [String: (String, Int)] = [:]
        for r in x.live {
            if let p = r.parentID { x.children[p, default: []].append(r) }
            x.loadedByList[r.listID, default: 0] += 1
            if r.isCompleted { x.doneByList[r.listID, default: 0] += 1 }
        }
        var smart: [Destination: Int] = [.today: 0, .scheduled: 0, .all: 0, .flagged: 0, .urgent: 0, .assigned: 0]
        for r in x.shown where !r.isCompleted {
            x.openByList[r.listID, default: 0] += 1
            smart[.all]! += 1
            if Smart.inToday(r, clock) { smart[.today]! += 1 }
            if Smart.isOverdue(r, clock) { x.overdue += 1 }
            if r.due != nil { smart[.scheduled]! += 1 }
            if r.extras?.flagged == true { smart[.flagged]! += 1 }
            if r.extras?.urgent == true { smart[.urgent]! += 1 }
            if isAssignedToMe(r) { smart[.assigned]! += 1 }
            for t in r.extras?.tags ?? [] { tagCounts[t.lowercased(), default: (t, 0)].1 += 1 }
        }
        x.smartCounts = smart
        x.tags = tagCounts.values.map { (name: $0.0, count: $0.1) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        index = x
        updateBadge()
    }

    var badgeCount: Int {
        guard auth == .fullAccess else { return 0 }
        switch badgeMode {
        case .off: return 0
        case .overdue: return index.overdue
        case .overdueAndToday: return index.smartCounts[.today] ?? 0   // == the Today count
        }
    }

    private func updateBadge() {
        let n = badgeCount
        let label = n > 0 ? "\(n)" : nil
        let tile = NSApplication.shared.dockTile
        if tile.badgeLabel != label { tile.badgeLabel = label }
    }

    /// Ops run one after another so their effects (and undos) apply in order.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = tail
        tail = Task { await prev?.value; await op() }
    }

    func fail(_ error: Error) { banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    func fail(_ message: String) { banner = message }

    private func merge(_ r: Reminder, replacing oldID: String? = nil) {
        var r = r
        if r.extras == nil { r.extras = snap.reminders[oldID ?? r.id]?.extras }
        if let oldID, oldID != r.id {
            snap.reminders[oldID] = nil
            if selection.remove(oldID) != nil { selection.insert(r.id) }
            if editingID == oldID { editingID = r.id }
        }
        snap.reminders[r.id] = r
    }

    // MARK: Derived data

    var viewedListID: String? { if case .list(let id) = destination { id } else { nil } }
    var bridgeReadable: Bool { bridgeEnabled && snap.bridge.readOK }

    func list(_ id: String) -> RList? { snap.lists.first { $0.id == id } }
    func account(_ id: String) -> Account? { snap.accounts.first { $0.id == id } }
    func supports(_ cap: String) -> Bool { bridgeReadable && snap.accounts.contains { $0.caps.contains(cap) } }

    /// Reminders that are not pending deletion.
    var live: [Reminder] { index.live }
    /// Live reminders outside hidden lists — what sidebar counts, smart lists, tags and the badge use.
    var shown: [Reminder] { index.shown }

    func children(of id: String) -> [Reminder] { index.children[id] ?? [] }

    func isAssignedToMe(_ r: Reminder) -> Bool {
        guard let a = r.extras?.assigneeID, let me = list(r.listID)?.currentUserParticipantID else { return false }
        return a.caseInsensitiveCompare(me) == .orderedSame
    }

    // Sidebar
    struct SidebarAccount: Identifiable { let account: Account; var entries: [SidebarEntry]; var id: String { account.id } }
    enum SidebarEntry: Identifiable {
        case list(RList), group(RGroup, [RList])
        var id: String { switch self { case .list(let l): l.id; case .group(let g, _): g.id } }
    }

    var sidebarAccounts: [SidebarAccount] {
        snap.accounts.compactMap { a in
            let lists = snap.lists.filter { $0.accountID == a.id && !hiddenLists.contains($0.id) }
            guard !lists.isEmpty else { return nil }
            let groups = snap.groups.filter { $0.accountID == a.id }
            var entries: [SidebarEntry] = lists.filter { l in l.groupID == nil || !groups.contains { $0.id == l.groupID } }.map { .list($0) }
            // Order: the user's drag order, then Reminders' own sidebar order, then title.
            let mine = Dictionary(sidebarOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { x, _ in x })
            let theirs = Dictionary(a.listOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { x, _ in x })
            func before(_ x: String, _ xt: String, _ y: String, _ yt: String) -> Bool {
                let kx = (mine[x] ?? Int.max, theirs[x] ?? Int.max), ky = (mine[y] ?? Int.max, theirs[y] ?? Int.max)
                return kx != ky ? kx < ky : xt.localizedStandardCompare(yt) == .orderedAscending
            }
            entries += groups.map { g in
                .group(g, lists.filter { $0.groupID == g.id }.sorted { before($0.id, $0.title, $1.id, $1.title) })
            }
            entries.sort { before($0.id, Self.entryTitle($0), $1.id, Self.entryTitle($1)) }
            return SidebarAccount(account: a, entries: entries)
        }
    }
    private static func entryTitle(_ e: SidebarEntry) -> String { switch e { case .list(let l): l.title; case .group(let g, _): g.name } }

    var pinnedLists: [RList] { bridgeReadable ? snap.lists.filter { $0.isPinned && !hiddenLists.contains($0.id) } : [] }

    var allTags: [(name: String, count: Int)] { index.tags }

    func count(_ d: Destination) -> Int? {
        switch d {
        case .today, .scheduled, .all, .flagged, .urgent, .assigned: return index.smartCounts[d] ?? 0
        case .list(let id): return index.openByList[id] ?? 0
        case .group(let id): return snap.lists.filter { $0.groupID == id }.reduce(0) { $0 + (index.openByList[$1.id] ?? 0) }
        case .tag(let t): return index.tags.first { $0.name.caseInsensitiveCompare(t) == .orderedSame }?.count ?? 0
        case .completed: return nil
        }
    }

    /// completed ÷ loaded for a list's progress pie. ponytail: only within the loaded completed window.
    func progress(_ listID: String) -> Double {
        let total = index.loadedByList[listID] ?? 0
        return total == 0 ? 0 : Double(index.doneByList[listID] ?? 0) / Double(total)
    }

    func isAvailable(_ d: Destination) -> Bool {
        switch d {
        case .flagged: supports("supportsFlagged")
        case .urgent: supports("supportsUrgentAlarm")
        case .assigned: supports("supportsAssignments") && snap.lists.contains(where: \.isShared)
        default: true
        }
    }

    // List contents
    struct Row: Identifiable, Hashable { let reminder: Reminder; let depth: Int; var id: String { reminder.id } }
    struct RowSection: Identifiable {
        enum Kind: Hashable { case plain, overdue, day(Date), today(TodayBucket), list(String), section(String), completed }
        let id: String
        var title: String
        var kind: Kind
        var rows: [Row]
    }

    func title(_ d: Destination) -> String {
        switch d {
        case .today: "Today"
        case .scheduled: "Scheduled"
        case .all: "All"
        case .flagged: "Flagged"
        case .completed: "Completed"
        case .assigned: "Assigned to Me"
        case .urgent: "Urgent"
        case .list(let id): list(id)?.title ?? ""
        case .group(let id): snap.groups.first { $0.id == id }?.name ?? ""
        case .tag(let t): "#" + t
        }
    }

    /// Tags present in the current view (for the tag filter bar).
    func tagsInView(_ d: Destination) -> [String] {
        let rs = candidates(d, includeCompleted: false)
        var seen: [String: String] = [:]
        for r in rs { for t in r.extras?.tags ?? [] { seen[t.lowercased()] = seen[t.lowercased()] ?? t } }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func candidates(_ d: Destination, includeCompleted: Bool) -> [Reminder] {
        shown.filter { r in
            let visibleCompletion = includeCompleted || !r.isCompleted || justCompleted.contains(r.id)
            switch d {
            case .today: return (!r.isCompleted || justCompleted.contains(r.id)) && (Smart.inToday(r, clock) || justCompleted.contains(r.id) && r.due != nil)
            case .scheduled: return (!r.isCompleted || justCompleted.contains(r.id)) && r.due != nil
            case .all: return visibleCompletion
            case .flagged: return visibleCompletion && r.extras?.flagged == true
            case .urgent: return visibleCompletion && r.extras?.urgent == true
            case .assigned: return visibleCompletion && isAssignedToMe(r)
            case .completed: return r.isCompleted
            case .list(let id): return r.listID == id && visibleCompletion
            case .group(let id): return list(r.listID)?.groupID == id && visibleCompletion
            case .tag(let t): return visibleCompletion && r.extras?.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } == true
            }
        }
    }

    func sections(_ d: Destination) -> [RowSection] {
        let d = search.isEmpty ? d : .all   // search looks through every list, results grouped by list
        var rs = candidates(d, includeCompleted: false)
        if !search.isEmpty { rs = rs.filter { Display.matches($0, query: search, listTitle: list($0.listID)?.title ?? "") } }
        if !tagFilter.isEmpty {
            rs = rs.filter { r in tagFilter.allSatisfy { t in r.extras?.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } == true } }
        }
        let flat: ([Reminder]) -> [Row] = { Sorting.smart($0, clock: self.clock).map { Row(reminder: $0, depth: 0) } }

        switch d {
        case .today:
            let buckets = Dictionary(grouping: rs) { Smart.todayBucket($0, clock, groupByTime: groupByTime) }
            let order: [TodayBucket] = groupByTime ? [.overdue, .allDay, .morning, .afternoon, .tonight] : [.overdue, .today]
            return order.compactMap { b in
                guard let items = buckets[b], !items.isEmpty || (groupByTime && b != .overdue) else { return nil }
                return RowSection(id: "today-\(b.rawValue)", title: b.title, kind: b == .overdue ? .overdue : .today(b), rows: flat(items))
            }
        case .scheduled:
            // Just-completed rows stay in their day for the 1.5 s they remain visible.
            let groups = Dictionary(grouping: rs) { r -> ScheduledBucket in
                var x = r
                x.isCompleted = false
                return Smart.scheduledBucket(x, clock) ?? .overdue
            }
            let keys = Set(groups.keys).union(Smart.scheduledDays(clock)).sorted()
            return keys.map { k in
                let items = groups[k] ?? []
                switch k {
                case .overdue: return RowSection(id: "overdue", title: "Overdue", kind: .overdue, rows: flat(items))
                case .day(let day): return RowSection(id: "day-\(day.timeIntervalSince1970)", title: dayTitle(day), kind: .day(day), rows: flat(items))
                case .month(let m): return RowSection(id: "month-\(m.timeIntervalSince1970)", title: m.formatted(.dateTime.month(.wide).year()), kind: .plain, rows: flat(items))
                }
            }.filter { !$0.rows.isEmpty || $0.kind != .overdue }
        case .completed:
            let byDay = Dictionary(grouping: rs) { clock.cal.startOfDay(for: $0.completionDate ?? .distantPast) }
            return byDay.keys.sorted(by: >).map { day in
                let items = byDay[day]!.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                return RowSection(id: "done-\(day.timeIntervalSince1970)", title: day == .distantPast ? "Earlier" : dayTitle(day), kind: .plain, rows: items.map { Row(reminder: $0, depth: 0) })
            }
        case .list(let id):
            var out: [RowSection] = []
            let l = list(id)
            let sorted = Sorting.sorted(rs, style: l?.sortingStyle, manual: l?.manualOrder ?? [], clock: clock)
            let secs = snap.sections[id] ?? []
            let sectionOf: (Reminder) -> String? = { r in
                // Subtasks follow their parent's section — looked up in the whole list, not just the rows a
                // search or tag filter left visible (only the parent's membership is fetched; see Backend.needsSection).
                let key = r.parentID.flatMap { p in self.snap.reminders[p]?.listID == id ? p : nil } ?? r.id
                return self.snap.sectionOf[key].flatMap { s in secs.contains { $0.id == s } ? s : nil }
            }
            let unsectioned = sorted.filter { sectionOf($0) == nil }
            out.append(RowSection(id: "list-\(id)", title: "", kind: .plain, rows: nested(unsectioned)))
            for s in secs {
                out.append(RowSection(id: s.id, title: s.name, kind: .section(s.id), rows: nested(sorted.filter { sectionOf($0) == s.id })))
            }
            if showCompleted.contains(id) {
                let done = live.filter { $0.listID == id && $0.isCompleted && !justCompleted.contains($0.id) }
                    .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                if !done.isEmpty { out.append(RowSection(id: "completed-\(id)", title: "Completed", kind: .completed, rows: done.map { Row(reminder: $0, depth: 0) })) }
            }
            return out
        case .all, .flagged, .urgent, .assigned, .group, .tag:
            let byList = Dictionary(grouping: rs, by: \.listID)
            return orderedListIDs.compactMap { lid in
                guard let items = byList[lid], !items.isEmpty, let l = list(lid) else { return nil }
                let sorted = Sorting.sorted(items, style: l.sortingStyle, manual: l.manualOrder, clock: clock)
                return RowSection(id: "list-\(lid)", title: l.title, kind: .list(lid), rows: nested(sorted))
            }
        }
    }

    /// Lists in sidebar order.
    var orderedListIDs: [String] {
        sidebarAccounts.flatMap { $0.entries.flatMap { e -> [String] in
            switch e { case .list(let l): [l.id]; case .group(_, let ls): ls.map(\.id) }
        } }
    }

    /// Parents followed by their (sorted) subtasks; orphans are top level. One level, like Reminders.
    private func nested(_ sorted: [Reminder]) -> [Row] {
        let ids = Set(sorted.map(\.id))
        var kids: [String: [Reminder]] = [:]
        for r in sorted { if let p = r.parentID, ids.contains(p) { kids[p, default: []].append(r) } }
        var out: [Row] = []
        for r in sorted where r.parentID.map({ !ids.contains($0) }) ?? true {
            out.append(Row(reminder: r, depth: 0))
            // An open card shows its own checklist, so its subtasks aren't drawn twice.
            if !collapsed.contains(r.id) && r.id != editingID { out += (kids[r.id] ?? []).map { Row(reminder: $0, depth: 1) } }
        }
        return out
    }

    func dayTitle(_ day: Date) -> String {
        let days = clock.cal.dateComponents([.day], from: clock.today, to: day).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    /// Where a reminder created from this view goes, and with which attributes.
    func newReminderTarget(_ d: Destination) -> (listID: String?, due: DateComponents?) {
        switch d {
        case .list(let id): (id, nil)
        case .group(let id): (orderedListIDs.first { list($0)?.groupID == id }, nil)
        case .today, .scheduled: (nil, Due.components(clock.today, allDay: true, timeZone: nil, clock: clock))
        default: (nil, nil)
        }
    }

    // MARK: Reminder ops

    /// Payload is read when undo runs, so the op can replace the provisional inverse with real pre-write values.
    final class UndoToken {
        var edits: [(String, ReminderEdit)] = []
        var guards: [String: Reminder] = [:]
        var ids: [String] = []
    }
    /// UndoManager holds targets unowned, so tokens must outlive their actions. ponytail: never pruned (a few bytes each).
    private var undoTokens: [UndoToken] = []
    private func newToken() -> UndoToken { let t = UndoToken(); undoTokens.append(t); return t }

    func locked(_ id: String) -> Bool { snap.reminders[id].flatMap { list($0.listID) }?.readOnly == true }

    /// The one edit path: per-item ReminderEdit. Undo = inverse edits for the same keys, applied only where the
    /// value is still what we wrote (`guards`), so undo never clobbers a newer change from another device (R11).
    func applyEdits(_ items: [(String, ReminderEdit)], name: String, undo um: UndoManager?,
                    bases: [String: Reminder] = [:], guards: [String: Reminder] = [:], undoable: Bool = true,
                    copyMoves: Bool = false, onFailure: (@MainActor () -> Void)? = nil) {
        let befores = items.compactMap { id, e in snap.reminders[id].map { ($0, e) } }
            .filter { !$0.1.isEmpty && !locked($0.0.id) }
        guard !befores.isEmpty else { return }
        let token = newToken()
        token.edits = befores.map { b, e in (b.id, Edits.diff(base: Edits.applied(e, to: b), draft: b)) }
        token.guards = Dictionary(befores.map { b, e in (b.id, Edits.applied(e, to: b)) }, uniquingKeysWith: { a, _ in a })
        let completesRepeating = befores.contains { $0.0.isRepeating && $0.1.isCompleted == true }
        if undoable && !completesRepeating {   // R1: completing a repeating reminder advances it; no undo
            um?.registerUndo(withTarget: token) { t in self.applyEdits(t.edits, name: name, undo: um, guards: t.guards, copyMoves: copyMoves) }
            um?.setActionName(name)
        }
        enqueue {
            var errors: [Error] = [], conflicts: [String] = []
            var edits: [(String, ReminderEdit)] = [], wrote: [String: Reminder] = [:]
            for (b, e) in befores {
                do {
                    let (r, before, c) = try await self.backend.apply(e, to: b.id, base: bases[b.id], onlyIfStill: guards[b.id], copyIfRefused: copyMoves)
                    self.merge(r, replacing: b.id)
                    conflicts += c
                    edits.append((r.id, Edits.diff(base: r, draft: before)))
                    wrote[r.id] = r
                } catch {
                    errors.append(error)
                }
            }
            token.edits = edits
            token.guards = wrote
            if let first = errors.first {
                self.fail(errors.count > 1 ? "\(errors.count) changes failed: \(first.localizedDescription)" : first.localizedDescription)
                if edits.isEmpty { um?.removeAllActions(withTarget: token) }
                onFailure?()
            } else if !conflicts.isEmpty {
                self.banner = "Replaced a change made on another device (\(Set(conflicts).sorted().joined(separator: ", "))). Undo restores it."
            }
        }
    }

    func commitCard(draft: Reminder, base: Reminder, undo um: UndoManager?, onFailure: (@MainActor () -> Void)? = nil) {
        let e = Edits.diff(base: base, draft: draft)
        guard !e.isEmpty else { return }
        // An hourly rule can't be expressed in EventKit, so an undo would write Daily instead.
        applyEdits([(base.id, e)], name: "Edit", undo: um, bases: [base.id: base],
                   undoable: !(base.extras?.hourly == true && e.recurrence != nil), onFailure: onFailure)
    }

    private var completing: Set<String> = []

    func toggleComplete(_ ids: [String], undo um: UndoManager?) {
        // R1 guard: a repeating reminder that was just completed has already advanced; a second click would complete the next one.
        let rs = ids.compactMap { snap.reminders[$0] }
            .filter { !locked($0.id) && !($0.isRepeating && (completing.contains($0.id) || justCompleted.contains($0.id))) }
        guard let first = rs.first else { return }
        let done = !first.isCompleted
        var targets = rs.filter { $0.isCompleted != done }
        // Completing a non-repeating parent completes its open subtasks too (Reminders behaviour).
        if done {
            for p in targets where !p.isRepeating {
                targets += children(of: p.id).filter { !$0.isCompleted && !targets.contains($0) }
            }
            justCompleted.formUnion(targets.map(\.id))
            let keep = targets.map(\.id)
            Task { try? await Task.sleep(for: .seconds(1.5)); justCompleted.subtract(keep) }
        }
        let reps = targets.filter(\.isRepeating).map(\.id)
        completing.formUnion(reps)
        applyEdits(targets.map { ($0.id, ReminderEdit(isCompleted: done)) }, name: done ? "Complete" : "Uncomplete", undo: um)
        if !reps.isEmpty { enqueue { self.completing.subtract(reps) } }
    }

    func setDue(_ ids: [String], _ make: (Reminder) -> DateComponents?, undo um: UndoManager?) {
        // Clearing the date of a repeating reminder is refused by EventKit (R7); the card asks first instead.
        let items = ids.compactMap { id in snap.reminders[id].map { (id, make($0), $0.isRepeating) } }
        if items.contains(where: { $0.1 == nil && $0.2 }) { fail(AppError.needsDueForRepeat) }
        applyEdits(items.filter { !($0.1 == nil && $0.2) }.map { ($0.0, ReminderEdit(due: .some($0.1))) }, name: "Reschedule", undo: um)
    }

    /// Urgent needs the private bridge, an account that supports it, and a date with a time (the alarm rings then).
    private(set) var urgentTripped = false
    func canSetUrgent(_ r: Reminder) -> Bool {
        bridgeReadable && !urgentTripped && !locked(r.id) && r.due.map { !Due.isAllDay($0) } == true
            && account(list(r.listID)?.accountID ?? "")?.caps.contains("supportsUrgentAlarm") == true
    }

    func setUrgent(_ ids: [String], _ on: Bool, undo um: UndoManager?) {
        let targets = ids.compactMap { snap.reminders[$0] }.filter { canSetUrgent($0) && ($0.extras?.urgent ?? false) != on }.map(\.id)
        guard !targets.isEmpty else { return }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in self.setUrgent(targets, !on, undo: um) }
        um?.setActionName(on ? "Mark as Urgent" : "Remove Urgent")
        enqueue {
            let (updated, failures) = await self.backend.setUrgent(on, ids: targets)
            updated.forEach { self.merge($0) }
            if let first = failures.first {
                // A failed read-back means the private call didn't behave as verified: stop using it this session.
                if first.hasPrefix("VERIFY") { self.urgentTripped = true }
                self.fail(first.replacingOccurrences(of: "VERIFY: ", with: "") + (self.urgentTripped ? " Urgent is turned off until the app restarts." : ""))
                um?.removeAllActions(withTarget: token)
            }
        }
    }

    func setPriority(_ ids: [String], _ p: Priority, undo um: UndoManager?) {
        applyEdits(ids.map { ($0, ReminderEdit(priority: p.raw)) }, name: "Priority", undo: um)
    }

    /// A move to another account is a copy in EventKit (new IDs; tags, subtasks, attachments don't follow),
    /// so it's confirmed, refused for subtask trees, and not undoable (R8).
    func move(_ ids: [String], toList listID: String, undo um: UndoManager?, confirmed: Bool = false) {
        guard let target = list(listID), !target.readOnly else { return }
        let rs = ids.compactMap { snap.reminders[$0] }.filter { $0.listID != listID && !locked($0.id) }
        let cross = rs.filter { list($0.listID)?.accountID != target.accountID }
        if !cross.isEmpty {
            if cross.contains(where: { !children(of: $0.id).isEmpty || $0.parentID != nil }) {
                fail("Reminders with subtasks can't move to another account. Use Open in Reminders.")
                return
            }
            guard confirmed else {
                pendingCrossMove = (rs.map(\.id), listID, "Move to another account?",
                                    "Reminders copies reminders moved to another account: tags, flags, sections and attachments won't follow, and the originals go to Recently Deleted. This can't be undone.")
                return
            }
        }
        // Reminders refuses moves into or out of a shared list; those are copied there and the original deleted.
        let copied = bridgeReadable ? rs.filter { target.isShared || list($0.listID)?.isShared == true } : []
        if copied.contains(where: { !children(of: $0.id).isEmpty || $0.parentID != nil }) {
            fail("Reminders with subtasks can't move into or out of a shared list. Use Open in Reminders.")
            return
        }
        let lossy = copied.contains { r in
            guard let x = r.extras else { return false }
            return !x.tags.isEmpty || x.flagged || !x.urls.isEmpty || !x.images.isEmpty || !x.earlyAlerts.isEmpty || x.hourly || x.assigneeID != nil
        }
        if lossy && !confirmed {
            pendingCrossMove = (rs.map(\.id), listID, "Copy to “\(target.title)”?",
                                "Reminders can't move reminders into or out of a shared list, so Tidy copies them there and moves the originals to Recently Deleted. Tags, flags, attachments, early alerts and assignees won't come along.")
            return
        }
        let crossIDs = Set(cross.map(\.id))
        applyEdits(rs.filter { !crossIDs.contains($0.id) }.map { ($0.id, ReminderEdit(listID: listID)) }, name: "Move", undo: um,
                   copyMoves: bridgeReadable)
        applyEdits(cross.map { ($0.id, ReminderEdit(listID: listID)) }, name: "Move", undo: um, undoable: false)
    }

    func create(title: String, listID: String?, due: DateComponents?, undo um: UndoManager?, open: Bool = false) {
        create(ReminderEdit(title: title.trimmingCharacters(in: .whitespacesAndNewlines), due: .some(due)), listID: listID, undo: um, open: open)
    }

    func create(_ edit: ReminderEdit, listID: String?, undo um: UndoManager?, open: Bool = false) {
        guard !(edit.title ?? "").isEmpty else { return }
        // Registered now (so the undo stack keeps its order); the id is filled in once the create ran.
        let token = newToken()
        um?.registerUndo(withTarget: token) { t in
            if t.ids.isEmpty { self.enqueue { self.delete(t.ids, undo: um) } } else { self.delete(t.ids, undo: um) }
        }
        um?.setActionName("New Reminder")
        enqueue {
            do {
                let r = try await self.backend.create(edit, listID: listID)
                self.merge(r)
                token.ids = [r.id]
                if open { self.selection = [r.id]; self.editingID = r.id }
            } catch {
                self.fail(error)
                um?.removeAllActions(withTarget: token)
            }
        }
    }

    /// Hidden at once; really removed after 8 s or on quit, so undo is free inside the window (R9).
    func delete(_ ids: [String], undo um: UndoManager?) {
        var all = ids.filter { snap.reminders[$0] != nil && pendingDeletes[$0] == nil && !locked($0) }
        for id in all { all += children(of: id).map(\.id).filter { !all.contains($0) } }   // subtasks go with the parent
        guard !all.isEmpty else { return }
        let now = Date()
        for id in all { pendingDeletes[id] = now }
        selection.subtract(all)
        if let e = editingID, all.contains(e) { editingID = nil }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in self.undelete(all, undo: um) }
        um?.setActionName("Delete")
        flushTask?.cancel()
        flushTask = Task { try? await Task.sleep(for: .seconds(8)); await flushDeletes(olderThan: 8) }
    }

    private var flushing: Set<String> = []

    private func undelete(_ ids: [String], undo um: UndoManager?) {
        let still = ids.filter { pendingDeletes[$0] != nil && !flushing.contains($0) }
        still.forEach { pendingDeletes[$0] = nil }
        if still.count < ids.count {
            banner = "Some reminders were already deleted. Recover them from Recently Deleted in Reminders."
        }
        guard !still.isEmpty else { return }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in self.delete(still, undo: um) }
    }

    func flushDeletes(olderThan age: TimeInterval = 0) async {
        let now = Date()
        // Children first, so a parent never disappears before its subtasks.
        let due = pendingDeletes.filter { now.timeIntervalSince($0.value) >= age && !flushing.contains($0.key) }.map(\.key)
            .sorted { (snap.reminders[$0]?.parentID != nil ? 0 : 1) < (snap.reminders[$1]?.parentID != nil ? 0 : 1) }
        guard !due.isEmpty else { return }
        flushing.formUnion(due)
        let failed = await backend.delete(due)
        flushing.subtract(due)
        for id in due {
            pendingDeletes[id] = nil
            if !failed.contains(id) { snap.reminders[id] = nil }
        }
        if !failed.isEmpty { fail("Couldn't delete \(failed.count) reminder(s).") }
        if !pendingDeletes.isEmpty {
            flushTask = Task { try? await Task.sleep(for: .seconds(8)); await flushDeletes(olderThan: 8) }
        }
    }

    /// Every delete is confirmed first (the dialog is in MainView).
    func requestDelete(_ ids: [String], undo um: UndoManager?) {
        let ids = ids.filter { !locked($0) && snap.reminders[$0] != nil && pendingDeletes[$0] == nil }
        if !ids.isEmpty { confirmDeleteIDs = ids }
    }

    /// Title, message and button for the delete confirmation.
    func deleteConfirmation(_ ids: [String]) -> (title: String, message: String, button: String) {
        let rs = ids.compactMap { snap.reminders[$0] }
        let subtasks = Set(rs.flatMap { children(of: $0.id).map(\.id) }).subtracting(ids).count
        let title = rs.count == 1 ? "Delete “\(rs[0].title.isEmpty ? "New Reminder" : rs[0].title)”?" : "Delete \(rs.count) reminders?"
        var notes: [String] = []
        if subtasks > 0 { notes.append(subtasks == 1 ? "Its subtask is deleted too." : "Their \(subtasks) subtasks are deleted too.") }
        if rs.contains(where: \.isRepeating) { notes.append("Repeating reminders are deleted with all future occurrences.") }
        notes.append("You can undo with ⌘Z, or recover it later from Recently Deleted in Reminders.")
        return (title, notes.joined(separator: " "), rs.contains(where: \.isRepeating) ? "Delete All Occurrences" : "Delete")
    }

    /// Overdue = due on an earlier day (what the Overdue section shows).
    var overdueIDs: [String] {
        shown.filter { !$0.isCompleted && !locked($0.id) && ($0.due.flatMap { Due.day($0, clock: clock) } ?? .distantFuture) < clock.today }.map(\.id)
    }

    /// Asks first (the dialog is in MainView).
    func requestMoveOverdueToToday() {
        if !overdueIDs.isEmpty { confirmMoveOverdue = true }
    }

    func moveOverdueToToday(undo um: UndoManager?) {
        setDue(overdueIDs, { Due.moving($0.due, toDay: self.clock.today, clock: self.clock) }, undo: um)
    }

    /// New reminders can only be created where they'll stay visible and writable.
    var canCreate: Bool {
        switch destination {
        case .completed, .flagged, .urgent, .assigned, .tag: return false
        default:
            let t = newReminderTarget(destination)
            return list(t.listID ?? snap.defaultListID ?? "")?.readOnly != true
        }
    }

    func startDraft() {
        guard canCreate else { return }
        composeFinisher?()
        flushDraft()
        let t = newReminderTarget(destination)
        editingID = nil
        draft = Draft(listID: t.listID, due: t.due)
    }

    /// + / ⌘N: the full card for a new reminder, dated today. Nothing is written until it closes with a title.
    func startCompose() {
        guard canCreate else { return }
        composeFinisher?()
        flushDraft()
        editingID = nil
        let t = newReminderTarget(destination)
        composing = Reminder(id: "NEW-" + UUID().uuidString, listID: t.listID ?? snap.defaultListID ?? "", title: "",
                             isCompleted: false, priority: 0,
                             due: Due.components(clock.today, allDay: true, timeZone: nil, clock: clock), alarms: [])
    }

    /// Creates the composed reminder (if it got a title) and closes the card. Safe to call twice.
    func finishCompose(_ d: Reminder, undo um: UndoManager?) {
        guard composing?.id == d.id else { return }
        composing = nil
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let notes = (d.notes ?? "").isEmpty ? nil : d.notes
        create(ReminderEdit(title: title, notes: notes.map { .some($0) }, priority: d.priority == 0 ? nil : d.priority,
                            due: .some(d.due), recurrence: d.recurrence.map { .some($0) },
                            location: d.alarms.compactMap(\.location).first.map { .some($0) }),
               listID: list(d.listID) != nil ? d.listID : nil, undo: um)
    }

    /// Days with open reminders (dots in the date picker).
    var dueDays: Set<Date> {
        Set(shown.lazy.filter { !$0.isCompleted }.compactMap { $0.due.flatMap { Due.day($0, clock: self.clock) } })
    }

    /// Saves typed draft text (if any) and closes the draft row.
    func flushDraft() {
        guard let d = draft else { return }
        draft = nil
        createParsed(d.text, listID: d.listID, due: d.due, undo: NSApp.keyWindow?.undoManager)
    }

    /// Creates from typed text, taking a date/repeat written in it ("Do dishes tonight") out of the title.
    func createParsed(_ text: String, listID: String?, due: DateComponents?, undo um: UndoManager?) {
        let d = NaturalDate.parse(text, clock: clock)
        let title = (d.map { $0.cleanedTitle.isEmpty ? text : $0.cleanedTitle } ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        create(ReminderEdit(title: title, due: .some(d?.due ?? due), recurrence: d?.recurrence.map { .some($0) }), listID: listID, undo: um)
    }

    /// Quit: commit the open card and draft, finish queued ops, flush pending deletes.
    func drain() async {
        commitOpenCard?()
        composeFinisher?()
        flushDraft()
        await tail?.value
        await flushDeletes()
    }

    func saveOrphanedDraft(undo um: UndoManager?) {
        guard let o = orphanedDraft else { return }
        orphanedDraft = nil
        create(ReminderEdit(title: o.title.isEmpty ? "Untitled" : o.title, notes: .some(o.notes), due: .some(o.due)),
               listID: list(o.listID) != nil ? o.listID : nil, undo: um)
    }

    var showCompletedApplies: Bool { if case .list = destination { true } else { false } }

    func toggleShowCompleted() {
        let key: String
        switch destination {
        case .list(let id): key = id
        default: return
        }
        if showCompleted.contains(key) { showCompleted.remove(key) } else { showCompleted.insert(key) }
    }

    /// ⌘1…9: visible smart lists, then pinned lists (Reminders maps ⌘1…9 to pinned items).
    var shortcutDestinations: [Destination] {
        return orderedSmart.filter { isAvailable($0) && !hiddenSmartLists.contains(title($0)) } + pinnedLists.map { .list($0.id) }
    }

    // MARK: List ops

    func createList(title: String, color: RGBA, accountID: String?) {
        enqueue {
            do {
                let id = try await self.backend.createList(title: title, color: color, accountID: accountID)
                await self.reload()
                self.destination = .list(id)
            } catch { self.fail(error) }
        }
    }

    func updateList(_ id: String, title: String? = nil, color: RGBA? = nil, undo um: UndoManager?) {
        guard let old = list(id) else { return }
        let token = newToken()
        um?.registerUndo(withTarget: token) { _ in
            self.updateList(id, title: title == nil ? nil : old.title, color: color == nil ? nil : old.color, undo: um)
        }
        um?.setActionName(title != nil ? "Rename List" : "Change Color")
        enqueue {
            do { try await self.backend.updateList(id, title: title, color: color); await self.reload() }
            catch { self.fail(error); um?.removeAllActions(withTarget: token) }
        }
    }

    /// Shows the delete confirmation with the real count (completed reminders included).
    func prepareListDelete(_ l: RList) {
        listDeleteCount = nil
        listToDelete = l
        Task { listDeleteCount = try? await backend.reminderCount(inList: l.id) }
    }

    /// With a target, every reminder (completed too) is moved first and the list is kept if any move fails;
    /// otherwise EventKit deletes the reminders with the list. Not undoable — confirmed with counts instead (R10).
    func deleteList(_ id: String, moveRemindersTo target: String?) {
        enqueue {
            do {
                try await self.backend.deleteList(id, moveTo: target)
                if self.destination == .list(id) { self.destination = .today }
            } catch { self.fail(error) }
            await self.reload()
        }
    }

    // MARK: Open in Reminders

    func openInReminders(reminder id: String) {
        NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")!)
    }
    func openInReminders(list id: String) {
        NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://REMCDList/\(id)")!)
    }
}
