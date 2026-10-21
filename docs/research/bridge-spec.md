# Private ReminderKit bridge spec (in-process, through EventKit's store), macOS 27.2

Everything below comes from reading source code and static inspection only. Nothing was built, nothing touched Reminders data, and no TCC prompt was triggered.

## 0. Sources and evidence tags

| Key | Source |
|---|---|
| **MB** | DamascenoRafael/reminders-menubar@master: `reminders-menubar/Extensions/EKReminder+Extensions.swift` (EKR), `Extensions/EKCalendar+Extensions.swift` (EKC), `Services/RemindersService.swift` (RS), `reminders_menubar{,_appstore}.entitlements`. Shipping app, sandboxed. Issues #300, #309, #313. |
| **GE** | BRO3886/go-eventkit@main `reminders/bridge_darwin.m`. Commits 4253d37 (URL), e45587f (flag), c32f341 (tags), 8596dd8 and e34aac1 (listID move). Issue #13. |
| **RC** | viticci/remctl@main: `remctl-private.m` (RCP), `docs/private-metadata.md` (PM), `docs/architecture.md`, `docs/notes/private-api-audit-2026-08-12.md` (AUD), `docs/notes/macos27-compat-review.md` (C27), `remctl` (Python CLI), CHANGELOG, issues #13 #15 #19 #37 #49 #65. Runs as a **standalone `[REMStore new]` helper, not sandboxed**. |
| **RK** | johnmatthewtennant/reminderkit-cli@HEAD: `reminderkit-generated.m` (RKG), `reminderkit-handwritten.m` (RKH), issues #27 #28 #34 #37 #43 #44. Standalone `[[REMStore alloc] initUserInteractive:YES]` (RKG ~L103). |
| **SH** | bunny-holes/sherpa `apple/eventkit-service/Sources/SherpaReminderKitShim/SherpaReminderKitShim.m`. **In-process via the EK backing object**: tags, flag, URLs, sections, subtasks, images, with read-back after every write. |
| **TA** | toommyliu/Tally: `Tally/Services/ReminderKitBridge.m`, `ReminderStore.swift`, `Supporting/Tally.entitlements`. **Sandboxed app**, in-process: URL plus early alert. |
| **H264** | thatmarcel/macOS-26.4-headers `headers/ReminderKit/*.h` and `headers/EventKit/*.h`. Class dumps with MinOS 26.4, used for selector types and receivers. |
| **DEC** | EthanArbuckle/iPhone18-3_26.1_23B85_Restore, an **iOS 26.1** decompile. EventKit and ReminderKit code is shared with macOS, so applying it to macOS is an INFERENCE. Files: `EventKit/EKReminderStore.mm`, `EKEventStore.mm`, `EKFrozenReminder{Reminder,Calendar,Object}.mm`, `ContentKit/WFReminderContentItemChangeTransaction.mm`, `RemindersUICore/RemindersUICore_94.mm`. |
| **L27** | Local static checks on 27.2 (26B5091g). Selector strings in `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.26.dyldreadonly`: **121 of 123** selectors used in this spec are present. The two absent ones are `categorizeGroceryItemsWithReminderIDs:` and `fetchSmartListWithObjectID:error:`, which remctl also found removed in 27.0. `dyld_info -exports ReminderKit` shows every REM class used here. `dyld_info -dlopens EventKit` shows EventKit **soft-links** ReminderKit. Strings show a selector *exists*, not which class owns it or its signature. |
| SPEC | My recommendation (no prior art). |
| INFERENCE | Reasoned, not observed. |

## 1. Corrections to the earlier research files

1. **MB #309 is not a "private save clobbered the time" bug.** It is a feature request ("Detect urgent from the title"). The reporter mentioned that the urgent button froze title parsing and changed the time, and the maintainer acknowledged "two bugs involving urgent and time". It is UI state, with no evidence of a ReminderKit clobber. The real risks are below in #3 and §2.5.
2. **EventKit edits only write keys that changed.** `EKFrozenReminderReminder _applyChanges:` gates every field on `hasUnsavedChangeForKey:` (DEC `EKFrozenReminderReminder.mm` `_applyChanges`). So an EventKit save does not overwrite tags, flags or sections. Notes go through `setNotesAsString:` only when notes changed, which drops styling only then. `EKCalendarItem.url` maps to `setIcsUrl:`, which is why it never shows in Reminders.
3. **MB's write code has real defects to avoid:**
   - Three separate `REMSaveRequest`s per edit (tags, then urgent, then flagged; RS L166-173), each built from the same stale backing object.
   - It ignores the save result: `perform(saveSyncSel, with: nil)` (EKR L307-312).
   - BOOL getters use `perform(sel) != nil` (EKR L181-188).
   - `perform("alloc")` followed by `takeUnretainedValue` (EKR L291-304) has ARC retain-count problems.
4. **Hashtag type should be 0.** Apple's own code uses `addHashtagWithType:0` (DEC ContentKit L45; RemindersUICore_94 L2093, L4085, L4405). MB, GE and RK use 0. **RC and SH use 1**, which is unverified and should not be copied.
5. **Assignment status should be 1.** Apple uses `addAssignmentWithAssigneeID:originatorID:status:1` (DEC RemindersUICore_94 L1495), and RC uses 1. RK uses `addAssignmentWithAssignee:originator:status:0`, which is suspect.
6. **remctl's "setSortingStyle: absent" is probably a false negative.** `sortingStyle` is a readwrite property on `REMListChangeItem` (H264). Change items override `respondsToSelector:` and `forwardingTargetForSelector:`, and `+instancesRespondToSelector:` misses forwarded methods (AUD §4: 15 of 110 methods are forwarded). Rule: **probe on live, unsaved objects, never on classes.**
7. **SH's reverse lookup is wrong.** It calls `calendarItemWithIdentifier:` with `daCalendarItemUniqueIdentifier`, but that value is the *external* identifier (§2.2).
8. **remctl had no API for reordering lists inside a group.** It detaches and re-attaches in reverse order (`remctl` Python ~L8496-8530). RK shows the real API: `insertListChangeItem:before/afterListChangeItem:` (RKH L129-279).

## 2. Bridge architecture (minimum shape)

### 2.1 Loading and acquiring objects

