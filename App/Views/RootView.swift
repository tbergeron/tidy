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

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            ReminderListView(destination: store.destination)
                .navigationSplitViewColumnWidth(min: 320, ideal: 560)
        }
        .overlay(alignment: .bottom) { BannerView() }
        .onChange(of: store.loaded, initial: true) { _, loaded in if loaded { store.noteWindowShown() } }
        .sheet(isPresented: $store.showNewList) { ListEditor(list: nil) }
        .sheet(item: $store.listToEdit) { ListEditor(list: $0) }
        .sheet(isPresented: $store.showMoveSheet) { MoveSheet(ids: Array(store.selection)) }
        .storeDialogs()
    }
}

