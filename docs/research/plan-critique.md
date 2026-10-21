# Review of the TickTickReminders implementation plan

I found 61 issues: 22 missing features, 9 risky private-API dependencies, 12 data-loss risks, 3 places to simplify, 8 UI gaps, 5 verification gaps and 2 factual errors. The plan's structure is sound. The worst problems are that edits from another device can be silently overwritten (#32, #33), the trip rules contradict each other (#23), and the reschedule rule for alarms leaves stale alarms behind (#34).

I checked three things myself, read-only:
- **SwiftUI 27.** The `reorderContainer(for:itemID:in:isEnabled:move:)` signature the plan uses exists in the SDK.
- **Reminders data model.** `ReminderData_v2026_A.mom` has no show-completed or section-collapsed attribute. Only `showingLargeAttachments` and `shouldAutoCategorizeItems` turned up. So keeping both as app-local settings is right.
- **List icons.** The 71 icons are template vector images named `ListBadge<Name>` (for example `ListBadgeBookmarks1`) in `/System/Library/PrivateFrameworks/RemindersUICore.framework/Versions/A/Resources/Assets.car`. They are not SF Symbols.

## 1. Missed or hand-waved capabilities and user operations

1. **Moving a reminder to another account loses data silently in M1.** M1 has no private reads, so it can't know about tags, flag, section, URL, images, early alert or urgent. It also can't apply the "refuse when it has subtasks" rule. The verified `-[REMAccountChangeItem canCopyReminderLosslesslyToAccountChangeItem:]` is never used. The original also lands in the source account's Recently Deleted.
   - **Fix:** In public-only mode, always confirm with a warning such as "tags, flags, sections and attachments may be lost". With the private bridge (PB) on, gate the move on `canCopyReminderLosslessly…` and list the extras that will be lost, read from PB.
2. **Moving a single subtask is unspecified** (to another list, a section, or via the Move sheet). EventKit detaches it ("Cannot remove subtasks and change list simultaneously").
   - **Fix:** Rule: the subtask becomes top-level in the destination, after a confirm. Do it as PB outdent plus `listID` in one transaction (txn). In public mode, refuse.
3. **Indenting into a parent that sits in another section leaves a stale entry.** The child's own section entry stays in the list's membership blob.
   - **Fix:** In the same txn, drop the child's membership. Add this case to S9.
4. **Deleting a repeating reminder removes the whole series on a bare ⌫.** Reminders' own model distinguishes "this reminder" from "all future".
   - **Fix:** Confirm with "Delete all occurrences?". Keep "this occurrence only" deferred, but say so in the dialog.
5. **R14 and R1 conflict for repeating parents.** Completing a repeating parent completes its children, then the parent advances. The next occurrence therefore starts with every subtask already done.
   - **Fix:** Don't cascade completion for repeating parents until an extended S4 shows what Reminders does.
6. **Subtask counts and the checklist are wrong for older items.** Completed children older than the 30-day window aren't loaded, so "2/5" and the card checklist are off.
   - **Fix:** The open card uses PB `fetchRemindersWithParentReminderIDs:error:` (verified present). Row counts either come from that call or are labelled as incomplete-only.
7. **The restore target is unspecified.** Soft-deleted reminders have no list (`ZLIST` is NULL), and the original list may itself be deleted.
   - **Fix:** Restore to the original list ID from the Recently Deleted result. If that list is gone, use the default list after a confirm. Always restore the children too (same ID batch, or `undeleteSubtaskWithID:` once proven).