- **Loading.** EventKit soft-links ReminderKit (L27). Explicitly `dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW)`. Load `ReminderKitInternal` only for Recently Deleted (GE L180-189, TA L30-45, RC L730).
  - Do **not** link the private frameworks.
  - Get classes with `NSClassFromString`.
  - Message them through `id<SPIProtocol>` protocols declared in the shim `.m` (remctl-style declarations, RCP L9-244). This gives correct ARC and ABI behaviour, unlike `perform`.
- **Store.**
  - Primary: `EKEventStore.reminderStore` (an `EKReminderStore`) → `.remStore` (a `REMStore`). Both are private properties (H264 `EKEventStore.h`, `EKReminderStore.h`; both selectors present in L27).
  - Fallback: `REMReminder.store`, or the `_store` ivar (GE L308-316, TA L79-95, SH ~L506).
  - EventKit itself does `[[REMStore alloc] init]` in-process (DEC `EKReminderStore.mm` L107-130). A fresh store should therefore also work in the sandbox (INFERENCE). Reuse EventKit's store anyway: it is one connection, and its change observer is already wired (§2.7).
- **EKReminder → REMReminder** (for bulk reads only):
  - `ek.backingObject` (an `EKFrozenReminderReminder`) → `_reminder` (MB EKR L161-166), or
  - the ivar `_remObject` on `EKFrozenReminderObject` (GE L201-215, TA L59-77, SH ~L495; DEC `EKFrozenReminderObject.mm` L26).
  - Probe both and check `isKindOfClass:REMReminder`.
- **EKCalendar → REMList:** `cal.backingObject` (an `EKFrozenReminderCalendar`) → `_list` (MB EKC L4-20), or the `_remObject` ivar (GE L217-231).
- **EKSource → REMAccount:** `source.backingObject.remAccount` (H264 `EKFrozenReminderSource.h`), or `REMList.account`, or the calendar backing object's `_account` (DEC `EKFrozenReminderCalendar.mm` L214-226).
- **Objects EventKit never exposes:**
  - Groups: `[[account groupContext] fetchGroupsWithError:]` (RKG L490-501).
  - Group children: `[[group sublistContext] fetchListsWithError:]` (RKG L516-523).
  - Sections: `[store fetchListSectionsWithListObjectID:error:]` (RKG L1407-1414; H264 `REMStore.h`).
  - Accounts: `[store fetchAccountsWithError:]`.
- **For writes, never reuse EventKit's cached backing object.** Right before building a change item, re-fetch by ID: `[store fetchReminderWithObjectID:error:]` / `fetchListWithObjectID:error:` / `fetchListSectionWithObjectID:error:`. EventKit makes the same calls on its own store (DEC `EKReminderStore.mm` L802, L1242). This removes the stale-snapshot problem (SPEC).

### 2.2 Identifier mapping (VERIFIED in DEC code, consistent with MB's parent grouping)

| EventKit | ReminderKit | Evidence |
|---|---|---|
| `EKReminder.calendarItemIdentifier` | `REMReminder.objectID.uuid.UUIDString` (upper case) | DEC `EKFrozenReminderReminder.mm` L621-640; MB EKR L121-129 (equals `parentReminderID.uuid`) |
| UUID → REMObjectID | `[REMReminder objectIDWithUUID:[[NSUUID alloc] initWithUUIDString:id]]`, or `+[REMObjectID objectIDWithUUID:entityName:@"REMCDReminder"]`, or URL `x-apple-reminderkit://REMCDReminder/<UUID>` + `objectIDWithURL:` | DEC same file L47-62; H264 `REMObjectID.h`; RCP L461 |
| `calendarItemExternalIdentifier` | `REMReminder.daCalendarItemUniqueIdentifier` (not the UUID) | DEC L666-680 |
| `EKCalendar.calendarIdentifier` | `REMList.objectID.uuid.UUIDString`; `[REMList objectIDWithUUID:]` | DEC `EKFrozenReminderCalendar.mm` L159-179 |
| (no EventKit object) group | `REMList` with `isGroup == YES`; ID via `REMList objectIDWithUUID:` (remctl builds group IDs with REMCDList URLs) | RCP L1038-1150 |
| section | `REMListSection.objectID` (REMCDListSection); memberships use **NSUUID**s (reminder UUID, section UUID) | RCP L2150-2168 |
| sharee / current user | `REMSharee.objectID` (REMCDSharee); `REMList.currentUserShareParticipantID` is the sharee's UUID string | RKH L753-772 |
| `EKSource.sourceIdentifier` ↔ `REMAccount.objectID.uuid` | assumed equal | INFERENCE |
| Move within one account | ID is kept: `removeFromList` + target `addReminderChangeItem:` | DEC `_applyChanges` |
| Move to another account, or account type 3 or 4 | EventKit **copies** the reminder, so the ID changes | DEC `_applyChanges`, `_reminderCopiedToNewList:` |

Compare IDs case-insensitively. Key all app-local metadata by `calendarItemIdentifier`.

### 2.3 Capability probe at launch (never saves)

1. Classes exist (L27 export list).
2. Pick one real reminder and one real list from the account (read only).
3. Create a throwaway `REMSaveRequest` with `updateReminder:` and `updateList:`. Use `respondsToSelector:` on those **live change items** and their contexts (`hashtagContext`, `flaggedContext`, `urgentAlarmContext`, `dueDateDeltaAlertContext`, `subtaskContext`, `attachmentContext`, `assignmentContext`, `sectionsContextChangeItem`, `appearanceContext`, `sublistContext`, `groceryContextChangeItem`). RCP L777-840 does the same and reports `saveCalled:false`.
4. Check signatures with `methodSignatureForSelector:` against these known encodings (AUD):

   | Selector | Encoding |
   |---|---|
   | `insertReminderChangeItem:before/afterReminderChangeItem:` | `v32@0:8@16@24` |
   | `reminderIDsOrdering` | `@16@0:8` |
   | `updateManualOrdering:` | `v24@0:8@16` |
   | `autoCategorizeRemindersWithReminderIDs:` | `v24@0:8@16` |
   | `fetchCustomSmartListWithObjectID:error:` | `@32@0:8@16^@24` |
   | `REMColor colorSpace` | `Q` |

   Forwarded properties (`flagged`, `listID`, `sortingStyle`, `name`) go through **KVC** (`valueForKey:` / `setValue:forKey:`; GE L240-251, L575-579; MB EKR L269, L283).
