# ReminderKit bridge spec check on macOS 27.2 (26B5091g)

**Bottom line:** the EventKit-to-ReminderKit bridge holds up on this machine. Every selector the spec relies on exists, except `categorizeGroceryItemsWithReminderIDs:` and `fetchSmartListWithObjectID:error:` (the spec already lists both as gone) and two renamed ones (`colorSpace`, `createShareForListWithID:`). I found one real data-integrity bug in the spec, in the early-alert path (correction C1), plus several smaller corrections.

## How I inspected it

All of this was static. Nothing was built, nothing was loaded into a process, no Reminders data was touched and no TCC prompt was triggered.

- **The suggested command doesn't work.** `dyld_info -objc` refuses dylibs that live in the shared cache ("cannot print live objc info from dylibs in dyld shared cache").
- **Owning class.** I used `dyld_info -disassemble`, whose labels show `-[Class sel]` and `+[Class sel]`.
- **Type encodings, properties and ivars.** A read-only Python reader parsed the cache files under `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/`, using the labeled `__objc_methlist` and `__objc_const` lists. The relative selector and type base is `0x1f4696e20`, checked against `+[REMStore initialize]`.
- **Which selectors a method calls.** I decoded the cache's objc stubs.

| Note | Meaning |
|---|---|
| (fwd) | The selector is not implemented on the change item itself. It reaches a `*Storage` object via `forwardingTargetForSelector:`, or via `setValue:forUndefinedKey:`, which calls `[storage setValue:forKey:]` after checking `saveRequest.isSaved`. |
| (D) | The property is declared `@dynamic`. |

## The EK → REM bridge on 27.2

- **Classes.** `EKReminder : EKCalendarItem : EKObject`. The backing class is `EKFrozenReminderReminder : EKFrozenReminderObject : EKPersistentObject`. There is no `EKPersistentReminder` class at all.
- **`-[EKObject backingObject]`** (`@16@0:8`) returns the ivar at offset 0x10 (`_persistentObject`, typed `EKPersistentObject`).
- **These all return the same ivar, `_remObject` (type `@`), on `EKFrozenReminderObject`:**
  - `-[EKFrozenReminderReminder _reminder]`
  - `-[EKFrozenReminderCalendar _list]`
  - `-[EKFrozenReminderSource remAccount]` (property `T@"REMAccount",R,N`)
  - `-[EKFrozenReminderObject REMObject]`, which the spec missed. It works for reminders, lists and sources alike. Use it as the primary accessor and keep `_reminder` / `_list` as fallbacks.
- **`-[EKFrozenReminderCalendar _account]` is not an ivar read.** It does fetch work. Prefer `REMList.account`.
- **Store.**
  - `-[EKEventStore reminderStore]` (property `R,N,V_reminderStore`) is a plain two-instruction ivar getter, so it can be nil. Nil-check it.
  - `-[EKReminderStore remStore]` is `R,N,V_remStore`.
  - On 27.2, `EKReminderStore initWithEventStore:token:` creates its store with `-[REMStore initWithStoreContainerToken:]`, not `init` as the iOS decompile showed. It then registers `+storeDidChangeNotificationName` with `addObserver:selector:name:object:`.
- **ID mapping, now verified in 27.2 code:**
  - `EKFrozenReminderReminder calendarItemIdentifier` = `_reminder.objectID.uuid.UUIDString`
  - `calendarItemExternalIdentifier` = `_reminder.daCalendarItemUniqueIdentifier`
  - `EKFrozenReminderCalendar calendarIdentifier` = `_list.objectID.uuid.UUIDString`
  - `EKFrozenReminderSource sourceIdentifier` = `remAccount.objectID.uuid.UUIDString`. The spec marked this as an inference; it is now verified.
  - EventKit's own lookup, `backingReminderWithIdentifier:`, does `NSUUID initWithUUIDString:` → `objectIDWithUUID:` → `fetchReminderWithObjectID:error:`.
