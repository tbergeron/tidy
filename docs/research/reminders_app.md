# Apple Reminders.app on macOS 26 and 27: feature inventory and what each API path can reach

**Scope:** macOS 27.2, Reminders 7.0, SDK 27.0. I only read system bundles and web sources. Nothing was run against Reminders, and no personal data was touched.

**Evidence tags:**
- **[VERIFIED: path]** read from a local system file.
- **[DOCS]** Apple support or developer docs.
- **[FORUM/BLOG]** community or press sources.
- **[UNVERIFIED/INFERENCE]** my own reasoning, or a single unconfirmed source.

---

## 0. Key findings

1. **EventKit has nothing new for Reminders since macOS 14** [VERIFIED: SDK 27.0 headers].
   - There is no parent/subtask, tag, flag, section, group, smart list, attachment, early-reminder, urgent, vehicle-trigger, "when messaging" or assignee API.
   - `grep parent|subtask|tag|flag|section|attachment` across `EKReminder.h`, `EKCalendarItem.h` and `EKCalendar.h` returns nothing.
   - `EKRecurrenceFrequency` only has daily, weekly, monthly and yearly. There is no hourly.
2. **The real data model is ReminderKit's Core Data store, synced over CloudKit.** The 2026 model is at `/System/Library/PrivateFrameworks/ReminderKit.framework/Versions/A/Resources/ReminderData.momd/ReminderData_v2026_A.mom` [VERIFIED]. Its entities include:
   - `REMCDReminder`, with: `flagged`, `hashtags`, `parentReminder`, `titleDocument`/`notesDocument` (rich text), `dueDateDeltaAlertsData` (early reminders), `urgentPresentationAlarmsAsData`, `isUrgentStateEnabledForCurrentUser`, `contactHandles` ("when messaging"), `userActivity` (link back to Mail/Safari), `displayDate*`, `timeZone`, `icsUrl`, `daCalendarItemUniqueIdentifier`, `externalIdentifier`, `ck*` fields.
   - `REMCDList`, with: `isGroup`, `childLists`, `parentList`, `color`, `badgeEmblem`, `sortingStyle`, `isPinnedByCurrentUser`/`pinnedDate`, `listTypeRawValue`, `shouldAutoCategorizeItems`, `shouldCategorizeGroceryItems`, `groceryLocaleID`, `membershipsOfRemindersInSectionsAsData`, `sectionIDsOrderingAsData`, `reminderIDsMergeableOrdering`, `sharees`, `sharingStatus`, `sharedOwner*`, `showingLargeAttachments`, `mostRecentTargetTemplateIdentifier`.
   - Other entities: `REMCDSmartList` (`smartListType`, `filterData`, `parentList`), `REMCDListSection`, `REMCDSmartListSection`, `REMCDTemplate`, `REMCDTemplateSection`, `REMCDPublicTemplate` (public-link fields), `REMCDHashtag`, `REMCDHashtagLabel`, `REMCDAlarm` with trigger subtypes `REMCDAlarmDateTrigger`, `REMCDAlarmTimeIntervalTrigger`, `REMCDAlarmLocationTrigger` (address/radius/proximity/latitude/longitude/routing) and `REMCDAlarmVehicleTrigger`, `REMCDDueDateDeltaAlert`, `REMCDAssignment`, `REMCDSharee`, attachment types (URL, Image, File, Audio with `transcribedText`), `REMCDRecurrenceRule` (same fields as `EKRecurrenceRule`), `REMCDAccount` (`listIDsMergeableOrdering`, `recentlyDeletedInfoAsData`, `smartLists`, `templates`), and `REMCDSavedReminder`/`REMCDSavedAttachment` (template contents).
3. **Reminders' own App Intents (the Shortcuts actions) cover almost every advanced feature.** See `/System/Library/PrivateFrameworks/RemindersAppIntents.framework/.../extract.actionsdata` [VERIFIED].
   - They also expose an `AccountCapabilities` entity: a per-account feature matrix (§1).
   - Some actions **open Reminders in the foreground** (`openAppWhenRun=true`): `AddOrRemoveTagsAppIntent`, `CreateCustomSmartListAppIntent`, `MoveRemindersAppIntent`, `TTRSearchRemindersAppIntent`, all `Open*` intents, and `UpdateSectionIsCollapsedAppIntent`.
   - `DeleteRemindersAppIntent` has `authenticationPolicy=1`, which requires the device to be unlocked.
   - Some actions are **not discoverable** in the Shortcuts editor: `SnoozeRemindersAppIntent`, `CompleteRemindersAppIntent` (plural), `MoveRemindersToList/ToParentReminder/ToSection`, `GetDefaultListAppIntent` and `OpenSmartListAppIntent`.
   - Workaround: `UpdateReminderAppIntent` (runs in the background) already takes `tags`, `list`, `section` and `parent`, so it can replace the foreground-opening tag and move actions.
4. **There is no public API that lets one app call another app's App Intents directly.** The only routes are user-installed shortcuts run via `/usr/bin/shortcuts run` or the `shortcuts://` URL scheme [UNVERIFIED/INFERENCE].
   - WWDC26 session 345 mentions sharing entities across apps, but says nothing about calling another app's intents ([developer.apple.com/videos/play/wwdc2026/345](https://developer.apple.com/videos/play/wwdc2026/345)) [DOCS].
5. **AppleScript can be used from an App Store app.** The sdef declares access groups (§3), which is what the `com.apple.security.scripting-targets` entitlement needs, so a sandboxed app can drive it.
   - Add `NSAppleEventsUsageDescription`. The user sees a one-time Automation (TCC) prompt.
   - This path covers `flagged` (read/write), `emblem` (read/write), list `container` (read-only, exposes groups) and reminder `container` (read-only, exposes the parent of a subtask) [VERIFIED sdef].

