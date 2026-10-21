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
        .frame(minWidth: 760, minHeight: 480)
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
            if store.destination == .calendar { CalendarView() } else { ReminderListView(destination: store.destination) }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search")
        .overlay(alignment: .bottom) { BannerView() }
        .sheet(isPresented: $store.showNewList) { ListEditor(list: nil) }
        .sheet(item: $store.listToEdit) { ListEditor(list: $0) }
        .sheet(isPresented: $store.showMoveSheet) { MoveSheet(ids: Array(store.selection)) }
        .confirmationDialog("Delete repeating reminder?", isPresented: Binding(
            get: { store.confirmDeleteIDs != nil }, set: { if !$0 { store.confirmDeleteIDs = nil } })
        ) {
            Button("Delete All Occurrences", role: .destructive) {
                if let ids = store.confirmDeleteIDs { store.delete(ids, undo: um) }
                store.confirmDeleteIDs = nil
            }
        } message: {
            Text("Reminders deletes every future occurrence of a repeating reminder. Deleting only this one isn't available yet.")
        }
        .confirmationDialog(deleteListTitle, isPresented: Binding(
            get: { store.listToDelete != nil }, set: { if !$0 { store.listToDelete = nil } })
        ) {
            if let l = store.listToDelete {
                Button("Delete List and \(openCount(l)) Reminders", role: .destructive) { store.deleteList(l.id, moveRemindersTo: nil) }
                if let target = store.snap.defaultListID, target != l.id, let t = store.list(target) {
                    Button("Move Reminders to “\(t.title)”, then Delete") { store.deleteList(l.id, moveRemindersTo: target) }
                }
            }
        } message: {
            Text(store.listToDelete?.id == store.snap.defaultListID
                 ? "This is your default list. Reminders will pick another default."
                 : "Deleting a list also deletes its reminders.")
        }
    }

    private var deleteListTitle: String { "Delete “\(store.listToDelete?.title ?? "")”?" }
    private func openCount(_ l: RList) -> Int { store.live.filter { $0.listID == l.id && !$0.isCompleted }.count }
}

struct BannerView: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let text = store.banner {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                Text(text).lineLimit(3)
                Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(for: .seconds(8))
                if store.banner == text { store.banner = nil }
            }
        }
    }
}

struct OnboardingView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Works directly with Apple Reminders").font(.title2.weight(.semibold))
            Text("Everything you do here is saved in Reminders and syncs to your iPhone, iPad and Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Continue") { Task { await store.requestAccess() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(40)
    }
}

struct DeniedView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Reminders access is off").font(.title2.weight(.semibold))
            Text("Turn on Full Access for TickTickReminders in System Settings › Privacy & Security › Reminders, then reopen the app.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
            }
        }
        .padding(40)
    }
}

struct NoAccountView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.slash").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No Reminders account").font(.title2.weight(.semibold))
            Text(AppError.noAccount.errorDescription ?? "")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(40)
    }
}
