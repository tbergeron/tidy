# Accessing Apple Reminders features that EventKit doesn't expose, from a third-party macOS Swift app (macOS 27.2 / SDK 27.0, 2026-10-21)

## 0. Key findings

1. **Public SDK reality.** EventKit is the only public read/write API. macOS 27 adds no Reminders-specific public API. The new `AppSchema.reminders` domain (CreateList / CreateReminder / CreateSection / DeleteReminders / UpdateReminder intents; Group / List / Reminder / Section / LocationTrigger entities) only lets *our* app adopt the schemas so Siri and Apple Intelligence can route to it. It cannot call Apple's Reminders. `RunSystemShortcutIntent` / `SystemShortcut` are iOS 27 only (macOS unavailable). There is no public way on macOS to invoke another app's App Intents. [VERIFIED: `…/MacOSX.sdk/System/Library/Frameworks/AppIntents.framework/…/arm64e-apple-macos.swiftinterface` ~L11718–11900, L3638, L5112]
2. **On macOS, EventKit reminders sit on top of ReminderKit.** `EKReminder.backingObject` holds a `REMReminder`. Ivar `_remObject` is used by go-eventkit; reminders-menubar reaches it through the `_reminder` selector, so the name drifts between code bases. remindd contains `REMEventKitBridgingDataViewInvocation_*` and `REMStoreModeEventKitSync`. Its access level is "inferred from TCC". So private ReminderKit calls need **no private entitlement**, only Reminders full access. [VERIFIED: `strings /usr/libexec/remindd`; `dyld_info -exports …/ReminderKit`; code in go-eventkit and reminders-menubar below]
3. **Private writes work from a sandboxed app.** reminders-menubar's sandbox build (only `app-sandbox` + `personal-information.calendars`) writes tags, flagged and urgent through `REMSaveRequest`, using the store EventKit already owns (`REMReminder.store`).
   - The app sandbox profile does **not** allow mach-lookup to `com.apple.remindd`; the calendars entitlement only grants `com.apple.CalendarAgent`.
   - So a fresh `[REMStore new]` inside the sandbox may fail. Reuse EventKit's store instead. [VERIFIED: `/System/Library/Sandbox/Profiles/appsandbox-common.sb:549`, `application.sb:153`; [reminders-menubar EKReminder+Extensions.swift](https://github.com/DamascenoRafael/reminders-menubar/blob/master/reminders-menubar/Extensions/EKReminder%2BExtensions.swift), [entitlements](https://github.com/DamascenoRafael/reminders-menubar/blob/master/reminders-menubar/reminders_menubar.entitlements); the store-reuse point is INFERENCE]
   - App Store guideline 2.5.1 (public APIs only) still applies: no private ReminderKit in a Mac App Store build.
4. **AppleScript is too slow for bulk reads.** Each Apple Event takes 3–4 s; listing 224 reminders takes about 60 s. It also launches Reminders.app and leaves it open. It is fine for occasional targeted writes: flagged, emblem, color, `show`.
5. **Shortcuts / App Intents cover almost everything**: tags, subtasks, sections, groups, flagged, urgent, early alert, images, pinned, sort style, layout, groceries. They are driveable from a Mac App Store app via `Shortcuts Events` with the access group `com.apple.shortcuts.run`. But they need a user-installed helper shortcut, cost about 1–2 s per run, and may not be able to target a reminder by ID (open question). Treat this as an optional fallback, not a backbone.
6. **SQLite is not worth it.** It needs Full Disk Access, is impossible in the sandbox, and the schema churns a lot (20 Core Data model versions ship in ReminderKit). In-process private reads through `backingObject` give the same data without Full Disk Access.

---

## 1. Local system facts (read-only inspection)

### 1.1 Reminders App Intents metadata
Source: `/System/Library/PrivateFrameworks/RemindersAppIntents.framework/Versions/A/Resources/Metadata.appintents/extract.actionsdata` (generator xcode-tools 27A225a). 39 actions, 13 entities, 16 enums, 10 queries. [VERIFIED]

**Primitive type IDs** (my mapping, [INFERENCE]): p0 = String, p1 = Bool, p2 = Int, p7 = Double, p8 = Date, p9 = DateComponents, p10 = Placemark, p11 = URL, p12 = AttributedString(?), i3 = INPerson, i12 = IntentFile, f0 = recurrence rule.

**Entity properties** (`cap` is a property-capabilities bitmask; meaning [INFERENCE]: 1 = updatable, 2 = deferred):

| Entity | Properties |
|---|---|
| ReminderEntity (sync 1; Syncable, Collaborative, AssistantEntity, Indexed; schema `reminders.reminder`) | title p0; note p12?; images [i12]; subtasks [ReminderEntity]; **tags [String]**; urls [URL]; dueDate DateComponents?; recurrence f0?; isCompleted; **isFlagged?**; creationDate?; completionDate?; list ListEntity; **section SectionEntity?**; locationTrigger?; lastModifiedDate?; contactPerson INPerson?; **assignedPerson INPerson?**; **vehicleTrigger enum?**; **earlyAlert EarlyAlertEntity?**; **isUrgent?**; priorityLevel enum?; isSubtask Bool; **parent ReminderEntity? (cap 2)** |
| ListEntity (schema `reminders.list`) | color ColorEntity? (cap 1); badge ListBadgeEntity? (cap 1); **parent GroupEntity? (cap 1)**; name; **type ListType (standard/groceries)**; participants [INPerson]?; owner INPerson?; sections [SectionEntity]? (cap 2); **isPinned?**; showsCompleted?; autoCategorize?; **listLayout (list/columns)?**; **sortingStyle?** |
| SectionEntity | isCollapsed? (cap 1); name; list; reminders [ReminderEntity]? |
| GroupEntity | nameUpdatableProperty; name; lists [ListEntity]; showsCompleted? |
| SmartListEntity | type (today/scheduled/all/flagged/assigned/urgent/completed); isHidden? |
| EarlyAlertEntity | unit (minute/hour/day/week/month); interval Int |
| ListBadgeEntity | emblem?; emoji? |
| ColorEntity | name?, red, green, blue, alpha (Double?) |
| LocationTriggerEntity | place GeoToolbox.PlaceDescriptorEntity; event arrive/depart |
| LocationAlarmEntity | mobileSpace (default/car); event; placemark? |
| AccountEntity | name; lists; capabilities |
| AccountCapabilities | supportsSubtasks, Attachments, ListAppearance, Groups, Flagged, PersonTrigger, Location, HourlyRecurrence, Templates, ListSharees, ListShareesMutation, MoveAcrossLists, MoveAcrossSharedLists, MultipleDateAlarmsOnRecurrence, Sections, DueDateDeltaAlerts, Handoff, ReminderActions, Assignments, Hashtags, CustomSmartLists, PinnedLists, TextStyling, GroceriesList, RecentlyDeletedList, UrgentAlarm; defaultPriorityLevel |
| RemotePreferencesEntity | timeZoneOverride? |

