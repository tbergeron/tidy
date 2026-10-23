import SwiftUI

/// Bridge status, capabilities and a dump of the selected reminder (compare against Reminders.app).
struct DiagnosticsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Private features (ReminderKit)") {
                Toggle("Enabled", isOn: $store.bridgeEnabled)
                LabeledContent("Status", value: store.bridgeReadable ? "Reading" : store.snap.bridge.loaded ? "Loaded, reads failing" : "Off")
                LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                ForEach(store.snap.bridge.report, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Accounts") {
                ForEach(store.snap.accounts) { a in
                    VStack(alignment: .leading) {
                        Text(a.title).bold()
                        Text(a.caps.isEmpty ? "No capabilities read" : a.caps.sorted().joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section("Selected reminder") {
                if let id = store.selection.first, let r = store.snap.reminders[id] {
                    Text(dump(r)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") { Platform.copy(dump(r)) }
                } else {
                    Text("Select a reminder first.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func dump(_ r: Reminder) -> String {
        var s = ""
        Swift.dump(r, to: &s)
        if let sec = store.snap.sectionOf[r.id] { s += "section: \(sec)\n" }
        return s
    }
}