5. Per account, read `account.capabilities` (`REMAccountCapabilities`, a real object; H264). Its BOOLs: supportsSubtasks, Sections, Hashtags, Flagged, UrgentAlarm, DueDateDeltaAlerts, Groups, PinnedLists, Attachments, Assignments, ListSharees, MoveAcrossLists, MoveAcrossSharedLists, CustomSmartLists, Templates, RecentlyDeleted, GroceriesList, HourlyRecurrence, ListAppearance, TextStyling.
   - Use them to hide smart lists and features.
   - Writes are allowed only when the target's account capability is true, the account is CloudKit, and the EK calendar has `allowsContentModifications`. RC #19 crashed on a non-iCloud (Exchange) target.

### 2.4 Safety net

- **Exceptions.** Wrap every call in an ObjC `@try`/`@catch` shim (RCP L774 with focused catches; TA L203-297). Any NSException disables that capability for the session.
- **Read-back.** After a save, re-fetch the touched objects with `fetchReminderWithObjectID:` and compare the specific fields (SH L826-841, RK `verifyReminderMovedToList` RKG ~L1912).
- **Tombstone guard (SPEC, from remctl's 26.2 incident where a wrong argument type set `ZMARKEDFORDELETION=1`, AUD L52).**
  - Applies after any *structural* write.
  - If `fetchReminderWithObjectID` returns nil but `fetchReminderIncludingMarkedForDeleteWithObjectID:error:` returns the object, it was tombstoned. Immediately `[[sr2 updateList:list] undeleteRemindersWithoutUndoWithIDs:@[oid]]`, then trip the kill switch.
- **Kill switch.** A UserDefaults flag plus automatic trips (probe mismatch, exception, failed verification, tombstone). When tripped, the app runs public EventKit only.
- **OS-build gate (SPEC).**
  - Scalar writes (flag, urgent, tags, URL, early alert) run whenever the probe passes.
  - Structural writes (moves, reparenting, sections, groups, ordering, restore) need a one-click **self-test** on a throwaway list first, recorded per build.
  - Reason: in remctl's incident the selector existed but its argument contract had changed (AUD L29, L52).
- **No automatic retries** of additive operations (RC architecture; PM "Validation and partial writes").

### 2.5 REMSaveRequest lifecycle: one user action = one request

1. If the action also changes public fields, do the EventKit save first (`save(_:commit:true)`). EventKit and ReminderKit cannot share a transaction. Because of the changed-keys-only rule (§1.2) the order is safe. GE does the same: "Field edits are saved through EventKit before the move" (commit 8596dd8; L1190-1240).
2. Re-fetch fresh REM objects by ID (§2.1).
3. `sr = [[REMSaveRequest alloc] initWithStore:store]` (H264). Register **every** object through *this* request (`updateReminder:`, `updateList:`, `updateAccount:`, `updateListSection:`, `add…`).
   - Never mix change items from different requests. RC #19 (macOS 26.5.1) crashed with "parentReminderChangeItem has incorrect saveRequest".
   - Multi-item requests are proven: list + 2 reminders (RCP L1938-1950); list + N subtasks (RCP L912-933); account + N lists (RKH L85-127).
4. Apply mutations inside `@try`.
5. `BOOL ok = [sr saveSynchronouslyWithError:&err]`, and check both `ok` and `err`. A request is single-use (`saved` property).
   - Async variant: `saveWithQueue:completion:`, which Apple's Shortcuts uses (DEC ContentKit L205).
6. Verify (§2.4). Call `[ek refreshSourcesIfNecessary]` (GE L417-420, L485-488; SH ~L832), then trigger the app's own reload.
7. Create-with-extras:
   - **Plain reminder + tags/flag/etc.:** EventKit create, then one private request. If the private step fails, keep the reminder and report "extras not applied".
   - **Subtask:** create it privately in one request (`addReminderWithTitle:toReminderSubtaskContextChangeItem:`), then set public fields through EventKit. Do not create a top-level reminder and reparent it, which can leave a stray reminder. TA instead rolls back by deleting (TA `ReminderStore.swift` L161-176).

### 2.6 Threading

- EventKit's own commit runs `saveSynchronouslyWithError:` on the caller's thread (DEC `EKReminderStore.mm` L1933-2006), and MB and TA call it on `@MainActor`. So it is safe on main, but it blocks on XPC. `REMStore` also has an `assertOnMainThreadFetches` switch (H264).
- **Spec:** one `actor` with a `DispatchSerialQueue` executor owns the `EKEventStore`. All EventKit and REM calls and the synchronous save run there. Only Sendable snapshots go to the UI.
- GE also serializes writes on a dispatch queue (commit 175a265).

### 2.7 Change propagation (VERIFIED in DEC, INFERENCE for macOS)

- `EKReminderStore` observes `+[REMStore storeDidChangeNotificationName]` with `object:nil` (DEC L169-170). Its handler `remindersChanged` clears caches and calls `-[EKEventStore reminderStoreChanged]` (L58-69).
- That **posts `EKEventStoreChangedNotification` on the main queue, asynchronously**, with `userInfo {EKEventStoreRemindersDataChangedUserInfoKey: YES, EKEventStoreCalendarDataChangedUserInfoKey: NO}` (DEC `EKEventStore.mm` L429-475).
- So a private save does trigger EKEventStoreChanged. The userInfo key lets the app tell reminder changes from calendar changes.
- Existing `EKReminder` objects keep stale backing snapshots, so always re-fetch.
- Whether this notification fires for saves made in our own process, and how long it takes, is **not proven**. Reload explicitly after our own saves and debounce the notification.

## 3. Operations: READ

Each entry: (a) call chain, (b) where it is proven, (c) bugs and OS versions tested, (d) how to reach the object, (e) ID notes.

- **Tags.**
  - (a) `REMReminder.hashtags` (an NSSet of `REMHashtag`, each with `.name`, `.type`, `.objectID`).
  - (b) In-process: MB EKR L133-144, GE L253-277, SH. (c) 26.x to 27.x (MB ships). (d) The backing object. (e) Treat names as case-insensitive identities (MB `Tag`).
  - Global tag list: union over all reminders (MB RS L192-201). `REMHashtagLabelDataView_AllHashtagLabelsInvocation` exists (L27) but its parameters are **unproven**.
- **Flagged.** `[rem valueForKey:@"flagged"]`, a `long long` 0/1 forwarded to storage (H264 `REMReminder.h`; GE L240-251; SH typed-scalar read ~L346-372). In-process. 26 and 27.
- **Urgent.** `rem.isUrgentStateEnabledForCurrentUser` (BOOL) (MB EKR L155-159). In-process. Needs macOS 26 or later and `supportsUrgentAlarm`.
- **Parent and children.**
  - `rem.parentReminderID.uuid`, which equals the parent's calendarItemIdentifier (MB EKR L121-129). Group children client-side and promote orphans to top level (MB RS L57-73).
  - Alternative: `[[rem subtaskContext] fetchRemindersWithError:]` (SH ~L634-665). In-process. 26/27.
  - Subtasks show up in EventKit fetches as ordinary reminders.
- **Section of a reminder.**
  - `[[[REMListSectionsDataView alloc] initWithStore:store] fetchListSectionWithReminderID:rem.objectID error:]` → `REMListSection.displayName` (SH ~L668-720). In-process. OS unknown (SH, Oct 2026).
  - This is **one XPC call per reminder**. Mark it `ponytail: per-reminder section fetch, swap for REMRemindersListDataView_ListSectionsInvocation if lists are slow` (that class exists in L27; parameters unproven).
- **List sections (name and order).**
  - `[store fetchListSectionsWithListObjectID:listOID error:]` → `[REMListSection]` (displayName, objectID, canonicalName) (RKG L1407; SH ~L941). Both standalone and in-process.
  - Returned order equals display order: RK relies on this (RKG L1426-1444). **INFERENCE**, so check it in the self-test.
  - Collapsed state: **no ReminderKit property** (H264 `REMListSection.h`), so keep it app-local.
- **List groups, membership and order.**
  - Groups: `[[account groupContext] fetchGroupsWithError:]`.
  - Children: `[[group sublistContext] fetchListsWithError:]` (RKG L490-523).
  - Membership: `list.parentList` / `parentListID`, plus `isGroup` and `canBeIncludedInGroup` (H264). Standalone (RK, macOS 15 and later).
  - Top-level order: `account.listIDsOrdering` (an NSOrderedSet of REMObjectID; H264 `REMAccount.h`). **Unproven** by prior art.
- **Manual order of reminders.** `REMList.reminderIDsOrdering` (an NSOrderedSet of objects with `uuid`) (MB EKC L22-48; RKG L1274-1295 uses `storage.reminderIDsMergeableOrdering`). In-process, 26/27. Reminders that have not merged into the ordering yet are missing, so append them in a stable fallback order (RC CHANGELOG 2.x).
- **List badge, emblem, emoji.** `list.badgeEmblem` (raw: an emoji JSON string or an emblem name) and `list.appearanceContext.badge` (`REMListBadge` with `.emblem` / `.emoji`) (H264; PM "List appearance"). The 71 valid emblem names live in RemindersUICore. **Header read only**, not exercised by prior art.
- **Pinned.** `list.isPinned`, `list.pinnedDate`. Pinned-list order (`pinnedListsManualOrdering`) is unproven. Fallback: sort by `pinnedDate`.
- **sortingStyle.** `list.sortingStyle` is an NSString (H264). The raw values are **UNVERIFIED** (strings present in L27: `manual`, `default`, `dueDate`, `displayDate`, `creationDate`, `priority`, `title`). Capture the real values in the self-test.
- **showsCompleted.** **No ReminderKit property.** Only `-[EKEventStore showCompletedReminders]` exists, which is the old global setting (H264). Treat it as app-local.
- **List type (groceries).** `list.shouldCategorizeGroceryItems` and `groceryLocaleID` (H264; PM "Groceries").
- **Early alerts.** `[[rem dueDateDeltaAlertContext] dueDateDeltaAlerts]` → `REMDueDateDeltaAlert.identifier` and `.dueDateDelta.unit` / `.count`.
  - Unit: 0 = minute, 1 = hour, 2 = day, 3 = week, 4 = month (PM).
  - Count: **negative means before the due date** (TA L150-156; PM shows a mirror value of -15).
  - Header-verified. Writes are proven in-process by TA.
- **URL attachments.** `[[rem attachmentContext] urlAttachments]` → `REMURLAttachment.url` (GE L280-300, SH). Or the `rem.attachments` array filtered on class `REMURLAttachment` (MB EKR L79-98). In-process.
- **Image attachments.** `attachmentContext.imageAttachments` → `REMImageAttachment` (`fileURL`, `width`, `height`, `fileSize`, `uti`) (SH ~L583-600; H264).
  - The file lives in `group.com.apple.reminders` and is **unreadable from the sandbox**. Without the sandbox it needs Full Disk Access or may raise an app-data TCC prompt (RC CHANGELOG 1.8.0 correction).
  - Spec: show a placeholder and "Open in Reminders". Never read the file automatically.
- **Assignment, sharees, owner.**
  - Assignment: `[[rem assignmentContext] currentAssignment]` → `.assigneeID`, `.originatorID`, `.status`, `.assignedDate`.
  - Sharees: `list.sharees` (`REMSharee` with displayName, address, objectID), or `[[REMListShareeContext alloc] initWithList:].sharees` (RKH L723-737).
  - Owner: `sharedOwnerName`, `sharedOwnerAddress`, `isOwnedByMe`, `isSharedToMe`, `isShared` (GE L495-510).
  - "Assigned to Me": `assigneeID.uuid == list.currentUserShareParticipantID` (RKH L753-772). INFERENCE.
- **Account capabilities.** `REMAccount.capabilities` (§2.3; RCP L846-850).
- **Custom smart lists and filters.** `[store fetchCustomSmartListsWithError:]` → `REMSmartList` (name, filterData, color, badgeEmblem, isPinned, parentList, sortingStyle) (H264).
  - `filterData` is UTF-8 JSON on 26 and later, or older NSKeyedArchiver data wrapping `REMCustomSmartListFilterDescriptor`. Known keys: operation, hashtags, date, time, priorities, flagged, location, lists (PM "Smart lists").
  - Evaluate the filters in the app. The read path is from the header; RC reads them through SQLite.
- **Recently Deleted.**
  - `dlopen` ReminderKitInternal, then `[store resultFromPerformingSwiftInvocation:[[REMRemindersListDataView_RecentlyDeletedInvocation alloc] initWithFetchResultTokenToDiffAgainst:nil] parametersData:<binary plist> storages:nil error:]`.
  - Parameters: `{accountID:{uuid,entityName}, deletedAfterDate: now-30d, remindersPrefetch:{base:none}, countCompleted:YES}`.
  - Result: `resultData` → plist `model.reminders[]` with `objectID.uuid` and nested `subtasks` (RCP L730-753).
  - Standalone, live on macOS 27 (RC #37). Gate on `supportsRecentlyDeletedList`.
- **Templates.** `[[account templatesContext] fetchTemplatesWithError:]` (H264; AUD says "present"). Header-verified; RC reads them via SQLite.
- **Hourly recurrence.** `rem.recurrenceRules` → `REMRecurrenceRule.frequency` (a `long long`). The raw value for hourly is **UNVERIFIED** (H264 has `hourlyRecurrentDueDate…` helpers; capability `supportsHourlyRecurrence`).
  - EventKit cannot represent hourly. Treat such rules as read-only and **never assign `recurrenceRules` through EventKit** on those reminders.
  - Other EventKit edits are safe because of the changed-keys rule (§1.2).

## 4. Operations: WRITE

(a) The chain inside one request `sr` with fresh objects. (b)/(c) proof and OS. Notes where needed.

- **Add or remove tags.**
  - `h = [[sr updateReminder:rem] hashtagContext]`. Add with `[h addHashtagWithType:0 name:n]`. Remove with `[h removeHashtag:<REMHashtag from rem.hashtags>]`.
  - Diff instead of using `removeAllHashtags`, so existing hashtag objects and creation dates are kept. Apple's own code removes specific hashtags (DEC ContentKit L122; RKG L1730-1763).
  - Replace-all is proven in-process: MB EKR L228-258, GE L358-422, SH ~L843-880.
  - `add` creates a new object every time, so check for duplicates first (RK #30). The name is normalized with `nameWithDisallowedCharactersReplaced:` (DEC), so read it back.
- **Rename or delete a tag globally.** There is **no API** (no `renameHashtagLabel`; L27). Bulk rewrite every reminder that carries the tag, in batched requests (`ponytail: 200 change items per request, chunk size untested`). Removing the last reference garbage-collects the label (PM via falconbradley).
- **Set flagged.** `[[ci flaggedContext] setFlagged:(NSInteger)0|1]`. Setting `flagged` directly on the change item does not save (GE comment L464-467).
  - Proven in-process: MB EKR L262-271 (KVC), GE L433-491, SH (typed ABI check).
  - Works headless on 26.7 without launching Reminders.app (RC #65).
- **Set urgent.** `[[ci urgentAlarmContext] setIsUrgentStateEnabledForCurrentUser:BOOL]` (MB EKR L276-285; RCP L2254-2260). macOS 26 or later. Whether it needs a timed due date is UNVERIFIED, so gate it in the UI.
- **Add or remove an early alert.**
  - `c = [ci dueDateDeltaAlertContext]`.
  - Remove existing: `[c removeDueDateDeltaAlertsWithIdentifiers:<NSUUIDs from rem's alerts>]` then `[c removeAllFetchedDueDateDeltaAlerts]`.
  - Add: `[c addDueDateDeltaAlertWithDueDateDelta:[[REMDueDateDeltaInterval alloc] initWithUnit:u count:-n]]`.
  - Proven: TA L125-190 (sandboxed, in-process), RCP L2261-2289 (standalone, 27.0 matrix).
  - **Requires a due date.** What happens when the due date is cleared through EventKit is UNVERIFIED.
- **Create a subtask.** `[sr addReminderWithTitle:t toReminderSubtaskContextChangeItem:[[sr updateReminder:parent] subtaskContext]]` returns a change item whose `objectID.uuid` is the new calendarItemIdentifier.
  - Proven: SH ~L1080-1125 (in-process), RCP L2119-2149 (27.0 matrix).
  - **Crashed on 26.5.1** for a non-iCloud target (RC #19). Gate on `supportsSubtasks` and the CloudKit account, and check `subtaskContext.reminderChangeItem.saveRequest == sr`.
- **Reparent: indent and outdent.**
  - Indent: `[[pCI subtaskContext] addReminderChangeItem:childCI]`, or `insertReminderChangeItem:childCI after/beforeReminderChangeItem:siblingCI` (RKG L1320-1368). Fallback: `[listCI _reassignReminderChangeItem:childCI withParentReminderChangeItem:pCI]`.
  - Outdent: `[[sr updateList:list] addReminderChangeItem:childCI]` (RKG L1299-1311), then `insertReminderChangeItem:childCI afterReminderChangeItem:parentCI` to place it right after the parent. `removeFromParentReminder` is in the header but **unproven**.
  - Standalone only (RK #11, #12, #35). Enforce one level of nesting and the same list in the app.
- **Create a section.**
  - `ctx = [listCI sectionsContextChangeItem]; s = [sr addListSectionWithDisplayName:n toListSectionContextChangeItem:ctx];`
  - `[ctx setUnsavedSectionIDsOrdering:existingOIDs + s.remObjectID]; [ctx setShouldUpdateSectionsOrdering:YES]` (RCP L1154-1190, 27.0).
  - Pass the **full** ordering. Refuse duplicate names (PM).
- **Rename a section.** `[[sr updateListSection:sec] setDisplayName:n]` (RCP L1192-1220).
- **Delete a section.** `[[sr updateListSection:sec] removeFromList]`. Its reminders move out of the section (RCP L1221-1245; RKG L1885-1910).
- **Reorder sections.** `setUnsavedSectionIDsOrdering:<full list of REMObjectIDs>` + `setShouldUpdateSectionsOrdering:YES` (RKG L1829-1883).
- **Move a reminder into a section.**
  - `[ctx setUnsavedMembershipsOfRemindersInSections:[[REMMemberships alloc] initWithMembershipByMemberIdentifier:merged]]`, where `merged` is the existing `ctx.unsavedMembershipsOfRemindersInSections.membershipByMemberIdentifier` plus `[[REMMembership alloc] initWithMemberIdentifier:remUUID groupIdentifier:secUUID isObsolete:NO modifiedOn:[NSDate date]]` (RKG L1446-1473).
  - Proven: SH ~L1013-1070 (in-process), RCP L2150-2168 (27.0).
  - For a cross-list move, use the **destination** list's change item (RK #44).
  - remi claims ReminderKit memberships do not sync and writes SQLite instead (`docs/TECHNICAL_DESIGN.md` L126). RC and SH contradict this. Add a cross-device check to the self-test.
- **Move a reminder out of a section.** The same membership with `isObsolete:YES` on the old section. **UNPROVEN**, so test first; until then, offer "Open in Reminders".
- **Create, rename, delete a list group.**
  - Create: `[sr addGroupWithName:n toAccountGroupContextChangeItem:[[sr updateAccount:acct] groupContext] groupObjectID:nil]`, plus `setParentOwnerID:acct.remObjectID` (RCP L987-1036, RKH L24-53).
  - Rename: `[groupCI setName:]` through the forwarded setter (RCP L1572). Not `storage setName:` as RKH L55-83 does.
  - Delete: first `[accountCI addListChangeItem:childCI]` for every child, then `[groupCI removeFromParent]` (RKH L85-127). `removeFromParent` is also EventKit's own list delete (DEC L1975-1980).
  - **Never cascade-delete lists without a confirmation showing counts.**
- **Move a list into or out of a group.**
  - In: `[[groupCI sublistContext] addListChangeItem:listCI]` or `insertListChangeItem:listCI before/afterListChangeItem:sibCI`.
  - Out: `[accountCI addListChangeItem:listCI]` (RKH L184-279).
  - Alternative: `[listCI setParentSubContainerID:groupOID|nil]` + `setParentOwnerID:acct` (RCP L1038-1105).
  - Check `canBeIncludedInGroup` and that both are in the same account. Verify `parentList` afterwards.
- **Reorder lists in the sidebar.**
  - Top level: `[accountCI insertListChangeItem:x before/afterListChangeItem:y]` (RKH L129-182, groups only).
  - Inside a group: the same call on `sublistContext`. Standalone; OS unknown.
- **Insert a reminder at a manual position.** `[listCI insertReminderChangeItem:moveCI before/afterReminderChangeItem:anchorCI]`, with both reminders in the same list.
  - Proven: RCP L1859-1969 (27.0 live; probe on 26.2); RK #43, which was a no-op until fixed in 42e7621.
  - For a new reminder: EventKit create, then insert.
  - The change only shows when the list's sortingStyle is manual (SPEC).
- **Set list emblem or emoji.** `[[listCI appearanceContext] setBadgeEmblem:name]` or `setBadge:[[REMListBadge alloc] initWithEmoji:e]` (RCP L345-404; 27.0 matrix). Use only the 71 official emblem names; unknown names fall back to the default icon (PM).
- **Pin or unpin a list.** `[listCI setIsPinned:BOOL]` (RCP L1586-1625, 27.0). Built-in smart lists: **none** (§5).
- **Set sortingStyle.** `[listCI setValue:style forKey:@"sortingStyle"]`. **UNPROVEN.** Allow only values that were read back from Reminders; otherwise read-only.
- **Set showsCompleted.** **None** (§5).
- **Set list type (groceries).** `[[listCI groceryContextChangeItem] setShouldCategorizeGroceryItems:BOOL]` + `setGroceryLocaleID:` (RCP L406-435; 27.0). Leave categorization to Reminders: the explicit categorizer changed selector and argument types between 26.2 and 27.0, and the wrong pairing tombstoned objects (AUD L29, L52).
- **Add or remove a URL attachment.**
  - Replace the single URL: `[[ci attachmentContext] setURLAttachmentWithURL:u]` (GE L303-356, TA L97-123: in-process, sandboxed).
  - Append: `addURLAttachmentWithURL:` (RCP L2317-2330, SH).
  - Clear: `removeURLAttachments` (GE, SH). Remove one: `removeAttachment:<REMURLAttachment>` (H264).
  - Accept http and https only.
- **Add or remove an image attachment.**
  - Add: `[[ci attachmentContext] addImageAttachmentWithURL:f width:px height:px error:&e]`, with pixel sizes from CGImageSource (SH ~L1190-1225, in-process; RCP L2222-2246 uses NSImage point sizes, which is the weaker choice).
  - `addImageAttachmentWithData:uti:width:height:` is in the header and avoids passing a file URL that remindd must read. **UNPROVEN.**
  - Remove: `removeAttachment:` (Apple's own code: DEC ContentKit L161).
  - No generic files or PDFs (PM).
- **Move a reminder with subtasks across lists (EventKit -3002; RC #13 on 26.3).** In order:
  1. Set `listID` through KVC (`setValue:targetListOID forKey:@"listID"`) on the parent **and every child** in one request. **UNPROVEN** as a combination, built from GE L527-592 (single reminder) and RCP L912-933 (`setListID:` on children during restore). Verify every ID afterwards.
  2. Fallback: clone and delete, `_copyReminder:toListChangeItem:` + `_copyReminder:toReminderSubtaskContextChangeItem:` then delete the originals (RCP L1784-1857; RC #13 and #15; 26.3 and 27). This **creates new IDs and loses creation date and position**, so require explicit user confirmation and never do it silently.
- **Move to or from a shared list.** Use `listID` through KVC (GE commit 8596dd8; -3002 reproduced on 27.0.1 26A434, openclaw/remindctl #104).
  - Then verify `listID` changed. `addReminderChangeItem:` silently does nothing for shared lists (RK #27, macOS 15).
  - Second fallback: AppleScript `move`, which works between shared lists (GE #13). Address the reminder at app level, `reminder id "x-apple-reminder://UUID"`, because AppleScript cannot see lists inside groups (error -1728; RC CHANGELOG).
- **Restore from Recently Deleted.**
  - `fetchReminderIncludingMarkedForDeleteWithObjectID:` → `[[sr updateList:dest] undeleteRemindersWithoutUndoWithIDs:@[oid]]`.
  - For each deleted child: `[[sr updateReminder:child] setListID:destOID]`, then save. IDs are kept (RCP L842-940; macOS 27 live, RC #37).
  - Deleting a parent soft-deletes its subtasks with it: INFERENCE from the nested `subtasks` in the result.
- **Assign a reminder.**
  - Assign: `[[ci assignmentContext] removeAllAssignments]` + `addAssignmentWithAssigneeID:shareeOID originatorID:currentUserShareeOID status:1`.
  - Unassign: `removeAssignment:` / `removeAllAssignments` (RCP L2194-2221; RKH L801-896). The list must already be shared.

## 5. No viable private path (spec says app-local, hidden, or "Open in Reminders")

| Item | Reason |
|---|---|
| Per-list "Show Completed" | No ReminderKit property; App Intent only |
| Section collapsed state | Not on `REMListSection` |
| Built-in smart lists: hide, show, pin | `fetchSmartListWithObjectID:error:` is gone on 26.2, 27.0 and 27.2 (L27, AUD); the Swift-only `fetchNonCustomSmartList(withType:)` is not usable. Compute Today, Scheduled, Flagged, Urgent and Assigned in the app |
| Atomic global tag rename | Bulk rewrite only |
| Creating or revoking list sharing; template public links | `createShareForListWithID:` is CloudKit share UI; template links are unreliable per RC |
| Reading image file bytes inside the sandbox | Protected group container |
| Location alarms through ReminderKit | RC abandoned it; use EventKit |
| Explicit grocery categorization | Contract churns between versions |
| Unproven, so test before enabling: | sortingStyle write, hourly recurrence write, removing a reminder from a section, pinned-list order (`[[accountCI pinnedListsContext] updateManualOrdering:REMManualOrdering]`), bulk section reads through Swift invocations, vehicle and contact triggers |
| Standalone only, possible later (out of the first pass) | Custom smart list create/edit/delete (RCP L1247-1410: `addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:`, `setParentOwnerID:`, KVC `minimumSupportedVersion=20220430`, `setSmartListType:@"com.apple.reminders.smartlist.custom"`, `setFilterData:`); templates (`addTemplateWithName:configuration:toAccountChangeItem:`, `addListUsingTemplate:toAccountChangeItem:`; 27.0 matrix) |

## 6. Self-test matrix (one throwaway list, structural writes enabled per OS build)

1. Create a list and a section.
2. Create a reminder with a due date.
3. Write tags, flag, urgent, early alert and URL; add 2 subtasks; set the section; insert before or after.
4. Edit title, notes and due date through EventKit, then confirm every private field survived.
5. Indent and outdent.
6. Move between lists (plain, with subtasks, shared if available).
7. Group create, move a list in and out, then delete.
8. Record the `sortingStyle` values and section order.
9. Delete, then restore from Recently Deleted.
10. Tombstone check on every ID. Clean up.
11. Separately: check that the section membership appears on a second device.

## 7. Final table

| Operation | Call chain (one `sr` per action; fresh objects by ID) | Proven where | OS tested | Risk | Notes |
|---|---|---|---|---|---|
| Get REMStore | `ek.reminderStore.remStore`; fallback `rem.store` / `_store` ivar | in-proc EK backing (GE L308, TA L79, SH) + EventKit's own `[REMStore new]` (DEC L107-130) | 26-27.2 headers and strings | Low | Do not link the framework; `dlopen` + `NSClassFromString` |
| EKReminder→REMReminder | `backingObject._reminder` or ivar `_remObject` | in-proc (MB EKR L161, GE L201, TA L59) | 26-27 | Low | Reads only; writes re-fetch by ID |
| ID mapping | `calendarItemIdentifier == objectID.uuid.UUIDString`; `[REMReminder/REMList objectIDWithUUID:]` | DEC L621-640 / L159-179; MB | iOS 26.1 decompile, MB 26-27 | Low | externalIdentifier = `daCalendarItemUniqueIdentifier` |
| Read tags | `rem.hashtags[].name` | in-proc (MB, GE, SH) | 26-27 | Low | Case-insensitive |
| Read flagged | KVC `flagged` (long long) | in-proc (MB, GE, SH) | 26-27 | Low | Do not use `perform != nil` |
| Read urgent | `isUrgentStateEnabledForCurrentUser` | in-proc (MB) | 26-27 | Low | 26 or later |
| Read parent/children | `parentReminderID.uuid`; `subtaskContext fetchRemindersWithError:` | in-proc (MB, SH) | 26-27 | Low | Group client-side |
| Read section of reminder | `REMListSectionsDataView initWithStore:` → `fetchListSectionWithReminderID:error:` | in-proc (SH) | ~26-27 (unstated) | Med | One XPC call each (ponytail) |
| Read list sections | `store fetchListSectionsWithListObjectID:error:` | standalone (RK) + in-proc (SH, same selector on data view) | 26-27 | Low | Order assumed; self-test checks |
| Read groups/membership | `account.groupContext fetchGroupsWithError:`; `group.sublistContext fetchListsWithError:`; `list.parentList` | standalone (RK) | 15-26 | Low | Groups are not EKCalendars |
| Read sidebar order | `account.listIDsOrdering` | none (header only) | — | Med | Fallback: EK order |
| Read manual order | `list.reminderIDsOrdering` | in-proc (MB EKC) | 26-27 | Low | Append unmerged IDs |
| Read emblem/emoji | `list.badgeEmblem`, `appearanceContext.badge` | none (header); RC via SQLite | — | Low | — |
| Read pinned | `list.isPinned` / `pinnedDate` | none (header); RC via SQLite | — | Low | — |
| Read sortingStyle | `list.sortingStyle` (NSString) | none (header) | — | Low | Values unverified |
| Read showsCompleted | — | **none** | — | — | App-local |
| Read groceries | `shouldCategorizeGroceryItems`, `groceryLocaleID` | none (header); RC via SQLite | — | Low | — |
| Read early alerts | `dueDateDeltaAlertContext.dueDateDeltaAlerts` | header; writes in-proc (TA) | — | Low | Unit 0-4, negative = before |
| Read URL attachments | `attachmentContext.urlAttachments[].url` | in-proc (MB, GE, SH) | 26-27 | Low | `EK.url` is not this field |
| Read image attachments | `imageAttachments[].fileURL/width/height` | in-proc (SH) | ~26-27 | Med | File unreadable in sandbox |
| Read assignee/sharees/owner | `assignmentContext.currentAssignment`; `list.sharees`; `sharedOwnerName`; `currentUserShareParticipantID` | standalone (RK) | 15-26 | Low | — |
| Read capabilities | `account.capabilities.supports*` | standalone (RC) + header | 26.2, 27.0 | Low | Drives what is hidden |
| Read custom smart lists | `store fetchCustomSmartListsWithError:` → `filterData` JSON | none in-proc (header); RC via SQLite | 26, 27 | Med | Evaluate in app |
| Read Recently Deleted | Swift invocation `REMRemindersListDataView_RecentlyDeletedInvocation` | standalone (RCP L730) | 27 | Med | Needs ReminderKitInternal |
| Read templates | `account.templatesContext fetchTemplatesWithError:` | none (header) | — | Low | — |
| Read hourly recurrence | `rem.recurrenceRules[].frequency` | none (header) | — | Med | Raw value unknown; never write through EK |
| Add/remove tags | `hashtagContext addHashtagWithType:0 name:` / `removeHashtag:` | in-proc (MB, GE, SH: replace-all); standalone (RK: diff) | 15-27 | Low | Type 0 (Apple uses it); check duplicates |
| Rename/delete tag globally | Bulk remove/add over every reminder | none (composed) | — | Med | Chunk the requests |
| Set flagged | `flaggedContext setFlagged:(NSInteger)` | in-proc (MB, GE, SH) | 26-27 | Low | Headless OK (RC #65) |
| Set urgent | `urgentAlarmContext setIsUrgentStateEnabledForCurrentUser:` | in-proc (MB) | 26-27 | Low | Possibly needs timed due |
| Add/remove early alert | `removeDueDateDeltaAlertsWithIdentifiers:` + `removeAllFetchedDueDateDeltaAlerts` + `addDueDateDeltaAlertWithDueDateDelta:` | in-proc (TA, sandboxed); standalone (RC) | ~26-27 | Low | Needs due date |
| Create subtask | `sr addReminderWithTitle:toReminderSubtaskContextChangeItem:` | in-proc (SH); standalone (RC) | 27.0 OK; **26.5.1 crash** | Med | Gate supportsSubtasks + iCloud |
| Indent | `parentCI.subtaskContext addReminderChangeItem:` / `insert…after/before` | standalone (RK) | 15-26 | Med | Same list, one level |
| Outdent | `listCI addReminderChangeItem:` (+ insert after parent) | standalone (RK) | 15-26 | Med | `removeFromParentReminder` unproven |
| Create section | `addListSectionWithDisplayName:toListSectionContextChangeItem:` + full `setUnsavedSectionIDsOrdering:` + `setShouldUpdateSectionsOrdering:YES` | standalone (RC, RK, remi) | 27.0 | Med | Refuse duplicates |
| Rename section | `updateListSection: setDisplayName:` | standalone (RC) | 27.0 | Low | — |
| Delete section | `updateListSection: removeFromList` | standalone (RC, RK, remi) | 27.0 | Med | Reminders stay in the list |
| Reorder sections | `setUnsavedSectionIDsOrdering:` (full) + `setShouldUpdateSectionsOrdering:YES` | standalone (RK) | 26 | Med | — |
| Move into section | `sectionsContextChangeItem setUnsavedMembershipsOfRemindersInSections:` (merge existing) | in-proc (SH); standalone (RC, RK) | 27.0 | Med | Check sync (remi disputes it) |
| Move out of section | Membership `isObsolete:YES` | **none** | — | High | Test first |
| Create group | `addGroupWithName:toAccountGroupContextChangeItem:groupObjectID:nil` + `setParentOwnerID:` | standalone (RC, RK) | 26-27 | Med | — |
| Rename group | `groupCI setName:` | standalone (RC) | 26-27 | Low | — |
| Delete group | `accountCI addListChangeItem:` per child, then `groupCI removeFromParent` | standalone (RK); RC variant | 15-27 | High | Confirm; keep the lists |
| List into/out of group | `group.sublistContext addListChangeItem:` / `insertListChangeItem:…`; out: `accountCI addListChangeItem:`; alt `setParentSubContainerID:` | standalone (RK, RC) | 15-27 | Med | Check `canBeIncludedInGroup` |
| Reorder sidebar | `accountCI` / `sublistContext insertListChangeItem:before/afterListChangeItem:` | standalone (RK) | 15-26 | Med | RC used detach/reattach |
| Insert at manual position | `listCI insertReminderChangeItem:before/afterReminderChangeItem:` | standalone (RC, RK) | 27.0 (26.2 probe) | Med | Visible only with manual sort |
| Set emblem/emoji | `appearanceContext setBadgeEmblem:` / `setBadge:REMListBadge initWithEmoji:` | standalone (RC) | 27.0 | Low | 71 official names only |
| Pin/unpin list | `listCI setIsPinned:` | standalone (RC) | 26.2, 27.0 | Low | Built-in smart lists: none |
| Set sortingStyle | KVC `sortingStyle` | **none** | — | High | Round-trip values only |
| Set showsCompleted | — | **none** | — | — | App-local |
| Set list type | `groceryContextChangeItem setShouldCategorizeGroceryItems:` / `setGroceryLocaleID:` | standalone (RC) | 26.2, 27.0 | Med | No explicit categorizer |
| Add/remove URL | `attachmentContext setURLAttachmentWithURL:` / `addURLAttachmentWithURL:` / `removeURLAttachments` | in-proc (GE, TA sandboxed, SH) | 26-27 | Low | http/https only |
| Add image | `addImageAttachmentWithURL:width:height:error:` (pixels) | in-proc (SH); standalone (RC) | ~27 | Med | Data variant unproven |
| Remove image | `attachmentContext removeAttachment:` | Apple code (DEC ContentKit) | iOS 26.1 | Low | — |
| Move with subtasks | KVC `listID` on parent + every child, else clone-delete `_copyReminder:…` | none (composed); clone standalone (RC) | 26.3, 27 | High | Clone = new IDs; confirm first |
| Move to/from shared | KVC `listID`, verify; fallback AppleScript `move` by id | in-proc (GE) | ~26 (-3002 seen on 27.0.1) | Med | `addReminderChangeItem:` silently no-ops (RK #27) |
| Restore deleted | `fetchReminderIncludingMarkedForDelete…` + `listCI undeleteRemindersWithoutUndoWithIDs:` + children `setListID:` | standalone (RC) | 27 | Med | IDs kept |
| Assign | `assignmentContext removeAllAssignments` + `addAssignmentWithAssigneeID:originatorID:status:1` | standalone (RC, RK) | 26-27 | Med | Status 1, as Apple uses |
| Save | `saveSynchronouslyWithError:` (or `saveWithQueue:completion:`), on the store actor | EventKit's own commit (DEC L2006); everyone | 26-27 | Low | Check BOOL and error; single use |
| Change notification | `storeDidChange` → EK `remindersChanged` → `EKEventStoreChanged` (main, userInfo RemindersDataChanged) | DEC `EKEventStore.mm` L429-475 | iOS 26.1 | Low | Also reload explicitly and call `refreshSourcesIfNecessary` |

Open points that block nothing: the `sortingStyle` raw values, the hourly frequency value, and removing a reminder from a section. The self-test (§6) settles all three on the dev Mac before those features are turned on.