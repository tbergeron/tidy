# Spikes (M0)

One line per spike: outcome · decision · macOS build. Run in the `ttr-test` macOS user (throwaway Apple Account, iCloud Reminders on, marker list `TTR-TEST-ACCOUNT`), never against real data.

```bash
TEST_RUNNER_TTR_INTEGRATION=1 xcodebuild test -project Tidy.xcodeproj -scheme Tidy -destination 'platform=macOS' -derivedDataPath build/DD -only-testing:Tests/IntegrationTests
```

Fixtures to create **in Reminders.app** in the test account: `FX-rich` (tags, flag, urgent, early alert, URL, image, section, 2 subtasks, styled notes, location, timed weekly), `FX-hourly`, `FX-allday`, `FX-timed`, `FX-remindme`, a group with 2 lists, one list per sort style, early alerts in each unit, a custom smart list.

| # | Question | Outcome | Decision | Build |
|---|---|---|---|---|
| S1 | EK edits keep tags/flag/section/attachments/early alert/urgent; notes styling lost only when notes written? | | | |
| S2 | Subtasks via EK: flat? `parentReminderID` matches? EK complete/remove parent → children? | | | |
| S3 | Timed due w/o alarm notifies? Alarms on FX-timed / FX-allday / FX-remindme | | | |
| S4 | Repeating complete: same ID advances (test `repeatingCompletionAdvancesInPlace`); tags/flag copied to the completed copy? EK delete → series? | | | |
| S5 | Same-account move keeps ID (test `sameAccountMoveKeepsID`), drops section? Parent w/ subtasks → -3002 | | | |
| S6 | `calendars(for: .reminder)` with a group: child lists listed, group absent? | | | |
| S7 | EK remove → Recently Deleted invocation → undelete keeps ID + extras | | | |
| S8 | Bridge reads match FX-rich; hashtag type; early-alert unit order + sign; hourly `frequency`; section order; sublist order; probe leaves `lastModifiedDate` unchanged | | | |
| S9 | Every M3 write round-trips (no duplicate early alert; other reminders keep sections; …) | | | |
| S10 | `EKEventStoreChanged` after a private-only save? count/latency/userInfo | | | |
| S12 | 5k reminders: reload time, bridge batch, section reads | | | |
| S15 | Card inside List, reorder + drops, popovers, 5k rows scrolling | | | |
| S17 | Component shapes of FX-allday / FX-timed; color snapping | | | |
| S19 | Urgent on a date-only reminder | | | |
| S20 | Sample `filterData` JSON | | | |
| — | ⌘K "This Weekend" on a Friday: Reminders picks tomorrow or next week? (`Due.thisWeekend`) | | | |
