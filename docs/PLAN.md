# TickTickReminders — a Things-style macOS client for Apple Reminders

## Context

You want a TickTick/Todoist/Things-class task manager for macOS whose **only backend is Apple Reminders**: an alternative UI over the same data that syncs to your iPhone through iCloud. It should cover everything Reminders can do: create, edit, delete, reschedule and move reminders and lists, plus groups, sections, tags, subtasks, flags and the rest.

The project folder `~/Workshop/Tidy` is empty and not a git repo yet.

The environment:
- **Machine:** macOS 27.2 (26B5091g), Xcode 27.0, Swift 6.4.
- **Tools:** XcodeGen is installed.
- **Signing identities:** "Apple Development" and "Developer ID Application" (team ABCDE12345).

Research was done in two workflows (17 agents), covering:
- TickTick, Todoist and Things 3 on the Mac;
- a full inventory of Reminders.app on macOS 26 and 27;
- an audit of the EventKit SDK 27 headers;
- every other way into Reminders data (AppleScript, Shortcuts/App Intents, private ReminderKit, the SQLite store);
- existing apps built on Reminders;
- macOS 27 SwiftUI architecture;
- a static check of the private ReminderKit calls against this Mac's 27.2 binaries;
- a draft plan and a 61-point critique, both folded in below.

The full reports are in the scratchpad and get copied into `docs/research/` at the start of M0.

### Decisions you made (locked)

1. **Distribution:** personal / Developer ID. Not the Mac App Store.
2. **Reminders-only data** (tags, subtasks, sections, groups, flags, urgent, early alerts, URL attachments, manual order, emblems, pins, sort style and so on) is reached through **private ReminderKit, in-process**, via EventKit's own backing objects and store. That is the approach Reminders MenuBar ships with.
   - Every call is probed at launch.
   - Failures degrade to read-only plus "Open in Reminders".
   - There is a kill switch that drops to public-EventKit-only mode.
   - No Shortcuts bridge. AppleScript is dropped as well, since "Open in Reminders" covers what it would add.
3. **UI:** Things-style minimal look with **pure Reminders semantics**: no Someday, This Evening, Deadline or Inbox.
4. **Platform:** macOS 27 only, so no availability branches.
5. **Extras:** a Calendar view (day/week/month) with drag-to-reschedule, plus **read-only Calendar events**.
6. **Out of scope:** natural-language quick add and a global hotkey, menu bar extra, widgets, kanban, Pomodoro/habits, iOS.

---

## Research summary (what drives the design)

### Competitors on the Mac (full reports in `docs/research/r_{things,ticktick,todoist}.md`)

**Things 3** sets the look:
- a sidebar of fixed lists, then bold Areas with Projects underneath, each Project with a progress pie;
- spacious rows with grey trailing metadata (date pill, tag pills, icons);
- to-dos that expand inline into a card (title, notes, checklist, tags, date button bar);
- a tag filter bar at the top of each list, with ⌘-click for AND;
- a Move sheet with type-to-filter (⇧⌘M);
- Upcoming drawn as per-day drop targets;
- calendar events shown above Today and Upcoming;
- every action on the keyboard;
- glass sidebar on OS 26/27.

**TickTick** sets the calendar view:
- day, week and month views;
- an all-day lane;
- drag a block to reschedule, snapping to a 15-minute grid;
- an "Arrange Tasks" tray of undated items you drag in;
- overdue shown in red;
- "Postpone all overdue".

**Todoist:**
- an overdue section in Today with a bulk Reschedule;
- an Upcoming view with empty days kept as drop targets;
- inline create chains (Return creates the next task).

**What maps onto Reminders:**

| Things idea | Reminders equivalent |
|---|---|
| Areas | List groups |
| Projects | Lists |
| Headings | Sections |
| Checklist | Subtasks (one level) |
| Tags | Real Reminders tags |
| Today and Upcoming | Today (which includes overdue) and Scheduled |
| Logbook | Completed |
| Trash | Recently Deleted |

Things' importer and GoodTask prove the limits of public EventKit, and our bridge removes most of them.

### Reminders access, verified

**Public EventKit has not changed since macOS 14.** It covers:
- lists: create, rename, color, delete;
- reminders: title, plain notes, start and due dates, completion, priority 0–9;
- alarms: absolute, relative, location;
- recurrence: daily, weekly, monthly or yearly, with no hourly option.

Public EventKit has **no** tags, subtasks, sections, groups, flags, urgent, early alerts, images, manual order, emblem or pin. `EKCalendarItem.url` is an invisible `icsUrl`, *not* the URL Reminders.app shows.

**The private bridge, checked statically on 27.2.** This is the chain from EventKit objects to their ReminderKit backing objects:
- `EKObject.backingObject` (an `EKFrozenReminderReminder`, `…Calendar` or `…Source`) → `REMObject` (or the fallbacks `_reminder` / `_list` / `remAccount`) → `REMReminder` / `REMList` / `REMAccount`.
- `EKEventStore.reminderStore.remStore` → `REMStore`. The getter can return nil.

ID mapping, verified in the 27.2 code:

| EventKit identifier | Backing value |
|---|---|
| `calendarItemIdentifier` | `REMReminder.objectID.uuid` |
| `calendarIdentifier` | `REMList` UUID |
| `sourceIdentifier` | `REMAccount` UUID |
| `calendarItemExternalIdentifier` | `daCalendarItemUniqueIdentifier` |

**An EventKit save writes only the keys that changed.** `_applyChanges` gates every field on `hasUnsavedChangeForKey:`. So EK edits keep tags, flags, sections and attachments, **unless** we assign notes (which flattens rich text), `recurrenceRules` (which destroys hourly repeats) or `alarms` as a whole array (which can drop vehicle triggers).

**Verdicts per private operation:**

| Verdict | Operations |
|---|---|
| **GO** (all selectors present) | Every read; writes for tags, flag, urgent, URL, remove image, rename group |
| **CAUTION** (proven only in a standalone process, or arity/semantics not yet confirmed) | Early alerts (duplicate-alert bug unless fetched with `fetchOptionsIncludingDueDateDeltaAlerts`); subtasks and indent; sections and membership (merge-vs-replace unknown); groups; manual order; emblem; pin; sort style; groceries; image add; moves that EK rejects with `-3002`; restore from Recently Deleted; assignment |
| **NO-GO** | `categorizeGroceryItemsWithReminderIDs:`, `fetchSmartListWithObjectID:error:`, global tag rename |

**Known failure history:**
- Private selectors drifted between 26.2 and 27.0.
- One wrong-argument call tombstoned objects.
- Subtask creation crashed on 26.5.1.

Hence the probes, the per-OS-build self-test, verification after every write, and running spikes on throwaway data first.

---

## Feature coverage

**Path legend:**