**Enums:** SortingStyle has 10 cases: default, manual, displayDate↑/↓, priority↑/↓, creationDate↑/↓, title↑/↓. Others: PriorityLevel (none/low/medium/high), ReminderInsertionPosition (top/bottom), MoveTargetType (list/section/parentReminder), DeleteRecurringRemindersOption (thisReminder/allFutureReminders), VehicleTrigger (connected/disconnected).

**Queries:** each entity has a default query (capabilities 66, 67 or 70) with no property parameters. So there is no "find where property = …" query in this framework. The bit meanings are [UNVERIFIED].

**Actions.** `openApp = True` means the action brings Reminders.app to the foreground. "Hidden" means `isDiscoverable = false`.

| Action | Parameters → output | openApp | Hidden? |
|---|---|---|---|
| TTRCreateReminderAppIntent | title, note?, isFlagged?, images, tags, urls, dueDate?, recurrence?, locationTrigger?, list?, section?, isAllDay?, earlyAlert?, isUrgent?, vehicleTrigger?, priorityLevel?, parentReminder?, contactPerson?, assignedPerson?, subtasks [String]? → Reminder | no | |
| UpdateReminderAppIntent | target, isCompleted?, isFlagged?, title?, note?, images?, **tags?**, urls?, dueDate?, recurrence?, locationTrigger?, subtasks?, **list?**, **section?**, earlyAlert?, isUrgent?, vehicleTrigger?, contactPerson?, assignedPerson?, priorityLevel?, **parent?** → Reminder | **no** | |
| AddOrRemoveTagsAppIntent | operation, reminders, tags | **yes** | |
| MoveRemindersAppIntent | reminders, position, targetType, list?, section?, parentReminder? | **yes** | |
| MoveRemindersTo{List,Section,ParentReminder}AppIntent | reminders, position, target? | no | hidden |
| CompleteReminder(s)AppIntent | reminder(s), isCompleted, completeSubtasks | no | plural form hidden |
| DeleteRemindersAppIntent | entities, deleteSubtasks?, deleteRecurringReminders? | no | |
| SnoozeRemindersAppIntent | entities, nextTriggerTime DateComponents? | no | hidden |
| TTRCreateListAppIntent | name, type, group? | no | |
| UpdateListAppIntent | target, name?, type?, color?, badge?, parent?, propertyToUpdate | no | |
| UpdateList{AutoCategorize, Badge, Color, IsPinned, Layout, Parent, ShowsCompleted, SortingStyle}AppIntent | one property each | no | |
| DeleteListsAppIntent | entities | no | |
| CreateGroupAppIntent / UpdateGroupAppIntent / UpdateGroupNameAppIntent / DeleteRemindersListGroupsAppIntent | name, lists / name?, lists? / name / entities, deleteSublists? | no | |
| CreateSectionAppIntent / UpdateSectionAppIntent / DeleteSectionsAppIntent | list, name / name?, isCollapsed? / entities, deleteReminders | no | |
| UpdateSectionIsCollapsedAppIntent | entity, property | yes | |
| CreateCustomSmartListAppIntent | name? only — **opens the UI; no filter parameters** | yes | |
| UpdateSmartList(IsHidden)AppIntent | target, isHidden | no | |
| Open{Group, Reminder(showDetail, inSmartList), SmartList, List}, TTRSearchReminders | — | yes | some hidden |
| GetDefaultListAppIntent | requireCloudKitAccount → List | no | hidden |

Also:
- Reminders.app's own metadata has `TTROpenSmartListAppIntent`.
- The widget extension has `TTRReminderSetCompletedIntent(reminder, isCompleted, isFromUrgentReminderActivity)`.
- Assistant schema IDs: reminders.createReminder / updateReminder / deleteReminders / createList / createSection.

[VERIFIED: same file; `/System/Applications/Reminders.app/Contents/Resources/Metadata.appintents/extract.actionsdata`; `…/PlugIns/RemindersWidgetExtension.appex/…`]

**Older Shortcuts actions ("Find Reminders" / "Add New Reminder")** also expose properties: Tags, Has Subtasks, Subtasks, Parent Reminder, Is Flagged, Images, URL, List, Priority, Is Completed, Completion Date, Due Date, Has Alarms, Notes. Add New Reminder has parameters `WFTags`, `WFParentTask` and images. [VERIFIED: the strings exist in `/System/Library/PrivateFrameworks/ContentKit.framework/…/Localizable.loctable` and `WorkflowKit.framework/…/Localizable.loctable`; that they are the Find Reminders filters is INFERENCE]

