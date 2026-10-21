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
            ReminderListView(destination: store.destination)
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search")
        .overlay(alignment: .bottom) { BannerView() }
        .sheet(isPresented: $store.showNewList) { ListEditor(list: nil) }
        .sheet(item: $store.listToEdit) { ListEditor(list: $0) }
        .sheet(isPresented: $store.showMoveSheet) { MoveSheet(ids: Array(store.selection)) }
        .confirmationDialog(deleteText.title, isPresented: Binding(
            get: { store.confirmDeleteIDs != nil }, set: { if !$0 { store.confirmDeleteIDs = nil } })
        ) {
            Button(deleteText.button, role: .destructive) {
                if let ids = store.confirmDeleteIDs { store.delete(ids, undo: um) }
                store.confirmDeleteIDs = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(deleteText.message)
        }
        .confirmationDialog(moveOverdueTitle, isPresented: $store.confirmMoveOverdue) {
            Button("Move to Today") { store.moveOverdueToToday(undo: um) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("They keep their time of day. You can undo this with ⌘Z.")
        }
        .confirmationDialog("Move to another account?", isPresented: Binding(
            get: { store.pendingCrossMove != nil }, set: { if !$0 { store.pendingCrossMove = nil } })
        ) {
            Button("Move") {
                if let m = store.pendingCrossMove { store.move(m.ids, toList: m.listID, undo: um, confirmed: true) }
                store.pendingCrossMove = nil
            }
        } message: {
            Text("Reminders copies reminders moved to another account: tags, flags, sections and attachments won't follow, and the originals go to Recently Deleted. This can't be undone.")
        }
        .confirmationDialog(deleteListTitle, isPresented: Binding(
            get: { store.listToDelete != nil }, set: { if !$0 { store.listToDelete = nil } })
        ) {
            if let l = store.listToDelete {
                Button(store.listDeleteCount.map { "Delete List and \($0) Reminders" } ?? "Delete List and Its Reminders", role: .destructive) {
                    store.deleteList(l.id, moveRemindersTo: nil)
                }
                if let target = store.snap.defaultListID, target != l.id, let t = store.list(target), t.accountID == l.accountID {
                    Button("Move Reminders to “\(t.title)”, then Delete") { store.deleteList(l.id, moveRemindersTo: target) }
                }
            }
        } message: {
            Text((store.listToDelete?.id == store.snap.defaultListID ? "This is your default list. Reminders will pick another default. " : "")
                 + "Deleting a list also deletes its reminders, including completed ones.")
        }
    }

    private var moveOverdueTitle: String {
        let n = store.overdueIDs.count
        return n == 1 ? "Move 1 overdue reminder to today?" : "Move \(n) overdue reminders to today?"
    }
    private var deleteListTitle: String { "Delete “\(store.listToDelete?.title ?? "")”?" }
    private var deleteText: (title: String, message: String, button: String) { store.deleteConfirmation(store.confirmDeleteIDs ?? []) }
}

struct BannerView: View {
    @Environment(Store.self) private var store
    @Environment(\.undoManager) private var um

    var body: some View {
        if let o = store.orphanedDraft {
            HStack(spacing: 10) {
                Text("“\(o.title)” was deleted on another device while you were editing it.").lineLimit(2)
                Button("Save as New Reminder") { store.saveOrphanedDraft(undo: um) }
                Button("Discard") { store.orphanedDraft = nil }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 16)
        } else if let text = store.banner {
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
            Text("Turn on Full Access for Tidy in System Settings › Privacy & Security › Reminders, then reopen the app.")
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
