import SwiftUI
import UIKit

@main
struct TidyApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onAppear { store.start() }
                .onOpenURL(perform: open)
        }
        .commands { AppCommands(store: store) }   // iPad keyboard menu
        .onChange(of: phase) { _, p in
            // The open editor, queued ops and pending deletes (R9) are saved before iOS suspends the app.
            guard p == .background else { return }
            let task = UIApplication.shared.beginBackgroundTask()
            Task {
                await store.drain()
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    /// Widget taps: tidy://today, tidy://reminder/<id>.
    private func open(_ url: URL) {
        guard url.scheme == "tidy" else { return }
        store.destination = .today
        store.openToday += 1
        if url.host() == "reminder", let id = url.pathComponents.dropFirst().first, store.snap.reminders[id] != nil {
            store.editingID = id
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        switch store.auth {
        case .fullAccess:
            if store.loaded && store.snap.lists.isEmpty { NoAccountView() } else { MainView() }
        case .notDetermined:
            OnboardingView()
        default:
            DeniedView()
        }
    }
}