- **Spec §1.2 is verified on 27.2.**
  - `-[EKFrozenReminderReminder _applyChanges:error:]` makes 17 `hasUnsavedChangeForKey:` calls. It only ever calls: `setTitleAsString:`, `removeFromList` + `addReminderChangeItem:` (or `_reminderCopiedToNewList:`), `setCreationDate:`, `setNotesAsString:`, `setIcsUrl:`, start and due date components, `setCompleted:`, `setCompletionDate:`, `setPriority:`, `setDaCalendarItemUniqueIdentifier:`, alarm add/remove, `removeAllRecurrenceRules` + `addUpdatedRecurrenceRule:`, and `setUserActivity:`. It never touches tags, flag, sections or attachments.
  - The calendar version, `_applyChanges:error:`, only calls `setName:` and `setColor:`.
  - `EKReminderStore _commit:error:` creates a request with `initWithStore:`, calls `_applyChangesToSaveRequest:error:`, then `saveSynchronouslyWithError:` on the caller's thread.
  - A cross-account copy, `_copyToNewList:error:`, uses `initWithReminderChangeItem:insertIntoListChangeItem:` and does nothing about subtasks.
- **Change notification, verified on 27.2.** `-[EKReminderStore remindersChanged]` → `-[EKEventStore reminderStoreChanged]` → `postNotificationName:object:userInfo:`. The keys `EKEventStoreRemindersDataChangedUserInfoKey` and `EKEventStoreCalendarDataChangedUserInfoKey` are exported, but they are **not in the public SDK headers**. Use the string literals.

## Corrections to the spec (claims that are wrong)

**C1. Data-integrity bug: early alerts.**
- `-[REMReminderDueDateDeltaAlertContext dueDateDeltaAlerts]` just returns `storage.fetchedDueDateDeltaAlerts`.
- `removeAllFetchedDueDateDeltaAlerts` loops over the same `fetchedDueDateDeltaAlerts`.
- `-[REMReminderChangeItem dueDateDeltaAlertContext]` only checks `supportsDueDateDeltaAlerts`. It does **not** fetch the alerts.
- `fetchReminderWithObjectID:error:` uses `+defaultFetchOptions`, which is a plain `alloc`/`init` with no `init` override. So `includeDueDateDeltaAlerts` is NO.
- **What goes wrong.** The spec's "re-fetch by ID, then remove the existing alerts and add one" silently removes nothing, so the reminder ends up with **duplicate alerts**. Reads from the EventKit backing object or a default fetch show no alerts at all.
- **Fix.**
  - Fetch with `fetchReminderWithObjectID:fetchOptions:error:` (or `fetchRemindersWithObjectIDs:fetchOptions:error:`) and `+[REMReminderFetchOptions fetchOptionsIncludingDueDateDeltaAlerts]`.
  - Assert `storage.hasUnfetchedDueDateDeltaAlerts == NO` before writing.
  - (`+[REMReminderChangeItem _ensureDueDateDeltaAlertsAreFetchedIfNecessary:]` exists, but neither of these paths calls it.)

**C2. The probe plan can't check forwarded selectors with `methodSignatureForSelector:`.**
- The change items override `forwardingTargetForSelector:`, `respondsToSelector:`, `valueForUndefinedKey:` and `setValue:forUndefinedKey:`, but **not** `methodSignatureForSelector:`. That holds for reminder, list, account, base-section and smart-list change items, and for the read classes `REMReminder`, `REMList`, `REMAccount`, `REMBaseSection` and `REMSmartList`.
- So on a live change item it returns nil for every forwarded selector.
- Get forwarded encodings from `[ci forwardingTargetForSelector:sel]` (which returns `storage`), or from `class_getInstanceMethod(REM*Storage, sel)`.
- `respondsToSelector:` on live objects is fine, so the spec's "probe live objects, never classes" rule still stands.

