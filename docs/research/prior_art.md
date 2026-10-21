# Prior art: third-party apps and tools built on Apple Reminders, and what they learned

## 0. Scope and method

- **Code read directly** (raw GitHub via `curl`, read-only, nothing written to disk):
  - DamascenoRafael/reminders-menubar, master branch, v2.2.0 (2026-09-08)
  - keith/reminders-cli
  - openclaw/remindctl (formerly steipete), v0.3.9 (2026-10-20)
  - viticci/remctl: docs, notes and `remctl-private.m`
  - FradSer/mcp-server-apple-events and FradSer/event
  - READMEs of falconbradley/claude-connector-apple-reminders, rex/mcp-apple-reminders, martijnstegink/apple-notes-reminders-mcp, eneko-codes/apple-reminders-mcp
  - supermemoryai/apple-mcp `utils/reminders.ts`
- **Vendor docs:** GoodTask help pages, BusyCal docs, Things support pages, Fantastical help index.
- **Store data:** App Store lookup by known app ID and the GoodTask customer-review RSS feed (direct fetches, not searches).
- **Local, read-only:**
  - the EventKit headers in SDK 27.0
  - `ReminderKit.framework/Resources/framework.sb`
  - the `ReminderData.momd` versions
  - `strings` on Xcode 27's `IDEFoundation`
- **Not covered:** the WebSearch budget for this turn ran out partway through. These went unresearched: "Tasks", "Clean", "Taska", "Doit", "Lister", "Reminder Pro", detailed Reddit and forum complaint threads, and how TickTick and Todoist import from Reminders. Anything below on those is marked UNVERIFIED. A follow-up turn with more search budget can fill these gaps.

---

## 1. Key lessons (TL;DR for the planner)

