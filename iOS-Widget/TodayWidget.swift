import AppIntents
import EventKit
import SwiftUI
import WidgetKit

@main
struct TidyWidgets: WidgetBundle {
    var body: some Widget { TodayWidget() }
}

/// Today (overdue + due today) like Reminders' widget, but the count sits in a header row so the reminders get
/// the full width. Tapping a circle completes the reminder; tapping a title opens it in Tidy.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: TodayProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today")
            .description("Overdue and due today, with room for long titles.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayEntry: TimelineEntry {
    var date: Date
    var items: [Reminder]
    var colors: [String: Color] = [:]   // list ID → list color, for the circles
    var access = true
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let titles = ["Water the plants", "Call the dentist", "Buy milk", "Pay rent", "Book flights", "Gym"]
        return TodayEntry(date: .now, items: titles.enumerated().map { i, t in
            Reminder(id: "\(i)", listID: "", title: t, isCompleted: false, priority: 0, due: nil, alarms: [])
        })
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        Task { completion(context.isPreview ? placeholder(in: context) : await Self.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        Task {
            let entry = await Self.load()
            // Timed reminders turn red when they pass and the day rolls over at midnight; the app also
            // reloads the widget whenever Today changes.
            let clock = Clock.current
            let midnight = clock.cal.date(byAdding: .day, value: 1, to: clock.today) ?? .now
            completion(Timeline(entries: [entry], policy: .after(min(midnight, .now.addingTimeInterval(30 * 60)))))
        }
    }

    /// Reads Reminders directly (public EventKit; the widget doesn't load the private bridge), minus the lists and
    /// reminders hidden in the app (shared through the App Group).
    static func load() async -> TodayEntry {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return TodayEntry(date: .now, items: [], access: false)
        }
        let store = EKEventStore()
        let clock = Clock.current
        let end = clock.cal.date(byAdding: .day, value: 1, to: clock.today)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let rems: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { c.resume(returning: $0 ?? []) }
        }
        var colors: [String: Color] = [:]
        for cal in store.calendars(for: .reminder) { colors[cal.calendarIdentifier.uppercased()] = Color(cgColor: cal.cgColor) }
        let shared = UserDefaults(suiteName: "group.com.brainpad.tidy")
        let hiddenLists = Set(shared?.stringArray(forKey: "hiddenLists") ?? [])
        let hiddenFromToday = Set(shared?.stringArray(forKey: "hiddenFromToday") ?? [])
        let today = rems.compactMap(Reminder.init).filter {
            Smart.inToday($0, clock) && !hiddenLists.contains($0.listID) && !hiddenFromToday.contains($0.id)
        }
        return TodayEntry(date: .now, items: Sorting.smart(today, clock: clock), colors: colors)
    }
}

struct CompleteReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Reminder"
    static let isDiscoverable = false

    @Parameter(title: "Reminder ID") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        let store = EKEventStore()
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder, !r.isCompleted {
            r.isCompleted = true   // a repeating one advances to its next date (R1)
            try store.save(r, commit: true)
        }
        return .result()
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    private let clock = Clock.current

    /// Rows that fit under the header. No "+N more" line: the header's count already says how many there are.
    private var capacity: Int {
        switch family {
        case .systemLarge: 12
        default: 4
        }
    }

    var body: some View {
        let shown = Array(entry.items.prefix(capacity))
        VStack(alignment: .leading, spacing: 5) {
            header
            if !entry.access {
                Spacer(minLength: 0)
                Text("Open Tidy to allow access to Reminders.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if entry.items.isEmpty {
                Spacer(minLength: 0)
                Label("All done for today", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(shown) { row($0) }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        .widgetURL(URL(string: "tidy://today"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill").foregroundStyle(.yellow).widgetAccentable()
            Text("Today").font(.headline)
            Spacer(minLength: 4)
            Text("\(entry.items.count)").font(.title3.weight(.bold)).monospacedDigit()
                .foregroundStyle(entry.items.contains { Smart.isOverdue($0, clock) } ? Color.red : .primary)
        }
    }

    private func row(_ r: Reminder) -> some View {
        HStack(spacing: 10) {
            if family != .systemSmall {
                Button(intent: CompleteReminderIntent(id: r.id)) {
                    Circle().strokeBorder(entry.colors[r.listID] ?? .secondary, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete \(r.title)")
            }
            Link(destination: URL(string: "tidy://reminder/\(r.id)")!) {
                HStack(spacing: 6) {
                    if Priority(raw: r.priority) != .none {
                        Text(Priority(raw: r.priority).marks).fontWeight(.bold).foregroundStyle(.orange)
                    }
                    Text(r.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if family != .systemSmall {
                        if r.isRepeating { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                        if let when = when(r) {
                            Text(when.text).font(.caption).monospacedDigit()
                                .foregroundStyle(when.overdue ? Color.red : .secondary)
                        }
                    }
                }
            }
        }
        .font(.subheadline)
        .frame(height: 20)
    }

    /// Today: the time (red once it's passed), nothing when all-day. Earlier days: "Yesterday", "Oct 20".
    private func when(_ r: Reminder) -> (text: String, overdue: Bool)? {
        guard let due = r.due, let day = Due.day(due, clock: clock) else { return nil }
        let overdue = Smart.isOverdue(r, clock)
        guard day == clock.today else { return (Display.duePill(due, clock: clock).text, overdue) }
        guard !Due.isAllDay(due), let d = Due.date(due, clock: clock) else { return nil }
        return (d.formatted(date: .omitted, time: .shortened), overdue)
    }
}