**C3. Probe table: `REMColor colorSpace` is RENAMED.** It is now the property `colorRGBSpace` (`TQ,R,N`), getter `Q16@0:8`. `initWithRed:green:blue:alpha:colorSpace:` still exists. The strings check counted it as present only because "colorSpace" appears inside other selectors.

**C4. The `REMSaveRequest` getter is `isSaved`** (property `TB,N,GisSaved,V_saved`). Sending `saved` would fail.

**C5. `sortingStyle` values are now known**, from exported `NSString` constants in ReminderKit:
- `default` and `manual`
- `displayDate_asc` / `displayDate_desc`
- `creationDate_asc` / `creationDate_desc`
- `priority_asc` / `priority_desc`
- `title_asc` / `title_desc`

There is **no `dueDate` style**, and the spec's list was missing the `_asc`/`_desc` suffixes. Read the constants with `dlsym("REMSortingStyle…")`. The setter path exists: `REMListChangeItem sortingStyle` is `C,D,N` and forwards to `REMListStorage setSortingStyle:` (`v24@0:8@16`). That refutes remctl's "absent".

**C6. The emblem names live in ReminderKit, not only RemindersUICore.** There are 71 exported constants, `REMListBadgeEmblem*`. Examples: `default`, `bookmarks1`, `celebration1`, `concept1`, `education1`, `finance1`, `fitness`, `food`, `health1`, `pet1`, `shopping1`, `sport1`, `symbol1`, `transport1`, `vacation`, `weather1`, `wine`, `work1`. Read them with `dlsym` instead of hard-coding.

**C7. Hourly recurrence is probably `frequency == 4` (inferred from disassembly).**
- `+[REMRecurrenceRule _convertREMRecurrenceFrequencyToCalRecurrenceFrequency:]` maps 0 to 3 onto Cal values 1 to 4. For 4 it logs a fault and returns 1. Together with the `hourlyRecurrentDueDate…` helpers, that points to 4 = hourly.
- This confirms "never set recurrence through EventKit" on hourly reminders: whenever recurrence changes, `_applyChanges` calls `removeAllRecurrenceRules` and re-adds the rules.

**C8. The spec's "header only / unproven" calls really exist:**
- `-[REMReminderChangeItem removeFromParentReminder]` (`v16`), plus `removeFromParentReminderAllowingUndo` (`@16`).
- `REMReminderAttachmentContextChangeItem addFileAttachmentWithURL:error:` and `addFileAttachmentWithData:uti:` exist, so "no generic files" is a Reminders.app UI limit, not an API limit.

**C9. Section membership merge is a data-loss risk.**
- `REMMembership.memberIdentifier` and `.groupIdentifier` really are `NSUUID` (confirmed).
- But there is **no saved-membership read API**. Only `unsavedMembershipsOfRemindersInSections` exists, on the context change item and on `REMListStorage`.
- So the spec's "merge with the existing `ctx.unsaved…`" merges with nil or pending changes only.
- If `setUnsavedMemberships…:` replaces instead of merging, other reminders lose their sections. The self-test must check that a second reminder keeps its section.

**C10. Setting flagged.** `-[REMReminderFlaggedContextChangeItem setFlagged:]` just calls `[reminderChangeItem setFlagged:]`, which forwards to storage `setFlagged:` (`v24@0:8q16`). Statically, the KVC path and the context path do the same thing, so go-eventkit's claim that setting it directly doesn't save is not supported by the code. Keep using the context.

**C11. Pinning.** `-[REMListChangeItem setIsPinned:]` checks `accountCapabilities.supportsPinnedLists` itself, then sets `pinnedDate` to now or nil. So pinned means `pinnedDate != nil`.