| Code | Meaning |
|---|---|
| EK | Public EventKit |
| PB | Private bridge. "PB·S" means it is gated by the self-test for the current OS build. |
| APP | Computed in the app |
| LOC | UserDefaults preference |
| OPEN | Deep link `x-apple-reminderkit://REMCDReminder/<UUID>` (or `REMCDList/…`) into Reminders.app |
| X | Excluded |
| DEF | Deferred |

Milestones M0–M5 are defined further down.

### Accounts and lists

- **Accounts** (`EK sources`):
  - One sidebar header per account, shown only when more than one account has lists.
  - Capabilities come from PB `account.capabilities`, and `supportsCloudKitSync` gates every private write (M2).
- **Default list:** read via EK `defaultCalendarForNewReminders()` and badged. It can't be set (no API).
  - Deleting or renaming it asks for an extra confirmation, then the default is re-read.
- **Lists:**
  - Create, rename and recolor via EK (M1). The color picker offers Reminders' 12 swatches plus a custom color.
  - Delete via EK `removeCalendar`, which deletes every reminder in the list. The confirm sheet shows counts and offers "Move reminders to … then delete" (M1).
  - Read-only when `!allowsContentModifications || isImmutable`.
- **Per-list attributes:**
  - Emblem or emoji: read in M2, write PB·S in M3. Icons are the 71 `REMListBadgeEmblem*` names (via `dlsym`), drawn from `RemindersUICore.framework/Resources/Assets.car` image `ListBadge<Name>`, tinted with the list color, with `list.bullet` as fallback.
  - Pinned: pinned means `pinnedDate != nil`. Write PB·S (M3). Enforce Reminders' limit of 9 pinned items, counting pinned lists and standard smart lists together.
  - Sort style: the 10 `REMSortingStyle*` constants via `dlsym`. Write PB·S (M3).
  - Groceries type: PB·S (M3). Disabled while `shouldAutoCategorizeItems` is on, which shows as "Auto-Categorize on (edit in Reminders)".
  - Show completed: LOC, because Reminders has no such attribute (confirmed in the data model).
- **Manual order of reminders:**
  - Read PB `reminderIDsOrdering`; IDs missing from it are appended by (creationDate, id).
  - Write PB·S `insertReminderChangeItem:before/after…`. A drag also sets the list's sort style to manual.
  - M1 falls back to creation order.
- **Sidebar order:**
  - Read PB `account.listIDsOrdering`. Sublist order is found in S8.
  - Write PB·S `insertListChangeItem:before/after…`. Fallback is by title.
- **Sharing:**
  - Read the shared badge and participants via PB.
  - Invite, stop sharing and permissions go to OPEN.
- **Not supported:**
  - Moving a list to another account (no API anywhere).
  - Convert to Smart List (destructive).
  - The list/column layout setting: it is never written, so it is preserved.
- **Templates:**
  - Read via PB (`templatesContext`).
  - "New List from Template" is PB·S in M5 (`addListUsingTemplate:toAccountChangeItem:`).
  - Saving or editing templates and public template links are DEF → OPEN.

### List groups (drawn like Things Areas)

- **Read:** PB `account.fetchListsAndSublistsWithError:` (M2). In M1, child lists appear flat.
- **Write**, all PB·S (M3):
  - Create: empty, with the selected lists, or by dropping a list onto a list.
  - Rename.
  - Delete keeping its lists (the default), or delete with its lists (EK removes each list, with counts).
  - Move a list in or out, and reorder.
- **Rules:**
  - Groups are **one level deep**, enforced by the app.
  - A list can join a group only if `canBeIncludedInGroup`, is in the same account, and is not pinned.
  - Reminders can't be dropped onto a group.
  - A group's view shows all its lists' reminders (APP).
  - A group's own "show completed" is LOC.

### Sections (drawn like Things headings)

- **Read:**
  - The sections themselves and their order: PB `fetchListSectionsWithListObjectID:error:`. S8 checks that this order matches the display order.
  - Each reminder's section: PB `REMListSectionsDataView fetchListSectionWithReminderID:error:`, for the visible list only. Marked `// ponytail:` because it is one XPC call per reminder; upgrade to the bulk invocation if S12 shows it is slow.
