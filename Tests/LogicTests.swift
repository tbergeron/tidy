import EventKit
import Foundation
import Testing
@testable import TickTickReminders

/// Wednesday 2026-10-21 10:00 in Montreal, week starting Sunday.
private let tz = TimeZone(identifier: "America/Montreal")!
private let clock: Clock = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    cal.firstWeekday = 1
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
    return Clock(now: now, cal: cal)
}()
private func at(_ d: Int, _ h: Int = 0, _ m: Int = 0, month: Int = 10) -> Date {
    clock.cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
}
private func reminder(_ id: String = "A", due: DateComponents? = nil, priority: Int = 0, created: Date? = nil,
                      done: Bool = false, parent: String? = nil) -> Reminder {
    Reminder(id: id, listID: "L", title: id, isCompleted: done, priority: priority, due: due, alarms: [], created: created,
             extras: parent.map { Extras(parentID: $0) })
}
private func allDay(_ d: Int, month: Int = 10) -> DateComponents { Due.components(at(d, month: month), allDay: true, timeZone: nil, clock: clock) }
private func timed(_ d: Int, _ h: Int, _ m: Int = 0) -> DateComponents { Due.components(at(d, h, m), allDay: false, timeZone: tz, clock: clock) }

@Suite struct DueTests {
    @Test func dateOnlyIsFloatingWithoutTime() {
        let c = allDay(21)
        #expect(c.hour == nil && c.minute == nil && c.timeZone == nil)
        #expect(c.calendar?.identifier == .gregorian)
        #expect((c.year, c.month, c.day) == (2026, 10, 21))
        #expect(Due.isAllDay(c))
    }

    @Test func timedKeepsZone() {
        let c = timed(21, 15, 30)
        #expect(c.timeZone == tz && c.hour == 15 && c.minute == 30)
        #expect(Due.date(c, clock: clock) == at(21, 15, 30))
    }

    @Test func gregorianEvenForJapaneseUserCalendar() {
        var jp = clock
        jp.cal = Calendar(identifier: .japanese)
        jp.cal.timeZone = tz
        let c = Due.components(at(21), allDay: true, timeZone: nil, clock: jp)
        #expect(c.year == 2026)
    }

    @Test func movingKeepsTimeOfDay() {
        let moved = Due.moving(timed(21, 15), toDay: at(25), clock: clock)
        #expect((moved.day, moved.hour) == (25, 15))
        #expect(Due.moving(nil, toDay: at(25), clock: clock).hour == nil)
    }

    @Test func weekendAndNextWeek() {
        #expect(Due.thisWeekend(clock) == at(24))   // Saturday
        #expect(Due.nextWeek(clock) == at(25))      // Sunday (firstWeekday = 1)
        #expect(Due.tomorrow(clock) == at(22))
    }
}

@Suite struct AlarmPlanTests {
    @Test func newTimedDueAddsAlarm() {
        #expect(AlarmPlan.shifted([], from: nil, to: timed(22, 9), clock: clock) == [at(22, 9)])
        #expect(AlarmPlan.shifted([], from: nil, to: allDay(22), clock: clock).isEmpty)
    }

    @Test func timedToTimedShiftsEveryAbsoluteAlarm() {
        let out = AlarmPlan.shifted([at(21, 15), at(21, 14)], from: timed(21, 15), to: timed(23, 9), clock: clock)
        #expect(out == [at(23, 9), at(23, 8)])
    }

    @Test func dateOnlyShiftsByWholeDays() {
        #expect(AlarmPlan.shifted([at(20, 9)], from: allDay(21), to: allDay(24), clock: clock) == [at(23, 9)])
    }

    @Test func timedToDateOnlyDropsDueAlarmKeepsOthers() {
        let out = AlarmPlan.shifted([at(21, 15), at(21, 8)], from: timed(21, 15), to: allDay(22), clock: clock)
        #expect(out == [at(22, 8)])
    }

    @Test func dateOnlyToTimedAddsDueAlarm() {
        #expect(AlarmPlan.shifted([], from: allDay(21), to: timed(21, 18), clock: clock) == [at(21, 18)])
    }

    @Test func clearingDueRemovesOnlyTheDueAlarm() {
        #expect(AlarmPlan.shifted([at(21, 15), at(20, 9)], from: timed(21, 15), to: nil, clock: clock) == [at(20, 9)])
    }