---

## 1. Accounts and capabilities

`AccountCapabilities` entity properties [VERIFIED: RemindersAppIntents actionsdata]:
- supportsSubtasks, supportsAttachments, supportsListAppearance, supportsGroups, supportsFlagged
- supportsPersonTrigger, supportsLocation, supportsHourlyRecurrence, supportsTemplates
- supportsListSharees, supportsListShareesMutation, supportsMoveAcrossLists, supportsMoveAcrossSharedLists
- supportsMultipleDateAlarmsOnRecurrence, supportsSections, supportsDueDateDeltaAlerts, defaultPriorityLevel
- supportsHandoff, supportsReminderActions, supportsAssignments, supportsHashtags, supportsCustomSmartLists
- supportsPinnedLists, supportsTextStyling, supportsGroceriesList, supportsRecentlyDeletedList, supportsUrgentAlarm

The per-account values are only known at runtime. That makes this entity the best runtime source for greying out features in our UI (readable via Shortcuts).

| Account | Backend | Features | Evidence |
|---|---|---|---|
| iCloud (upgraded) | CloudKit private DB (`ck*` fields in model). Not reachable over CalDAV. | All features | [DOCS] every guide page says "All features … require updated iCloud reminders"; [BLOG] [BusyMac: upgrade moves to-dos off CalDAV](https://support.busymac.com/blog/112990); [VERIFIED] model `ckIdentifier`/`ckServerRecordData` |
| iCloud (not upgraded) | iCloud CalDAV VTODO | Basic only. The "Update Reminders" option still exists. | [DOCS] [accounts page](https://support.apple.com/guide/reminders/add-and-remove-accounts-remnd5faf3ad/mac) |
| CalDAV (Yahoo, AOL, Fastmail, Nextcloud…) | VTODO | Basic. Subtasks (RELATED-TO) show **flat** and Indent/Outdent is greyed out. | [FORUM] [Nextcloud](https://help.nextcloud.com/t/sub-tasks-in-apple-reminders/167668) |
| Exchange | EWS tasks | Basic | [DOCS] "some features aren't available…"; per-feature detail [UNVERIFIED] |
| Google | Not offered as a reminders provider | — | [DOCS] "If Reminders doesn't appear for a provider, that provider doesn't offer a reminders feature"; Google specifically [UNVERIFIED] |
| On My Mac / local (`EKSourceTypeLocal`) | local | Fails capability checks for flag/tag/subtask writes | [FORUM] [dullybot/reminders-cli PR#22](https://github.com/dullybot/reminders-cli/pull/22) |

Feature gates confirmed by error strings in `RemindersAppIntents` Localizable.loctable [VERIFIED]:
- "Sections are an iCloud account feature."
- "Adding or removing tags is unsupported for this account type"
- "Moving list across accounts is not supported"
- "Auto-categorization requires an account that supports sections."

Templates need upgraded iCloud on macOS 13+ / iOS 16+ [VERIFIED: RemindersUICore strings `PUBLIC_TEMPLATE_NOT_SUPPORT_ALERT_MESSAGE_MACOS`].

---

## 2. Feature inventory

Paths are compared in this order: **EK** (public EventKit) / **AS** (AppleScript) / **AI** (Reminders App Intents via Shortcuts) / **CalDAV** (non-iCloud accounts only).

### 2.1 Lists

| Feature | Details | EK | AS | AI | CalDAV |
|---|---|---|---|---|---|
| Create/rename/delete | Standard | `EKCalendar(for:.reminder)` + `saveCalendar`/`removeCalendar` | name rw; make/delete via Standard Suite [UNVERIFIED] | `TTRCreateListAppIntent(name,type,group)`, `UpdateList*`, `DeleteListsAppIntent` | calendar collection |
| Color | Palette: Red, Orange, Yellow, Green, Light Blue, Blue, Indigo, Pink, Purple, Brown, Gray, Rose, plus Custom [VERIFIED: RemindersUICore strings] | `cgColor` rw | `color` rw (text) | `ColorEntity` (r,g,b,a) | `calendar-color` [INFERENCE] |
| Icon/badge | SF-symbol emblem or emoji (`badgeEmblem`) | ✗ | `emblem` rw | `ListBadgeEntity(emblem, emoji)` | ✗ |
| Type (Standard/Groceries) | Groceries auto-sorts items into category sections: Produce, Meat, Dairy, Eggs & Cheese, Frozen Foods, Bakery, … [VERIFIED: ReminderKit strings]; extra grocery language setting | ✗ | ✗ | `ListType{standard,groceries}` rw | ✗ |
| Auto-Categorize (Apple Intelligence sections) | macOS 26+; File > Auto-Categorize; can't be combined with grocery categorization; not for groups | ✗ | ✗ | `UpdateListAutoCategorizeAppIntent` | ✗ |
| Pinned | Limit of 9 pinned + standard smart lists combined; Cmd-1…9 [DOCS]; a pinned list can't be moved into a group [VERIFIED string] | ✗ | ✗ | `UpdateListIsPinnedAppIntent` | ✗ |
| Layout list/columns | Columns are the list's sections; unsectioned reminders go to "Others"; Hide Empty Columns; **not** available for standard smart lists or groups [DOCS] | ✗ | ✗ | `ListLayout{list,columns}` | ✗ |
| Sort style | default, manual, displayDate oldest/newest, priority lowest/highest, creationDate oldest/newest, title asc/desc [VERIFIED enum]. Dragging switches to Manual. Per list; syncs to own devices but not to other participants of a shared list [DOCS] | ✗ | ✗ | `UpdateListSortingStyleAppIntent` | ✗ |
| Manual reminder order | `reminderIDsMergeableOrdering` (on the list) | ✗ | ✗ | Only `position{top,bottom}` when moving; no arbitrary index | `X-APPLE-SORT-ORDER` [UNVERIFIED] |
| Show/hide completed | Per list | ✗ | ✗ | `UpdateListShowsCompletedAppIntent` | ✗ |
| Sidebar list order | `listIDsMergeableOrdering` (on the account) | ✗ | ✗ | ✗ | — |
| Move list to another account | Not supported anywhere [VERIFIED string + DOCS] | ✗ | ✗ | ✗ | — |
| Default list | Set in Settings | `defaultCalendarForNewReminders()` read-only | `default list` read-only | `GetDefaultListAppIntent` (not discoverable) | — |
| Sharing | Via Mail/Messages; invite permission options; per-participant Remove; Stop Sharing; notify on added/completed; upgraded iCloud only [DOCS share page] | ✗ | ✗ | `ListEntity.participants/owner` **read-only** | (CalDAV sharing n/a) |
| Convert to Smart List | Reminders get tagged with the list name and moved to the default list; subtasks get flattened; not allowed for shared or default lists [DOCS] | ✗ | ✗ | ✗ | ✗ |

### 2.2 List groups

- **What they are:** a `REMCDList` with `isGroup=1` and `childLists`.
- **UI:** create from a selection or by dragging a list onto a list; Rename; Open in New Window; Delete with "Keep Lists" or delete lists too; clicking a group shows all its lists' reminders [DOCS [organize](https://support.apple.com/guide/reminders/organize-reminder-lists-remnee767c58/mac)].
- **Restrictions:**
  - Reminders can't be inserted into a group directly [VERIFIED string].
  - No column view [DOCS].
  - Nesting depth isn't stated anywhere. The model has a single `parentList`, so probably one level [INFERENCE].
- **Shared lists in groups (conflicting):** the guide summary says shared lists can't be grouped, but strings mention "shared lists in this group", plus "The list cannot be added to groups" [VERIFIED]. Maybe lists shared *with* you are excluded [UNVERIFIED].
- **EK:** none. Lists inside a group appear as plain `EKCalendar`s. Whether the group itself appears as a calendar is unknown [UNVERIFIED].
- **AS:** a list's `container` is either an account or a list (the group), read-only [VERIFIED].
- **AI:** `CreateGroupAppIntent(name,lists)`, `UpdateGroup*` (name, lists, parent via `UpdateListParent`), `DeleteRemindersListGroupsAppIntent(deleteSublists)`, `GroupEntity.showsCompleted`.

### 2.3 Sections

- **Where they exist:** in lists, in the Today smart list (Morning/Afternoon/Tonight, reorderable via File > Edit Sections), and in custom smart lists (`REMCDSmartListSection`; the "Parent list or smart list to add the new section to" string) [VERIFIED + DOCS [sections](https://support.apple.com/guide/reminders/manage-sections-in-reminder-lists-remn14bf0e77/mac)].
- **UI:** New Section (⌥⌘N), New Section with Selection (⌃⌘N), Move to Section, rename, collapse.
- **Deleting:** in the UI, deleting a section deletes its reminders [DOCS]. The App Intent has a `deleteReminders` flag.
- **"Others":** a pseudo-section that can't be renamed [VERIFIED].
- **Storage:** membership is stored **on the list** (`membershipsOfRemindersInSectionsAsData`), not on the reminder [VERIFIED model]. So EventKit edits to a reminder probably keep its section. Moving it to another calendar via EventKit probably drops it [INFERENCE].
- **EK:** none. DTS confirmed there's no way to get sections or groups ([forum 820848](https://developer.apple.com/forums/thread/820848), Apr 2026) [DOCS].
- **AS:** none.
- **AI:** `CreateSectionAppIntent`, `UpdateSectionAppIntent(name,isCollapsed)`, `DeleteSectionsAppIntent(deleteReminders)`, `ReminderEntity.section` read, `UpdateReminder(section)` write, `MoveReminders(... targetType=section)`.

### 2.4 Smart lists

**Built-in** (`SmartListType` enum: today, scheduled, all, flagged, assigned, urgent, completed [VERIFIED]):

| List | Semantics |
|---|---|
| Today | Due today **plus all overdue** [DOCS]. Top-level sections are Overdue, All-Day and Timed; timed items are grouped Morning/Afternoon/Tonight when View > **Group by Time** is on [VERIFIED menu; BLOG [9to5Mac](https://9to5mac.com/2025/04/10/my-favorite-ios-18-upgrade-for-apples-reminders-app-is-tiny/), [512pixels](https://512pixels.net/2023/08/another-plea-to-the-reminders-team/)]. Dropping into a section sets the time to Morning 9:00, Afternoon 15:00, Tonight 18:00 (Night 21:00) [VERIFIED: ReminderKit `TIME_OF_DAY_CREATION_*`; FORUM Apple Community]. Section order is changeable since iOS 18 / macOS 15 [BLOG]. The "Show all-day reminders as overdue" setting affects overdue status [DOCS]. |
| Scheduled | Has a due date, grouped by date. Dragging to another date reschedules [DOCS]. |
| All | Every account, grouped by list [DOCS]. |
| Flagged | Flagged reminders. |
| Completed | All completed reminders. Has a "Clear" bulk-delete action [DOCS]. |
| Assigned | Assigned to me in shared lists. |
| Urgent | Marked urgent (new in 26.2 / 27) [VERIFIED enum + `SMART_LIST_URGENT_TITLE`; semantics INFERENCE]. |
| Recently Deleted | Not a SmartListType. Since iOS 18 / macOS 15; 30 days (purge can take up to 40); Recover, Delete, Delete All; can't drag into smart lists [DOCS [delete](https://support.apple.com/guide/reminders/delete-reminders-remna83c9566/mac); BLOG [Macworld](https://www.macworld.com/article/2508673/how-to-restore-reminders.html)]. |
| Siri Suggestions / "Siri Found in Apps" | Strings exist [VERIFIED]; current semantics [UNVERIFIED]. |
| Tags browser | "All Tags"; click a tag to include, click again to exclude (crossed out); All Selected / Any Selected; "untagged only" [DOCS [tags](https://support.apple.com/guide/reminders/tag-reminders-remn45640f4f/mac)]. |

- Show/hide built-ins via View > Show Smart List.
- Today, Flagged and Assigned can be sorted like lists.
- No column view for built-ins.
- No subtask creation in Today, Scheduled, Flagged or custom smart lists [DOCS].

**Custom smart lists** (filters, [VERIFIED: `Reminders.app/.../en.lproj/TTRMListDetailFilterEditor.strings`] + [DOCS](https://support.apple.com/guide/reminders/create-custom-smart-lists-remnfec66479/mac)):
- **Tags:** Any Tag / Any Selected / All Selected / Untagged Reminders Only.
- **Date:** Any / No Date / Today / On Date / Before a Date / After a Date / Specified Range / Relative Range (In the Next or In the Past × N Hour/Day/Week/Month/Year), plus "Include Past Due".
- **Time:** Any / No Time / Morning / Afternoon / Evening / Night. Windows are Morning 6–12, Afternoon 12–17, Evening 17–21, Night 21–6 [VERIFIED: ReminderKit `CUSTOM_SMART_LIST_*_HOUR`].
- **Location:** No Location / Specific (Arriving or Leaving).
- **Flag:** Flagged / Not Flagged.
- **Priority:** Any / No / Low / Medium / High.
- **Lists:** Include or Exclude selected.
- **Match:** all or any.
- **Requirements and limits:** iCloud list required; some filters can't be viewed on macOS 12 / iOS 15 and earlier.
- **EK / AS:** none.
- **AI:** `CreateCustomSmartListAppIntent(name)` only. It takes **no filter parameters** and opens the app. Filters (`filterData`) can't be read or written. `UpdateSmartList(isHidden)` applies to system smart lists ("Show/Hide Reminders System Smart List") [VERIFIED].

### 2.5 Reminder fields

| Field | Details | EK | AS | AI | CalDAV |
|---|---|---|---|---|---|
| Title | Rich `titleDocument` | `title` (plain) | `name` | title | SUMMARY |
| Notes | Rich text: Bold, Italic, Underline, Bulleted/Dashed/Numbered list (Edit > Font / Bullets and Numbering) [VERIFIED MainMenu.nib]; capability `supportsTextStyling` | `notes` plain. Writing it likely flattens the styling [INFERENCE] | `body` plain | `note` | DESCRIPTION |
| URL | URL attachment (`REMCDURLAttachment`) | **`EKCalendarItem.URL` is a different field: Reminders never shows it, and it reads nil for URLs set in the UI** [FORUM [739541](https://developer.apple.com/forums/thread/739541), [128140](https://developer.apple.com/forums/thread/128140), [Mailbutler](https://feedback.mailbutler.io/board/p/creating-task-in-apple-reminders-writes-link-to-notes--), [falconbradley](https://github.com/falconbradley/claude-connector-apple-reminders)] | ✗ | `urls` rw | URL |
| App link-back (Mail, Safari, Maps, FaceTime callback) | `userActivity` [DOCS [add from another app](https://support.apple.com/guide/reminders/add-a-reminder-from-another-app-remn1f735fdc/mac)] | ✗ | ✗ | ✗ (private `REMUserActivity`) | ✗ |
| Images / attachments | Photos, Continuity camera/scan/sketch; File/Audio attachment entities exist in the model (audio has `transcribedText`; UI not confirmed) [VERIFIED model] | ✗ | ✗ | `images` rw | ✗ |
| Priority | Low/Med/High show as !/!!/!!! [DOCS]. Scale: 0 none, 1–4 high, 5 medium, 6–9 low [VERIFIED sdef]. Write 1/5/9. | `priority` | `priority` | `PriorityLevel{none,low,medium,high}` | PRIORITY (same RFC 5545 scale) |
| Flag | — | ✗ ([udondan#63](https://github.com/udondan/reminders-cli/issues/63)) | `flagged` rw | `isFlagged` rw | ✗ [INFERENCE] |
| Tags | Typing `#word` inline in the title or notes converts it to a tag; multi-word tags use - or _; suggestions are shared with Notes; Rename merges; Delete leaves the text plain [DOCS] | **Invisible** (Apple engineer: "not currently possible to view, modify, or add tags… through EventKit", [683921](https://developer.apple.com/forums/thread/683921)). Writing "#x" into the title or notes via EK does **not** create a tag [FORUM; INFERENCE]. | ✗ | `tags` on Create/Update; `AddOrRemoveTagsAppIntent` (opens app); `ReminderEntity.tags` read; no rename/delete intent | ✗ |
| Subtasks | **One level only** ("Nested subtasks is unsupported" [VERIFIED]); indent ⌘], outdent ⌘[; drop onto a reminder; completing/deleting/moving a parent cascades [DOCS [subtasks](https://support.apple.com/guide/reminders/add-subtasks-to-reminders-remn32a9622b/mac)] | **Flattened**: subtasks appear as ordinary reminders in the same calendar with no parent info. DTS: "EventKit doesn't have an API… to retrieve the subtask" [DOCS forum 820848]. The `parentReminder` property claimed in [iMCP#145](https://github.com/mattt/iMCP/issues/145) does not exist in public headers [VERIFIED]; any runtime property would be private. | `container` read-only = parent reminder | `parent`, `isSubtask`, `subtasks` read; `parentReminder`/`subtasks` on Create; `UpdateReminder(parent)`; `MoveReminders(targetType=parentReminder)`; Complete/Delete have a `*Subtasks` flag | RELATED-TO shows flat |
| Due date / time | Date-only = all-day; optional time; per-reminder time zone [DOCS]. "Time Zone Override" (`RemotePreferencesEntity.timeZoneOverride`, read-only) [VERIFIED] | `dueDateComponents` (no hour = all-day), `timeZone` (nil = floating), `startDateComponents` (no UI) | `due date`, `allday due date`, `remind me date` | `dueDate`, `isAllDay` | DUE/DTSTART |
| Notification at due time | Reminders creates a date alarm | Add an `EKAlarm` (absolute, or relative 0). A due date alone doesn't notify [FORUM [Don-Works PR#1](https://github.com/Don-Works/reminders-mcp/pull/1)] | `remind me date` | implicit | VALARM |
| Early Reminder | Minute/hour/day/week/month × count, or Custom; needs a date; stored as `dueDateDeltaAlerts`, **separate from alarms** [VERIFIED model + strings] | ✗ ([RemCTL/MacStories](https://www.macstories.net/stories/introducing-remctl-the-power-user-reminders-cli-for-macos-and-ai-agents/): private only) | ✗ | `earlyAlert` (`EarlyAlertEntity` unit+interval) | ✗ |
| Urgent (AlarmKit alarm) | iOS 26.2+; alarm rings only on the device Find My uses as your location (iPhone/iPad); breaks through silent mode and Focus; Mac can set the flag; iCloud only [DOCS dates page; BLOG [9to5Mac](https://9to5mac.com/2025/11/04/ios-26-2-alarms-and-timers-in-reminders/)]; menu "Mark as Urgent" [VERIFIED nib] | ✗ (`urgentPresentationAlarms` separate) | ✗ | `isUrgent` rw | ✗ |
| Repeat | Presets: Never, Hourly, Daily, Weekdays, Weekends, Weekly, Biweekly, Monthly, Every 3 Months, Every 6 Months, Yearly, Custom [VERIFIED ReminderKit strings]. Custom: hourly/daily/weekly (+days)/monthly (each N, or first…fifth/last day/weekday/weekend day/<weekday>)/yearly (+months, on the…). End Repeat: Never / On Date; an occurrence-count string also exists [VERIFIED] | `EKRecurrenceRule` covers everything **except Hourly** (no frequency) [VERIFIED]; raw value >3 is stored as DAILY [FORUM Don-Works]. Completing a recurring reminder splits off a completed copy [FORUM]. | ✗ | `recurrence` (`RecurrenceRule` type); delete options `{thisReminder, allFutureReminders}`; "future repeating reminder… can only edit the current" [VERIFIED] | RRULE |
| Location | Arriving/Leaving + adjustable radius; suggestions from your Contacts card [DOCS] | `EKAlarm.structuredLocation` (+radius) + `proximity` enter/leave [VERIFIED headers]. `EKReminder.location` string isn't persisted [FORUM] | ✗ | `locationTrigger` (`LocationTriggerEvent{arrive,depart}`) | VALARM + X-APPLE-STRUCTURED-LOCATION [INFERENCE] |
| Getting in / out of car | Paired car; `REMCDAlarmVehicleTrigger` | ✗ (a hidden alarm subtype: rewriting `alarms` may remove it [INFERENCE]) | ✗ | `VehicleTrigger{connected,disconnected}` | ✗ |
| When Messaging a person | `contactHandles` | ✗ | ✗ | `contactPerson` | ✗ |
| Assignee | Shared iCloud lists only; Assign/Reassign/Remove; notifies the assignee [DOCS [assign](https://support.apple.com/guide/reminders/assign-shared-reminders-remnf1ce7672/mac)] | ✗ | ✗ | `assignedPerson` rw | ✗ |
| Completed | — | `isCompleted`, `completionDate` | rw | `CompleteReminderAppIntent(completeSubtasks)` | STATUS/COMPLETED |
| Created / modified | — | `creationDate`, `lastModifiedDate` (read-only) | read-only | read-only | CREATED/LAST-MODIFIED |
| Move between lists | — | set `.calendar` (effect on section and parent unknown); "Cannot remove subtasks and change list simultaneously" [VERIFIED] | Standard Suite move [UNVERIFIED] | `UpdateReminder(list)`, `MoveReminders(position top/bottom)` | — |
| Delete | Goes to Recently Deleted | `removeReminder` (whether it lands in Recently Deleted: [UNVERIFIED]) | delete | `DeleteRemindersAppIntent(deleteSubtasks, deleteRecurringReminders)`, needs unlock | — |
| Snooze | Notification "Later" menu: Remind Me in 1 Hour / at <time> / Tomorrow (at <time>) / Next Weekend; Mark as Completed; Ignore [VERIFIED ReminderKit strings] | Change the alarm yourself | ✗ | `SnoozeRemindersAppIntent(nextTriggerTime)` (not discoverable) | — |

### 2.6 Templates

- **Saving:** File > Save as Template, optionally including completed items. Not possible for standard smart lists. Templates made from shared or smart lists are just snapshots. Grocery lists become standard [DOCS [templates](https://support.apple.com/guide/reminders/use-reminder-list-templates-remn29caf6e1/mac)].
- **Using:** View Templates, then Create List. You can edit, rename, delete and reorder templates, and edit their Template Info (color/icon).
- **Sharing:** Share Template creates a public link. You choose whether to include dates, times, tags and locations; images are never included. Manage Link / Stop Sharing. Recipients get a copy.
- **Requirements:** macOS 13+ / iOS 16+, upgraded iCloud.
- **EK / AS / AI:** none (there are no template intents).

### 2.7 Apple Intelligence (WWDC25 → WWDC26)

- **macOS 26:**
  - **Suggested reminders:** share content to Reminders and Apple Intelligence extracts action items. "Include All" / per-item add [DOCS [AI page](https://support.apple.com/guide/reminders/use-apple-intelligence-in-reminders-mchl979b81e9/mac)].
  - **Auto-Categorize:** sorts reminders into sections. Turning it off asks whether to keep the sections.
- **macOS / iOS 27:**
  - **"Describe a reminder":** natural-language entry with AI-filled metadata. The local string reads "Title or Describe Reminder" [VERIFIED; BLOG [9to5Mac](https://9to5mac.com/2026/09/29/heres-everything-new-for-reminders-in-ios-27/), [MacRumors](https://www.macrumors.com/guide/ios-27-calendar-reminders/)].
  - **Quick bar:** the inline metadata box gains Time, Urgent and Repeat (iOS).
  - **Grocery sorting:** more accurate, and works in more languages.
  - **New Shortcuts actions:** Create/Delete Group, List, Section. "Get What's On Screen" works with Reminders.
  - **Siri:** can search reminders.
  - **Visual Intelligence:** integrates with Reminders.
  - **Widget:** extra-large 4×6 "Reminders: List" on iPhone [BLOG [9to5Mac widgets](https://9to5mac.com/2026/06/22/ios-27-adds-brand-new-widgets-for-your-iphones-home-screen/)].
- **Non-AI suggestion features:** suggested date/time/list/tag/priority/location/"When Messaging"; autocompletion from completed reminders (the "Show Suggestions" setting) [VERIFIED strings; DOCS].
- **Unconfirmed strings:** "Shopping mode" (Start Shopping, "Now shopping in %@", AirPod checks) exists in RemindersUICore, but no public documentation confirms it [VERIFIED strings / UNVERIFIED feature].
- **API access:** none of this is in EK or AS. AI: `UpdateListAutoCategorize` and list `type` only.
- **For our app:** the public `FoundationModels` framework is in the SDK, so we can rebuild "describe" parsing and categorization ourselves [VERIFIED SDK].

### 2.8 Mac UI surface

**Menus** [VERIFIED: `Base.lproj/MainMenu.nib` strings]:
- **File:** New Reminder, New List, New Section, New Section with Selection, New Group, Create Smart List, Convert to Smart List, Save as Template, View Templates, Share List, Manage Shared List, Auto-Categorize, Edit Sections, Print.
- **Edit:** Mark as Completed, Flag, Priority (None/Low/Medium/High), Urgent / Mark as Urgent, Mark Due Date As (Today, Tomorrow, This Weekend, Next Week), Mark All Overdue to Today, Indent/Outdent Reminder, Assign, Add Tag, Move to Section, Show Info, Font (B/I/U), Bullets and Numbering, Spelling, Substitutions, Transformations, Speech.
- **View:** as List / as Columns, Sort By, Group by Time, Show Completed, Show All Subtasks / Hide All Subtasks, Show Sidebar, Show Smart List, Go To, Tags, Enter Full Screen.
- **Help:** Creating Smart Lists, Using Tags.

**Keyboard shortcuts** [DOCS [shortcuts](https://support.apple.com/guide/reminders/keyboard-shortcuts-remn19b3424c/mac), macOS 27]:

| Action | Keys |
|---|---|
| New reminder | ⌘N |
| New list | ⇧⌘N |
| New section | ⌥⌘N |
| New section from selection | ⌃⌘N |
| Go to pinned list | ⌘1…9 |
| Indent / outdent | ⌘] / ⌘[ |
| Show all / hide all subtasks | ⌘E / ⇧⌘E |
| Flag | ⇧⌘F |
| Print | ⌘P |
| Sidebar | ⌥⌘S |
| Complete | ⇧⌘C |
| Show/hide completed | ⇧⌘H |
| Delete tag | Delete |
| Due today | ⌘T |
| Due tomorrow | ⌥⌘T |
| All overdue → today | ⌃⌘T |
| This weekend (next weekend if today is the day before) | ⌘K |
| Next week | ⌥⌘K |
| Full screen | ⌃⌘F |
| Close / Quit | ⌘W / ⌘Q |

**Other surfaces:**
- **Settings** [DOCS [settings](https://support.apple.com/guide/reminders/change-reminders-settings-remn4a9a4fe6/mac)]: Default List, Today Notification time (for all-day items), Show all-day reminders as overdue, Badge Count (overdue + today), mute assigned-reminder notifications, Show Suggestions, grocery additional language, Reset Grocery Categories.
- **Notifications:** banners or alerts; Options menu holds the snooze choices and Complete; before an early reminder fires, only "Mark as Completed" is offered [DOCS [notifications](https://support.apple.com/guide/reminders/manage-notifications-remn4e53b572/mac)].
- **Widgets:** desktop and Notification Center; per-widget list and size; interactive completion through `TTRReminderSetCompletedIntent(reminder,isCompleted,isFromUrgentReminderActivity)` [VERIFIED widget appex; DOCS [widgets](https://support.apple.com/guide/reminders/use-reminders-widgets-remn83e1a96e/mac)].
- **Siri:** Reminders implements SiriKit `INAddTasksIntent`, `INCreateTaskListIntent`, `INDeleteTasksIntent`, `INSearchForNotebookItemsIntent`, `INSetTaskAttributeIntent`, `INSnoozeTasksIntent` [VERIFIED IntentsExtension Info.plist].
- **Spotlight:** a Spotlight index extension [VERIFIED PlugIns]; Spotlight "New Reminder"/"nr" quick action [DOCS].
- **Quick Reminder:** the strings "Show Quick Reminder — Opens the Quick Reminder view" exist [VERIFIED; behavior UNVERIFIED].
- **Handoff:** activity type `com.apple.reminders.activity.list` [VERIFIED].
- **Deep link:** URL scheme `x-apple-reminderkit://REMCDReminder/<UUID>` (undocumented) [VERIFIED scheme in Info.plist; FORUM [Hookmark](https://discourse.hookproductivity.com/t/is-reminders-app-linkable/2397/8)].
- **Print:** HTML print template [VERIFIED `RemindersUICore/.../reminder-printing-template.html`].
- **Calendar app:** shows scheduled reminders [DOCS].
- **Drag and drop:**
  - reminders between lists (move), onto a reminder (subtask), into sections or columns, onto Scheduled dates (reschedule);
  - lists onto lists (creates a group);
  - from Recently Deleted to a list (recover) [DOCS].
- **iCloud.com:** no tags and no smart lists [BLOG].

---

## 3. AppleScript summary (sdef)

**Access groups** for the `scripting-targets` entitlement [VERIFIED]:
- application / account: `com.apple.reminders.read-write`, `com.apple.reminders.read`
- list: `com.apple.reminders.List.read-write`
- reminder: `com.apple.Reminders.read-write`, `com.apple.Reminders.read` (note the capital "R")
- show: `com.apple.Reminders.UI`
- App bundle id: `com.apple.reminders`.

**Readable / writable fields:**
- list: name, color, emblem (rw); id and container (read-only).
- reminder: name, body, completed, completion date, due date, allday due date, remind me date, priority, flagged (rw); container (list or parent reminder), creation date, modification date (read-only).

**Not available:** tags, sections, groups (beyond container), URLs, images, early reminders, urgent, location, recurrence, assignees, smart lists, templates.

**Relevance:** the only public route for **flags** and **emblems**, and a read-only way to see **subtask parents** and **group membership**. Bridging AppleScript `id` to EventKit `calendarItemIdentifier` is untested [UNVERIFIED].

---

## 4. Does editing through EventKit keep the extra attributes?

All of this is [INFERENCE] from the data model; none of it has been tested.

**Probably preserved:**
- Tags (a separate `REMCDHashtag` relation), flagged (its own column), parent link (a relation), section membership (stored on the list), attachments (separate entities), early reminders and urgent (separate data), assignment (`REMCDAssignment`).
- Reason: EventKit sits on ReminderKit and saves field by field. Community tools that mix EventKit writes with ReminderKit writes report no data loss ([falconbradley](https://github.com/falconbradley/claude-connector-apple-reminders)). Apple doesn't document this either way.

**At risk:**
1. **Notes rich text.** Writing `notes` likely flattens `notesDocument`.
2. **Hourly recurrence.** EventKit can't represent it; rewriting `recurrenceRules` would destroy it. How EventKit even *reads* an hourly rule is unknown.
3. **Vehicle triggers.** They are an alarm-trigger subtype; replacing `alarms` may drop them.
4. **Moving a reminder to another calendar.** May drop its section, break the parent link, or change its identifier.
5. **Cascades.** Completing or deleting a parent through EventKit probably does **not** cascade to its subtasks, unlike the UI and the App Intents flags.
6. **Recently Deleted.** Whether `removeReminder` sends items to Recently Deleted is unknown.

---

## 5. Mapping to Apple Reminders backend

Column meanings:
- **EK-native:** works through public EventKit.
- **Alternate path:** AppleScript (AS) or a user-installed Shortcut calling Reminders' App Intents (SC).
- **App-local metadata only:** our own store; does not sync into Reminders.
- **Not feasible:** no public path; "private" means only the private ReminderKit framework could do it (not App Store safe).

| Feature | Reminders/EventKit-native (public API) | Needs alternate path (AppleScript/Shortcuts) | App-local metadata only | Not feasible |
|---|---|---|---|---|
| Accounts/sources list | ✓ `sources`, `EKSource` | SC `AccountEntity` + capabilities matrix | — | — |
| Create/rename/delete list | ✓ | SC (create with type/group) | — | — |
| List color | ✓ CGColor | AS / SC | — | — |
| List emblem/emoji | — | AS `emblem`, SC badge | fallback | — |
| List type Groceries | — | SC create/update `type` | — | grocery categorization logic (Reminders-internal) |
| Auto-Categorize toggle | — | SC | own FoundationModels categorizer | Apple's section suggestions |
| Pin list | — | SC `UpdateListIsPinned` | — | — |
| List groups CRUD | — | SC Create/Update/Delete Group; AS read container | — | — |
| Sidebar list order | — | — | ✓ | sync to Reminders order (private) |
| Move list across accounts | — | — | — | ✗ (unsupported anywhere) |
| List sort style | — | SC read/write | ✓ (own view sort) | — |
| Column/kanban layout | — | SC `listLayout` (Reminders' setting) | ✓ own board UI over SC sections | — |
| Show/hide completed per list | — | SC | ✓ | — |
| Manual reminder order | — | SC top/bottom only | ✓ | sync of arbitrary order (private) |
| Sections CRUD / collapse / move into | — | SC | — | — |
| Sections in Today / custom smart lists | — | SC (create in smart list) [UNVERIFIED] | ✓ | — |
| List sharing / participants | — | SC read-only participants/owner; AS `show`/deep link to hand off | — | ✗ create/modify sharing |
| Assign reminder | — | SC `assignedPerson` | — | — |
| Default list | ✓ read | SC read | — | set (private / Settings only) |
| Built-in smart lists (Today incl. overdue, Scheduled, All, Flagged, Completed) | ✓ compute via predicates (flag via AS/SC) | flags via AS/SC | ✓ view logic (group by time 6/12/17/21 windows) | — |
| Assigned / Urgent smart lists | — | SC reads (`assignedPerson`, `isUrgent`) | ✓ compute | — |
| Hide system smart lists | — | SC `isHidden` (Reminders' own UI) | ✓ | — |
| Custom smart lists (filters) | — | SC create by name only | ✓ own filter engine | ✗ read/write Reminders' `filterData` |
| Convert list to smart list | — | — | ✓ emulate (tag + move via SC) | — |
| Recently Deleted browse/recover | — | — | ✓ own undo / trash | ✗ |
| Title / notes (plain) | ✓ | — | — | rich-text styling (private) |
| URL attachment | ✗ (`EKCalendarItem.URL` not shown) | SC `urls` | — | — |
| App link-back (userActivity) | — | — | — | ✗ (private) |
| Images | — | SC `images` add/read | — | file/audio attachments |
| Priority | ✓ (1/5/9) | — | — | — |
| Flag | — | AS / SC | — | — |
| Tags add/remove/read | — | SC (`UpdateReminder.tags`, AddOrRemove) | — | — |
| Tag rename / delete / merge | — | SC batch emulation (slow) [INFERENCE] | ✓ | native rename (private) |
| Inline `#tag` conversion | — | SC after parsing | ✓ parser | EK text doesn't become a tag |
| Subtasks (1 level) | ✗ (flat) | SC parent/subtasks/move; AS read parent | — | — |
| Due date / all-day / time zone | ✓ | — | — | — |
| Start date | ✓ (no Reminders UI) | — | — | — |
| Alarms (absolute/relative) | ✓ `EKAlarm` | — | — | — |
| Early Reminder | — | SC `earlyAlert` | — | — |
| Urgent alarm | — | SC `isUrgent` | — | firing alarms ourselves (AlarmKit is iOS-only [UNVERIFIED for macOS]) |
| Repeat (daily…yearly, custom, end date/count) | ✓ `EKRecurrenceRule` | SC `recurrence` | — | — |
| Hourly repeat | — | SC `recurrence` [UNVERIFIED] | — | ✗ via EK |
| Location arrive/leave + radius | ✓ `EKAlarm.structuredLocation/proximity` | SC | — | — |
| Getting in/out of car | — | SC `vehicleTrigger` | — | — |
| When Messaging a person | — | SC `contactPerson` | — | — |
| Complete / uncomplete (+subtasks) | ✓ (no cascade) | SC `completeSubtasks` | — | — |
| Delete (+subtasks, recurring scope) | ✓ basic | SC flags (needs unlock) | — | — |
| Move reminder to list | ✓ `.calendar` | SC (keeps section/parent semantics) | — | — |
| Reschedule (drag to date) | ✓ | — | ✓ UI | — |
| Snooze | ✓ edit alarm/due | SC Snooze (not discoverable) | — | Reminders notification actions themselves |
| Templates (save/create/edit) | ✓ instantiate via EK+SC | — | ✓ own template store | ✗ Reminders' templates |
| Public template links | — | — | — | ✗ |
| Apple Intelligence suggest / describe | — | — | ✓ FoundationModels + share extension | Apple's own pipeline |
| Notifications | ✓ (Reminders delivers EK alarms) | — | own extra notifications (risk of duplicates) | intercepting Reminders' notification actions |
| Widgets | ✓ data via EK | SC for extras | ✓ own WidgetKit | Reminders' widgets |
| Siri/Shortcuts | — | — | ✓ own App Intents | invoking Reminders' intents directly (no public API) |
| Spotlight | — | — | ✓ CoreSpotlight + App Intents | — |
| Print | — | — | ✓ NSPrintOperation | — |
| Open in Reminders | — | AS `show`; `x-apple-reminderkit://` (undocumented) | — | — |
| Settings (Today notification time, all-day overdue, badge) | — | — | ✓ | changing Reminders' own settings |
| Change notifications | ✓ `EKEventStoreChangedNotification` | — | — | — |

---

## 6. Open questions (need on-device tests with a throwaway iCloud account)

1. **IDs:** how EK `calendarItemIdentifier` / `calendarItemExternalIdentifier`, AppleScript `id`, App Intents `ReminderEntity` id and the `x-apple-reminderkit` UUID relate. This is essential for any hybrid design.
2. **Groups:** does a list group show up in `calendars(for:.reminder)`? Do Recently Deleted items or custom smart lists ever appear in EK fetches?
3. **Hourly repeats:** what EK returns for an hourly reminder, and whether saving that reminder through EK (without touching its recurrence) keeps the rule.
4. **Preservation:** confirm §4. Do EK saves keep tags, flag, parent, section, rich notes, early reminder, urgent and vehicle alarms? What does moving `.calendar` do to section and parent?
5. **Cascades:** EK `removeReminder` on a parent: are subtasks orphaned or deleted? Does the item go to Recently Deleted?
6. **Grocery lists:** do items added through EK get auto-categorized?
7. **Shortcuts from a sandboxed app:** can it call `/usr/bin/shortcuts run`, or must it use `shortcuts://`? How fast is it, does it steal focus, and can shortcuts be distributed and installed programmatically?
8. **Shared lists:** are tags supported on shared lists? Can owned shared lists be put in groups (the docs and strings conflict)?
9. **Group nesting:** confirmed depth (model suggests one level).
10. **Text styling:** is it macOS-only? Is the End Repeat occurrence count exposed in the Mac UI?
11. **Urgent alarms:** does the alarm ever ring on the Mac in 27.x, or only on the Find My device?
12. **macOS 27 changes:** what is Mac-specific (Mac guide 7.0 lists no "what's new")? Is shopping mode real?
13. **Other accounts:** per-provider capability values for Exchange, CalDAV and local accounts. Read them at runtime via the `AccountCapabilities` entity.
14. **EventKit write limits:** does writing EK `priority` values other than 1, 5 or 9 render consistently? Is `startDateComponents` respected by Reminders?
15. **Shared entities:** could the WWDC26 cross-app "entity sharing" (session 345) give a third-party app public access to Reminders entities?