**C12. Where the Swift invocations live.**
- `REMRemindersListDataView_RecentlyDeletedInvocation`, `_ListSectionsInvocation` and `REMHashtagLabelDataView_AllHashtagLabelsInvocation` are all in **ReminderKitInternal**, not ReminderKit.
- Recently Deleted parameters, confirmed from demangled symbols: `init(accountID:deletedAfterDate:countCompleted:remindersPrefetch:)`.
- AllHashtagLabels parameters: `init(sortingStyle:)`.
- ListSections parameters: `init(list:fetchPredefinedGroceryListSections:configuration:)`.

## Calls the spec missed (all PRESENT)

- **Batch reads.** On `REMStore`:
  - `fetchRemindersWithObjectIDs:error:` and `…:fetchOptions:error:`
  - `fetchListsWithObjectIDs:error:`
  - `fetchRemindersWithParentReminderIDs:error:` (one call for all subtasks)
  - `fetchListSectionsWithObjectIDs:error:`
  - `enumerateAllGroupsAndListsWithBlock:`
- **Other read helpers.**
  - `REMAccount fetchListsAndSublistsWithError:`
  - `REMList fetchRemindersAndSubtasksWithError:`
  - `REMReminderSubtaskContext fetchRemindersForMovingWithError:`
  - `REMReminderSubtaskContext fetchSubtasksMarkedForDeletionWithError:`
  - `REMStore fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:`, the correct reverse lookup for external IDs
- **Tombstones and restore.**
  - `fetchListIncludingMarkedForDeleteWithObjectID:error:`
  - `REMAccountChangeItem undeleteListWithID:usingUndo:`
  - `REMListSublistContextChangeItem undeleteChildListWithID:usingUndo:`
  - `REMListSectionContextChangeItem undeleteSectionWithID:`
  - `REMReminderSubtaskContextChangeItem undeleteSubtaskWithID:usingUndo:`
  - `REMListChangeItem undeleteReminderWithID:usingUndo:`
  - `REMListChangeItem undeleteRemindersWithoutUndoWithIDs:isCalDAV:`
  - The `usingUndo:` argument type (`@`) is unknown.
- **Structure.**
  - `REMSaveRequest addListWithName:toListSublistContextChangeItem:` (create a list straight inside a group)
  - `REMSaveRequest addReminderWithTitle:toListChangeItem:`
  - `REMSaveRequest addGroupWithName:toAccountGroupContextChangeItem:` (two-argument form)
  - `REMListChangeItem insertReminderChangeItem:adjacentToReminderChangeItem:isAfter:withParentReminderChangeItem:`, the real primitive behind `subtaskContext addReminderChangeItem:`
  - `REMListChangeItem removeFromParentAllowingUndo`
- **Tags.**
  - `addHashtagWithType:name:creationDate:` keeps the creation date during a bulk rename.
  - `undeleteHashtagWithID:`
  - `REMHashtagLabelDataView_HashtagIDsWithHashtagLabelNamesInvocation` (in ReminderKitInternal; parameters unproven)
- **Capabilities.**
  - `supportsCloudKitSync` is a better "is this account CloudKit" gate than raw account types.
  - Also present: `supportsListShareesMutation`, `supportsLocation`, `supportsPersonTrigger`, `supportsMultipleDateAlarmsOnRecurrence`.
  - `-[REMAccountChangeItem canCopyReminderLosslesslyToAccountChangeItem:]` answers cross-account move questions.
- **Your Calendar view and sidebar counts** (ReminderKitInternal, parameters unproven):
  - `REMRemindersInCalendarDataView_Invocation`
  - `REMAccountsListDataView_Invocation` (counts for today, scheduled, flagged, urgent, assigned-to-me, recently deleted)
  - `_AssignedInvocation`, `_FlaggedInvocation`, `_UrgentAlarmInvocation`, `_TaggedInvocation`