    @Test func unchangedDueLeavesAlarms() {
        #expect(AlarmPlan.shifted([at(1, 1)], from: timed(21, 15), to: timed(21, 15), clock: clock) == [at(1, 1)])
    }
}

@Suite struct PriorityTests {
    @Test(arguments: [(0, Priority.none), (1, .high), (4, .high), (5, .medium), (6, .low), (9, .low)])
    func readsByRange(raw: Int, p: Priority) { #expect(Priority(raw: raw) == p) }

    @Test func writesCanonicalValues() {
        #expect(Priority.allCases.map(\.raw) == [0, 9, 5, 1])
    }
}

@Suite struct SmartListTests {
    @Test func todayIncludesOverdueNotTomorrow() {
        #expect(Smart.inToday(reminder(due: allDay(19)), clock))
        #expect(Smart.inToday(reminder(due: timed(21, 23)), clock))
        #expect(!Smart.inToday(reminder(due: allDay(22)), clock))
        #expect(!Smart.inToday(reminder(due: allDay(19), done: true), clock))
        #expect(!Smart.inToday(reminder(), clock))
    }

    @Test func overdue() {
        #expect(Smart.isOverdue(reminder(due: allDay(20)), clock))
        #expect(!Smart.isOverdue(reminder(due: allDay(21)), clock))   // all-day today is not overdue
        #expect(Smart.isOverdue(reminder(due: timed(21, 9)), clock))  // earlier today
    }

    @Test func groupByTimeEdges() {
        let b = { Smart.todayBucket(reminder(due: $0), clock, groupByTime: true) }
        #expect(b(timed(21, 11, 59)) == .morning)
        #expect(b(timed(21, 12)) == .afternoon)
        #expect(b(timed(21, 17)) == .tonight)
        #expect(b(allDay(21)) == .allDay)
        #expect(b(allDay(18)) == .overdue)
        #expect(Smart.todayBucket(reminder(due: timed(21, 9)), clock, groupByTime: false) == .today)
    }

    @Test func scheduledBuckets() {
        #expect(Smart.scheduledBucket(reminder(due: allDay(20)), clock) == .overdue)
        #expect(Smart.scheduledBucket(reminder(due: allDay(27)), clock) == .day(at(27)))
        #expect(Smart.scheduledBucket(reminder(due: allDay(28)), clock) == .month(at(1)))
        #expect(Smart.scheduledBucket(reminder(due: allDay(3, month: 11)), clock) == .month(at(1, month: 11)))
        #expect(Smart.scheduledDays(clock).count == 7)
    }
}

@Suite struct SortingTests {
    @Test func manualOrderThenUnmergedByCreation() {
        let rs = [reminder("C", created: at(3)), reminder("B", created: at(2)), reminder("A", created: at(1)), reminder("D", created: at(4))]
        let out = Sorting.sorted(rs, style: "manual", manual: ["D", "B"], clock: clock).map(\.id)
        #expect(out == ["D", "B", "A", "C"])
    }

    @Test func priorityHighestFirst() {
        let rs = [reminder("low", priority: 9), reminder("none"), reminder("high", priority: 1), reminder("med", priority: 5)]
        #expect(Sorting.sorted(rs, style: "priority_desc", manual: [], clock: clock).map(\.id) == ["high", "med", "low", "none"])
    }

    @Test func dueOldestFirstUndatedLast() {
        let rs = [reminder("none"), reminder("late", due: allDay(25)), reminder("soon", due: allDay(22))]
        #expect(Sorting.sorted(rs, style: "displayDate_asc", manual: [], clock: clock).map(\.id) == ["soon", "late", "none"])
        #expect(Sorting.sorted(rs, style: "displayDate_desc", manual: [], clock: clock).map(\.id) == ["late", "soon", "none"])
    }
}

@Suite struct RecurrenceTests {
    @Test(arguments: [RepeatPreset.daily, .weekdays, .weekends, .weekly, .biweekly, .monthly, .every3Months, .every6Months, .yearly])
    func presetRoundTripsThroughEventKit(p: RepeatPreset) {
        let r = p.recurrence()!
        let back = RecurrenceMap.recurrence(RecurrenceMap.rule(r))
        #expect(RepeatPreset(back) == p)
    }