- **Write**, all PB·S (M3):
  - Create (⌥⌘N), and New Section with Selection (⌃⌘N).
  - Rename and reorder.
  - Delete in two ways: "Delete Section and Reminders" (Reminders' default) or "Delete Section Only".
  - Move a reminder into or out of a section.
- **Membership is stored on the list, not the reminder,** so section writes must not disturb other reminders:
  - S9 must prove that writing one reminder's membership keeps every other reminder's section.
  - The commit check compares the list's whole membership map before and after.
  - Moving to another list drops the section unless the same transaction sets one in the destination list.
  - Indenting a reminder drops its own membership entry.
- **Display:**
  - Collapsed state is LOC.
  - Unsectioned reminders appear first, with no header.

### Smart lists

| Smart list | What it shows | Milestone |
|---|---|---|
| **Today** | Due today plus all overdue (APP). Sections: Overdue (with "Move All to Today", ⌃⌘T), then Today, or All-Day / Morning / Afternoon / Tonight when Group by Time is on (LOC, default on). Dropping into a time section sets 09:00 / 15:00 / 18:00. A possible "Night" bucket and the exact boundaries are checked against a Reminders fixture. | M1; drops in M5 |
| **Scheduled** | Overdue, Today, Tomorrow, the next 5 days (always shown as drop targets), then month groups. Dragging to a day keeps the time. | M1 |
| **All** | Everything, grouped by list. | M1 |
| **Flagged** | Flagged reminders (APP over PB). Shown only when the flag capability is available. | M2 |
| **Assigned to Me** | Rule: `assigneeID == list.currentUserShareParticipantID`. This is inferred and needs a shared fixture. | M2 |
| **Urgent** | Reminders with urgent on. Hidden without `supportsUrgentAlarm`. | M2 |
| **Completed** | EK `predicateForCompletedReminders`, a 30-day window with "Load older", grouped by day. "Clear…" uses the soft delete. | M1 |
| **Recently Deleted** | PB·S. Recover returns an item to its original list, or to the default list (after a confirm) if that list is gone; children come back with it. Dropping a row onto a sidebar list recovers it there. Permanent delete → OPEN. | M3 |
| **Tags view** | Chips cycle include → exclude (struck through) → off, with an All/Any segment and an "Untagged" chip. | M2 |
| **Custom smart lists** | Read and evaluate `filterData` in the app. Any unknown filter key → OPEN. Creating or editing them is DEF. | M5 |

**Sorting:**
- Per-smart-list sort and the order of Today's sections are LOC.
- Hiding built-in smart lists is LOC. Reminders' own hidden state is not readable, because `fetchSmartListWithObjectID:` is missing.

### Reminder fields

**Title and notes (EK):**
- Write only keys the user changed (see the base-diff rule, R11).
- `#word` typed in the title or notes becomes a tag (M3).
- Rich text: if S1 finds a way to detect styled notes, those notes are locked with OPEN and a per-reminder "Edit as plain text (removes formatting)" button. **Editing rich text itself is excluded.**

**Flag, tags, urgent, URLs:**

| Field | Read | Write | Milestone | Notes |
|---|---|---|---|---|
| Flag | PB | PB | M2 / M3 | |
| Tags | PB | PB, as add/remove **deltas**, never a full-set replace | M2 / M3 | Case-insensitive. Hashtag type is fixed after S8 (expected 0). |
| Urgent | PB | PB | M2 / M3 | S19 checks whether it needs a timed due date. |
| URL attachments | PB | PB add/remove, http/https only | M2 / M3 | EK `url` is never touched. |

**Images:**
- Read metadata via PB and show a placeholder with OPEN. The files sit in a protected container and are never read.
- Add (an NSOpenPanel, pixel sizes from CGImageSource) is PB·S. Remove is PB.

**Shown as read-only chips with OPEN, never written:** file and audio attachments, vehicle triggers, "when messaging" triggers, `userActivity` link-backs, extra early alerts. These survive edits because we write only changed keys and never assign `alarms` as a whole.

**Priority:** EK. Read 1–4 as high, 5 as medium and 6–9 as low; write 0/1/5/9 only. Shown as `!`, `!!`, `!!!`.

**Dates and times (EK, rules R2–R3, M1):**
- Date-only means all-day.
- `startDateComponents` is never written, because Reminders ignores it.

**Early reminder:**
- Read via PB with the delta-alert fetch options.
- Write is PB·S: assert the alerts were fetched, then `removeAllFetchedDueDateDeltaAlerts`, then add.
- Needs a due date. Presets: 5, 15 and 30 min, 1 h, 1 day, 1 week, 1 month, Custom. Minutes and hours are hidden for date-only items.
- Clearing the due date also clears the early alert.

**Repeat (EK, M1):**
- Presets: Daily, Weekdays, Weekends, Weekly, Biweekly, Monthly, Every 3 Months, Every 6 Months, Yearly, and Custom (nth or last weekday, end by date or count).
- Hourly repeats are read via PB (`frequency == 4`) and shown read-only as "Hourly (edit in Reminders)".

**Location alarms (EK):**
- `structuredLocation` with arrive/leave and a radius.
- An icon in M1, and an editor in M5 (MapKit search).
- `EKReminder.location` is never used.

**Completion:**
- Complete and uncomplete via EK (rule R1 covers repeating reminders).
- Completing a non-repeating parent also completes its children in the same batch (M2).

**Subtasks (one level):**
- Read the tree via PB `parentReminderID`. Orphans are promoted to top level. The open card fetches the full child set with `fetchRemindersWithParentReminderIDs:error:`.
- Write is PB·S (M3):
  - create a subtask;
  - indent/outdent (⌘] / ⌘[) or drop one reminder onto another;
  - moving a single subtask to another list makes it a top-level reminder there, after a confirm.
- Subtasks are never created inside smart lists.

**Assignee:** read via PB. Writing is DEF, because it needs a second account and the status value is unverified.

**Snooze and notifications:** X. remindd delivers every alarm; we never post our own notifications.

**Duplicate, copy/paste, paste multi-line text as reminders:** EK, plus PB copies of tags and flag (M5).

### CRUD for what you named

| Object | Create | Edit | Delete | Reschedule | Move / reorder |
|---|---|---|---|---|---|
| Reminder | EK (M1). Extras via EK then PB (M3). Subtask: PB first. | EK fields (M1); PB extras (M3) | EK soft delete with undo (M1); PB restore (M3) | EK with the alarm rule: shortcuts and Scheduled drag (M1), calendar drag (M4) | To a list via EK (M1); the -3002 chain (M3); section, parent and order via PB·S (M3) |
| List | EK (M1); inside a group needs PB·S (M3) | Name and color via EK (M1); emblem, pin, sort, groceries via PB·S (M3) | EK, with counts and a "move first" option (M1) | — | Sidebar order and group membership via PB·S (M3) |
| Group | PB·S (M3) | Rename via PB (M3) | Keep its lists, or delete them too; confirm (M3) | — | Reorder via PB·S |
| Section | PB·S | Rename via PB·S | Delete two ways; confirm | — | Reorder via PB·S |
| Tag | Through a reminder (M3) | Bulk rename via PB·S, merging case-insensitively with a confirm (M5) | Bulk delete via PB·S (M5) | — | — |

---

## Semantics rules

Each rule has one implementation and one test.

- **R1 Repeating completion.**
  - Completing a repeating reminder keeps the same `calendarItemIdentifier`, which advances to the next due date and stays incomplete. iCloud adds a separate completed copy with a new ID.
  - After the save, re-read the item. Rows are identified by `(id, due)`, which avoids Reminders MenuBar bug #304.
  - A guard ignores a second click while one is in flight. Never retry.
  - There is no undo for this.
  - Repeating parents do **not** cascade completion to their subtasks until S4 shows what Reminders does.
- **R2 Alarms on reschedule.** The rule is "shift by the same change as the due date". Only absolute, non-location alarms are affected, and `alarms` is never assigned as a whole.

  | Situation | What happens |
  |---|---|
  | Create a timed reminder | Add `EKAlarm(absoluteDate: due)` |
  | Timed → timed | Shift every absolute alarm by Δ |
  | Date-only → date-only | Shift by whole days |
  | Date-only → timed | Shift by Δ days, and add an alarm at the due time if there isn't one |
  | Timed → date-only, or clear the due date | Remove the alarm that matched the old due time (±60 s), shift the others |

  S3 confirms this with fixtures made in Reminders.app.
- **R3 Dates.**
  - Date-only: components `{y,m,d}` from `Calendar(identifier: .gregorian)`, floating (no time zone).
  - Timed: `{y,m,d,h,min}`, Gregorian, using the item's existing time zone, otherwise the current one.
  - When reading, resolve with Gregorian and (tz ?? current).
- **R4 Priority.** Read by ranges and write 1, 5 or 9 (see Reminder fields).
- **R5 URLs** exist only as PB attachments.
- **R6 Notes** are written only when changed, and are locked when they contain styling (see Reminder fields).
- **R7 Recurrence.**
  - Assign `recurrenceRules` only when the user changed the repeat picker.
  - Hourly repeats are read-only.
  - In public-only mode, any change to an existing rule asks first: "Replaces the current repeat (may be Hourly)".
  - Clearing the due date of a repeating reminder offers to clear the repeat too (otherwise EK error 18).
- **R8 Moves.**
  - Same account, plain reminder: EK `calendar` change. The ID is expected to stay (static inference, checked in S5), and the section is dropped.
  - A parent with subtasks, or a shared list on either end, fails in EK with `com.apple.reminderkit` -3002. Instead, set `listID` on the parent and every child in one PB·S transaction and verify each one. On a mismatch, a compensating transaction moves the already-moved items back, the capability trips, and the user is told. Otherwise → OPEN. In public-only mode, refuse with OPEN.
  - Cross-account: confirm, listing what will be lost, using PB `canCopyReminderLosslesslyToAccountChangeItem:` plus the extras we read. Refuse if it has subtasks. Re-key afterwards, because the ID changes. In public-only mode, always warn.
  - In public-only mode, each cross-list move gets its own commit, with per-item errors.
  - No silent clone-and-delete.
- **R9 Delete.**
  - The row hides immediately; the real EK `remove` runs after 8 s, or on quit (`applicationShouldTerminate` → `.terminateLater` flushes). It lands in Recently Deleted (S7 confirms).
  - Deleting a repeating reminder asks "Delete all occurrences?".
  - A parent's children follow according to S2: either EK cascades, or we remove them in the same batch. Public-only mode warns that "subtasks may remain".
  - Undo after the 8 s window uses PB restore, which keeps IDs.
- **R10 Cascades.** List, group, section and "Clear completed" deletes always confirm with counts.
- **R11 Base-diff writes.**
  - The card takes a snapshot ("base") when it opens. On commit, only keys the user changed against that base are written.
  - If the fresh value also differs from the base (someone edited it elsewhere), we still write ours and show "Replaced a change from another device" with an undo that restores theirs.
  - Undo reverts a field only if it still holds the value we wrote.
  - Text commits after 1 s idle or a focus change, not only on close.
  - If the item was deleted elsewhere, the draft is kept with a "Save as New Reminder" option.
- **R12 Write order.**
  - One user action = an EK save or batch commit first, then at most one `REMSaveRequest`, built from objects re-fetched by ID.
  - Private writes are never retried.
  - If only part succeeds, a banner shows the `.partial` result.
- **R13 Read-only lists** are read-only in the UI as well.

---

## Architecture (about 17 files, no dependencies)

```
TickTickReminders/
  project.yml   SPIKES.md   docs/research/*.md
  App/
    App.swift              @main, WindowGroup + Settings scenes, Commands (keyboard map), onboarding gate
    Model.swift            Sendable values: Reminder, Extras, RList, RGroup, RSection, Account, Caps,
                           CalEvent, Due, Recurrence, EarlyAlert, ReminderEdit, Destination, Snapshot
    Logic.swift            pure: due components (R3), alarm plan (R2), priority (R4), smart-list predicates
                           (injected now/calendar/tz), sorters (10 styles + manual), recurrence model <-> EKRecurrenceRule,
                           tag/URL deltas, base-diff (R11), "This Weekend"/"Next Week", calendar layout + drop->date
    Backend.swift          actor Backend: the one EKEventStore + TTRBridge; load/apply/create/delete/place/...; AppError
    Store.swift            @MainActor @Observable Store: Snapshot, debounced reload, serial op queue, pending deletes, undo
    Bridge/TTRBridge.h     Swift-visible private surface; also SWIFT_OBJC_BRIDGING_HEADER
    Bridge/TTRBridge.m     dlopen, @protocol decls, probe, reads, TTRTxn writes, @try, before/after diff, tombstone check, self-test
    Views/RootView.swift   NavigationSplitView, onboarding/denied/no-account states, banner
    Views/Sidebar.swift
    Views/ReminderList.swift   rows, headings, subtasks, tag bar, completed group, Move sheet
    Views/Card.swift       inline card + date/repeat/alert/tag/location popovers
    Views/CalendarView.swift
    Views/Diagnostics.swift    bridge status, self-test, trips, kill switch, JSON dump of a reminder's full record
  Tests/LogicTests.swift         Swift Testing, pure logic
  Tests/IntegrationTests.swift   hosted, guarded, serialized; also hosts the M0 spikes
```

### Project, signing, entitlements

- **`project.yml` (XcodeGen, `syncedFolder` sources).**
  - Deployment target macOS 27.0, `SWIFT_VERSION 6.0` (Swift 6 language mode), default isolation nonisolated (`Store` and the views are `@MainActor` explicitly).
  - `ENABLE_HARDENED_RUNTIME YES`, team ABCDE12345.
  - Targets: the app, plus a `bundle.unit-test` target with `TEST_HOST` set to the app.
- **Bundle IDs** `com.ticktickreminders.app.dev` (Debug, Apple Development) and `com.ticktickreminders.app` (Release, Developer ID, `--timestamp`).
  - Pick them once and never change them, because TCC keys permissions on bundle ID plus designated requirement.
  - Never ad-hoc sign: that prompts for permission again on every build.
- **App Sandbox: OFF.** It is a personal Developer ID app. Running unsandboxed matches the setups where the private structural writes were proven (remctl, go-eventkit), and it removes the need for scripting, file and network entitlements. The design still forbids SQLite reads, Full Disk Access and a standalone `[REMStore new]`: everything goes through EventKit's store.
- **Entitlements:** `com.apple.security.personal-information.calendars`, the hardened-runtime resource access that covers both reminders and events.
- **Info.plist:**
  - `NSRemindersFullAccessUsageDescription`
  - `NSCalendarsFullAccessUsageDescription`
  - `UTExportedTypeDeclarations` for the drag payload type
  - `LSApplicationCategoryType`
- **Release:**
  1. `xcodebuild -configuration Release`
  2. `ditto -c -k`
  3. `notarytool submit --wait` (you store the credentials once)
  4. `stapler staple`
  5. `spctl -a -vv`

### Concurrency and data flow

- **`actor Backend`** runs on a `DispatchSerialQueue` executor and owns the only `EKEventStore` and the `TTRBridge`. EventKit and REM objects never leave it.
  - Methods are synchronous inside the actor, so it is **not re-entrant**.
  - `fetchReminders` blocks on a semaphore with a 30 s timeout that calls `cancelFetchRequest`. This is legal because it blocks Backend's own queue, not the cooperative pool.
  - The completion is explicitly `@Sendable` and maps to `Reminder` values on EventKit's queue. That avoids Swift 6's "incorrect actor executor" crash.
  - **Never call `ek.reset()`.** On an error, call `rollback()` on that operation's objects only.
- **Load:**
  - EK: all incomplete reminders, plus completed ones in a 30-day window.
  - PB (if enabled): accounts and capabilities; lists and groups; extras for all IDs in batches of 500 (`fetchRemindersWithObjectIDs:fetchOptions:` with delta alerts included); sections and memberships for the visible list.
  - Events: `predicateForEvents` over the visible calendar range plus a buffer.
  - `// ponytail:` a full reload on every change. Add diffing only if S12 measures more than 1 s at 5k reminders.
- **`@MainActor @Observable Store`** holds the Snapshot.
  - Reload is debounced 300 ms after `.EKEventStoreChanged`, `NSCalendarDayChanged`, wake, `didBecomeActive` (only there, after `refreshSourcesIfNecessary()`) and a 60 s tick for overdue state.
  - A serial op queue: `tail = Task { await prev?.value; await op() }`.
  - **No optimistic-patch layer.** Backend returns fresh records within tens of milliseconds and Store applies them. The only exceptions are hiding pending deletes and the completion animation (strike and grey, then hide after 1.5 s).
- **Undo** (`@Environment(\.undoManager)`):
  - The inverse is registered synchronously when the op starts, so redo works, against a per-op target. On failure, `removeAllActions(withTarget:)`.
  - Batch operations are wrapped in an undo group.
  - Inverses: edit → old values (subject to R11); complete → prior states; create → pending delete; delete → unhide, or PB restore after the window; move, reorder or section change → move back; list/section/group attributes → old value.
  - Not undoable, so confirmed instead: list, group and section deletes, and repeating completion.
- **IDs.** `calendarItemIdentifier` is the primary key, uppercased at the boundary. The external ID (`calendarItems(withExternalIdentifier:)`, filtered by list and title) is only an undo fallback. After a cross-account move, re-key the selection and the open card.
- **App-local state** (UserDefaults or SceneStorage, never Reminders data): hidden smart lists, show-completed and collapsed state, Group by Time, smart-list sort and Today section order, completed window, `bridgeEnabled`, `bridgeTrips[osBuild]`, `selfTestPassed[osBuild]`, show events, hidden event calendars, calendar mode, destination.

### Private bridge (`TTRBridge.h/.m`, ObjC)

- **Loading.**
  - `dlopen` ReminderKit with `RTLD_NOW`. ReminderKitInternal is loaded lazily, only for Recently Deleted.
  - Classes come from `NSClassFromString` and are messaged through `@protocol` declarations, which keeps ARC and the ABI correct. Never `perform:` or IMP casts from Swift.
  - Store: `ek.reminderStore.remStore`, nil-checked, with `REMReminder.store` as fallback.
- **Exceptions.** Every private call is wrapped in `@try` inside ObjC. No Swift closure ever runs inside a `@try`.
- **Swift-facing API.**
  - Reads return small readonly records: `TTRAccountInfo`, `TTRListInfo`, `TTRReminderInfo`, `TTRSectionInfo`.
  - Writes go through **`TTRTxn`**, which wraps exactly one `REMSaveRequest`. Its mutators re-fetch by ID through that request and use deltas: `addTags:removeTags:`, `addURL:/removeURL:`, `setFlagged:`, `setUrgent:`, `setEarlyAlert:`, `addSubtask:`, `setParent:`, `moveReminderAndChildren:toList:`, `place:before:`, `setSection:`, section and group operations, `setEmblem:`, `setPinned:`, `setSortingStyle:`, `setGrocery:`, `addImage:`, `removeAttachment:`, `restore:`.
  - The first failure poisons the transaction.
- **`commit`:**
  1. Calls `saveSynchronouslyWithError:` and checks both the BOOL and the error (the getter is `isSaved`).
  2. Compares the full EK and PB record of every touched object before and after. For list-level operations it also compares the list's whole membership and order maps.
  3. Any difference nobody asked for trips the capability and alerts the user.
  4. Tombstone check: reminders, lists and sections are re-fetched both normally and with `…IncludingMarkedForDelete`. Auto-undelete applies to reminders only, once S7 proves it.
- **Corrections from the verification pass, all applied:**
  - Use `REMObject` as the primary accessor.
  - Probe forwarded selectors through `REM*Storage` classes, because `methodSignatureForSelector:` returns nil on change items.
  - `REMColor.colorRGBSpace` (renamed from `colorSpace`).
  - The getter is `isSaved`, not `saved`.
  - Fetch early alerts with the delta-alert fetch options.
  - Hashtag type and assignment status get fixed values after S8, plus a launch assertion against a tag made in Reminders.app.

### Probe, self-test, kill switch

- **Launch probe** (never saves):
  - Checks that the classes exist.
  - Calls `respondsToSelector:` on live, **unsaved** change items built on the self-test list if one exists, otherwise on one existing reminder. S8 proves this leaves `lastModifiedDate` unchanged.
  - Compares signatures against the encodings verified on 27.2.
  - Reads the account capabilities.
  - Produces a `TTRCap` bitmask.
- **Gates:**
  - **Scalar writes** (tags, flag, urgent, URL): need the probe to pass, the account capability, `supportsCloudKitSync`, and a modifiable list.
  - **PB·S writes** (everything marked CAUTION, including early alerts): additionally need `selfTestPassed[osBuild]`.
- **Self-test** (a Diagnostics button):
  - Creates "TTR Self-Test <date>" (plus its own group), runs every gated op through the real `Backend`/`TTRTxn`, verifies each one, then deletes everything it created.
  - In your real account it touches only objects it created. Account-level ordering and pin tests run only in the `ttr-test` user.
  - After a macOS update, gated writes switch off and the sidebar footer says "Private features limited after macOS update — run self-test".
- **Trips:**
  - An exception, a failed verification, a tombstone or a probe mismatch makes **that one capability read-only** (reads stay on). The trip is persisted per OS build.
  - Only the user toggle, or a failure of the store or backing-object probe, switches to **global public-EventKit mode**, which is the M1 feature set with extras hidden.
  - Diagnostics can reset trips.

---

## UI spec (Things look, Reminders semantics)

### Window

- `NavigationSplitView` with two columns. No inspector: the inline card is the editor (`// ponytail:` add `.inspector` if the card ever feels cramped).
- Glass comes from the system for the sidebar and toolbar. The card has a solid background, 10 pt corner radius and a soft shadow. Only the floating "+" button uses `glassEffect`.
- Rows about 32 pt; title 13 pt; metadata 11 pt in secondary color.
- Colors: accent blue for headings and selection, red for overdue, orange for flag, and each list's own color for its title and pie.

### Sidebar

1. **Smart lists**, each hidden automatically when unsupported and hideable from its context menu. Trailing counts.

   | List | Symbol | Color | Count |
   |---|---|---|---|
   | Today | star | yellow | due today + overdue |
   | Scheduled | calendar | red | incomplete matches |
   | All | tray | — | incomplete matches |
   | Flagged | flag | orange | incomplete matches |
   | Completed | checkmark | green | none |
   | Assigned to Me | person | — | incomplete matches |
   | Urgent | alarm | red | incomplete matches |

   Then **Calendar** (⌘0) and **Recently Deleted**.
2. **Pinned** lists, mapped to ⌘1…9 in visible order.
3. **Lists**, under one header per account when there are several, in Reminders' sidebar order:
   - Groups are bold with a disclosure arrow; their lists follow.
   - Each list shows its emblem or emoji, or else a pie in the list color (completed ÷ total over the loaded window, `// ponytail:`).
   - Incomplete count on the right, plus a shared badge.
   - Lists, groups, sections and tags are renamed inline.
4. **Tags** with counts.
5. Bottom bar: "+ New List" (menu: New List, New Group).

### List view

- **Header:** large title in the list color. Below it, the tag filter bar shows only tags used in this list: click filters, ⌘-click adds with AND, ⌃⎋ clears.
- **"…" menu:** Sort By, Show Completed, Group by Time (Today only), New Section, Open in Reminders.
- **Row:**
  - A rounded-square checkbox (subtasks get small circles).
  - Priority marks `!`/`!!`/`!!!`, then a single-line title.
  - Trailing metadata in grey: date pill ("Today" / "Fri" / "Nov 13" and the time; red when overdue), then repeat, location, tag capsules, notes, attachments, subtask count "2/5", flag, urgent, assignee initials, and read-only chips.
  - In smart lists, also a dot and name for the reminder's list. Subtasks show their parent's title.
- **Section headings:** blue, bold, with a hairline rule. A chevron appears on hover to collapse. Their "…" menu has Rename, the two Delete options and New Section.
- **Subtasks:** indented 24 pt with a disclosure per parent (LOC). ⌘E / ⇧⌘E show or hide all. When a card is open, its checklist is the only place that parent's children are drawn.
- **Completed:** a grey "Completed · N" group with "Clear…".
- **Inline create:**
  - Space or ⌘N inserts a new row below the selection, at the same level and in the same section.
  - Return commits and starts the next row.
  - Esc cancels an empty row and commits a non-empty one.
  - Created in a smart list, the reminder goes to the default list with that view's attribute (Today → due today, Flagged → flagged, tag view → that tag, group → the group's first list), and never as a subtask.
  - Create is disabled when the view's write capability is tripped.

