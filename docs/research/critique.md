## Completeness critique: research phase (Reminders-backed macOS client)

**Checked locally (read-only, so not just taken from the reports):**
- `ReminderKit.framework/Versions/A/Resources/framework.sb:2` allows `mach-lookup com.apple.remindd`.
- `application.sb` and `appsandbox-common.sb` have no `remindd` entry. This matters for contradiction C2.
- `RunSystemShortcutIntent` and `SystemShortcut` are `@available(macOS, unavailable)` (AppIntents swiftinterface L3633–3638, L5106–5112).
- `Shortcuts Events.app/.../Shortcuts.sdef` declares access group `com.apple.shortcuts.run` (L14–74).
- The Reminders.sdef access groups exist in both capitalizations: `com.apple.reminders.read`, `com.apple.reminders.read-write`, `com.apple.reminders.List.read-write`, `com.apple.Reminders.read`, `com.apple.Reminders.read-write`, `com.apple.Reminders.UI`.
- `EKErrorReminderAlarmContainsEmailOrUrl` is at `EKError.h:101`.
- No `macos(15+)` annotations in the EventKit headers.
- `EKEventStore.EventStoreChanged` is a `MainActorMessage` (EventKit swiftinterface L16).

---

### 1. GAPS (affect architecture or feasibility)

1. **Which tier is the product built on.** This is unresolved and every other decision depends on it:
   - Mac App Store with EventKit + AppleScript + Shortcuts, or
   - Developer ID with private ReminderKit, or
   - both builds.

   The user asked for "everything you can do in Reminders". Without private ReminderKit or a working Shortcuts bridge, that means no tags, subtasks, sections, groups or fast flags. No report puts numbers on what the Mac App Store-only build would lose.
2. **Data preservation under EventKit writes has not been tested anywhere.** Each of these is inference only:
   - Do tags, flag, parent, section, early alert, urgent, images and the URL attachment survive an EK `save`?
   - Do rich-text notes get flattened?
   - Is an hourly rule kept, and do vehicle alarms survive when `alarms` is rewritten?

   This is the main data-loss risk for an app whose core job is editing.
3. **"Move" is only partly feasible, and the user asked for it explicitly.**
   - Moving a parent that has subtasks, or moving to or from a shared list, fails with `-3002` (forum/remctl evidence only).
   - What happens to section membership on a move is unknown.
   - Whether `calendarItemIdentifier` changes on a same-account move is unknown.
   - Whether cross-account moves of reminders work is unknown.
   - Moving a list into a group has no public path (AppleScript `container` is read-only).
   - Sidebar list order is local only.
   - Nobody has written down what "move lists" will mean for the user.
4. **Subtasks seen through EventKit.** "Flat top-level reminders, no parent info" comes from forum and DTS sources, not a test. It is also unknown whether an EK complete or delete of a parent cascades or leaves the children orphaned. Without the parent link, every list view will show subtasks as unrelated siblings.
5. **ID join across paths.** A hybrid design has to match records across four ID schemes, and no report establishes how they relate:
   - EK `calendarItemIdentifier` and `calendarItemExternalIdentifier`
   - AppleScript `x-apple-reminder://UUID`
   - the App Intents `ReminderEntity` id
   - `x-apple-reminderkit://REMCDReminder/UUID`

   prior_art claims `calendarItemIdentifier` equals the REM UUID based on the reminders-menubar code. That is the only evidence, and it is not a test.
6. **Shortcuts bridge viability.** No end-to-end evidence for any of:
   - a sandboxed app sending `run shortcut` to Shortcuts Events and getting output back (one forum user got nil);
   - targeting a reminder by ID inside a shortcut (FradSer matches by title);
   - whether hidden intents (MoveToSection/Parent, Snooze, GetDefaultList) can be used in a hand-built shortcut;
   - real latency;
   - installing the helper shortcut.
7. **Notification semantics.** Unresolved:
   - Does a timed due date with no alarm notify?
   - Does Reminders.app create an absolute EKAlarm for timed reminders?
   - How do date-only reminders notify (the Reminders setting is unreadable)?
   - Does Reminders.app keep or show more than one date alarm? BusyCal says "not supported", while `AccountCapabilities.supportsMultipleDateAlarmsOnRecurrence` exists.

   The answers decide the Things/TickTick-style "reminder time ≠ due date" design and the multi-reminder feature.
8. **Date-model decision is pending.** Two options:
   - When = `dueDateComponents` with Deadline kept local, or
   - When = `startDateComponents`.

   It depends on whether Reminders.app on 27.x ignores `startDateComponents` in its UI and its Today/Scheduled lists. The only evidence is forum thread/809699.