    @Test func lastWeekdayOfMonthAndEnds() {
        let r = Recurrence(frequency: .monthly, weekdays: [.init(day: 2), .init(day: 3), .init(day: 4), .init(day: 5), .init(day: 6)],
                           setPositions: [-1], end: .count(5))
        let back = RecurrenceMap.recurrence(RecurrenceMap.rule(r))
        #expect(back.setPositions == [-1] && back.end == .count(5) && back.weekdays.count == 5)
        let dated = Recurrence(frequency: .weekly, end: .date(at(1, month: 12)))
        #expect(RecurrenceMap.recurrence(RecurrenceMap.rule(dated)).end == .date(at(1, month: 12)))
    }

    @Test func describe() {
        #expect(RecurrenceMap.describe(nil) == nil)
        #expect(RecurrenceMap.describe(RepeatPreset.weekdays.recurrence()) == "Weekdays")
        #expect(RecurrenceMap.describe(Recurrence(frequency: .daily, interval: 3)) == "Every 3 days")
        #expect(RecurrenceMap.describe(RepeatPreset.daily.recurrence(), hourly: true) == "Hourly")
    }
}

@Suite struct EditTests {
    @Test func diffOnlyChangedKeys() {
        let base = reminder(due: allDay(21), priority: 5)
        var draft = base
        draft.title = "New"
        draft.priority = 4   // still "high"? no: 4 is high, 5 medium → changed
        let e = Edits.diff(base: base, draft: draft)
        #expect(e.title == "New" && e.priority == 4 && e.due == nil && e.notes == nil && e.listID == nil)
        var same = base
        same.priority = 5
        #expect(Edits.diff(base: base, draft: same).isEmpty)
    }

    @Test func emptyNotesIsNotAChange() {
        var base = reminder()
        base.notes = nil
        var draft = base
        draft.notes = ""
        #expect(Edits.diff(base: base, draft: draft).isEmpty)
    }

    @Test func conflictsOnlyForEditedKeysChangedElsewhere() {
        let base = reminder()
        var fresh = base
        fresh.title = "Changed on iPhone"
        fresh.priority = 1
        let e = ReminderEdit(title: "Mine")
        #expect(Edits.conflicts(e, base: base, fresh: fresh) == ["title"])
        #expect(Edits.conflicts(ReminderEdit(notes: .some("x")), base: base, fresh: fresh).isEmpty)
    }

    @Test func inverseRestoresBase() {
        let base = reminder(due: allDay(21))
        let e = ReminderEdit(title: "X", due: .some(nil), listID: "M")
        let after = Edits.applied(e, to: base)
        let back = Edits.applied(Edits.diff(base: after, draft: base), to: after)
        #expect(back == base)
    }

    @Test func rebaseAdoptsUntouchedKeysOnly() {
        let base = reminder()
        var draft = base
        draft.title = "Typing"
        var fresh = base
        fresh.title = "Remote title"
        fresh.priority = 1
        let (b, d) = Edits.rebase(base: base, draft: draft, fresh: fresh)
        #expect(d.title == "Typing" && b.title == base.title)    // the user's edit wins and still diffs
        #expect(d.priority == 1 && b.priority == 1)               // untouched key follows the other device
        #expect(Edits.diff(base: b, draft: d).title == "Typing")
    }

    @Test func tagDeltaIsCaseInsensitive() {
        let (add, remove) = Edits.tagDelta(base: ["Work", "home"], edited: ["work", "Errand", "errand"])
        #expect(add == ["Errand"] && remove == ["home"])
    }
}

@Suite struct DisplayTests {
    @Test func duePill() {
        #expect(Display.duePill(allDay(21), clock: clock).text == "Today")
        #expect(Display.duePill(allDay(22), clock: clock).text == "Tomorrow")
        #expect(Display.duePill(allDay(20), clock: clock).overdue)
        #expect(!Display.duePill(allDay(23), clock: clock).overdue)
    }
}

@Suite struct CalendarLayoutTests {
    @Test func dropTimeSnapsTo15Minutes() {
        #expect(CalendarLayout.dropTime(y: 44 * 9 + 10, hourHeight: 44, day: at(21), clock: clock) == at(21, 9, 15))
        #expect(CalendarLayout.dropTime(y: -20, hourHeight: 44, day: at(21), clock: clock) == at(21, 0))
        #expect(CalendarLayout.dropTime(y: 44 * 30, hourHeight: 44, day: at(21), clock: clock) == at(21, 23, 45))
    }

