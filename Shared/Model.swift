import Foundation

// Sendable value snapshots. EventKit / ReminderKit objects never leave `Backend`.

struct Reminder: Identifiable, Hashable, Sendable, Codable {
    let id: String                  // calendarItemIdentifier, uppercased
    var externalID: String?
    var listID: String
    var title: String
    var notes: String?
    var isCompleted: Bool
    var completionDate: Date?
    var priority: Int               // raw EK value 0…9; see Priority
    var due: DateComponents?        // no hour = all-day (R3)
    var alarms: [Alarm]
    var recurrence: Recurrence?
    var created: Date?
    var modified: Date?
    var extras: Extras?             // nil when the private bridge is off

    var isRepeating: Bool { recurrence != nil || extras?.hourly == true }
    var parentID: String? { extras?.parentID }
}

struct Alarm: Hashable, Sendable, Codable {
    var absolute: Date?
    var relative: TimeInterval?
    var location: LocationAlarm?
}

struct LocationAlarm: Hashable, Sendable, Codable {
    var title: String
    var latitude: Double
    var longitude: Double
    var radius: Double              // meters, 0 = system default
    var leaving: Bool
}

struct Recurrence: Hashable, Sendable, Codable {
    enum Frequency: Int, Sendable, CaseIterable, Codable { case daily, weekly, monthly, yearly }
    struct Weekday: Hashable, Sendable, Codable { var day: Int; var week: Int = 0 }   // day 1 = Sunday … 7
    enum End: Hashable, Sendable, Codable { case date(Date), count(Int) }

    var frequency: Frequency
    var interval: Int = 1
    var weekdays: [Weekday] = []
    var monthDays: [Int] = []
    var months: [Int] = []
    var setPositions: [Int] = []
    var end: End?
}

/// Reminders-only data read through the private bridge.
struct Extras: Hashable, Sendable, Codable {
    var tags: [String] = []
    var flagged = false
    var urgent = false
    var parentID: String?
    var urls: [URL] = []
    var images: [ImageInfo] = []
    var earlyAlerts: [EarlyAlert] = []
    var assigneeID: String?
    var hourly = false
}

struct ImageInfo: Hashable, Sendable, Codable { var width: Int; var height: Int; var uti: String? }
struct EarlyAlert: Hashable, Sendable, Codable { var unit: Int; var count: Int }  // unit 0…4 = min…month (order confirmed in S8)

struct RList: Identifiable, Hashable, Sendable, Codable {
    let id: String                  // calendarIdentifier, uppercased
    var title: String
    var color: RGBA
    var accountID: String
    var accountTitle: String
    var readOnly: Bool              // !allowsContentModifications: no item edits
    var immutable: Bool             // can't rename/recolor/delete the list itself
    // bridge
    var groupID: String?
    var emblem: String?
    var isPinned = false
    var sortingStyle: String?
    var isGroceries = false
    var isShared = false
    var manualOrder: [String] = []  // reminder IDs
    var currentUserParticipantID: String?   // shared lists: "Assigned to Me" = assignee == this
}

struct RGroup: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    var accountID: String
}

struct RSection: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
}

struct Account: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var caps: Set<String> = []       // e.g. "supportsHashtags", from REMAccountCapabilities
    var listOrder: [String] = []     // list/group IDs in sidebar order
}

struct RGBA: Hashable, Sendable, Codable {
    var r: Double, g: Double, b: Double, a: Double = 1

    /// Reminders' list colors.
    static let palette: [RGBA] = [
        RGBA(r: 1, g: 0.23, b: 0.19), RGBA(r: 1, g: 0.58, b: 0), RGBA(r: 1, g: 0.8, b: 0), RGBA(r: 0.2, g: 0.78, b: 0.35),
        RGBA(r: 0.35, g: 0.78, b: 0.98), RGBA(r: 0, g: 0.48, b: 1), RGBA(r: 0.35, g: 0.34, b: 0.84), RGBA(r: 1, g: 0.18, b: 0.33),
        RGBA(r: 0.69, g: 0.32, b: 0.87), RGBA(r: 0.64, g: 0.52, b: 0.37), RGBA(r: 0.56, g: 0.56, b: 0.58), RGBA(r: 0.85, g: 0.65, b: 0.6),
    ]
}

struct BridgeStatus: Hashable, Sendable, Codable {
    var loaded = false
    var readOK = false
    var report: [String] = []
}

struct Snapshot: Sendable, Codable {
    var accounts: [Account] = []
    var lists: [RList] = []
    var groups: [RGroup] = []
    var reminders: [String: Reminder] = [:]
    var defaultListID: String?
    var sections: [String: [RSection]] = [:]   // listID → ordered sections (viewed list only)
    var sectionOf: [String: String] = [:]      // reminderID → sectionID (viewed list only)
    var completedSince: Date = .distantPast
    var bridge = BridgeStatus()
}

/// One optional per field: nil = untouched, `.some(nil)` = clear. Only present keys are written (R11).
/// The last loaded Snapshot on disk, shown instantly at launch while the real load runs.
/// It holds the user's reminders, so it lives in this app's own Application Support folder.
enum SnapshotCache {
    static var url: URL {
        let dir = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Tidy", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "snapshot.json")
    }
    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    static func save(_ snap: Snapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct ReminderEdit: Sendable {
    var title: String?
    var notes: String??
    var isCompleted: Bool?
    var priority: Int?
    var due: DateComponents??
    var recurrence: Recurrence??
    var location: LocationAlarm??
    var listID: String?

    var isEmpty: Bool {
        title == nil && notes == nil && isCompleted == nil && priority == nil && due == nil
            && recurrence == nil && location == nil && listID == nil
    }
}

/// Sidebar / navigation target.
enum Destination: Hashable, Codable, Sendable {
    case today, scheduled, all, flagged, completed, assigned, urgent
    case list(String), group(String), tag(String)
}

enum AppError: LocalizedError, Sendable {
    case notAuthorized, noAccount, notFound, timeout, readOnly
    case needsDueForRepeat, unsupported(String), moveRejected, eventKit(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Tidy doesn't have access to Reminders."
        case .noAccount: "No Reminders account is set up. Turn on iCloud Reminders in System Settings › Internet Accounts."
        case .notFound: "Changed or deleted on another device."
        case .timeout: "Reminders didn't respond."
        case .readOnly: "This list can't be changed."
        case .needsDueForRepeat: "Repeating reminders need a date."
        case .unsupported(let what): "This account doesn't support \(what)."
        case .moveRejected: "Reminders refused this move (subtasks or a shared list). Use Open in Reminders."
        case .eventKit(let msg): msg
        }
    }
}