### Inline card

Open with Return, double-click or ⌘I. Close with Esc, ⌘↩, clicking outside or changing the selection. It expands in place with a `.snappy` animation.

**Contents:**
- Checkbox and title; notes (or the plain-text lock).
- A checklist of subtasks with a "New subtask" row and drag reordering.
- Tag pills with "+" (autocomplete).
- URL chips, and image placeholders with OPEN.
- Summary chips such as "Tomorrow 9:00 · Weekly · 1 day before · Urgent · Arriving: Home".
- Bottom-right bar:
  - Date (⌘S) popover: Today, Tomorrow, This Weekend, Next Week, a graphical picker, a Time toggle, Repeat presets plus a Custom… sheet, Early Reminder, Urgent, Clear.
  - Tags (⇧⌘T), Flag, a Priority menu, Location (M5), a List/Section picker.
  - A "…" menu: Open in Reminders, Copy Link, Delete.

**Keys:**

| In | Key | Effect |
|---|---|---|
| Title | Return | Go to notes |
| Card | ⌘↩ / Esc | Close |
| Checklist row | Return | New subtask |
| Empty subtask | ⌫ | Delete it |
| Checklist | Paste of several lines | One subtask per line |

**Card states:** one table in the code decides which controls are hidden or locked when the bridge is off, a capability is tripped, the list is read-only, or the item repeats.