- **Pinned-list order.** `REMAccountPinnedListsContextChangeItem updateManualOrdering:` takes a `REMManualOrdering`, whose initializer is `initWithObjectID:listType:listID:topLevelElementIDs:secondaryLevelElementIDsByTopLevelElementID:uncommitedElementsAccountID:modifiedDate:`. Note that `listType` is `s` (short).
- **Renamed.** `createShareForListWithID:` is now `-[REMStore createShareForListWithID:appIconData:error:]` (`@40@0:8@16@24^@32`). Also new: `fetchShareForListWithID:error:`.

## Selectors that are MISSING (confirmed)

| Selector | Status on 27.2 |
|---|---|
| `categorizeGroceryItemsWithReminderIDs:` | MISSING |
| `fetchSmartListWithObjectID:error:` | MISSING (only `fetchSmartListSection…` variants remain) |
| `renameHashtagLabel*` | MISSING (no global rename API) |
| `REMColor colorSpace` | RENAMED → `colorRGBSpace` |
| `createShareForListWithID:` | RENAMED → `createShareForListWithID:appIconData:error:` |

Things I could not settle statically (UNKNOWN): hashtag type 0 versus 1 and assignment status 1 (only the `q` argument type is confirmed), the element type of `setUnsavedSectionIDsOrdering:` (REMObjectID or NSUUID), whether the membership setter merges or replaces, and the order of the five early-alert units (the range 0 to 4 is enforced in `initWithUnitInteger:count:`).

## Final table