    @Test func overlappingItemsShareColumns() {
        let cols = CalendarLayout.columns([
            ("a", at(21, 9), at(21, 10)), ("b", at(21, 9, 30), at(21, 11)), ("c", at(21, 10), at(21, 10, 30)), ("d", at(21, 12), at(21, 13)),
        ])
        #expect(cols["a"]! == (0, 2) && cols["b"]! == (1, 2) && cols["c"]! == (0, 2))
        #expect(cols["d"]! == (0, 1))   // separate cluster
    }

    @Test func monthGridIsWholeWeeks() {
        let days = CalendarLayout.month(containing: at(21), clock: clock)
        #expect(days.count % 7 == 0)
        #expect(days.first == at(27, month: 9))   // Sunday before Oct 1, 2026
        #expect(days.contains(at(31)))
        #expect(CalendarLayout.week(containing: at(21), clock: clock).first == at(18))
    }
}

@Suite struct ReviewRegressionTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!

    @Test func movingKeepsLocalTimeForForeignZone() {
        // 21:00 Paris == 15:00 Montreal. Moved to the 25th it must still show 15:00 here, and stay in Paris time.
        let c = Due.components(at(21, 15), allDay: false, timeZone: paris, clock: clock)
        let moved = Due.moving(c, toDay: at(25), clock: clock)
        #expect(moved.timeZone == paris)
        #expect(Due.date(moved, clock: clock) == at(25, 15))
    }

    @Test func todayBucketUsesLocalHour() {
        let c = Due.components(at(21, 10), allDay: false, timeZone: paris, clock: clock)   // 16:00 Paris, 10:00 here
        #expect(Smart.todayBucket(reminder(due: c), clock, groupByTime: true) == .morning)
    }

    @Test func sameIgnoresComponentObjects() {
        var a = timed(21, 9)
        a.calendar = nil
        #expect(Due.same(a, timed(21, 9), clock: clock))
        #expect(!Due.same(timed(21, 9), timed(21, 10), clock: clock))
        #expect(!Due.same(allDay(21), timed(21, 0), clock: clock))
        #expect(Due.same(nil, nil, clock: clock) && !Due.same(nil, allDay(21), clock: clock))
    }

    @Test func conflictsUsePriorityRanges() {
        let base = reminder(priority: 1)
        var fresh = base
        fresh.priority = 3   // still "high": not a conflict
        #expect(Edits.conflicts(ReminderEdit(priority: 5), base: base, fresh: fresh).isEmpty)
    }

    @Test func removingDropsNamedKeys() {
        let e = Edits.removing(["title", "date"], from: ReminderEdit(title: "x", priority: 1, due: .some(nil)))
        #expect(e.title == nil && e.due == nil && e.priority == 1)
    }

    @Test func dropTimeOnSpringForwardDay() {
        // 2027-03-14 is DST start in Montreal: 02:00 → 03:00. A drop at the 09:00 line must give 09:00.
        let day = clock.cal.date(from: DateComponents(year: 2027, month: 3, day: 14))!
        let t = CalendarLayout.dropTime(y: 44 * 9, hourHeight: 44, day: day, clock: clock)
        #expect(clock.cal.component(.hour, from: t) == 9)
        #expect(CalendarLayout.wallHours(t, on: day, clock: clock) == 9)
    }
}

@Suite struct DuePresetTests {
    @Test func presetTimes() {
        #expect(DuePreset.todayMorning.date(clock) == at(21, 9))
        #expect(DuePreset.thisEvening.date(clock) == at(21, 18))
        #expect(DuePreset.tomorrowMorning.date(clock) == at(22, 9))
        #expect(DuePreset.inAWeek.date(clock) == at(28, 9))
    }

    @Test func detailsShowWhen() {
        #expect(DuePreset.inAWeek.name == "Next Week")
        #expect(DuePreset.inAWeek.detail(clock).contains("28"))      // the date it lands on
        #expect(DuePreset.tomorrowMorning.detail(clock).hasPrefix("Thu"))
    }
}