**Spike S15:** if a card inside a SwiftUI `List` can't meet the keyboard, focus, animation and 5k-row bar, this list becomes an `NSTableView` representable.

### Behaviours

- **Search (⌘F):** `.searchable`, in memory, `localizedStandardContains` over title, notes, tags and list name. Results grouped by list, with "Include Completed".
- **Multi-select:** `List(selection:)` plus `contextMenu(forSelectionType:)`. A batch action is one EK batch plus one transaction plus one undo group.
- **Drag and drop:** the payload is a `DragItems` Transferable with an exported UTType.

  | Gesture | Effect |
  |---|---|
  | Reorder in place | `reorderContainer` + `reorderable(collectionID:)` keyed by section (S15; fallback is `.onMove` within a section plus dropping on headings) |
  | Drop on a sidebar list | Move |
  | Drop on Today / Flagged / a tag | Due today / flag / add tag |
  | Drop on a Scheduled day or a calendar cell | Reschedule |
  | Drop on a reminder row | Make it a subtask (S15 decides; fallback is ⌘] only) |
  | Drag a list | Reorder, or drop onto another list to make a group |
  | Drop on a group | Refused, with a highlight |

- **Context menus:**
  - **Reminder:** Complete, Flag, Priority ▸, Due ▸, Move to… (⇧⌘M), Move to Section ▸ (built when opened), Add Tag…, Indent/Outdent, Urgent, Open in Reminders, Copy Link, Delete.
  - **List:** Rename, Color & Icon… (12 swatches + custom color, 71-icon grid, emoji), Pin, Sort By ▸, Show Completed, New Group with Selection, Move to Group ▸, Remove from Group, Groceries, Open in New Window, Open in Reminders, Delete.
  - **Group:** Rename, Delete ▸ (Keep Lists / Delete Lists Too).
  - **Tag:** Rename, Delete (M5).