### 1.2 Core Data model (Reminders storage schema)
Source: `/System/Library/PrivateFrameworks/ReminderKit.framework/Versions/A/Resources/ReminderData.momd` (current version `ReminderData_v2026_A`). [VERIFIED]

**Schema churn:** 20 model versions ship: v1–v7, 2022_C, 2023_A, 2023_minorE (Migrating/Migrated_to_ZREMCDBASELIST), 2024_minorA/C, 2025_A/C/D, 2026_A. REMCDReminder and REMCDList changed hash between 2025_D and 2026_A.

**48 entities**, including REMCDReminder, REMCDBaseList, REMCDList, REMCDSmartList, REMCDBaseSection, REMCDListSection, REMCDHashtag, REMCDHashtagLabel, REMCDAlarm, REMCDAlarmVehicleTrigger, REMCDDueDateDeltaAlert, REMCDAssignment, REMCDSharee, REMCDImageAttachment / REMCDURLAttachment, REMCDManualSortHint_v1, REMCDTemplate, REMCDSavedReminder.

**REMCDReminder attributes** include: title, titleDocument, notes, notesDocument, flagged, isUrgentStateEnabledForCurrentUser, urgentPresentationAlarmsAsData, dueDateDeltaAlertsData, parentReminder→, children→, ckParentReminderIdentifier, hashtags→, attachments→, assignments→, contactHandles, triggersContextData, displayDate*, timeZone, daCalendarItemUniqueIdentifier, ckIdentifier, markedForDeletion, list→.

**REMCDBaseList / REMCDList attributes** include: badgeEmblem, color, pinnedDate, isPinnedByCurrentUser, sortingStyle, sectionIDsOrderingAsData, membershipsOfRemindersInSectionsAsData, reminderIDsMergeableOrdering, isGroup, parentList→, childLists→, grocery fields, sharees→.

Two consequences:
- **Section membership is a blob on the list**, not a foreign key on the reminder.
- **Ordering is a mergeable blob** (CRDT-style).

### 1.3 Reminders.app bundle
- URL scheme `x-apple-reminderkit`; `NSAppleScriptEnabled`; sdef `Reminders.sdef`; activity type `com.apple.reminders.activity.list`. Bundle ID / application-identifier is `com.apple.reminders`. [VERIFIED: `plutil -p …/Info.plist`]
- Private entitlements: `com.apple.private.remindd` {debug, keepAlive, siriFoundInApps, sync, userInteractive}, `com.apple.private.tcc.allow` [kTCCServiceReminders, AddressBook], `com.apple.private.security.restricted-application-groups` [group.com.apple.reminders]. Mach lookups `com.apple.remindd` and `com.apple.remindd.userInteractive`. `com.apple.private.appintents-bundle-absolute-paths` points at RemindersAppIntents.framework. [VERIFIED: `codesign -d --entitlements -`]
- remindd says "Connection requested as UserInteractive but is missing the entitlement". So only the high-priority XPC mode is entitlement-gated; normal access is TCC-derived (`accessLevelIsInferredFromTCC`, `RDClientAccessLevelTruthSource`). [VERIFIED: strings]
- ReminderKit exports these classes: REMStore, REMSaveRequest, REMObjectID, REMReminderChangeItem; REMReminder{Hashtag, Flagged, Subtask, UrgentAlarm, DueDateDeltaAlert, Attachment, Assignment}Context(ChangeItem); REMListChangeItem; REMList{Section, Sublist, Appearance, Grocery, Sharee}ContextChangeItem; REMAccountGroupContextChangeItem; REMAccountPinnedListsContextChangeItem; REMSmartListCustomContextChangeItem; REMManualOrdering; REMEventKitBridgingDataView*. [VERIFIED: `dyld_info -exports`]
- The Shortcuts background runner can reach remindd through the `com.apple.shortcuts.access.reminder` sandbox extension. So background intents likely run in Shortcuts' runner without launching Reminders.app. [VERIFIED: `/System/Library/Sandbox/Profiles/com.apple.WorkflowKit.BackgroundShortcutRunner.sb:466`; the conclusion is INFERENCE]

### 1.4 Sandbox profile
`application.sb` L898–914:
- `scripting-targets` is enforced at the sandbox layer as `appleevent-send` to the destination bundle ID only.
- Access-group filtering is done by the target app's Cocoa Scripting.
- So the access-group strings must match the sdef exactly. Exact-case matching is [INFERENCE] → list both capitalizations.

[VERIFIED]

---

## 2. Path (a): Apple Events / AppleScript

**Scripting dictionary:** see "facts" in the task. Additional details:
- `reminder` has no `reminders` element, so children can't be enumerated. The parent is readable via `container` (list|reminder).
- `list.container` (account|list) is read-only, so a list can't be moved into a group.
- `list.emblem` / `color` are read-write text.
- `show` needs `com.apple.Reminders.UI`.
- The standard suite (make/delete/move) comes in via XInclude of CocoaStandard.

[VERIFIED: `Reminders.sdef`]

