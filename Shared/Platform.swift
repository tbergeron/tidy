#if os(macOS)
import AppKit
#else
import UIKit
import UserNotifications
#endif

/// The few things Store and the shared views need from AppKit / UIKit.
@MainActor enum Platform {
    #if os(macOS)
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
    /// Wake from sleep (macOS) / back to the foreground (iOS): the clock and data may be stale.
    static let didWake = (center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification)
    static var undoManager: UndoManager? { NSApp.keyWindow?.undoManager }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    /// Dock badge.
    static func setBadge(_ n: Int) {
        let label = n > 0 ? "\(n)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }
    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
    #else
    static let didBecomeActive = UIApplication.didBecomeActiveNotification
    static let didWake = (center: NotificationCenter.default, name: UIApplication.willEnterForegroundNotification)
    static var undoManager: UndoManager? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.undoManager
    }
    static func open(_ url: URL) { UIApplication.shared.open(url) }
    static func copy(_ s: String) { UIPasteboard.general.string = s }
    /// App icon badge; iOS only shows it once the user allows badges.
    private static var badgeAsked = false
    private static var lastBadge: Int?
    static func setBadge(_ n: Int) {
        guard n != lastBadge else { return }
        lastBadge = n
        let center = UNUserNotificationCenter.current()
        if n > 0 && !badgeAsked {
            badgeAsked = true
            center.requestAuthorization(options: [.badge]) { _, _ in center.setBadgeCount(n) }
        } else {
            center.setBadgeCount(n)
        }
    }
    static let privacySettings = URL(string: UIApplication.openSettingsURLString)!
    #endif
}