- **Move sheet (⇧⌘M):** type to filter lists, grouped by group and account, with their sections nested underneath.
- **Settings scene:** "all-day reminders as overdue" mirror, Group by Time, completed window, event calendars, private-features toggle.

### Calendar view (M4)

- **Modes:** Day, Week and Month (⌥⌘1/2/3). ⌘← / ⌘→ moves back and forward. `T` goes to today, but only while the calendar has focus.
- **Day and week:** a 44 pt-per-hour grid with an all-day lane. Timed reminders are 30-minute pills (`// ponytail:` they are really instants). Events are read-only blocks in their calendar's color.
- **Month:** cells with pills; "+k more" expands in place (no popover, because popovers have a crash pattern on 27).
- **Week start** follows `firstWeekday`.
- **Dragging:**
  - Snaps to 15 minutes.
  - Into the all-day lane → date-only (alarm removed per R2). Into a time slot → timed (alarm added).
  - Onto a month cell → new date, same time.
- **Other interactions:**
  - Double-click empty space creates a reminder there.
  - A collapsible "No Date" tray is the drag source for undated reminders.
  - Overdue reminders sit on their past day in red. Completed ones are hidden unless Show Completed is on.
  - Repeating reminders show only their current occurrence.
- **Editing:** clicking a reminder opens the same card in a side panel. ⌘L shows it in its list. Clicking an event shows a read-only info view.
- **Events:** the events toggle requests `requestFullAccessToEvents()` the first time it is used. A calendar picker (LOC) chooses which calendars show.

### Keyboard map

Reminders' own Mac shortcuts win; Things shortcuts are added where they don't clash.