| Operation | Verdict | Evidence (selector@class, encoding) | Notes |
|---|---|---|---|
| Get REMStore | GO | `-reminderStore@EKEventStore @16@0:8` (R,N); `-remStore@EKReminderStore @16@0:8`; `-store@REMReminder @16@0:8` | Getter can return nil, so check it. EventKit uses `initWithStoreContainerToken:`. |
| EKReminder→REMReminder | GO | `-backingObject@EKObject @16`; `-_reminder@EKFrozenReminderReminder @16`; `-REMObject@EKFrozenReminderObject @16`; ivar `_remObject` `@` | All return the same ivar. Add `REMObject`. |
| EKCalendar→REMList / EKSource→REMAccount | GO | `-_list@EKFrozenReminderCalendar @16`; `-remAccount@EKFrozenReminderSource @16` | `_account` fetches, so prefer `REMList.account`. |
| ID mapping | GO | `+objectIDWithUUID:@REMReminder/REMList/REMListSection/REMAccount @24@0:8@16`; `+objectIDWithUUID:entityName:@REMObjectID @32`; `+objectIDWithURL: @24` | All four EventKit IDs verified in 27.2 code, including sourceIdentifier. |
| Read tags | GO | `hashtags`@REMReminderStorage `@16` (fwd); `-name/-type(q)/-objectID@REMHashtag` | |
| Read flagged | GO | KVC → `-valueForUndefinedKey:@REMReminder` → `-flagged@REMReminderStorage q16` | |
| Read urgent | GO | `-isUrgentStateEnabledForCurrentUser@REMReminderStorage B16` (fwd) | |
| Read parent/children | GO | `parentReminderID`@Storage `@16`; `-fetchRemindersWithError:@REMReminderSubtaskContext @24@0:8^@16` | Batch: `fetchRemindersWithParentReminderIDs:error:`. |
| Read section of reminder | CAUTION | `-initWithStore:@REMListSectionsDataView @24`; `-fetchListSectionWithReminderID:error: @32@0:8@16^@24` | One XPC call per reminder. No saved-membership bulk API. |
| Read list sections | GO | `-fetchListSectionsWithListObjectID:error:@REMStore @32@0:8@16^@24`; `displayName`@REMBaseSection (D); `canonicalName`@REMListSection | Display order still unverified. |
| Read groups/membership | GO | `-fetchGroupsWithError:@REMAccountGroupContext @24`; `-fetchListsWithError:@REMListSublistContext @24`; `-parentList@REMList`; `isGroup`@REMListStorage B; `-canBeIncludedInGroup@REMList B16` | `fetchListsAndSublistsWithError:` does it in one call. |
| Read sidebar order | CAUTION | `-listIDsOrdering@REMAccount @16` (NSOrderedSet, R) | Element type unverified. |
| Read manual order | GO | `-reminderIDsOrdering@REMList @16@0:8` | Append unmerged IDs. |
| Read emblem/emoji | GO | `badgeEmblem`@REMListStorage (fwd); `-badge@REMListAppearanceContext`; `emblem/emoji`@REMListBadge | 71 `REMListBadgeEmblem*` constants. |
| Read pinned | GO | `-isPinned@REMList B16`; `pinnedDate`@REMListStorage | pinned = `pinnedDate != nil`. |
| Read sortingStyle | GO | `-sortingStyle@REMListStorage @16` (fwd) | Values settled (C5). |
| Read groceries | GO | `shouldCategorizeGroceryItems B16`, `groceryLocaleID @16` @REMListStorage (fwd) | |
| Read early alerts | CAUTION | `-dueDateDeltaAlerts@REMReminderDueDateDeltaAlertContext @16` → `storage.fetchedDueDateDeltaAlerts`; `unit/count q16`@REMDueDateDeltaInterval | Must fetch with `fetchOptionsIncludingDueDateDeltaAlerts` (C1). |
| Read URL attachments | GO | `-urlAttachments@REMReminderAttachmentContext @16`; `url`@REMURLAttachment | |
| Read image attachments | GO | `-imageAttachments @16`; `width/height Q16`@REMImageAttachment; `fileURL`/`fileSize`@REMFileAttachment; `uti`@REMAttachment | Files stay unreadable from the sandbox. |
| Read assignee/sharees/owner | GO | `-currentAssignment@REMReminderAssignmentContext`; `assigneeID/originatorID/assignedDate @16`, `status q16`@REMAssignment; `-initWithList:`/`sharees`@REMListShareeContext; `sharedOwnerName`, `currentUserShareParticipantID` (fwd); `-isShared/-isOwnedByMe/-isSharedToMe@REMList B16` | "Assigned to me" rule is still an inference. |
| Read capabilities | GO | `-capabilities@REMAccount @16`; all 20 `supports*` B16 on REMAccountCapabilities, plus extras | Use `supportsCloudKitSync`. |
| Read custom smart lists | GO | `-fetchCustomSmartListsWithError:@REMStore @24@0:8^@16`; `filterData`/`smartListType`@REMSmartList (D) | Evaluate filters in the app. |
| Read Recently Deleted | CAUTION | `-resultFromPerformingSwiftInvocation:parametersData:storages:error:@REMStore @48@0:8@16@24@32^@40`; `-initWithFetchResultTokenToDiffAgainst:@REMStoreSwiftInvocation @24`; `resultData`@REMStoreSwiftInvocationResult; class lives in ReminderKitInternal | Parameter fields match; plist encoding unproven in-process. |
| Read templates | GO | `-templatesContext@REMAccount`; `-fetchTemplatesWithError:@REMAccountTemplatesContext @24` | |
| Read hourly recurrence | CAUTION | `-frequency@REMRecurrenceRule q16` | Hourly = 4 (inferred, C7). Never write recurrence through EventKit. |
| Add/remove tags | GO | `-addHashtagWithType:name:@REMReminderHashtagContextChangeItem @32@0:8q16@24`; `-removeHashtag: v24`; `-removeAllHashtags v16`; `-nameWithDisallowedCharactersReplaced: @24` (instance) | Type value unverified. Use the `creationDate:` variant on rename. |
| Rename/delete tag globally | CAUTION | No rename API (MISSING); compose from the calls above | Bulk rewrite only. |
| Set flagged | GO | `-setFlagged:@REMReminderFlaggedContextChangeItem v24@0:8q16` → storage `setFlagged:` | Takes NSInteger. |
| Set urgent | GO | `-setIsUrgentStateEnabledForCurrentUser:@REMReminderUrgentAlarmContextChangeItem v20@0:8B16` | |
| Add/remove early alert | CAUTION | `-removeDueDateDeltaAlertsWithIdentifiers: v24`, `-removeAllFetchedDueDateDeltaAlerts v16`, `-addDueDateDeltaAlertWithDueDateDelta: @24` @REMReminderDueDateDeltaAlertContextChangeItem; `-initWithUnit:count:@REMDueDateDeltaInterval @32@0:8q16q24` | Duplicate-alert risk (C1). The context getter returns nil when the account lacks support. |
| Create subtask | CAUTION | `-addReminderWithTitle:toReminderSubtaskContextChangeItem:@REMSaveRequest @32@0:8@16@24`; `reminderChangeItem`/`saveRequest` | 26.5.1 crash history. Keep the gates. |
| Indent | CAUTION | `-addReminderChangeItem:@REMReminderSubtaskContextChangeItem v24` (calls `insertReminderChangeItem:adjacentTo…:isAfter:withParentReminderChangeItem:`); `-_reassignReminderChangeItem:withParentReminderChangeItem:@REMListChangeItem v32` | Proven standalone only. |
| Outdent | CAUTION | `-addReminderChangeItem:@REMListChangeItem v24`; `-removeFromParentReminder@REMReminderChangeItem v16` (exists) | Proven standalone only. |
| Create section | CAUTION | `-addListSectionWithDisplayName:toListSectionContextChangeItem:@REMSaveRequest @32`; `-setUnsavedSectionIDsOrdering: v24`; `-setShouldUpdateSectionsOrdering: v20@0:8B16` @REMListSectionContextChangeItem | Ordering element type unknown. |
| Rename section | CAUTION | `setDisplayName:` only on REMBaseSectionStorage `v24` (fwd; `displayName` C,D,N on REMBaseSectionChangeItem) | Forwarded only. |
| Delete section | CAUTION | `-removeFromList@REMListSectionChangeItem v16` | Proven standalone only. |
| Reorder sections | CAUTION | Same as create section | |
| Move into section | CAUTION | `-initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:@REMMembership @44@0:8@16@24B32@36`; `-initWithMembershipByMemberIdentifier:@REMMemberships @24`; `-setUnsavedMembershipsOfRemindersInSections:` v24 | Merge-or-replace unknown (C9). |
| Move out of section | CAUTION | Same calls with `isObsolete:YES` | Semantics unproven. Test first. |
| Create group | CAUTION | `-addGroupWithName:toAccountGroupContextChangeItem:groupObjectID:@REMSaveRequest @40` (+ two-argument form); `-setParentOwnerID:@REMListChangeItem v24` | Proven standalone only. |
| Rename group | GO | `setName:` (fwd to REMListStorage `v24`; `name` C,D,N on REMListChangeItem) | EventKit's own list rename uses this same path. |
| Delete group | CAUTION | `-addListChangeItem:@REMAccountChangeItem v24`; `-removeFromParent@REMListChangeItem v16` (EventKit's own list delete) | Confirm with counts. Re-parent children first. |
| List into/out of group | CAUTION | `-addListChangeItem:`, `-insertListChangeItem:before/afterListChangeItem: v24/v32` @REMListSublistContextChangeItem; `@REMAccountChangeItem` same; `-setParentSubContainerID: v24` | Check `canBeIncludedInGroup`. |
| Reorder sidebar | CAUTION | `-insertListChangeItem:before/afterListChangeItem:@REMAccountChangeItem / REMListSublistContextChangeItem v32@0:8@16@24` | Proven standalone only. |
| Insert at manual position | CAUTION | `-insertReminderChangeItem:before/afterReminderChangeItem:@REMListChangeItem v32@0:8@16@24` | Visible only with `sortingStyle == "manual"`. |
| Set emblem/emoji | CAUTION | `-setBadgeEmblem: v24`, `-setBadge: v24` @REMListAppearanceContextChangeItem; `-initWithEmoji:/-initWithEmblem:@REMListBadge @24` | Proven standalone only. Use the `REMListBadgeEmblem*` constants. |
| Pin/unpin list | CAUTION | `-setIsPinned:@REMListChangeItem v20@0:8B16` (direct; gates on `supportsPinnedLists`) | Proven standalone only. |
| Set sortingStyle | CAUTION | `sortingStyle` C,D,N → `-setSortingStyle:@REMListStorage v24` | Limit to the 10 known values. |
| Set list type (groceries) | CAUTION | `-setShouldCategorizeGroceryItems: v20B`, `-setGroceryLocaleID: v24` @REMListGroceryContextChangeItem | No explicit categorizer. |
| Add/remove URL | GO | `-setURLAttachmentWithURL: @24`, `-addURLAttachmentWithURL: @24`, `-removeURLAttachments v16`, `-removeAttachment: v24` @REMReminderAttachmentContextChangeItem | Tally proves it sandboxed and in-process. |
| Add image | CAUTION | `-addImageAttachmentWithURL:width:height:error: @48@0:8@16Q24Q32^@40`; `-addImageAttachmentWithData:uti:width:height: @48@0:8@16@24Q32Q40` | Width and height are NSUInteger. |
| Remove image | GO | `-removeAttachment: v24` | |
| Move with subtasks | CAUTION | KVC `listID` → `setValue:forUndefinedKey:` → `-setListID:@REMReminderStorage v24`; fallback `-_copyReminder:toListChangeItem:` / `-_copyReminder:toReminderSubtaskContextChangeItem:@REMSaveRequest @32` | Combined path unproven. A clone creates new IDs. |
| Move to/from shared list | CAUTION | Same as above | Verify `listID` afterwards. |
| Restore deleted | CAUTION | `-fetchReminderIncludingMarkedForDeleteWithObjectID:error:@REMStore @32`; `-undeleteRemindersWithoutUndoWithIDs:@REMListChangeItem v24` | Consider `undeleteSubtaskWithID:usingUndo:` instead of `setListID:` on children. |
| Assign | CAUTION | `-addAssignmentWithAssigneeID:originatorID:status:@REMReminderAssignmentContextChangeItem @40@0:8@16@24q32`; `-removeAllAssignments v16`; `-removeAssignment: v24` | Status value unverified. |
| Save | GO | `-initWithStore:@REMSaveRequest @24`; `-saveSynchronouslyWithError: B24@0:8^@16`; `-saveWithQueue:completion: v32@0:8@16@?24`; getter `isSaved` | Not `saved` (C4). |
| Change notification | GO | `+storeDidChangeNotificationName@REMStore`; `-remindersChanged@EKReminderStore v16`; `-reminderStoreChanged@EKEventStore v16`; `-refreshSourcesIfNecessary@EKEventStore v16` | Path verified on 27.2. userInfo keys are not in the SDK headers, so use literals. |
| Capability probe (signatures) | CAUTION | `respondsToSelector:` is overridden; `methodSignatureForSelector:` is not | Probe forwarded selectors via `storage` (C2). Fix `colorSpace` → `colorRGBSpace` (C3). |
| Smart list / template create (deferred) | CAUTION | `-addCustomSmartListWithName:toAccountChangeItem:smartListObjectID: @40`; `setSmartListType:`/`setFilterData:`@REMSmartListStorage (fwd); `-setMinimumSupportedVersion: v24@0:8q16`@Storage; `-addTemplateWithName:configuration:toAccountChangeItem: @40`; `-addListUsingTemplate:toAccountChangeItem: @32` | Still out of the first pass. |
| Grocery categorize, built-in smart list fetch | NO-GO | `categorizeGroceryItemsWithReminderIDs:` and `fetchSmartListWithObjectID:error:` are MISSING | As the spec says. |