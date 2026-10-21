import EventKit
import Foundation
import Testing
@testable import Tidy

/// Runs against real Reminders. Enabled only when ALL hold:
///  1. env TTR_INTEGRATION=1 (xcodebuild: TEST_RUNNER_TTR_INTEGRATION=1),
///  2. full Reminders access was already granted to the app,
///  3. a list named "TTR-TEST-ACCOUNT" exists — the marker that this is the throwaway test account.
/// Every test works in its own TTR-IT-<uuid> list and deletes it afterwards.
enum IntegrationEnv {
    static var enabled: Bool {
        guard ProcessInfo.processInfo.environment["TTR_INTEGRATION"] == "1",
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return false }
        return EKEventStore().calendars(for: .reminder).contains { $0.title == "TTR-TEST-ACCOUNT" }
    }
}

@Suite(.serialized, .enabled(if: IntegrationEnv.enabled, "needs the ttr-test account (see SPIKES.md)"))
struct IntegrationTests {
    let backend = Backend()
    private var clock: Clock { .current }

    private func withList(_ body: (String) async throws -> Void) async throws {
        let id = try await backend.createList(title: "TTR-IT-\(UUID().uuidString.prefix(8))", color: RGBA(r: 0.5, g: 0.5, b: 0.5), accountID: nil)
        do { try await body(id) } catch { try? await backend.deleteList(id); throw error }
        try await backend.deleteList(id)
    }

    private func fresh(_ id: String) async throws -> Reminder {
        try #require(await backend.reminders([id], useBridge: false).first)
    }

    /// S3 (part): a timed due date gets exactly one absolute alarm at the due time; date-only gets none.
    @Test func timedDueGetsAlarm() async throws {
        try await withList { list in
            let due = Due.components(Date().addingTimeInterval(3600 * 26), allDay: false, timeZone: nil, clock: clock)
            let r = try await backend.create(ReminderEdit(title: "timed", due: .some(due)), listID: list)
            #expect(r.alarms.compactMap(\.absolute).count == 1)
            let d = try await backend.create(ReminderEdit(title: "dateonly", due: .some(Due.components(Date(), allDay: true, timeZone: nil, clock: clock))), listID: list)
            #expect(d.alarms.isEmpty)
        }
    }

    /// R2 end to end: rescheduling shifts the alarm; unrelated edits don't touch due/alarms.
    @Test func rescheduleShiftsAlarmAndTitleEditLeavesDateAlone() async throws {
        try await withList { list in
            let t1 = Date().addingTimeInterval(3600 * 30)
            let r = try await backend.create(ReminderEdit(title: "a", due: .some(Due.components(t1, allDay: false, timeZone: nil, clock: clock))), listID: list)
            let t2 = t1.addingTimeInterval(3600 * 24)
            _ = try await backend.apply(ReminderEdit(due: .some(Due.components(t2, allDay: false, timeZone: nil, clock: clock))), to: r.id, base: r)
            let moved = try await fresh(r.id)
            let alarm = try #require(moved.alarms.compactMap(\.absolute).first)
            #expect(abs(alarm.timeIntervalSince(t2)) < 61)
            _ = try await backend.apply(ReminderEdit(title: "b"), to: r.id, base: moved)
            let renamed = try await fresh(r.id)
            #expect(renamed.title == "b" && renamed.due == moved.due && renamed.alarms == moved.alarms)
        }
    }

    /// S4 / R1: completing a repeating reminder keeps the same ID, advanced and still incomplete.
    @Test func repeatingCompletionAdvancesInPlace() async throws {
        try await withList { list in
            let today = Due.components(Date(), allDay: true, timeZone: nil, clock: clock)
            let r = try await backend.create(ReminderEdit(title: "daily", due: .some(today), recurrence: .some(Recurrence(frequency: .daily))), listID: list)
            let (updated, failed) = await backend.setCompleted([r.id], true)
            #expect(failed.isEmpty)
            let after = try #require(updated.first)
            print("S4: same id \(after.id == r.id), completed \(after.isCompleted), due \(String(describing: after.due)) was \(String(describing: r.due))")
            #expect(after.id == r.id)
            #expect(!after.isCompleted)
            #expect(after.due != r.due)
        }
    }

    /// S5 (part): moving a plain reminder between two lists of the same account keeps its ID.
    @Test func sameAccountMoveKeepsID() async throws {
        try await withList { a in
            try await withList { b in
                let r = try await backend.create(ReminderEdit(title: "mover"), listID: a)
                let (moved, _, _) = try await backend.apply(ReminderEdit(listID: b), to: r.id, base: r)
                print("S5: id kept \(moved.id == r.id)")
                #expect(moved.listID == b)
                #expect(moved.id == r.id)
            }
        }
    }

    /// R7: a repeating reminder can't lose its date without losing the repeat.
    @Test func clearingDueOfRepeatingIsRefused() async throws {
        try await withList { list in
            let today = Due.components(Date(), allDay: true, timeZone: nil, clock: clock)
            let r = try await backend.create(ReminderEdit(title: "rep", due: .some(today), recurrence: .some(Recurrence(frequency: .weekly))), listID: list)
            await #expect(throws: AppError.self) { try await backend.apply(ReminderEdit(due: .some(nil)), to: r.id, base: r) }
            let (cleared, _, _) = try await backend.apply(ReminderEdit(due: .some(nil), recurrence: .some(nil)), to: r.id, base: r)
            #expect(cleared.due == nil && cleared.recurrence == nil)
        }
    }

    /// S10-style smoke: the private bridge reads the reminders we just made (no writes).
    @Test func bridgeReadsOwnReminders() async throws {
        try await withList { list in
            let r = try await backend.create(ReminderEdit(title: "bridged"), listID: list)
            let snap = try await backend.load(completedSince: Date().addingTimeInterval(-86400), sectionsFor: list, useBridge: true)
            print("bridge report: \(snap.bridge.report)")
            #expect(snap.bridge.readOK)
            #expect(snap.reminders[r.id]?.extras != nil)
        }
    }
}