**Entitlements:**
- Sandbox / Mac App Store: `com.apple.security.scripting-targets` = `{ "com.apple.reminders": ["com.apple.reminders.read-write", "com.apple.reminders.List.read-write", "com.apple.Reminders.read-write", "com.apple.Reminders.UI"] }`. Including all case variants is [INFERENCE].
- Hardened runtime: `com.apple.security.automation.apple-events`.
- Info.plist: `NSAppleEventsUsageDescription`.
- Scripting-targets is Apple's sanctioned replacement for `temporary-exception.apple-events`. [DOCS: [QA1888](https://developer.apple.com/library/content/qa/qa1888/_index.html), [QA1802](https://developer.apple.com/library/archive/qa/qa1802/_index.html)]
- Sandboxed apps can see "Policy disallows prompt" or `errAEEventNotPermitted` when entitlements are wrong. [FORUM: [771769](https://developer.apple.com/forums/thread/771769)]
- `NSUserAppleScriptTask` runs out of process, so no entitlement is needed. But the script must live in `~/Library/Application Scripts/<bundle-id>/`, which the user (or an NSSavePanel the user confirms) has to install. [FORUM/DTS: [796387](https://developer.apple.com/forums/thread/796387)]

**Consent UX:**
- One-time Automation prompt: "<App> wants to control Reminders". Pre-flight with `AEDeterminePermissionToAutomateTarget`. If denied, the user fixes it in System Settings › Privacy & Security › Automation.
- This avoids the Reminders TCC grant for our app (Reminders.app has its own access), but adds the Automation grant.

[DOCS/INFERENCE]

**Performance (rem CLI, 2026):**
- Each Apple Event takes 3–4 s. Reminders.app handles events one at a time; parallel osascript doesn't help.
- JXA columnar reads: `lists` 8.3 s; all 224 reminders ≈60 s; stats ≈68 s.
- A per-element AppleScript loop over 8 reminders hit a 30 s timeout.
- Writes ≈0.5 s.
- EventKit does the same reads in 0.11–0.17 s.

[FORUM/BLOG: [rem performance.md](https://github.com/BRO3886/rem/blob/main/website/content/docs/performance.md)]

**Behaviour on macOS 26 and 27 betas:**
- Setting `flagged` works on 26.2 and 27.0 (remctl uses it). [FORUM/BLOG: [remctl architecture](https://github.com/viticci/remctl/blob/main/docs/architecture.md)]
- `tell list "<name>"` fails with -1728 for lists inside a group. Address reminders at application level: `reminder id "x-apple-reminder://<UUID>"`. [FORUM/BLOG: remctl CHANGELOG]
- Any Apple Event launches Reminders.app and leaves it open (macOS 26.7). [FORUM/BLOG: [remctl #65](https://github.com/viticci/remctl/issues/65)]
- A retried AppleScript "complete" on a repeating reminder can advance the series twice. [FORUM/BLOG: remctl CHANGELOG]
- AppleScript `move` succeeds between shared lists, where EventKit fails with -3002. [FORUM/BLOG: go-eventkit comment]
- Moving a list into a group: not possible (container is read-only). [VERIFIED sdef; that `move` also fails is UNVERIFIED]
- Nested reminders: "not accessible via AppleScript" was reported on Sonoma (2023). The current sdef allows a reminder as container, so this may have changed. [FORUM: [Hookmark](https://discourse.hookproductivity.com/t/is-reminders-app-linkable/2397?page=2); current state UNVERIFIED]

**IDs:**
- The AppleScript reminder id is `x-apple-reminder://<UUID>`, and `delete reminder id …` works. [FORUM: [MacScripter](https://macscripter.net/t/applescript-delete-reminder-by-id-uid/68970)]
- Hookmark rewrites it to `x-apple-reminderkit://REMCDReminder/<UUID>` as a deep link that opens the reminder in Reminders, reported working 2023–2025. [FORUM: Hookmark]
- Full ID mapping is in §8.

**Ways to send events:** NSAppleScript, OSAKit and ScriptingBridge (`sdef … | sdp -fh`) all run in-process and are subject to the sandbox. NSUserAppleScriptTask runs out of process. ScriptingBridge is the tidiest for typed access, but speed is the same (each property is an event).

**Use for:** flagged writes (Mac App Store build), list emblem/color, `show` deep link. **Never** for bulk reads.

---

## 3. Path (b): Shortcuts / App Intents

**Ways to run a helper shortcut:**

| Mechanism | Mac App Store sandbox? | Steals focus? | Input/output | Notes |
|---|---|---|---|---|
| Apple Event to **Shortcuts Events** (`com.apple.shortcuts.events`): `run shortcut "X" with input <text>` | ✅ with `scripting-targets {"com.apple.shortcuts.events": ["com.apple.shortcuts.run"]}` + `automation.apple-events` + `NSAppleEventsUsageDescription` | No. The sdef says to target Shortcuts Events to run in the background. | Text/JSON in; result comes back in the Apple Event reply | Access group [VERIFIED: `/System/Library/CoreServices/Shortcuts Events.app/Contents/Resources/Shortcuts.sdef`]. Bundle-ID key confirmed by an Apple engineer; one forum user got silent nil results [FORUM: [698879](https://developer.apple.com/forums/thread/698879)] |
| `/usr/bin/shortcuts run NAME -i in -o out` via Process | ❌ in practice: the child inherits our sandbox and needs WorkflowKit XPC plus `~/Library/Shortcuts/Temporary` [INFERENCE] | No | Files | Non-sandboxed apps hit "Operation not permitted" on `~/Library/Shortcuts/Temporary` without Full Disk Access (13.2, 2023) [FORUM: [724134](https://developer.apple.com/forums/thread/724134)]. CLI usage [VERIFIED: `shortcuts help run`] |
| `shortcuts://x-callback-url/run-shortcut?name=&input=text&text=&x-success=` | ✅ (just a URL open) | **Yes**, the Shortcuts app opens [INFERENCE] | x-success `result` | Broken since 26.5 / 15.7.7 / 14.8.7: x-success never fires, x-error errorCode=4 (FB22785648, possibly CVE-2026-28993), still unresolved 2026-05-29. The workaround is the clipboard, which wipes the user's clipboard. [FORUM: [Drafts](https://forums.getdrafts.com/t/problems-running-shortcuts-on-latest-os-26-5-and-other-updates/16754)] |

**Installing the helper:**
- Options: an iCloud share link, or a bundled `.shortcut` signed with `shortcuts sign --mode anyone|people-who-know-me -i -o` (needs network access to Apple's signing service) and opened with `NSWorkspace.open`.
- Either way the user must confirm in the Shortcuts UI; there is no silent import.
- Detect it with `exists shortcut "X"` through Shortcuts Events.
- Version the shortcut name (e.g. `TTR-Dispatch v3`).

[VERIFIED: `shortcuts help sign`; FORUM: [CLI notes](https://www.claudepluginhub.com/skills/bendrucker-shortcuts-plugins-shortcuts-2/cli)]

**Design:** one dispatcher shortcut. It takes JSON input `{op, args}`, then Get Dictionary → If/Otherwise → the Reminders intent → returns JSON text.

**Latency:** about 1–2 s to start each run. Repeat loops over many reminders are slow. [FORUM: [759448](https://developer.apple.com/forums/thread/759448); loop cost is INFERENCE]

**Background vs foreground:**
- Use `UpdateReminderAppIntent`, which runs in the background and covers tags, list, section, parent, flagged, urgent and early alert.
- Avoid `AddOrRemoveTags` and `MoveReminders`, which open Reminders.app.
- Hidden intents probably can't be added in the Shortcuts editor. [VERIFIED flags §1.1; editor behaviour INFERENCE]
- Shortcuts also asks its own per-shortcut privacy prompt for Reminders access. [INFERENCE]

**Main blocker — targeting by ID:** queries are default queries with no property parameters. Inside a shortcut, a reminder entity is usually found through Find Reminders filters (title/list/date…) or string search. Whether a shortcut can (a) output a stable identifier that matches EventKit's `calendarItemIdentifier` or (b) resolve a reminder from an ID or `x-apple-reminderkit` URL passed in is **UNVERIFIED**. Without that, writes are fragile (matching by title collides on duplicates).

**App Store:**
- Uses only public mechanisms. Requiring an optional, user-installed shortcut is acceptable when it powers optional features. [INFERENCE]
- Shortcuts' custom smart-list creation only opens the UI, so custom smart-list filters can't be set here.

---

## 4. Path (c): Private ReminderKit

**How existing projects use it (from their public source):**
- **In-process, sandbox-safe pattern:**
  1. Read `EKReminder.backingObject`, then `_reminder` (reminders-menubar) or the `_remObject` ivar (go-eventkit). The result is a `REMReminder`.
  2. Get `store` from it; create `REMSaveRequest initWithStore:`; call `updateReminder:` to get the change item.
  3. Use a context: `hashtagContext` (`removeAllHashtags`, `addHashtagWithType:name:` with type 0), `flaggedContext` (`setFlagged:`), `urgentAlarmContext` (`isUrgentStateEnabledForCurrentUser`, macOS 26+), `dueDateDeltaAlertContext`, `subtaskContext`, attachment context for URL / images.
  4. Commit with `saveSynchronouslyWithError:`.
- **Reads** by KVC on the `REMReminder`: `flagged`, `hashtags` (→ `name`), `parentReminderID.uuid`, `attachments` (`REMURLAttachment.url`), `userActivity.storage` (Mail links), `isUrgentStateEnabledForCurrentUser`. List order: `REMList.reminderIDsOrdering` (an ordered set of IDs with `uuid`).
- **Standalone (non-sandboxed) pattern:** `[REMStore new]`, then `REMObjectID objectIDWithURL:` with `x-apple-reminderkit://REMCD{Reminder,List,ListSection,SmartList,Sharee,Template,ManualSortHint_v1}/<ckIdentifier>`, then `fetchReminderWithObjectID:error:` and so on. Sections: `sectionsContextChangeItem` → `addListSectionWithDisplayName:toListSectionContextChangeItem:`. Custom smart lists: `addCustomSmartListWithName`. Order: `insertReminderChangeItem:before/afterReminderChangeItem:`. Recently Deleted needs ReminderKitInternal: `REMRemindersListDataView_RecentlyDeletedInvocation`.

[VERIFIED code: [reminders-menubar](https://github.com/DamascenoRafael/reminders-menubar/blob/master/reminders-menubar/Extensions/EKReminder%2BExtensions.swift), [go-eventkit bridge_darwin.m](https://github.com/BRO3886/go-eventkit/blob/main/reminders/bridge_darwin.m), [remctl-private.m](https://github.com/viticci/remctl/blob/main/remctl-private.m), [remctl private-metadata.md](https://github.com/viticci/remctl/blob/main/docs/private-metadata.md)]

**Entitlements:** none private. TCC Reminders full access is enough (rem, go-eventkit and remctl all work with Developer ID or local signing; reminders-menubar in the sandbox). [VERIFIED strings + FORUM/BLOG]

**Stability risk (high, measured):**
- Between 26.2 and 27.0 betas, `fetchSmartListWithObjectID:error:` and `categorizeGroceryItemsWithReminderIDs:` disappeared, and the replacement takes different argument types.
- Passing the wrong argument type **tombstoned objects** (set `ZMARKEDFORDELETION=1`).
- 26.5.1: creating a subtask raised an NSException ("parentReminderChangeItem has incorrect saveRequest").
- Ivar names differ between projects.

[FORUM/BLOG: [private-api-audit-2026-08-12](https://github.com/viticci/remctl/blob/main/docs/notes/private-api-audit-2026-08-12.md), [remctl #19](https://github.com/viticci/remctl/issues/19)]

Mitigations:
- `respondsToSelector:` plus a method-signature check (reminders-menubar checks `method_getNumberOfArguments`).
- A small Objective-C `@try` shim (Swift can't catch NSException).
- A read-only capability probe at launch, gated by OS build.
- After each write, re-read through EventKit to confirm it.
- A kill switch.

**Mac App Store:** ❌ guideline 2.5.1 (public APIs only). String-built selectors may slip past static scanning, but they are still a violation and a removal risk. [DOCS]

---

## 5. Path (d): Reading the Reminders SQLite store (from public sources; the user's database was not opened)

- **Location:**
  - Current: `~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-<UUID>.sqlite`, one per account/store. [FORUM/BLOG: [remctl macos27-compat-review](https://github.com/viticci/remctl/blob/main/docs/notes/macos27-compat-review.md)]
  - Legacy: `~/Library/Reminders/Container_v1/Stores/`. [FORUM: [gist](https://gist.github.com/jsejcksn/de89e62bf2468dd2092bee253365334b)]
- **Access:** needs Full Disk Access, which can't be prompted (the user adds it manually). The group is "restricted" (`com.apple.private.security.restricted-application-groups`). The sandbox denies it outright, so it is impossible in a Mac App Store app. [VERIFIED entitlement; sandbox conclusion is INFERENCE]
- **Tables:** ZREMCDREMINDER (ZTITLE, ZNOTES, ZCOMPLETED, ZFLAGGED, ZPRIORITY, ZDUEDATE, ZDISPLAYDATEDATE, ZTIMEZONE, ZISURGENTSTATEENABLEDFORCURRENTUSER, ZDUEDATEDELTAALERTSDATA, ZCKIDENTIFIER, ZDACALENDARITEMUNIQUEIDENTIFIER, ZMARKEDFORDELETION, ZLIST, ZPARENTREMINDER); ZREMCDBASELIST (color as a keyed archive, ZBADGEEMBLEM, ZPINNEDDATE, ZFILTERDATA JSON on 26+, grocery fields); ZREMCDOBJECT (hashtags, alarms, attachments; Z_ENT varies — resolve via Z_PRIMARYKEY); ZREMCDHASHTAGLABEL; ZREMCDBASESECTION; ZREMCDDUEDATEDELTAALERT. Attachment files live in `Files/Account-*/Attachments/`, named by SHA-512. [FORUM/BLOG: remctl, gist; ZPARENTREMINDER column name is INFERENCE from Core Data naming]
- **Traps:**
  - Section membership and ordering are blobs.
  - Due dates can be "floating" (ZTIMEZONE NULL, wall-clock time stored as UTC). [FORUM/BLOG: [remctl #49](https://github.com/viticci/remctl/issues/49)]
  - Deletes are soft (ZMARKEDFORDELETION=1, ZLIST NULL).
  - The reader can lag fresh writes.
  - WAL journal: read-only open needs care (`immutable=1` gives stale data). [INFERENCE]
- **Verdict:** skip it. In-process private reads give the same data without Full Disk Access.

---

## 6. (e) Data preservation when editing through EventKit

| Scenario | Finding | Tag |
|---|---|---|
| Plain EventKit edit (title / notes / priority / due / complete) on a reminder with tags, flag, section, subtasks, images, early alert, urgent | Probably preserved. The EventKit save goes through ReminderKit change items, which only touch fields EventKit models. All the OSS tools edit through EventKit and then apply private metadata separately; I found no reports of wipes. remctl's EventKit edit tests (26/27) kept alarms and schedules through title/notes/priority edits and list moves. | INFERENCE (strong) + [FORUM/BLOG: remctl compat review] |
| How subtasks appear in EventKit | As ordinary top-level reminders in the parent's list, with no parent link. There is no public subtask API (Apple DTS, April 2026). | [FORUM: [reminders-menubar #162](https://github.com/DamascenoRafael/reminders-menubar/issues/162); [DTS 820848](https://developer.apple.com/forums/thread/820848)] |
| Tags, sections, groups in EventKit | Invisible. Groups don't appear as calendars. | [FORUM: [683921](https://developer.apple.com/forums/thread/683921)]; groups-as-calendars INFERENCE |
| EventKit move of a parent that has subtasks | **Rejected** with `com.apple.reminderkit error -3002` (macOS 26.3); subtasks stay in the old list. Moving subtasks first detaches them into top-level reminders. | [FORUM/BLOG: [remctl #13](https://github.com/viticci/remctl/issues/13)] |
| EventKit move with a shared list on either end | -3002. Workarounds: private `listID` change (keeps the ID) or clone + delete (new ID; position and creation date lost). | [FORUM/BLOG: go-eventkit; [remctl #15](https://github.com/viticci/remctl/issues/15)] |
| EventKit delete | Soft delete into Recently Deleted (30 days). EventKit can't see or restore it afterwards. Whether subtasks follow the parent is **UNVERIFIED**; the Reminders UI deletes them. | [FORUM/BLOG: [remctl #37](https://github.com/viticci/remctl/issues/37)]; [DOCS: [Apple](https://support.apple.com/guide/reminders/remnda262a43/mac)] |
| EventKit complete of a parent | Subtasks probably not completed (the intent has an explicit `completeSubtasks` flag). | INFERENCE |
| `#tag` written into title/notes via EventKit | Stays plain text; it is not turned into a tag and doesn't show in tag filters. | [FORUM: [claude issue](https://claudeissues.com/issue/59897-feature-apple-reminders-integration-expose-tags-as-a-first-class-field-in-remind); remctl docs] |
| `EKCalendarItem.url` | Not the URL field Reminders shows (that is a `REMURLAttachment`). | [FORUM/BLOG: go-eventkit comment] |
| Notes/title styling | Reminders keeps CRDT `titleDocument` / `notesDocument` and supports text styling; EventKit writes plain strings, so styling is probably lost on rewrite. Only write notes when they actually changed (reminders-menubar rewrites notes on every edit). | INFERENCE |
| Due date & early alert | An early alert needs a due date. Clearing the due date via EventKit may orphan or clear it. A repeating reminder can't be saved without a due date. | [FORUM/BLOG: remctl]; orphaning UNVERIFIED |
| Hourly recurrence (Reminders supports it) | EKRecurrenceRule has no hourly frequency, so touching `recurrenceRules` can clobber it. | UNVERIFIED |
| Time zone | Always set `timeZone` on due date components, or the date is stored floating. | [FORUM/BLOG: remctl #49] |
| Timed due date with no explicit alarm | Clients add `EKAlarm(absoluteDate:)` themselves ("only reminders with time have an alarm"). | [FORUM/BLOG: reminders-menubar code comment] |

Minimal test matrix to run on disposable data before shipping. Build reminders with tags, flag, section, 2 subtasks, image, early alert, urgent and URL, then do each EventKit operation (edit title/notes, reschedule, clear due, complete, list move, delete) and read back through the private reads and the Reminders UI.

---

## 7. (f) Notifications

- remindd delivers every alarm (RDAlarmEngine, RDAlarmNotificationConsumer, `com.apple.reminders.notification`), whichever app created the alarm. [VERIFIED strings]
- Notifications are attributed to Reminders, and clicking opens Reminders.app; this can't be redirected. [DOCS: [EventKit "Setting an alarm"](https://developer.apple.com/documentation/eventkit/setting-an-alarm)]
- Urgent, location, vehicle and messaging triggers can only be delivered by remindd.
- If our app also posts its own notifications, users get duplicates. BusyCal's precedent is to tell users to turn off Calendar/Reminders alerts. [FORUM: [BusyCal FAQ](https://www.busymac.com/docs/faqs/71172-how-can-i-avoid-duplicate-alarms-from-being-displayed)]
- **v1:** don't post our own notifications. Make sure every timed reminder has an alarm.
- **Later:** an opt-in "notify via app" mode for time alarms only. It needs a setup guide, rescheduling on `EKEventStoreChanged`, and our own snooze/complete actions; location, vehicle and urgent triggers stay with Reminders.

---

## 8. Identifier mapping

| Where | Format | Evidence |
|---|---|---|
| EventKit `calendarItemIdentifier` | UUID string (compare upper-case) | Equals `REMReminder.parentReminderID.uuid` (reminders-menubar groups by this). [VERIFIED code] |
| ReminderKit `REMObjectID` URL | `x-apple-reminderkit://REMCDReminder/<UUID>` (also REMCDList, REMCDListSection, …) | remctl builds it from ZCKIDENTIFIER. [VERIFIED code] |
| AppleScript `id` | `x-apple-reminder://<UUID>` | Same UUID according to Hookmark's prefix rewrite. [FORUM; equality is INFERENCE] |
| Deep link | `x-apple-reminderkit://REMCDReminder/<UUID>`, or AppleScript `show`, or the Open*AppIntent | Scheme registered in Info.plist [VERIFIED]; behaviour [FORUM] |
| `calendarItemExternalIdentifier` (reminders-cli uses it) | Relation to ZCKIDENTIFIER / ZDACALENDARITEMUNIQUEIDENTIFIER unknown | UNVERIFIED |
| EKCalendar `calendarIdentifier` vs REMList UUID | Unknown | UNVERIFIED |

Local metadata should be keyed by `calendarItemIdentifier`. It changes on clone + delete moves and on account re-sync, so keep a fallback match on creation date + title.

---

## 9. Feature × access-path matrix
Cell format: read/write · reliability · latency. "—" = not possible. "priv-read" = KVC on the EventKit backing object.

| | **EventKit** | **AppleScript** | **Shortcuts / App Intents** | **Private ReminderKit** | **SQLite read** | **App-local** |
|---|---|---|---|---|---|---|
| **Mac App Store?** | ✅ | ✅ scripting-targets + Automation consent | ✅ Shortcuts Events + user-installed shortcut | ❌ 2.5.1 | ❌ sandbox | ✅ |
| **Developer ID?** | ✅ | ✅ | ✅ | ✅ (needs only Reminders TCC; works sandboxed via EventKit's store) | ✅ + Full Disk Access | ✅ |
| Lists create/rename/color/delete | R/W · high · ~0.1 s | R/W name/color · med · 1–4 s | R/W (type, group) · med · 1–2 s | R/W · med-risk · fast | R | — |
| List emblem/emoji icon | — | R/W `emblem` | R/W badge | R/W (71 emblem names) | R | — |
| Groceries type / auto-categorize | — | — | R/W | R/W (selectors churned 26→27) | R | — |
| List groups (create, move list in/out, delete) | — | R (container) only | R/W full | R/W | R | — |
| Pinned lists | — | — | R/W | R/W (built-in smart-list pin broken on 26.2/27) | R | possible but won't sync |
| Sort style | — | — | R/W | ? (setter absent) | R | own sort ✅ |
| Manual order in list | priv-read | — | top/bottom only on move | R/W insert before/after | R (blob) | own order ✅ (won't sync) |
| List layout (columns) / show completed | — | — | R/W | ? | ? | ✅ |
| Sections (CRUD, collapse, membership) | — | — | R/W | R/W | R (blob) | — |
| Reminder core fields (title, notes, start/due, all-day, priority, complete) | R/W · high · fast | R/W · slow | R/W | R/W | R | — |
| Recurrence | R/W (no hourly) | — | R/W | R/W | R | — |
| Time alarms | R/W | remind-me date | via due date only | R/W | R | — |
| Early alert | — | — | R/W | R/W | R | — |
| Urgent (26+) | priv-read | — | R/W | R/W | R | — |
| Location trigger | R/W | — | R/W | private writes abandoned by remctl | R | — |
| Vehicle trigger | — | — | R/W | ? (class exists) | R | — |
| Contact / messaging trigger | — | — | R/W contactPerson | ? | R | — |
| Flagged | priv-read | R/W · works 26/27 · launches Reminders.app | R/W | R/W | R | — |
| Tags | priv-read; `#text` stays text | — | R/W (UpdateReminder runs in background) | R/W | R | — |
| Subtasks: read parent/children | flat; parent via priv-read | parent via `container` | R/W | R/W (crash on 26.5.1 if misused) | R | — |
| Subtasks: create / reparent | — | — | R/W | R/W | — | — |
| Move between lists | R/W, but -3002 for shared lists or parent with subtasks | `move` OK across shared | R/W (list param) | R/W, keeps ID | — | — |
| Rich URL | `url` is not the Reminders URL field | — | R/W | R/W (add-only) | R | — |
| Images / attachments | — | — | R/W | add-only | R + files | — |
| Assignment / sharees | — | — | R/W assignedPerson; participants R | R/W | R | — |
| Built-in smart lists hide/show | — | — | R/W | ? | R | ✅ own views |
| Custom smart lists | — | — | create opens UI only | R/W (filter JSON) | R | ✅ own filters (recommended) |
| Snooze | emulate (move alarm/due) | — | hidden intent | ? | — | ✅ emulate |
| Recently Deleted / restore | — | — | — | R/W (Internal framework) | R | — |
| Templates | — | — | — | R/W | R | — |
| Open in Reminders.app | — | `show` | Open* intents | URL scheme | — | — |
| Change notifications | EKEventStoreChanged | — | — | ? | file watch | — |
| Alarm delivery | remindd | remindd | remindd | remindd | — | optional own (duplicate risk) |

---

## 10. Recommendation

**v1 — one codebase, sandboxed, Mac App Store-safe core:**
1. **EventKit for all CRUD and reads.**
   - `requestFullAccessToReminders`, `NSRemindersFullAccessUsageDescription`, `com.apple.security.personal-information.calendars`.
   - Set the time zone on due dates; add an EKAlarm for timed due dates; only write notes when changed.
   - Before a list move, check for subtasks or shared lists, catch -3002 and explain it to the user (or fall back).
2. **App-local metadata** (SwiftData in the app container, keyed by `calendarItemIdentifier`) only for app-only concepts: our own smart filters, Kanban/board columns, view prefs, our own manual order. Never as a duplicate tag system.
3. **AppleScript (scripting-targets)** for flagged writes, emblem, color and `show`. Never for reads.
4. **No own notifications.**

**v1 Developer ID "Enhanced" build** (same app with a compile/runtime flag, still sandboxed):
- In-process private ReminderKit through the EventKit backing object.
- Reads: tags, parent/subtasks, flagged, urgent, URL attachments, list order.
- Writes: tags, flagged, urgent, early alert, subtasks, sections, groups.
- All of it behind a capability probe, selector + signature checks, an Objective-C `@try` shim, read-back verification and a kill switch.
- This is what makes the UI actually match Reminders, so it is effectively required for a TickTick/Things-class app.

**Later / optional:**
- Shortcuts dispatcher as the Mac App Store route to tags, sections and subtasks — only once the ID-targeting question is solved.
- Adopt `AppSchema.reminders` (macOS 27) so Siri and Apple Intelligence route to our app.
- Opt-in own notifications.

**Skip:** SQLite (Full Disk Access, churn, private reads cover it), the x-callback-url route (broken since 26.5), and `/usr/bin/shortcuts` from the sandbox.

**Fallbacks:** private API missing → hide that feature or show it read-only, and offer "Open in Reminders" (URL scheme / `show`). EventKit -3002 → private `listID` move (Enhanced) or AppleScript `move` (Mac App Store).

**Entitlements:**
- Mac App Store: `app-sandbox`, `personal-information.calendars`, `automation.apple-events`, `scripting-targets` `{com.apple.reminders: [com.apple.reminders.read-write, com.apple.reminders.List.read-write, com.apple.Reminders.read-write, com.apple.Reminders.UI], com.apple.shortcuts.events: [com.apple.shortcuts.run]}`.
- Info.plist: `NSRemindersFullAccessUsageDescription`, `NSAppleEventsUsageDescription`.
- Developer ID: the same entitlements, plus hardened runtime and notarization.

---

## 11. Open questions
1. Can a Shortcuts helper return, or accept, an identifier that equals EventKit's `calendarItemIdentifier`, or the `x-apple-reminderkit` URL? What format is the ReminderEntity ID?
2. Is EventKit's `calendarItemExternalIdentifier` the same as ZCKIDENTIFIER? Is `EKCalendar.calendarIdentifier` the same as the REMList UUID? How stable are both across re-sync?
3. Does an EventKit delete of a parent remove, orphan or keep its subtasks? Does an EventKit complete cascade?
4. Do EventKit edits to notes drop rich-text styling? Does clearing the due date drop the early alert? Does editing `recurrenceRules` clobber hourly recurrence?
5. Does `[REMStore new]` work inside the sandbox, or only EventKit's store? Do `EKEventStoreChanged` notifications fire for private-only changes (tags, flags, sections)?
6. Does Reminders' AppleScript on 27.x list nested reminders, and can a list be moved into a group (`move`)?
7. Can the hidden Move-to-Section / Parent / Snooze intents be included in a hand-built `.shortcut`?
8. App Store review: does scripting-targets for `com.apple.reminders` with mixed-case access groups pass, and does matching depend on case?
9. Is there a pending-notification limit for `UNUserNotificationCenter` on macOS, if the own-notifications mode is ever built?
10. Do EventKit-created timed reminders with no EKAlarm still fire a notification on 26/27?