| Group | Shortcuts |
|---|---|
| Create | ⌘N New Reminder; ⇧⌘N New List; ⌥⌘N New Section; ⌃⌘N New Section with Selection |
| Edit | ⌘] / ⌘[ Indent / Outdent; ⌘E / ⇧⌘E Show / Hide All Subtasks; ⇧⌘F Flag; ⇧⌘C Complete; ⇧⌘H Show Completed |
| Dates | ⌘T Today; ⌥⌘T Tomorrow; ⌃⌘T All Overdue → Today; ⌘K This Weekend; ⌥⌘K Next Week |
| Navigate | ⌘1…9 pinned; ⌘0 Calendar; ⌥⌘S Sidebar; ⌘I Show Info; ⌘F Search |
| Things-style | Space new below; Return edit; ⇧⌘M Move; ⌘↑ / ⌘↓ reorder; ⌫ delete; ⌘S date; ⇧⌘R repeat; ⇧⌘T tags; ⌘L show in list; ⌘D duplicate |

- **Bare keys** (Space, ⌫, T) are handled with `onKeyPress` / `onDeleteCommand` on the List or Calendar only.
- **Chord menu items** that would hijack text editing (⌘↑/⌘↓, ⌘E and the like) are disabled while a text field has focus, using a focused value.
- New Window keeps its menu item but loses ⌘N.

### Onboarding and accessibility

**Onboarding:**
1. A welcome screen, then `requestFullAccessToReminders()`. Load after access is granted.
2. If denied: an explanation and a button to System Settings › Privacy › Reminders.
3. If there is no reminders account: "turn on iCloud Reminders".
4. Calendar access is requested only from the Calendar events toggle.
5. Under XCTest the app skips the permission request.

**Accessibility:**
- Every icon button has a label.
- Rows combine their children into a single accessibility label, with Complete, Flag and Delete actions.
- Color is never the only signal.
- Reduce Motion turns off the completion animation.

---

## Milestones

### M0 — Safety, scaffolding, spikes (nothing private touches your real data)

**Setup:**
- `git init`. Copy the research into `docs/research/`. `project.yml`, `xcodegen generate`, a minimal app, `Backend` loading from EK, `TTRBridge` load + probe + reads, and Diagnostics.

**Test environment (needs you):**
- Create a macOS user `ttr-test` signed into a **throwaway Apple Account** with iCloud Reminders, and a second device or VM on that account if you can. I can't create accounts for you.
- If you'd rather not, the fallback is to run spikes in your real account against one dedicated `TTR-SPIKE` list, and skip the account-level tests (sidebar order, pins, groups).

**Fixtures,** created in **Reminders.app** in the test account:
- `FX-rich`: tags, flag, urgent, early alert, URL, image, section, 2 subtasks, bold + bullet notes, location, timed + weekly repeat.
- `FX-hourly`, `FX-allday`, `FX-timed`, `FX-remindme`.
- A group with 2 lists.
- One list per sort style.
- Early alerts in each unit.
- A custom smart list.
- Optionally, a list shared with a second throwaway account.

**Spikes** run as `IntegrationTests`, in the shipping configuration (hardened runtime, Apple Development signing). Each one writes a single outcome line to `SPIKES.md`.

| # | Experiment | Decides |
|---|---|---|
| S1 | EK edits to copies of FX-rich (title, notes append, reschedule, priority, clear due, location alarm), then re-read everything through PB and in Reminders.app | Notes lock; early alert on clearing the due date; preservation |
| S2 | Subtasks through EK (flat? `parentReminderID` matches?); EK complete or remove a parent → children? | R1 cascade, R9 children |
| S3 | Timed due with no alarm vs with an alarm → does it notify? Alarms on FX-timed / FX-allday / FX-remindme | R2 |
| S4 | Repeating: same ID advances, a completed copy appears (do tags and flag copy?); a repeating parent with subtasks; EK delete → whole series? | R1, R9 |
| S5 | EK move of a plain reminder (ID kept? section dropped?); parent with subtasks → -3002 → PB `listID`; moving a single subtask; shared and cross-account if available | R8 |
| S6 | Does `calendars(for: .reminder)` return lists inside groups, and leave out the group itself? | M1 sidebar |
| S7 | EK remove → shows in the PB Recently Deleted invocation → `undeleteRemindersWithoutUndoWithIDs:` keeps the ID and extras; list removal and undelete | R9, list-delete undo |
| S8 | PB reads of every field. Learned values: hashtag type, early-alert unit order and count sign, `frequency` = 4 for hourly and what EK shows for it, section order = display order, sublist order, element type of `listIDsOrdering`, assignment status, emblem names ↔ assets (71 = 71). Batch fetch equals per-ID fetch. A probe leaves `lastModifiedDate` unchanged. | M2 parsing and constants |
| S9 | Write round trip for every PB·S op on a throwaway list, verified by read-back, in Reminders.app and on the second device. Includes: early-alert replace with no duplicate; a second reminder keeps its section; moving out of a section; indent across sections; image via Data vs URL; Groceries on in a list that has sections; section delete with children; EK edit + PB edit in one action keeps the EK time; tag bulk rename leaves other lists' tags alone. Tombstone check after each op. | GO or OPEN per op |
| S10 | Does `EKEventStoreChanged` fire after a private-only save? How fast and how often? What is in its userInfo (literal keys)? | Debounce; event-only reloads |
| S12 | 5k reminders: time the full reload, the PB batch, and section reads for a 200-item list | Diffing or bulk section reads |
| S15 | UI only: the card inside a List, `reorderContainer` + sections + row drops, repeated popovers, 5k-row scrolling | List vs NSTableView; drag approach |
| S17 | Component shapes of FX-allday / FX-timed; whether colors snap to the palette | R3 |
| S19 | Urgent on a date-only reminder | Urgent gate |
| S20 | A sample of `filterData` JSON | M5 evaluator |

**Exit:**
- Every spike has an outcome line.
- No unexpected tombstones.
- The probe is green on 27.2.
- **No private write runs in your real session until the M3 self-test passes there.**

### M1 — Public EventKit core

**Deliverables:**
- Signing; onboarding, denied and no-account states.
- `Backend` (load, apply with base-diff, create, delete with the pending window, move, batch) and `AppError` mapping.
- `Store`: reload, op queue, undo.
- Sidebar: Today, Scheduled, All, Completed, flat lists, counts, pie.
- List view and inline create chain.
- Card: title, notes, date/time with the alarm rule, repeat, priority, list picker, location icon.
- Complete (R1), delete with undo (R9), move (EK; -3002 → message + OPEN), Move sheet, drop on sidebar.
- Reschedule shortcuts and Scheduled drag.
- List create, rename, recolor, delete (with counts and "move first").
- Hide smart lists, Open in Reminders, Settings scene.
- LogicTests.

**Exit:**
- The public fields round-trip identically in our app, Reminders.app and your iPhone.
- Public integration tests pass in `ttr-test`.
- In your real account, read-only use is green.

### M2 — Bridge reads

**Deliverables:**
- Capabilities and gating; Diagnostics (with a JSON dump of FX-rich diffed against an expectation stored in SPIKES.md); kill switch and trips.
- Groups, sections, the subtask tree and the parent-completion cascade.
- Tags in rows and the sidebar, the tag bar and the tag view.
- Flagged, Urgent and Assigned to Me smart lists.
- Manual order and sort style applied.
- Emblems, pinned lists, ⌘1–9.
- Read-only card display of early alert, urgent, URLs, images and the read-only chips.
- Hourly lock; styled-notes lock.

**Exit:**
- The fixture views match Reminders.app.
- With the kill switch on, the app behaves exactly like M1.
- Reload stays within the S12 budget.

### M3 — Bridge writes

Ops in order of risk:
1. flag, tags, inline `#tag`, urgent, URL;
2. early alert;
3. subtask create, indent/outdent, drop onto a reminder, move a single subtask;
4. manual reorder;
5. sections (create, rename, reorder, delete, membership, ⌃⌘N);
6. the -3002 move chain;
7. groups (create, rename, delete, lists in and out, sidebar reorder, list onto list);
8. emblem, pin (limit 9), sort style, groceries;
9. image add/remove;
10. Recently Deleted: recover, drag-to-recover, undo after the 8 s window.

Plus the self-test runner.

**Exit:**
- The self-test passes on 27.2 in `ttr-test` and in your user.
- Every write shows up on the second device.
- An injected verify failure (debug flag) trips only its own capability.

### M4 — Calendar view and events

As specified above, with a `Logic` drop/layout implementation.

**Exit:**
- Drop and layout unit tests pass.
- A month with 500 events renders smoothly.
- Dropping an event is refused and the event is unchanged.

### M5 — Polish

- Keyboard map audit: every command is in the menus.
- Multi-select batch toolbar; search; multiple windows (`WindowGroup(for: Destination.self)`); print (`NSPrintOperation`).
- Location editor (MapKit search).
- Custom smart lists, evaluated read-only.
- Tag rename (merge) and delete.
- "New List from Template".
- Duplicate, copy/paste, paste multi-line text.
- Today Group-by-Time drops; the all-day-overdue mirror.
- Accessibility pass; 10k-reminder performance pass.
- Release: notarize and staple, then run the **probe and self-test on the notarized build**. It has a new bundle ID, so it gets new permission grants.

### Deferred or excluded (with reason)

| Item | Status | Reason |
|---|---|---|
| Template save/edit and public links; custom smart list create/edit | DEF | Proven only in a standalone process; config types unknown |
| Assignment writes | DEF | Need a second account; status value unverified |
| Sharing management | DEF → OPEN | CloudKit share UI |
| Hourly repeat writes | DEF | No write path; read-only in our app |
| Vehicle and messaging trigger writes | DEF | Unproven; shown read-only |
| Rich-text notes editing | X | Plain text with a lock instead |
| Auto-Categorize and grocery categorization | X | Contract churn; the categorize API is NO-GO |
| Permanent delete from Recently Deleted | X → OPEN | No API identified |
| Ghost future occurrences; "skip this occurrence" | DEF | Needs rule expansion |
| Own notifications and snooze | X | remindd owns alarm delivery |
| Pinned-list manual order | DEF | `updateManualOrdering:` signature is complex |
| Clone-and-delete moves | X | New IDs and lost data |
| Things-isms (Someday, Evening, Deadline, Inbox) | X | Your decision |
| NL quick add + hotkey, menu bar, widgets, kanban, Siri/Spotlight, iOS | X | Your decision |

---

## Verification

**Unit tests** (`Tests/LogicTests.swift`, Swift Testing, no permission needed):
- R3 components: date-only has no hour and no time zone; timed keeps its zone; Gregorian even under a Japanese or Buddhist user calendar; DST day; nil calendar or zone.
- R2 alarm shifts in every case.
- R4 priority mapping.
- Smart-list predicates with injected now, calendar and zone, including the Today and Scheduled buckets and the Group-by-Time edges.
- "This Weekend" (moves to next weekend when today is the day before) and "Next Week" with `firstWeekday`.
- Recurrence model ↔ `EKRecurrenceRule` round trip (weekdays, biweekly, every 3/6 months, last weekday, end by date or count; hourly never produces a rule).
- The 10 sort styles plus manual order with unmerged IDs, stable ties.
- Tag and URL deltas.
- R11 base-diff and conflict detection.
- Early-alert mapping, but only after S8 fixes the sign.
- Calendar `layoutDay` and `dropDate`.
- `ReminderEdit` inverse.

**Integration tests** (`Tests/IntegrationTests.swift`):
- `@Suite(.serialized)`, enabled only when **all three** hold: `TTR_INTEGRATION=1`, EK access is `.fullAccess`, and a `TTR-TEST-ACCOUNT` marker list exists.
- Each test creates `TTR-IT-<uuid>` and removes it in teardown.
- Coverage: EK CRUD, moves, repeating completion, pending deletes flushed on terminate, all spikes and the self-test matrix.
- Concurrent edits: a **second in-process `EKEventStore`** edits a reminder while a card's base is held; assert that the commit doesn't overwrite those fields.

**Commands:**
```bash
cd ~/Workshop/Tidy && xcodegen generate
xcodebuild -project TickTickReminders.xcodeproj -scheme TickTickReminders -destination 'platform=macOS' build
xcodebuild test -project TickTickReminders.xcodeproj -scheme TickTickReminders -destination 'platform=macOS' -only-testing:Tests/LogicTests
TEST_RUNNER_TTR_INTEGRATION=1 xcodebuild test -project TickTickReminders.xcodeproj -scheme TickTickReminders -destination 'platform=macOS' -only-testing:Tests/IntegrationTests   # ttr-test user only
```

**Manual end-to-end checklist,** comparing our app, Reminders.app and the iPhone after sync:
1. Every field: create, then change each one.
2. Timed ↔ all-day: the notification fires once, at the new time.
3. Repeating completion.
4. Delete → undo → delete → Recover: the same item, with its tags.
5. Moves: plain, a parent, a single subtask, a shared list, into a section, cross-account.
6. Lists, groups and sections: every op.
7. Tags: add, remove, inline, rename/merge, delete.
8. Indent/outdent and drop onto a reminder.
9. Calendar drags in all three modes; events stay read-only.
10. Kill switch on → public-only mode works and no extras are lost after edits.
11. Change the stored OS build → gated writes go off until the self-test runs.

---

## Risks

| Risk | Mitigation |
|---|---|
| Private API drift after a macOS update | Live probe at every launch; self-test per OS build before gated writes; verification diff and tombstone check on every commit; persistent trips; all private names in one ObjC file; fall back to OPEN |
| Data loss from EK writes | Changed keys only (R11); never assign alarms or recurrence as a whole; notes lock; S1 proves preservation |
| Edits from another device | Base-diff writes with conflict banner and undo; live refresh of fields not being edited; text auto-commits; a concurrent-store integration test |
| Delete and cascade loss | 8 s pending delete, flushed on quit; Recently Deleted restore; confirmations with counts |
| Section-membership replace and duplicate early alerts | S9 proves both before the ops unlock |
| Permission re-prompts | Stable signing identity per configuration, never ad-hoc; `tccutil reset Reminders <id>` for development |
| Swift 6 isolation crashes | A non-re-entrant `Backend` on its own serial queue; `@Sendable` completions mapping to value types; no EK object leaves the actor |
| SwiftUI List performance and macOS 27 `reorderable`/popover bugs | S12 and S15 spikes; NSTableView representable and inline (non-popover) fallbacks |