1. **Public EventKit only gives you the 2012-era data model.**
   - Apple DTS confirmed in April 2026 that EventKit has no API for subtasks, and no answer was given for groups or sections [FORUM/BLOG: https://developer.apple.com/forums/thread/820848].
   - Every serious project either accepts this (GoodTask, remindctl, BusyCal, Things) or goes to private ReminderKit (Reminders MenuBar, RemCTL, falconbradley, rex).
2. **Private ReminderKit is reachable from inside a sandboxed, EventKit-authorized app** through `EKReminder.backingObject._reminder`, which is a `REMReminder`, and through `REMSaveRequest`.
   - Reminders MenuBar ships this with `com.apple.security.app-sandbox` [VERIFIED: reminders-menubar `reminders_menubar.entitlements` and `Extensions/EKReminder+Extensions.swift`].
   - ReminderKit's framework sandbox profile allows `(mach-lookup (global-name "com.apple.remindd"))` [VERIFIED: /System/Library/PrivateFrameworks/ReminderKit.framework/Versions/A/Resources/framework.sb].
   - It is not on the Mac App Store. The repo has an `#if APPSTORE` build, but `appId = "PLACEHOLDER_APP_ID"` and an App Store lookup by bundle ID returns 0 results [VERIFIED: Constants.swift; itunes lookup].
3. **The best-known App Store front-end, GoodTask, uses only public APIs and stores its extras as text conventions or in its own files.**
   - Subtasks are `[ ]`/`[x]` lines in notes [DOCS: https://goodtaskapp.com/subtasks/].
   - Tags are text, written to notes by default [DOCS: https://goodtaskapp.com/about-tags/].
   - Smart lists, Quick Actions, Manual Sort, Repeat-after-completion and Auto-Snooze sync through GoodTask's own iCloud Drive files [DOCS: https://goodtaskapp.com/sync/].
4. **EventKit returns subtasks as ordinary, flat reminders.** You need the private `parentReminderID` to rebuild the tree. Things' importer says "any such hierarchy will be flattened" [DOCS: https://culturedcode.com/things/support/articles/1477596/]. Reminders MenuBar rebuilds it with the private parentReminderID [VERIFIED: RemindersService.createReminderItems].
5. **Completing a recurring reminder advances the same EKReminder object (same identifier) to the next occurrence.** Reusing views or state keyed by ID completed the next occurrence too (Reminders MenuBar issue #304, a data-loss class bug).
   - The fix was to reset view identity [VERIFIED: commit 3c7b657: "EventKit advances the same object to the next occurrence causing view reuse"].
   - Never retry a recurring completion blindly [FORUM/BLOG: remctl docs/notes/remindctl-comparison-2026-09-26.md].
6. **`EKReminder.url` is not the URL that Reminders.app shows.**
   - The visible link is a private `REMURLAttachment`. Values set via EventKit are stored but invisible in Reminders.app [VERIFIED: reminders-menubar `attachedUrl`; FORUM/BLOG: https://developer.apple.com/forums/thread/128140; falconbradley: the EK URL lands in `ZICSURL`, "which Reminders.app never draws"].
   - remindctl mirrors the URL into a managed notes line [VERIFIED: remindctl CHANGELOG 0.3.2, README].
7. **Timed due dates need an explicit `EKAlarm(absoluteDate:)` to notify, the same way Reminders.app does it.**
   - All three EventKit codebases do this. Reminders MenuBar's comment reads "In Apple Reminders only reminders with time have an alarm" [VERIFIED: reminders-menubar `addDueDateAndAlarm`; keith `addReminder`; remindctl `createReminder`].
   - When rescheduling, replace only the absolute, non-location alarms. Keep relative and location alarms [VERIFIED: remindctl `ReminderAlarmMutation`, CHANGELOG 0.3.3].
8. **Moves can fail.**
   - `com.apple.reminderkit` error -3002 is returned when either list is shared [VERIFIED: remindctl `ReminderUpdateSave.swift`].
   - EventKit also rejects moving a parent that has subtasks. RemCTL works around this with a ReminderKit clone-and-delete that changes the ID [DOCS: remctl docs/private-metadata.md, architecture.md].
9. **Identifiers.**
   - `calendarItemIdentifier` equals the ReminderKit UUID string. Apple's header says it is "not sync-proof … a full sync will lose this identifier" [VERIFIED: SDK EKCalendarItem.h; falconbradley README; consistent with reminders-menubar comparing it against `parentReminderID.uuid`].
   - Deep link format: `x-apple-reminderkit://REMCDReminder/<id>` [VERIFIED: remindctl ReminderLinks.swift; remctl-private.m].
10. **Swift 6 concurrency.**
    - EKReminder is not Sendable, and EventKit callbacks run off the main actor.
    - remindctl crashed with "Incorrect actor executor assumption". The fix was to snapshot into a Sendable struct inside the callback [VERIFIED: remindctl commit 7c902d0].
    - remindctl also bounds fetches at 30 s and calls `cancelFetchRequest` [VERIFIED: EventKitStore.swift, CHANGELOG 0.3.4].
11. **Never use AppleScript to read reminders.**
    - supermemoryai/apple-mcp (3.1k stars, archived) stubbed out search and fetch as "too slow and unreliable" [VERIFIED: utils/reminders.ts].
    - EventKit takes about 50–200 ms per 1,000 reminders, against 5–30 s for AppleScript [FORUM/BLOG: falconbradley README].
12. **Don't schedule your own notifications for reminders.** remindd already fires the alarms, so you get duplicates. GoodTask documents this: "you may get duplicate notifications from Reminders app" [DOCS: https://goodtaskapp.com/notifications/].
13. **Private selectors drift between OS builds (Tahoe 26.2 → Golden Gate 27.0).**
    - Examples: `categorizeGroceryItemsWithReminderIDs:` became `autoCategorizeRemindersWithReminderIDs:` on a different receiver with a different argument type, and `REMStore fetchSmartListWithObjectID:error:` was removed.
    - One wrong-argument experiment tombstoned objects (`ZMARKEDFORDELETION=1`) [DOCS: remctl docs/notes/private-api-audit-2026-08-12.md].
    - Probe every selector at runtime and fail closed.
14. **The SQLite schema churns yearly.** `ReminderData.momd` holds v1 through `ReminderData_v2026_A`, which is current [VERIFIED: local VersionInfo.plist]. Direct DB reads also need Full Disk Access, which rules them out for a sandboxed app (RemCTL, falconbradley and martijnstegink all need FDA).

---

## 2. Landscape table

| Project | Type / distribution | Access path | Tags | Subtasks | Sections | Flag | Urgent | Manual order | Notes |
|---|---|---|---|---|---|---|---|---|---|
| **GoodTask** (hahaint) | Mac App Store, $39.99 Mac, iOS sold separately; v8.5.0 (2026-10-18), min macOS 12 [VERIFIED: App Store lookup id1143437985] | Public EventKit (plus Calendar) [DOCS] | Text `#tag`/`@tag` in notes or title ("Tag on" setting) [DOCS] | Notes `[ ]`/`[x]` lines [DOCS] | No | No (a review complains of no flagged filter) [VERIFIED: review v7.8.3] | Own "Full-Screen Urgent Alerts", not native [VERIFIED: release notes] | Own, stored in iCloud Drive prefs [DOCS] | Board, Matrix, Project, Calendar views; Quick Actions; templates; multiple and relative alerts (8.5) |
| **Reminders MenuBar** | OSS GPL-3, GitHub/Homebrew/Sparkle; sandboxed; MAS build prepared but not published | EventKit plus private ReminderKit via `backingObject` | Read/write native (`hashtags`, `hashtagContext`) [VERIFIED] | Read native `parentReminderID`; displays tree [VERIFIED] | No | Read/write native (`flaggedContext`) [VERIFIED] | Read/write, macOS 26+ (`urgentAlarmContext`) [VERIFIED] | Read native `REMList.reminderIDsOrdering` [VERIFIED] | Also reads URL attachments and the Mail link (`userActivity`) |
| **keith/reminders-cli** | OSS CLI, Homebrew | Public EventKit, semaphores | No | No | No | No | No | No | Uses `calendarItemExternalIdentifier` as the external ID; NSDataDetector plus private KVC `timeIsSignificant` |
| **remindctl** (openclaw) | OSS MIT CLI, 402 stars, signed and notarized | Public EventKit only, by policy | No | No | No | No | No | No | README lists missing: sections, tags, smart lists, attachments, Urgent [VERIFIED] |
| **RemCTL** (viticci / MacStories, May 2026) | OSS CLI plus MCP, 626 stars; signed "Capability Host" LaunchAgent with FDA, Reminders and Automation grants | SQLite reads; EventKit writes (Swift bridge); ReminderKit writes (ObjC helper); AppleScript for flags | Full | Full, including clone | Full CRUD | Yes | Yes | Lists and custom smart lists | Also smart lists, templates, groups, groceries, Early Reminders, assignments, images, pins [DOCS] |
| **FradSer/event + mcp-server-apple-events** | OSS MCP (225 stars) and Swift CLI | EventKit plus a user-installed Shortcut ("AdvancedReminderEdit") run via `/usr/bin/shortcuts run`, JSON on stdin | Via Shortcut | Notes checklist; native parent via Shortcut **by title** | No | Via Shortcut | No | No | "Shortcuts can't search by ID reliably" [VERIFIED: ShortcutPayload.swift] |
| **falconbradley connector** | OSS, 3 stars | EventKit (Python/PyObjC); SQLite read (FDA); ReminderKit writes | Real, read and write | Parent param | – | – | – | – | Linked Mail/Messages chips via `REMUserActivity`; assignment reads |
| **rex/mcp-apple-reminders** | OSS | SQLite plus Swift EventKit helper plus ObjC ReminderKit helper | Yes | Yes | Yes | Yes | Yes | – | Three-tier, the same shape as RemCTL |
| **martijnstegink apple-notes-reminders-mcp** | OSS | SQLite (Notes), EventKit, AppleScript (subtasks, flagged) | – | AppleScript | Not read | AppleScript, slow | – | – | Flagged across the whole library is slow, so it is limited to one list |
| **eneko-codes/apple-reminders-mcp** | OSS | EventKit only | No | No | No | No | No | No | Some claims are contradicted (see §9) |
| **supermemoryai/apple-mcp** | Archived | JXA / AppleScript | – | – | – | – | – | – | Reads stubbed as too slow |
| **BusyCal** | MAS / Setapp | EventKit for Reminders, plus Todoist, MS To Do and Google Tasks [VERIFIED: App Store desc] | Not available | "not visible… no workaround" | No | "Private Flag" not available | – | – | Syncs completed reminders from the last 12 months only [DOCS] |
| **Fantastical** | MAS | EventKit (Reminders) [UNVERIFIED/INFERENCE] | ? | ? | ? | ? | ? | ? | Ships an in-app MCP helper `Contents/Helpers/FantasticalMCP.app` (v4.1.17+) [DOCS] |
| **Things 3 importer** | MAS | One-time import plus "Reminders Inbox" (reads one list, deletes items from Reminders after import) [DOCS] | "Tags will become Tags" [DOCS] | Flattened | – | Not imported | – | – | "Groups aren't accessible"; URL field not accessible; mechanism unknown (§10) |
| Structured, Sorted³ | MAS | "Connect your calendars and Reminders" (Structured) [VERIFIED: App Store desc] | ? | ? | ? | ? | ? | ? | Not researched further (budget) |

---

## 3. Deep dives

### 3.1 GoodTask
All [DOCS] from goodtaskapp.com unless tagged otherwise.

- **Data:**
  - "GoodTask uses and shares default Apple's Reminders app's data."
  - Since v5.4, preferences sync via iCloud Drive files: smart lists, Quick Actions, Repeat-after-completion, Manual Sort, Auto-Snooze. These are a local metadata layer keyed to reminders.
  - Not synced: notification settings, theme, drag-and-drop options, Board settings.
- **Subtasks:** "Subtasks are saved in notes field … different from Reminders app's subtasks." Syntax is `[ ] title` and `[x] title`. Dropping a task onto a task converts it to a subtask. Pasting multiple lines creates multiple subtasks.
- **Tags:** any symbol (`#`, `@`). Stored in notes by default (configurable). Smart-list filters use "Text include/exclude". Quick Action types include Tag, Switch (cycles tags), and Prompt.
- **Recurrence:** the native rule is stored in Reminders. "Repeat on Completion works only when you complete the task in GoodTask," and GoodTask "runs its engine before and after the next task is created" to fix start and due dates.
- **Views:**
  - List (events hidden).
  - Calendar (drag to a day changes the date).
  - Board: columns by Date (Today/Tomorrow/Later/No Due), Priority, List, or Tag. Dropping a card on another board "change[s] accordingly."
  - Matrix and Project views [VERIFIED: App Store description].
- **Sort:** four sort keys, grouped; "Custom"; per-list overrides. Dropping a task changes its fields to match the active sort. Dragging into a list changes the list ("Reminders lists only").
- **Notifications:** may duplicate Reminders' own alerts, so pick one app. iOS caps pending notifications at 64. Location alerts only fire on boundary crossing.
- **Today Page:** "Choose tasks for Today Page without changing their due dates," which is local metadata [VERIFIED: App Store description].
- **Complaints** [VERIFIED: US App Store RSS reviews for id1143437985]:
  - "limitations of EventKit itself (like the exclusion of tags from the API)" (v8.3.3)
  - "doesn't sync smart lists from Reminders … forced to recreate" and "No flagged item filter" (v7.8.3)
  - freezes with the spinning wheel (v8.1.7); "CPU hog … drain your battery" (v6.1.2)
  - badge not updating (v5.6.5, v6.9.5); sync between devices inconsistent (v7.0.1, v7.3.3, v7.6.5)
  - "Too many settings", "cluttered", "overcooked"
  - separate purchases per platform; notifications "inferior"

### 3.2 Reminders MenuBar (code-level patterns) [VERIFIED: master branch]

- **Store:** `@MainActor class RemindersService` singleton holding one `EKEventStore`.
  - Authorization: on macOS 14+ it checks `.fullAccess` and calls `requestFullAccessToReminders`.
  - `fetchReminders` is wrapped in `withCheckedContinuation`.
- **Default list:** `defaultCalendarForNewReminders() ?? calendars(for:.reminder).first`.
- **Predicates:**
  - Lists use `predicateForIncompleteReminders(withDueDateStarting:nil, ending:nil, calendars:)`.
  - Upcoming uses `ending: interval.endingDate`.
  - Recents fetch all reminders and filter `lastModifiedDate ≥ now-90d` client-side.
  - Search fetches everything once when search opens and caches it.
- **Change handling:** `Publishers.MergeMany(.EKEventStoreChanged, .NSCalendarDayChanged, .remindersDataShouldUpdate).debounce(300 ms, main)`, followed by a full `update()` that re-validates the list and tag filters.
  - Before refetching, it calls `optimisticallyRemove(reminderItem:)` on completion.
- **Value mapping:** `ReminderItem { id = calendarItemIdentifier, reminder: EKReminder, lastModifiedDate, childReminders }`. Equality is id plus lastModifiedDate plus children. It keeps a live EKReminder reference, which is the root cause of #304.
- **Tree:** reminders are grouped by private `parentId`. A child whose parent is not in the fetch set is promoted to top level.
- **Sort:**
  - Optional "due date on top".
  - Flagged, then High/Medium/Low/None, then "default order".
  - Default order comes from private `REMList.reminderIDsOrdering` (an NSOrderedSet of objects with `uuid`), mapped to `calendarItemIdentifier`.
- **Private read chain:** `EKReminder.backingObject` → `_reminder` (REMReminder). From there:
  - `hashtags` (NSSet of objects with `name`)
  - `flagged`
  - `isUrgentStateEnabledForCurrentUser` (macOS 26)
  - `parentReminderID.uuid`
  - `attachments` (`REMURLAttachment.url`)
  - `userActivity.storage` (`message:` Mail links)
  
  For lists: `EKCalendar.backingObject._list.reminderIDsOrdering`.
- **Private write chain:** `REMSaveRequest alloc initWithStore:(rem.store)` → `updateReminder:(rem)` → change item. On that item:
  - `hashtagContext` → `removeAllHashtags`, then `addHashtagWithType:name:` with type 0, called through a typed `@convention(c)` IMP cast
  - `flaggedContext` → `setValue(_, forKey:"flagged")`
  - `urgentAlarmContext` → `isUrgentStateEnabledForCurrentUser`
  
  Then `saveSynchronouslyWithError:`.
  - Order matters: the EventKit `save(commit:true)` must happen first so the backing object exists. That means two saves and two change notifications per edit.
- **Pitfall in their code:** BOOL getters read via `perform(sel) != nil`, which works only because YES is a non-null pointer bit [UNVERIFIED/INFERENCE: fragile; prefer `value(forKey:)` or a typed IMP].
- **Tag model:** case-insensitive identity (`id = name.lowercased()`); sanitizer keeps alphanumerics plus `-` and `_`; tags are resolved against known tags for canonical casing.
- **Bug history worth copying the fixes from:**
  - #304: next recurring occurrence shown and saved as completed (fixed in v2.1.1).
  - #309: "reminder time being overwritten when marking a reminder as urgent", a private save clobbering EventKit fields.
  - #315: text-field resizing on macOS 27.
- **Info.plist:** `NSRemindersFullAccessUsageDescription` and `NSRemindersUsageDescription`, plus `LSUIElement`.
- **Entitlements (App Store variant):** `app-sandbox`, `network.client`, `personal-information.calendars`. Nothing Reminders-specific.

### 3.3 keith/reminders-cli [VERIFIED: Sources/RemindersLibrary]

- One file-scope `EKEventStore`. Every operation blocks on a `DispatchSemaphore`; errors `exit(1)`.
- Lists are filtered to `allowsContentModifications`.
- Completion state is filtered client-side after `predicateForReminders(in:)`.
- Reminders are looked up by numeric index or by `calendarItemExternalIdentifier`.
- Clearing a due date also removes all alarms. Setting one adds an alarm only if components have an hour.
- Comment in the encoder: "url field is nil" (links to the forum thread above).

### 3.4 remindctl [VERIFIED: Sources/RemindCore, CHANGELOG]

- `public actor RemindersStore` with one `EKEventStore`. Authorization states include a `.writeOnly` case that is treated as an error.
- **Date-only vs timed:** components are `[.year,.month,.day]` for date-only and `[…, .hour,.minute,.second]` otherwise, always with `calendar` and `timeZone` set. "Preserve date-only due inputs as all-day reminders instead of midnight."
- Before assigning a new due date it sets `dueDateComponents = nil` first [UNVERIFIED/INFERENCE: workaround to force change detection].
- **Robustness:**
  - Skips reminders whose `calendar` is nil ("orphaned").
  - Reports "Reminder is missing a calendar" after a save instead of trapping.
  - Bounds fetches at 30 s.
  - Breaks sort ties by ID so the order is stable across EventKit fetches.
  - `list --create` reuses an existing list with the same name.
- New lists use `defaultCalendarForNewReminders()?.source`.
- Rename and delete are refused for lists that are not `allowsContentModifications`.

### 3.5 RemCTL (the most complete private-API map; macOS 26.2 and 27.0 tested) [DOCS: viticci/remctl docs]

- **Reads:** SQLite at `~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite`, read-only, with FDA.
- **Writes:** ReminderKit through `[REMStore new]` with `REMObjectID objectIDWithURL:` and `x-apple-reminderkit://REMCD{Reminder|List|ListSection|SmartList|Template|Sharee|ManualSortHint_v1}/<uuid>`.
- **Selector inventory** (34 classes, about 111 methods) [DOCS: private-api-audit-2026-08-12.md]. Key reminder contexts on `REMReminderChangeItem`:
  - `hashtagContext`, `flaggedContext`, `urgentAlarmContext`
  - `subtaskContext` → `REMSaveRequest addReminderWithTitle:toReminderSubtaskContextChangeItem:`
  - `attachmentContext` (`addURLAttachmentWithURL:`, `addImageAttachmentWithURL:width:height:error:`)
  - `dueDateDeltaAlertContext` (Early Reminders; units 0 = min … 4 = months)
  - `assignmentContext`
- **Lists:** `REMListChangeItem sectionsContextChangeItem` (memberships through `REMMembership`), `insertReminderChangeItem:before/afterReminderChangeItem:` (manual order), `groceryContextChangeItem`, `appearanceContext` (`REMListBadge initWithEmblem:` / `initWithEmoji:`), `setParentOwnerID:` (groups).
- **Smart lists:** `addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:`; the filter is UTF-8 JSON (`{"hashtags":{"hashtags":{"operation":"or","include":[…],"exclude":[]}}}`). Requires an active CloudKit account with `supportsCustomSmartLists`.
- **Hard-won rules:**
  - Validate everything before writing.
  - Return `partial` with the created ID rather than re-creating.
  - Verify by reading back.
  - Additive operations are never retried.
  - Refuse ambiguous names (sections and lists can have duplicates) and ask for the ID.
  - The 71 official list emblem names live in RemindersUICore; arbitrary SF Symbol names fall back to the default icon.
  - Removing a tag from its last reminder garbage-collects the tag [FORUM/BLOG: falconbradley].

### 3.6 MCP servers: lessons

- **Pick one primary path.** EventKit is fast and safe. AppleScript reads are unusable at scale.
- **The Shortcuts bridge (FradSer) works without private API, but:**
  - the user must install the Shortcut;
  - matching is by title, which is ambiguous;
  - it is serial and slow;
  - a sandboxed app spawning `/usr/bin/shortcuts` is unproven [UNVERIFIED].
- **Headless contexts can hang forever** on the TCC prompt. Use a timeout and kill (FradSer: 30 s server, 15 s CLI) [DOCS: FradSer README].
- **Write-confirmation and prompt-injection boundaries** matter when exposing Reminders to agents (titles and notes from shared lists are untrusted) [DOCS: FradSer README].
- **Hashtag-in-notes fake tags:** harriscarl/apple-eventkit-mcp stores tags as `#hashtags` at the end of notes [FORUM/BLOG: search summary]. falconbradley warns: "Writing `#foo` into a reminder's title does not tag it" [FORUM/BLOG].

### 3.7 BusyCal / Fantastical [DOCS: https://www.busymac.com/docs/busycal/114450-using-busycal-with-reminders]

- **BusyCal, unavailable:** sub-tasks ("Since Apple does not expose sub-tasks through EventKit, there is no workaround"), folders/groups, Attachments, Graphics, Locations, Location URLs, Tags, URLs, Private Flag.
- **BusyCal-own properties** ("My Alarm/Notes/Tag", snoozes) don't sync across BusyCal devices.
- **Display rule:** "When a task has any alarm, Reminders shows the alarm's date and time as the effective due date." Keep due date and alarm consistent.
- **Upgraded iCloud Reminders** (iOS 13+) no longer use CalDAV, so a direct CalDAV client sees stale or duplicate data. EventKit is the only sanctioned path.
- **Fantastical:** help pages say nothing specific about Reminders (only `!` priority syntax). Pattern worth copying later: a bundled MCP helper app.

### 3.8 Things / TickTick / Todoist

- **Things import** [DOCS]:
  - lists → projects; templates → projects; reminders → to-dos; due → When (start) date
  - repeating items lose their schedule; tags → tags
  - URL field "not accessible"; hierarchy flattened
  - image attachments, flag, priority, location and "when messaging" alerts not imported
  - "Groups aren't accessible … Lists nested inside them are also excluded"
- **Things "Reminders Inbox":** shows one chosen Reminders list in the Inbox. Items are "merely displayed" until imported, then "deleted from the Reminders app." "Apple doesn't let us access … Smart Lists."
- **Things / Siri:** "Siri AI is in beta with OS 27" [DOCS: Things article 2877019]. App Intents are worth exposing.
- **TickTick, Todoist:** not verified (budget).

---

## 4. Access-tier matrix (feature × mechanism)

| Feature | Public EventKit | EK backingObject → ReminderKit (in-process, sandbox OK) | Standalone ReminderKit (`REMStore new`) | AppleScript (sdef) | Shortcuts / App Intents | SQLite read |
|---|---|---|---|---|---|---|
| CRUD title/notes/due/start/priority/complete | ✅ | – | ✅ | ✅ (slow) | ✅ | read |
| Recurrence | ✅ `addRecurrenceRule` [VERIFIED: remindctl, menubar] | – | – | ✗ | ✅ (Create/Update intent) | read |
| Alarms (absolute/relative/location) | ✅ | – | ✅ | partial (`remind me date`) | earlyAlert/location | read |
| Lists create/rename/delete/color | ✅ (`source` fixed after creation [VERIFIED: EKCalendar.h]) | – | ✅ plus emblem/emoji/pin/group | name, color, emblem rw | ✅ (TTRCreateList, UpdateList) | read |
| Tags | ✗ | ✅ R/W [VERIFIED: menubar] | ✅ | ✗ | ✅ AddOrRemoveTags (macOS 27 metadata, established) | read |
| Subtasks (parent link) | ✗ (flattened) | Read ✅ [VERIFIED]; write unproven in-process | ✅ | container ro (`list\|reminder`) | ✅ MoveRemindersToParentReminder | read |
| Flagged | ✗ | ✅ R/W [VERIFIED] | ✅ | ✅ `flagged` rw | ✅ isFlagged | read |
| Urgent (macOS 26+) | ✗ | ✅ R/W [VERIFIED] | ✅ | ✗ | ✅ isUrgent | read |
| Sections | ✗ | unproven | ✅ | ✗ | ✅ CreateSection/MoveToSection | read |
| Groups | ✗ | – | ✅ | list container | ✅ CreateGroup | read |
| Manual order | ✗ | Read ✅ `reminderIDsOrdering` [VERIFIED] | ✅ write | ✗ | MoveReminders(position) | read |
| Visible URL / rich link | ✗ (`url` invisible) | Read ✅ | ✅ | ✗ | ✅ urls | read |
| Smart lists / templates | ✗ | – | ✅ (custom only on 26.2/27.0) | ✗ | CreateCustomSmartList | read |

---

## 5. Code patterns (short)

**a. Fetch with a Sendable snapshot, cancellation and timeout** (remindctl and Reminders MenuBar combined)

```swift
struct ReminderSnapshot: Sendable, Identifiable { let id: String; let title: String; let due: DateComponents?
  let isCompleted: Bool; let priority: Int; let listID: String; let modified: Date? }
extension ReminderSnapshot { init?(_ r: EKReminder) { guard let cal = r.calendar else { return nil } // orphan guard
  self.init(id: r.calendarItemIdentifier, title: r.title ?? "", due: r.dueDateComponents,
            isCompleted: r.isCompleted, priority: r.priority, listID: cal.calendarIdentifier, modified: r.lastModifiedDate) } }

func fetch(_ p: NSPredicate) async -> [ReminderSnapshot] {
  await withCheckedContinuation { cont in
    _ = store.fetchReminders(matching: p) { @Sendable rems in      // EventKit's queue: snapshot HERE
      cont.resume(returning: (rems ?? []).compactMap(ReminderSnapshot.init)) } } // keep the returned id → cancelFetchRequest on timeout
}
```

**b. Change observation**

```swift
NotificationCenter.default.publisher(for: .EKEventStoreChanged)
  .merge(with: NotificationCenter.default.publisher(for: .NSCalendarDayChanged))
  .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
  .sink { _ in Task { await model.reload() } }   // full re-fetch; no per-object diffs in public API
```

**c. Due date and alarm**

```swift
r.dueDateComponents = hasTime ? cal.dateComponents([.year,.month,.day,.hour,.minute], from: d)
                              : cal.dateComponents([.year,.month,.day], from: d)       // no hour ⇒ all-day
r.alarms?.filter { $0.structuredLocation == nil && $0.absoluteDate != nil }.forEach(r.removeAlarm) // keep relative/location
if hasTime { r.addAlarm(EKAlarm(absoluteDate: d)) }
```

**d. Recurring completion.** After `isCompleted = true; save`, the same ID now represents the next occurrence. Re-key UI state on `(id, lastModifiedDate)` or `.id(...)`. Discard pending UI and undo state. Never re-save a stale object or retry on timeout.

**e. Move errors**

```swift
catch let e as NSError where e.domain == "com.apple.reminderkit" && e.code == -3002 { /* shared-list or parent-with-subtasks move rejected */ }
```

**f. Deep links:** `x-apple-reminderkit://REMCDReminder/\(id)` and `…/REMCDList/\(calendarIdentifier)`, which open in Reminders.app.

**g. Private write (gated by an optional feature flag).** Every selector is checked with `responds(to:)`, and the feature fails closed. Call shape is `REMSaveRequest(initWithStore: backing.store)` → `updateReminder:` → `<context>`, then `saveSynchronouslyWithError:`. Batch all private edits into one save request and re-fetch afterwards (#309).

**h. Entitlements and Info.plist:**
- `com.apple.security.app-sandbox`
- `com.apple.security.personal-information.calendars`. Xcode 27 knows only addressbook, calendars, location and photos-library [VERIFIED: `strings` on IDEFoundation]; FradSer's `…personal-information.reminders` is not a known key.
- `NSRemindersFullAccessUsageDescription`; legacy `NSRemindersUsageDescription` for macOS < 14.
- For AppleScript: `NSAppleEventsUsageDescription` plus `com.apple.security.scripting-targets` with the sdef access groups.

---

## 6. Pitfall catalog

| Pitfall | Symptom | Mitigation | Source |
|---|---|---|---|
| Recurring object advance | The next occurrence shows or is saved as completed | Reset identity; no stale saves; no blind retries | [VERIFIED: menubar #304, 3c7b657; remctl comparison] |
| `EKReminder.calendar` nil | Crash on IUO | Skip on read; report after save | [VERIFIED: remindctl 0.3.5] |
| Non-Sendable EKReminder under Swift 6 | "Incorrect actor executor assumption" | Snapshot in callback | [VERIFIED: remindctl 7c902d0] |
| Hung fetch or TCC prompt | Infinite wait (headless) | Timeout plus `cancelFetchRequest` | [VERIFIED: remindctl 0.3.4; DOCS: FradSer] |
| `url` invisible | Links lost | Write the URL into notes; private attachment optional | [VERIFIED: remindctl, menubar] |
| Shared-list or parent move | Error -3002 | Explain; offer "open in Reminders" | [VERIFIED: remindctl] |
| Identifier lost on full sync | Local metadata orphaned | Fallback match by externalIdentifier, title and creationDate | [VERIFIED: SDK header] |
| Duplicate list names | Wrong target | Always address by ID | [VERIFIED: remindctl ListResolver; DOCS: remctl] |
| `removeCalendar` deletes all contents | Data loss | Confirm with counts | [FORUM/BLOG: eneko README] |
| Own notifications | Duplicate alerts | Rely on EKAlarm and remindd only | [DOCS: GoodTask] |
| Private selector drift | Silent no-op or tombstoning | Capability probe per build; fail closed | [DOCS: remctl audit] |
| Two saves per edit (EK plus private) | Double notifications or sync churn; clobbered time | Debounce; one REMSaveRequest; re-fetch | [VERIFIED: menubar #309] |
| Whole-DB fetch including completed | Slow on large DBs | Incomplete predicate plus windowed completed predicate (BusyCal: 12 months) | [DOCS: BusyCal] |

---

## 7. Recommendations for our app

1. **Two-tier architecture.**
   - Tier A, public EventKit: the default and App Store-safe.
   - Tier B, an optional "Native Extras" module using the in-process `backingObject` ReminderKit bridge: tags, flag, urgent, parent links, manual order, visible URL. It is fully capability-probed and off by default.
   - Ship outside the Mac App Store (Developer ID plus Sparkle, the Reminders MenuBar model) if Tier B is on.
   - Avoid SQLite and FDA entirely. The schema churns, and FDA is incompatible with a sandboxed app.
2. **One actor-isolated store service and immutable snapshots.**
   - Never hand EKReminder objects to SwiftUI. Re-fetch the EKReminder by ID when mutating.
   - Debounce `EKEventStoreChanged` and `NSCalendarDayChanged` at 300 ms with a full re-fetch, plus optimistic UI.
3. **Local metadata layer, GoodTask-style but minimal.** Keyed by `calendarItemIdentifier` plus a fallback fingerprint. It covers what Reminders can't do even privately: saved custom views and filters, Today selection, kanban column assignments, repeat-after-completion. Sync it through CloudKit or iCloud Drive.
4. **Tier-A fallbacks.**
   - Subtasks rendered as a notes checklist? Recommend against. It clutters native notes and conflicts with native subtasks. In Tier A, prefer to display native children as flat items, ideally with a read-only parent badge if Tier B is available.
   - Tags as text in Tier A? Recommend against writing `#` into the title. It isn't a real tag (falconbradley).
5. **Recurrence safety.** Complete-once semantics with an idempotency guard, a view-identity reset, and no auto-retry.
6. **Dates.** Date-only due dates are all-day; timed due dates get a matching absolute alarm. On reschedule, move only the alarms that matched the old due date. Always set `calendar` and `timeZone` on components.
7. **Moves.** Handle -3002 explicitly. In Tier A, don't move a parent that has subtasks. Never copy-and-delete silently, because that loses metadata and changes the ID.
8. **Performance.**
   - Fetch incomplete reminders for all lists once, plus completed reminders in a date window.
   - Search in memory with case- and accent-folding (remindctl).
   - Measure against roughly 10k reminders; GoodTask's CPU and freeze complaints are the warning.
9. **Open in Reminders** for anything unsupported: `x-apple-reminderkit://` deep links, plus the AppleScript `show` command if Automation is granted.
10. **Expose our own App Intents** for Siri AI on OS 27. An in-app MCP helper (Fantastical's pattern) is a later option.

---

## 8. Contradictions found in prior art

- **"EventKit cannot create repeating reminders"** (eneko-codes README) is contradicted by working `addRecurrenceRule` code in remindctl (0.2.0 `--repeat`) and Reminders MenuBar (v2.0.0 "Edit and set recurrence rules") [VERIFIED].
- **"Reminders' App Intents metadata: no section-related intent"** (eneko-codes, macOS 26.5 SDK) and **"Shortcuts/App Intents expose no tag parameter"** (falconbradley) are contradicted on macOS 27 by the RemindersAppIntents `extract.actionsdata` already established (CreateSectionAppIntent, AddOrRemoveTagsAppIntent, tags on Create/Update). These were likely added in 27 [UNVERIFIED/INFERENCE].
- **"A symbol scan of EventKit turns up no private [tag] property"** (falconbradley) is technically true of EventKit itself, but the tags are reachable through `EKReminder.backingObject._reminder.hashtags` [VERIFIED: menubar].

---

## 9. Open questions

1. Can the in-process `backingObject` path also write subtask parentage (`subtaskContext` / `_copyReminder:toReminderSubtaskContextChangeItem:`), section membership and manual-order inserts from a sandboxed app? Reminders MenuBar only reads these. RemCTL writes them via a standalone `REMStore` in a non-sandboxed host.
2. Does Mac App Store review flag `NSSelectorFromString`-based calls on `backingObject` (guideline 2.5.1)? No MAS evidence found; Reminders MenuBar's MAS build is unpublished.
3. Do `EKEventStore.calendars(for: .reminder)` results include lists nested in groups? Things says nested lists are "not accessible"; the mechanism of Things' importer, which claims to read tags and templates, is unknown. This needs a quick test on a disposable account.
4. Does `EKEventStore.remove(_:)` on a parent cascade to its native subtasks or orphan them? (falconbradley implements cascade itself; the native behavior is unknown.)
5. Can a sandboxed app run `/usr/bin/shortcuts run` (to reach Reminders' App Intents through a user-installed Shortcut)? Is there any public API to invoke another app's App Intents?
6. Are the private selectors on macOS 27.2 (26B5091g, our dev machine) unchanged from 27.0 26A5406e? RemCTL tested only up to 26A5406e.
7. Is a `.writeOnly` authorization status ever returned for reminders (remindctl handles it; FradSer declares `NSRemindersWriteOnlyAccessUsageDescription`)? The SDK only has `requestFullAccessToReminders`.
8. Does `EKEventStoreChanged` carry usable changed-object IDs on macOS 26/27 for incremental refresh, or is a full re-fetch required? All prior art does a full re-fetch.
9. Exact iCloud sync behavior of a private-API write (tags, flag) relative to the paired EventKit save: ordering and conflict windows.
10. Unresearched (search budget): Tasks, Clean, Taska, Doit, Lister, Reminder Pro, Sorted³ internals; TickTick and Todoist Reminders importers; Reddit and forum complaint threads.