8. **Drag-to-recover from Recently Deleted is missing** (it's a Reminders feature).
   - **Fix:** Sidebar list drop targets accept Recently Deleted rows and restore into that list.
9. **Pinned lists have no sidebar position, and the pin limit isn't enforced.** Reminders allows 9, counting pinned lists and standard smart lists together.
   - **Fix:** Add a "Pinned" block under the smart lists, map ⌘1…9 to visible order, and refuse a tenth pin with a message.
10. **The Groceries toggle ignores auto-categorize.** It doesn't check `shouldAutoCategorizeItems` (the two are mutually exclusive), and it doesn't say what Reminders does to existing sections.
    - **Fix:** Read `shouldAutoCategorizeItems` and show "Auto-Categorize on (edit in Reminders)". Disable Groceries while it is on. Add an S9 case for turning Groceries on in a list that already has sections.
11. **Order of lists inside a group is unspecified.** The plan reads only `account.listIDsOrdering`.
    - **Fix:** S8 must find where sublist order lives (the `fetchListsAndSublistsWithError:` order, or the group's own ordering). The reorder-within-group operation then writes there.
12. **No one-level rule for groups.** Nothing stops a group being dropped into a group, or a list being dropped onto a list that is already inside a group.
    - **Fix:** Enforce one level in the app. The model has a single `parentList`.
13. **No guard for deleting or renaming the default list** (EventKit open question 12).
    - **Fix:** Add a "This is your default list" confirm, then re-read `defaultCalendarForNewReminders()`.
14. **List delete offers no way to keep the reminders** (EventKit pitfall #18).
    - **Fix:** The confirm sheet offers "Move reminders to [list], then delete", using a batch move and the -3002 path.
15. **Data we can see but not edit is never shown.** This covers file and audio attachments, car triggers, "when messaging" triggers, `userActivity` link-backs (Mail/Safari; Reminders MenuBar reads them), and extra early alerts.
    - **Fix:** Show read-only chips with Open in Reminders. Refuse or warn on early-alert replace when more than one alert exists.
16. **Creating from smart lists is under-specified.** "Same parent level" in Today, Scheduled or Flagged would create subtasks, which Reminders forbids there. Creating in Flagged, Urgent or a tag view while that write capability is off makes the new item vanish from the view.
    - **Fix:** Never create subtasks in smart lists. Disable create in those views when the matching capability is off.
17. **Today and smart-list parity is incomplete.** Missing are per-smart-list sorting (Reminders sorts Today, Flagged and Assigned), Today's "Edit Sections" ordering, and possibly a fourth "Night" bucket (ReminderKit has a Night 21:00 time-of-day string).
    - **Fix:** Store smart-list sort and Today section order locally. Check the bucket set and boundaries against a Reminders.app fixture in M1.
18. **Inline `#tag` converts in the title only.** Reminders converts it in notes too.
    - **Fix:** Run the same parser when notes are committed, or document that only the title converts.
19. **Tag rename and delete semantics are missing.** Renaming to an existing tag merges it, and deleting a tag leaves plain text.
    - **Fix:** Merge case-insensitively with a confirm. Define the text behaviour of delete from an S9 fixture.
20. **Templates are reachable but entirely deferred.** Reading them is GO (`templatesContext fetchTemplatesWithError:`). "New List from Template" is one CAUTION call (`addListUsingTemplate:toAccountChangeItem:`).
    - **Fix:** Add it in M5 behind the self-test, or tell the user explicitly that templates are cut. They asked for everything reachable.
21. **Rich-text notes editing is excluded without saying so.** This covers Font B/I/U and bullets (`supportsTextStyling`).
    - **Fix:** State the exclusion.
22. **Clearing a due date leaves the early alert's fate open** (S1 has no default).
    - **Fix:** Default: the same action clears the early alert via PB.

## 2. Private calls marked CAUTION, NO-GO or UNKNOWN without a spike or fallback

23. **The plan contradicts itself on trips.** C.6 says any trip means public-EventKit mode. M3 exit says a trip disables only its own capability.
    - **Fix:** A trip makes that capability read-only, and reads stay on. Only the toggle, or a failed store or backing-object probe, switches to global public mode.
24. **Early alert is wrongly gated as a scalar write** (probe only). Its verdict is CAUTION, with the C1 duplicate bug, an unknown unit order and an unknown count sign.
    - **Fix:** Gate it like structural writes, behind the self-test. S8 must learn the count sign as well as the unit order. LogicTests must not hard-code "negative = before" until S8 confirms it.
25. **The tombstone guard is only as good as S7, and only covers reminders.** It relies on CAUTION calls (`fetchReminderIncludingMarkedForDelete…`, `undeleteRemindersWithoutUndoWithIDs:`). Lists, groups and sections touched by structural ops are not checked.
    - **Fix:** If S7 fails, structural writes stay off, because there is no safety net. Extend detection (not auto-restore) to `fetchListIncludingMarkedForDeleteWithObjectID:` and sections, and on detection trip, alert and offer Open in Reminders. Don't call `undeleteListWithID:usingUndo:` (argument type unknown) until S7 proves it.
26. **Bulk tag rename and delete (M5) are in no spike or self-test.**
    - **Fix:** Add them to the self-test matrix, including the check "a tag on a reminder in another list survives".
27. **R8 step 2 (AppleScript `move`) breaks user decision 2.** AppleScript was allowed only for flagged, emblem and show. The move is also forum-only and launches Reminders.app.
    - **Fix:** Drop it. The chain becomes PB `listID`, then Open in Reminders.
28. **The AppleScript fallbacks are unproven.** The mapping between AppleScript `emblem` text and the `REMListBadgeEmblem*` names is unknown. An AppleScript flag write without a flag read (the Flagged list is hidden in that mode) is write-only.
    - **Fix:** Add a tiny M5 spike for emblem names, plus a flag read-back of that single reminder after writing (about 3 s).
29. **The core batch read has no verdict.** `fetchRemindersWithObjectIDs:fetchOptions:error:` is only "PRESENT", and the same goes for `fetchListsAndSublistsWithError:`.
    - **Fix:** S8 asserts that batch results equal per-ID fetches on the fixtures, with per-ID fetching as the fallback.
30. **The launch probe touches a real reminder in the user's account at every launch.** It builds unsaved change items, and no one has shown that discarding them has no side effects.
    - **Fix:** Probe on the self-test list when it exists. Add an S8 check that `lastModifiedDate` is unchanged after a probe.
31. **"Learned values" are ambiguous** (hashtag type, assignment status): learned at runtime, or fixed after S8?
    - **Fix:** Hard-code them from S8, and have the probe read-assert them against a tag made in Reminders.app.

## 3. Data-loss and corruption risks not mitigated

32. **Edits from another device are silently overwritten.** "Assign only fields whose value differs" compares the card with fresh EventKit data. So on close the card rewrites fields the user never touched (for example a title changed on the iPhone).
    - **Fix:** Snapshot the reminder when the card opens (the base). The edit is the difference between the card and that base. Write a key only if the user changed it. If the fresh value also differs from the base, show "Replaced a change from another device", with undo restoring theirs. Undo applies the same rule: revert only if the current value is still what we wrote.
33. **`setTags:` and `setURLs:` replace the full set from a possibly stale snapshot.** They drop tags or URLs added elsewhere, and a batch "Add Tag" rewrites every selected reminder's whole set.
    - **Fix:** Use `addTags:removeTags:` and `addURL:/removeURL:` computed against the base, and read back only those.
34. **Rescheduling leaves stale alarms.** The ±60 s rule leaves other absolute alarms at the old time. BusyCal reports that Reminders shows an alarm's date as the effective due date. All-day reminders made in Reminders.app may carry a time-of-day alarm that never matches the floating-midnight due date.
    - **Fix:** Add all-day and "remind me at" fixtures to S3. Default rule: shift every absolute, non-location alarm by the same change as the due date (whole days for date-only reminders).
35. **Typed text can be lost.** Text commits only when the card closes, so a crash, quit or remote delete loses it.
    - **Fix:** Commit after 1 s idle or on focus change. In `applicationShouldTerminate`, return `.terminateLater`, flush the card and pending deletes, then reply. On "deleted elsewhere", keep the draft and offer "Save as New Reminder".
36. **The notes fallback accepts silent formatting loss** (just a footnote).
    - **Fix:** If S1 finds no way to detect styling, then on accounts with `supportsTextStyling`, editing notes requires a per-reminder "Edit as plain text (removes formatting)" unlock.
37. **Partial structural moves have no compensation.** If R8's PB `listID` move of a parent and its children fails verification, parent and children end up split across lists.
    - **Fix:** On mismatch, run a compensating txn that moves the already-moved IDs back, then trip, and report the exact IDs.
38. **Read-back only checks the intended property.** It won't catch the C9 membership replace wiping other reminders' sections, or a private save clobbering the EventKit due time (Reminders MenuBar #309).
    - **Fix:** `commit` diffs the full EventKit and PB record of every touched object, and for list-level blob ops the whole list's membership and order map, before and after. Any unintended difference trips the capability and alerts.
39. **Public mode shows hourly repeats as "Daily".** EventKit maps hourly (frequency 4) to daily (C7). A repeat edit then silently replaces the hourly rule.
    - **Fix:** In public mode, any change to an existing rule asks for confirmation: "Replaces the current repeat (may be Hourly)".
40. **Calling `ek.reset()` on error is unsafe here.** Actor re-entrancy lets a fetch completion map EventKit objects on EventKit's queue at the same moment.
    - **Fix:** Never call `reset()`; `rollback()` only the objects in the failed op. Optionally make fetch non-reentrant: a blocking 30 s wait on Backend's own serial queue is legal, because it isn't the cooperative pool. That shrinks `writeGen` to "drop reloads requested before the last write".
41. **One -3002 fails a whole batch in public mode.** It fails the entire `commit()`, and the no-retry rule then means nothing moved.
    - **Fix:** Give each cross-list move its own commit, and report failures per item.
42. **Undo is registered before the op succeeds.** If the op fails, the undo stays and later applies an inverse of something that never happened.
    - **Fix:** Register against a per-op target, and call `removeAllActions(withTarget:)` on failure.
43. **Deleting a parent in public mode may orphan its subtasks.** If S2 shows EventKit doesn't cascade the delete, public mode leaves orphaned subtasks without any warning.
    - **Fix:** Keep PB reads alive when only writes trip (see #23). In full public mode, warn "subtasks may remain".

## 4. Over-engineering

44. **Drop the optimistic patch and revert layer.** C.7 already returns fresh snapshots within tens of milliseconds.
    - **Fix:** Keep only hide-on-pending-delete and the completion animation, and apply the returned snapshots directly.
45. **Calling `refreshSourcesIfNecessary()` after every write (C.7 step 5) is wasteful.** It asks for a remote sync.
    - **Fix:** Call it only on `didBecomeActive`.
46. **Two smaller cuts:**
    - **Spikes run twice.** S7–S9 run unsandboxed first and S11 reruns them sandboxed. Run every spike in the shipping configuration (sandboxed, hardened runtime, Apple Development signing). Rerun unsandboxed only to diagnose a failure, and delete S11.
    - **The early-alert replace path is redundant.** Use `removeAllFetchedDueDateDeltaAlerts` after the fetched assertion, and drop the remove-by-ID path. This also settles the B.6 vs R13 wording conflict.

## 5. Under-specified UI and UX

47. **Bare-key and text-navigation shortcuts will break typing.**
    - **Problem:** Space, ⌫ and `T` declared as menu commands hijack typing in the card and in search. ⌘↑/⌘↓, ⌘←/⌘→ and ⌘E hijack caret movement and Find.
    - **Fix:** Handle Space, ⌫ and T with `onKeyPress` / `onDeleteCommand` on the List or Calendar only. Disable the chord menu items while a text field has focus (use a focused value).
48. **The inline card inside a SwiftUI `List` isn't spiked, and its key handling isn't defined.** Unspecified: row-height animation, focus order (title → notes → checklist), arrows and selection changes while open, and 5k rows.
    - **Fix:** S15 builds the real card inside a List, with this key table:
      - Return in title: move to notes.
      - ⌘↩ or Esc: close.
      - Return in a checklist row: new subtask.
      - ⌫ on an empty subtask: delete it.
      - Pasting multiple lines: one subtask per line.

      Decide the fallback now (an `NSTableView` representable).
49. **Subtasks are drawn twice:** as indented rows and as the card's checklist.
    - **Fix:** When the card is expanded, its checklist is the only child view. Collapsed rows show children indented.
50. **Editing from the Calendar view has no home.** There is no list row to expand, and a popover editor is the macOS 27 popover-crash pattern.
    - **Fix:** Clicking selects and opens the same card in a side panel or sheet. ⌘L jumps to the item in its list.
51. **The Calendar view is missing several pieces:**
    - **No drag source for undated reminders.** Add a collapsible "No Date" tray.
    - **Overdue items:** show them on their past day, in red.
    - **Completed items:** hide them unless Show Completed is on.
    - **Week start:** use `firstWeekday`.
    - **Month overflow:** "+k more" expands in place, not as a popover.
    - **Event click:** opens a read-only info view.
52. **Drawing list icons is unspecified.**
    - **Fix:** Load `Bundle(path: RemindersUICore).image(forResource: "ListBadge" + Name)` as a template tinted with the list colour, falling back to `list.bullet`. Emoji come from `orderFrontCharacterPalette`. The "Color & Icon…" sheet has the 12 swatches, a custom colour, the 71-icon grid and an emoji option.
53. **The tag view is undefined beyond the per-list tag bar.**
    - **Fix:** Chips cycle include → exclude (crossed out) → off, plus an All/Any segmented control and an "Untagged" chip.
54. **Five smaller UI gaps:**
    - **Drag conflicts:** dropping onto a row (make subtask) competes with `reorderContainer` gaps. S15 decides; the fallback is no drop-onto-row (⌘] only). Define hover and rejection highlights, including drops on a group.
    - **No Settings scene:** add `Settings {}` in App.swift (Apple fallback, all-day-overdue, Group by Time, completed window, event calendars).
    - **Completion feel:** specify a 1.5 s hide delay and a strike/grey style.
    - **Renaming:** inline fields for lists, groups, sections and tags.
    - **Card states:** add one table of card controls for bridge off, a tripped capability, a read-only list, a repeating item, and early-alert presets on date-only items (minutes and hours make no sense there). Inline create in "All" lands in that group's list, not the default list.

## 6. Verification gaps

55. **Concurrent edits can be tested without an iPhone.** A second in-process `EKEventStore` writes while the card is open; change notifications fire for other stores in the same process. Assert that closing the card does not overwrite those fields.
56. **Spike additions:**
    - **S1:** a location-alarm write through EventKit.
    - **S3:** all-day and remind-me fixtures.
    - **S4:** a repeating parent with subtasks.
    - **S5:** moving a single subtask.
    - **S7:** actually exercise list undelete.
    - **S8:** sublist order, the early-alert count sign, and the emblem name-to-asset mapping (71 = 71).
    - **S9:**
      - EventKit edit then PB edit in one action keeps the EventKit due time (#309 regression);
      - turning Groceries on in a list with sections;
      - section delete together with children.
    - **S10:** record `EKEventStoreChanged` userInfo (the verified literal keys `EKEventStoreRemindersDataChangedUserInfoKey` / `EKEventStoreCalendarDataChangedUserInfoKey`) so event-only changes can skip the reminders and PB reload.
57. **The self-test in the real account touches account-level state.** It exercises sidebar `listIDsOrdering`, pin slots and groups, all of which sync to every device.
    - **Fix:** In the real account, test only ops scoped to the test list and groups the test created. Run account-ordering and pin tests only in `ttr-test`, and snapshot and restore the order if it is touched.
58. **The release build is never checked with the bridge.** Developer ID signing and the different bundle ID mean new permission grants.
    - **Fix:** M5 exit runs the probe and the self-test on the notarized build, not just "it launches".
59. **Two smaller gaps:**
    - **M2 "matches element by element" is manual.** Have Diagnostics dump the parsed `FX-rich` record as JSON and diff it against an expectation checked into SPIKES.md.
    - **Missing tests:**
      - **LogicTests:** "This Weekend" (next weekend when today is the day before), "Next Week" with `firstWeekday`, the Group-by-Time buckets, the alarm shift rule (#34), and the edit diff against the base (#32).
      - **Integration:** pending deletes are flushed on terminate.

## 7. Factual errors against the research

60. **R8 calls the same-account move "verified in DEC".** It is only inferred statically, from `_applyChanges` calling `removeFromList` + `addReminderChangeItem:`. The critique (gap 3) lists it as unverified. Label it static until S5.
61. **Two overclaims:**
    - **Built-in smart lists:** the plan says their hidden state is "unreadable". Only `fetchSmartListWithObjectID:` is missing; the `fetchSmartListSection…` variants remain. Keeping it app-local is fine; drop the word.
    - **Sandbox proof:** C.3 says the bridge is "proven in sandboxed apps". Only reads and tag, flag and urgent writes are proven sandboxed; structural writes are proven only standalone (prior_art open question 1).

## What the plan gets right and must keep

- **EventKit writes only changed keys**, verified in `_applyChanges`: never assign `alarms` or `recurrenceRules` wholesale, write notes only when changed, never touch `url`/`location`/`startDateComponents`.
- **Write order:** EventKit first, then at most one `REMSaveRequest` built from objects re-fetched by ID. Private writes are never retried, and a partial result shows a banner.
- **Bridge corrections C1–C6 are applied:**
  - early alerts fetched with the right fetch options, plus the assertion;
  - forwarded selectors probed through the storage class;
  - `isSaved`, not `saved`;
  - sort-style and emblem constants read with `dlsym`;
  - `REMObject` as the primary accessor;
  - the store getter nil-checked.
- **Safety framework:** structural writes gated by a self-test per OS build, persistent trips, a global kill switch, all private names in one ObjC `@try` shim, and no exceptions crossing Swift frames.
- **Concurrency:** one `Backend` actor on a serial queue plus a MainActor `Store`, Sendable snapshots, a 30 s fetch timeout with `cancelFetchRequest`, a serial op queue, and undo on main.
- **Deletes:** pending delete with an 8 s window, Recently Deleted restore that keeps IDs, and confirmations with counts for every cascading delete.
- **Repeating reminders:** R1 row identity `(id, due)` with no retry.
- **URLs only as private attachments:** `EKCalendarItem.url` is never used.
- **Sandbox:** on, with a one-line escape hatch. No SQLite, no Full Disk Access, and no app-posted notifications.
- **Signing:** stable identities, never ad-hoc, separate Debug and Release bundle IDs.
- **Testing:** fixtures made in Reminders.app, a dedicated `ttr-test` macOS user, and integration tests guarded by an environment variable, full access and a marker list.
- **Semantics:** pure Reminders (no Someday, Evening or Deadline), Reminders shortcuts win over Things, and show-completed and collapsed state are app-local (confirmed correct, since the model has no such attributes).
- **Size:** about 18 files, no single-implementation protocols, no dependencies.