import AppKit
import EventKit
import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            switch store.auth {
            case .fullAccess:
                if store.loaded && store.snap.lists.isEmpty { NoAccountView() } else { MainView() }
            case .notDetermined:
                OnboardingView()
            default:
                DeniedView()
            }
        }
        .frame(minWidth: 360, minHeight: 360)   // narrow is fine with the sidebar hidden
    }
}

struct MainView: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um
    @AppStorage("sidebarHidden") private var sidebarHidden = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: Binding(get: { sidebarHidden ? .detailOnly : .all },
                                                      set: { sidebarHidden = $0 == .detailOnly })) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            ReminderListView(destination: store.destination)
                .navigationSplitViewColumnWidth(min: 320, ideal: 560)
        }
        .overlay(alignment: .bottom) { BannerView() }
        .background(WindowMemory())
        .onChange(of: store.loaded, initial: true) { _, loaded in if loaded { store.noteWindowShown() } }
        .sheet(isPresented: $store.showNewList) { ListEditor(list: nil) }
        .sheet(item: $store.listToEdit) { ListEditor(list: $0) }
        .sheet(isPresented: $store.showMoveSheet) { MoveSheet(ids: Array(store.selection)) }
        .storeDialogs()
    }
}


/// Remembers the main window's size and position between launches, under a fixed key. (SwiftUI's own autosave key
/// is derived from the view's type, so it changed with every build that touched the root view.)
struct WindowMemory: NSViewRepresentable {
    private static let key = "mainWindowFrame"

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        // After SwiftUI has placed the window, so the saved frame wins.
        DispatchQueue.main.async { context.coordinator.attach(v.window) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private static var claimed = false   // only the first window is remembered

        func attach(_ w: NSWindow?) {
            guard let w, window == nil, !Self.claimed else { return }
            Self.claimed = true
            window = w
            if let s = UserDefaults.standard.string(forKey: WindowMemory.key) {
                let r = NSRectFromString(s)
                // Only if it still lands on a connected screen (a display may have been unplugged).
                if r.width >= 300, r.height >= 300, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                    w.setFrame(r, display: true)
                }
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { n in
                    guard let w = n.object as? NSWindow else { return }
                    UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: WindowMemory.key)
                })
            }
        }
    }
}