9. **Recently Deleted and undo.** reminders_app (DOCS) says Recently Deleted exists since macOS 15. beyond_eventkit says EK `remove` soft-deletes into it (remctl #37). The platform report's soft-delete-then-recreate undo design does not take this into account. Nobody confirmed that EK can't restore from it, or how a re-created reminder interacts with the copy in Recently Deleted.
10. **Widget, share and Control extensions.** Whether they can get EventKit access on macOS 27 (inherited grant or their own TCC) is unknown. That decides whether interactive check-off is possible.
11. **Groups as calendars.** Unknown whether a group shows up in `calendars(for:.reminder)`, and whether lists nested in a group are returned at all. Things says nested lists are "not accessible", which would be severe if it applies to EventKit.
12. **Performance at scale.** No measurements of fetch cost for 10k+ reminders, including completed ones. GoodTask's CPU and freeze complaints are the warning sign.
13. **Account variance.** Exchange, CalDAV and local accounts were not tested:
    - recurring completion behaviour;
    - `allowsContentModifications` for participants in shared lists;
    - whether an "On My Mac" source exists on 27.

    Also, `AccountCapabilities` can only be read via Shortcuts, so a Mac App Store build cannot use it to gate features.
14. **Predicate edge cases.**
    - Are undated reminders included when bounds are set?
    - How do floating all-day due dates behave in range predicates?

    These directly affect the Today, Upcoming and Overdue queries.
15. **Fast flag toggle in a Mac App Store build.** Flags matter for Things/TickTick parity. AppleScript takes 3–4 s per event and launches Reminders.app (remctl #65), so in practice there is no fast public path.
16. **Cross-Mac sync of local metadata.** Not decided: none, CloudKit, or iCloud KVS. It affects manual order, Deadline, Someday, Won't Do and filters.
17. **No report covers:** accessibility and VoiceOver, localization of the NL parser beyond English, or import/export/backup.
18. **Concurrent edit from another device while our editor is open.** Covered only by the `refresh()` pattern. A conflict-merge policy is not defined.

### 2. CONTRADICTIONS

- **C1. EK `URL`.**
  - ticktick §16.1: "URL link ✔ single URL" (EK-native).
  - todoist, things, reminders_app, beyond_eventkit and prior_art: `EKCalendarItem.URL` "does not map to the Reminders.app URL field… reads nil for URLs set in the UI".
  - The ticktick mapping is wrong.
- **C2. Private ReminderKit from the sandbox.**
  - beyond_eventkit: "The app sandbox profile does **not** allow mach-lookup to `com.apple.remindd`… a fresh `[REMStore new]` inside the sandbox may fail."
  - prior_art: "ReminderKit's framework sandbox profile allows `(mach-lookup (global-name "com.apple.remindd"))`."
  - Both are literally true (I checked). Still unknown: is `framework.sb` applied to a third-party app that loads ReminderKit indirectly through EventKit?
- **C3. Shortcuts from a sandboxed app.**
  - ticktick: "Shortcuts: … run through `shortcuts://` or `/usr/bin/shortcuts`, which is sandbox-hostile"; "a third-party app cannot call Reminders' intents directly".
  - things Q8 proposes `shortcuts://x-callback-url/run-shortcut`.
  - beyond_eventkit and platform: Shortcuts Events Apple Event with `com.apple.shortcuts.run` is sandbox-OK and runs in the background. beyond_eventkit adds that x-callback has been "broken since 26.5 … x-success never fires".
- **C4. Recommended architecture.**
  - beyond_eventkit: private ReminderKit "is effectively required for a TickTick/Things-class app" (Developer ID Enhanced build).
  - platform: "Never use the private ReminderKit frameworks… Primary channel: Mac App Store"; use the Shortcuts bridge for tags and subtasks.
  - prior_art: Tier B is optional and off by default, and if it is on, ship outside the Mac App Store.
- **C5. Where local metadata lives.**
  - beyond_eventkit: "SwiftData in the app container".
  - platform: "One Codable JSON file… Why not SwiftData: non-Sendable `ModelContext`…".
- **C6. Early alert.**
  - ticktick: "Multiple reminders / offsets ✔ alarms[] … ✔ earlyAlert", and things: "early alert ≈ second `EKAlarm(relativeOffset)`". Both imply equivalence.
  - reminders_app: "stored as `dueDateDeltaAlerts`, **separate from alarms** [VERIFIED model]".
- **C7. Does a due date alone notify?**
  - eventkit: "A timed due date may act as the notification time in Reminders.app [thread/809699]".
  - reminders_app: "A due date alone doesn't notify [Don-Works PR#1]".
  - prior_art (BusyCal): "When a task has any alarm, Reminders shows the alarm's date and time as the effective due date."
- **C8. Recently Deleted.**
  - things and ticktick: "[UNVERIFIED that it exists]".
  - reminders_app: exists since macOS 15 [DOCS], but "whether `removeReminder` lands in Recently Deleted: [UNVERIFIED]".
  - beyond_eventkit: "EventKit delete: Soft delete into Recently Deleted (30 days)" [remctl #37].
- **C9. Subtask depth.**
  - todoist: "One user reports a 2-level ceiling".
  - reminders_app: "One level only ('Nested subtasks is unsupported' [VERIFIED])".
- **C10. AppleScript and subtasks.**
  - reminders_app: sdef reminder `container` = parent [VERIFIED].
  - beyond_eventkit (Hookmark 2023): "Nested reminders: not accessible via AppleScript".
  - ticktick Q4: unclear whether `make new reminder at <reminder>` works.
- **C11. Hotkey restriction.**
  - things: "macOS 15.2+ blocks hotkeys whose only modifier is Shift."
  - platform: macOS 15 blocks "⌥ or ⌥⇧-only" in sandboxed apps; "reports conflict on whether 15.2 relaxed it".
- **C12. Deleting a recurring reminder.**
  - eventkit: "INFERENCE: it removes the series", and "Delete only this occurrence is impossible".
  - ticktick and reminders_app: the AI path has `thisReminder` / `allFutureReminders`.
  - Not a direct conflict, but whether EK delete hits the occurrence or the series is untested.
- **C13. Moving a reminder across accounts.**
  - eventkit checklist: "[x] Move across accounts (set `calendar`)".
  - ticktick and todoist: "cross-account behavior unverified".
  - beyond_eventkit: `-3002` for shared lists.
- **C14. Tags on Things import.**
  - Things docs: "Tags will become Tags".
  - Every report: EK has no tag API, and the mechanism is unknown.
  - Either Things uses a non-EK path, or the doc is wrong.
- **C15. Shortcuts reaching tags and sections.** eneko and falconbradley (quoted in prior_art): "no section intent / no tag parameter". This conflicts with the 27 `extract.actionsdata`. It is probably version drift, but it shows that `actionsdata` changes between releases.

### 3. TOP 15 CLAIMS TO VERIFY ADVERSARIALLY

Unless noted, the test setup is a throwaway iCloud account in a separate macOS user or VM, with a small signed, sandboxed spike app.

1. **An EK `save(_:commit:true)` that changes only title or due date keeps everything EventKit can't see.**
   - Fields to check: tags, `flagged`, parent link, section membership, early alert, `isUrgent`, image, URL attachment, notes styling.
   - Method: build the reminder in Reminders.app with all of these, edit it via EK, then read it back via the AppleScript `flagged`/`container`, a Shortcuts "Find Reminders" readout, and the Reminders UI.
2. **An EK move behaves as follows:**
   - `reminder.calendar = otherList` fails with `com.apple.reminderkit -3002` when the reminder has subtasks, or when either list is shared;
   - otherwise it succeeds, keeps `calendarItemIdentifier`, and drops the section.
   - Check with the spike, and compare the ID before and after `fetch`.
3. **Subtasks come back from `predicateForReminders(in:)` as ordinary EKReminders**, with no public parent info.
   - EK `remove` and complete on the parent do not cascade.
   - Check: create the parent and child in the UI, run the EK ops, inspect in the UI.
4. **A timed `dueDateComponents` with zero alarms fires no notification on macOS 27.2.**
   - Also check: does a timed reminder created in Reminders.app expose exactly one `EKAlarm` with an `absoluteDate`?
   - Spike plus observation of the notification.
5. **`EKCalendarItem.URL` set via EK is not shown in Reminders.app**, and reads nil for a URL set in the UI.
   - Spike, with both directions tested.
6. **Completing a recurring reminder via EK keeps the same `calendarItemIdentifier`**, now incomplete with the next due date, and creates a new completed copy with a new ID (iCloud, 27.2).
   - Spike. Repeat on a local or CalDAV source if one is available.
7. **A sandboxed app can run a user shortcut through Shortcuts Events and get the output back in the reply.**
   - Setup: `scripting-targets {"com.apple.shortcuts.events":["com.apple.shortcuts.run"]}` + `automation.apple-events`, send `run shortcut "X" with input`.
   - Pass criteria: output returned, no Shortcuts window, measured latency.
   - Access group confirmed at `Shortcuts.sdef` L14–74. Runtime behaviour untested.
8. **A shortcut can resolve a reminder from an ID passed in and output an ID equal to `calendarItemIdentifier`.**
   - Check: build the dispatcher, then compare the output against EK.
9. **`UpdateReminderAppIntent` runs without opening Reminders, takes `tags`, `section` and `parent`, and is discoverable in the Shortcuts editor.**
   - Read `openAppWhenRun` and `isDiscoverable` for that action in `/System/Library/PrivateFrameworks/RemindersAppIntents.framework/Versions/A/Resources/Metadata.appintents/extract.actionsdata`, then try it in the editor.
10. **The private path works from a sandboxed app:** `EKReminder.backingObject → _reminder → REMSaveRequest(initWithStore:)` can write hashtags and flagged on 27.2.
    - Check: run the reminders-menubar code pattern in the sandboxed spike.
    - Also check whether `framework.sb` (L2) is in effect: try `[REMStore new]` in the same sandbox.
11. **EK `remove(_:commit:)` puts the reminder in Reminders' Recently Deleted**, and EK can't see it there afterwards.
    - Spike, then look in the Reminders UI Recently Deleted.
12. **Reading and re-saving a reminder whose hourly repeat was set in the UI keeps the hourly rule.**
    - Read without touching `recurrenceRules`; inspect what `recurrenceRules` reports.
    - Spike, plus an `EKTypes.h` check (no hourly frequency).
13. **Lists inside a Reminders group appear in `calendars(for:.reminder)`, and the group itself does not.**
    - Spike against a UI-created group.
14. **Reminders.app on 27.2 ignores `startDateComponents`:** not displayed, and no effect on Today or Scheduled.
    - Spike: set start only, then start ≠ due.
15. **A WidgetKit extension on macOS 27 can call `fetchReminders`, or is denied, under the host app's grant.**
    - Spike widget with the `calendars` entitlement, logging `authorizationStatus(for:.reminder)`.

**Runners-up:**
- AppleScript `set flagged` latency, and whether it launches Reminders.app.
- Whether an `EKEventStoreChanged` notification fires for private-only edits (tags, flag).
- Whether Reminders.app keeps more than one date EKAlarm.
- Whether a Reminders early alert shows up in EK `alarms`.
- Whether `predicateForIncompleteReminders` with bounds excludes undated reminders.
- Whether Mac App Store review accepts both scripting-target entitlements.

### 4. FEATURES NOT MAPPED ONTO THE REMINDERS BACKEND

- **Import/export/backup:**
  - TickTick backup and import (S23), Todoist CSV import and export with relative dates, a Things-style import.
  - Bulk-creating reminders from other apps' exports, and exporting Reminders to JSON or CSV.
  - None of the mapping tables cover this.
- **TickTick:**
  - Merge tasks (right-click Merge).
  - Move a section to another list; delete a section and move its tasks elsewhere.
  - Duplicate a list.
  - Per-priority ringtones (probably not feasible, since remindd delivers alerts).
  - Per-shared-list Do Not Disturb.
  - Multiple time zones in the calendar.
  - "Save search as filter".
  - Status "Restart" from Won't Do. Won't Do itself is mapped; its round-trip in Reminders.app is not defined.
- **Todoist:**
  - Section archive.
  - Project comments.
  - Copy task or view link (needs our URL scheme combined with `x-apple-reminderkit`).
  - Filter Assist (AI → filter query).
  - Forward-by-email address (not feasible).
  - "Save view for everyone" in shared projects (not feasible).
  - Insights widgets (computed).
  - Upcoming "Plan" sidebar with deadline-based inclusion.
- **Things:**
  - **Repeating projects:** a list can't repeat in Reminders. Needs local emulation or is not feasible.
  - "Show later items" (Shift+Cmd+E).
  - Find & Replace in notes.
  - Drag between windows.
  - The Today "group by project/area" setting.
- **Reminders-native features with no plan to surface them:**
  - Templates: save, create from, and public links. reminders_app marks these not feasible via EK/AI, but no local substitute is defined.
  - Groceries auto-categorization shown in our UI (does EK-added content get categorized?).
  - The Today Morning/Afternoon/Tonight drop sets the time (9/15/18/21). Mapped as view logic only, not as a write rule.
  - "Mark All Overdue to Today" exact parity.
  - The `userActivity` link-back chips (Mail, Safari), readable only via private API.
  - Siri Suggestions / "Found in Apps".
  - Handoff.
  - The Reminders settings that change semantics: "Show all-day reminders as overdue" and the Today notification time. These are unreadable, so our Today can diverge from Reminders' Today.
- **Cross-cutting, not mapped:**
  - A "lock or partial-edit" policy for items carrying attributes we can't see. Things' Reminders Inbox hides them; there is no consistent rule across the plan.
  - Accessibility (VoiceOver, keyboard-only parity).
  - Localization of the NL grammar.