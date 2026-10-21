# TickTick for macOS: product and UX research report, with a mapping to an Apple Reminders backend

**Research date:** 2026-10-21. Current TickTick Mac version is **8.2.40** (Mac App Store, released about a day earlier). Minimum OS is macOS 12. It is a native Swift app. [VERIFIED: S31, S40]

**Method.** help.ticktick.com renders with JavaScript, so its articles were read through the `r.jina.ai` reader proxy. TickTick is not installed on this machine, so no in-app check was possible. I did not run AppleScript or Shortcuts against Reminders and did not read any personal data.

**Tags.** [VERIFIED: src] means confirmed in an official source or local file. [DOCS] means vendor documentation. [FORUM/BLOG] means a third-party source. [UNVERIFIED/INFERENCE] means my own reasoning or unconfirmed.

### Source keys

**TickTick help articles**

| Key | Topic | URL |
|---|---|---|
| S1 | Add Tasks | https://help.ticktick.com/articles/7055782422935240704 |
| S2 | Desktop Interaction Tips | https://help.ticktick.com/articles/7351523697951244288 |
| S3 | Reminders | https://help.ticktick.com/articles/7055782395743567872 |
| S4 | Recurring tasks | https://help.ticktick.com/articles/7055782206349770752 |
| S5 | Filters | https://help.ticktick.com/articles/7055782240994721792 |
| S6 | Tags | https://help.ticktick.com/articles/7055782255804809216 |
| S7 | Lists and Smart Lists | https://help.ticktick.com/articles/7055782283059396608 |
| S8 | Group & Sort | https://help.ticktick.com/articles/7056594711640801280 |
| S9 | Timeline | https://help.ticktick.com/articles/7055782331050622976 |
| S10 | Kanban | https://help.ticktick.com/articles/7055782353376903168 |
| S11 | Calendar View Options | https://help.ticktick.com/articles/7055782085826445312 |
| S12 | Week / multi-day views | https://help.ticktick.com/articles/7055782149730861056 |
| S13 | Calendar subscriptions | https://help.ticktick.com/articles/7055781614550253568 |
| S14 | FAQ | https://help.ticktick.com/articles/7055792921664028672 |
| S15 | Task Details | https://help.ticktick.com/articles/7055782408586526720 |
| S16 | Multilevel Tasks | https://help.ticktick.com/articles/7055782219767349248 |
| S17 | Search | https://help.ticktick.com/articles/7473275590313771008 |
| S18 | Sticky Notes | https://help.ticktick.com/articles/7055780431722971136 |
| S19 | Widgets | https://help.ticktick.com/articles/7055780404896202752 |
| S20 | Suggested Tasks | https://help.ticktick.com/articles/7401564165023727616 |
| S21 | Eisenhower Matrix | https://help.ticktick.com/articles/7055782055577124864 |
| S22 | URL scheme | https://help.ticktick.com/articles/7055781515422072832 |
| S23 | Backup & Import | https://help.ticktick.com/articles/7055781405648748544 |
| S24 | What's New (2026) | https://help.ticktick.com/articles/7082552170989486080 |
| S25 | Updates in 2025 | https://help.ticktick.com/external/articles/7505896563223298048 |
| S26 | Updates in 2024 | https://help.ticktick.com/external/articles/7301088783166865408 |
| S27 | Updates in 2023 | https://help.ticktick.com/external/articles/7155128685119406080 |
| S28 | Appearance | https://help.ticktick.com/external/articles/7254750337695744000 |
| S29 | Agenda View | https://help.ticktick.com/articles/7213444784319365120 |

**Other TickTick and Apple sources**

| Key | Source | URL |
|---|---|---|
| S30 | TickTick Mac page | https://ticktick.com/mac |
| S31 | Mac App Store listing | https://apps.apple.com/us/app/ticktick-to-do-list-calendar/id966085870 |
| S34 | TickTick on X (Postpone) | https://x.com/ticktick/status/1432727380070699016 |
| S35 | TickTick on X (auto-import path) | https://x.com/ticktick/status/1221626953544826881 |
| S38 | TickTick blog, 20 lesser-known features | https://blog.ticktick.com/2020/12/08/20-lesser-known-ticktick-features/ |
| S39 | App Store Mac story | https://apps.apple.com/ph/mac/story/id1604445494 |
| S43 | TickTick blog, smart date parsing (2016) | https://blog.ticktick.com/2016/04/12/ticktick-270-a-new-breakthrough-with-city/ |
| S46 | TickTick blog, task nesting | https://blog.ticktick.com/2020/08/10/how-task-nesting-helps-you-with-gtd/ |

**Third-party sources**

| Key | Source | URL |
|---|---|---|
| S32 | Fechin shortcut cheat sheet | https://raw.githubusercontent.com/Fechin/reference/main/source/_posts/ticktick.md |
| S33 | TidBITS review (Aug 2025) | https://tidbits.com/2025/08/14/ticktick-provides-a-focused-daily-task-list-and-more/ |
| S36 | MakeUseOf organizing guide | https://www.makeuseof.com/guide-to-organizing-tasks-in-ticktick/ |
| S37 | Curtis McHale quick-add syntax | https://curtismchale.ca/2020/08/10/ticktick-quick-add-syntax/ |
| S40 | Desktop Insights tech-stack detection | https://desktopinsights.com/apps/ticktick |
| S41 | TechRounder | https://www.techrounder.com/productivity/integrating-ticktick-apple-reminders-and-apple-calendar-for-seamless-productivity/ |
| S42 | Community Raycast/Claude TickTick API reference | https://skillsmp.com/zh/creators/jkrumm/ticktick-raycast/claude-skills-ticktick-api |
| S44 | The Sweet Setup | https://thesweetsetup.com/a-close-look-at-ticktick/ |
| S45 | Cult of Mac (2018) | https://www.cultofmac.com/559009/ticktick-review-best-task-manager/ |

**Local files**

| Key | File |
|---|---|
| L1 | `…/MacOSX.sdk/System/Library/Frameworks/EventKit.framework/Headers/*.h` |
| L2 | `/System/Library/PrivateFrameworks/RemindersAppIntents.framework/Versions/A/Resources/Metadata.appintents/extract.actionsdata` |

---

## 0. New facts from local metadata (adds to what was already established)

These are entity properties and enum cases read from L2 with `python3 -I` (read only). [VERIFIED: L2]

**Readable entity properties**
- **ReminderEntity:** title, note, images, subtasks, tags, urls (plural), dueDate, recurrence, isCompleted, isFlagged, creationDate, completionDate, list, section, locationTrigger, lastModifiedDate, contactPerson, assignedPerson, vehicleTrigger, earlyAlert, isUrgent, priorityLevel, isSubtask, parent.
  - This means tags, section, parent and subtasks *can be read* through the Shortcuts path. EventKit cannot read them.
- **ListEntity:** color, badge, parent, name, type, participants, owner, sections, isPinned, showsCompleted, autoCategorize, listLayout, sortingStyle.
- **SectionEntity:** isCollapsed, name, list, reminders.
- **GroupEntity:** name, lists, showsCompleted.
- **SmartListEntity:** type, isHidden.
- **EarlyAlertEntity:** unit, interval.

**Enum cases**
- `ListLayout`: list, columns. Columns is the native equivalent of Kanban.
- `ListType`: standard, groceries.
- `SortingStyle`: default, manual, displayDateOldestFirst, displayDateNewestFirst, priorityLowestFirst, priorityHighestFirst, creationDateOldestFirst, creationDateNewestFirst, titleAscending, titleDescending.
- `ReminderInsertionPosition`: **top, bottom only.** You can't put a reminder at an arbitrary position, so a full manual order cannot be pushed to Reminders.
- `MoveTargetType`: list, section, parentReminder.
- `SmartListType`: today, scheduled, all, flagged, assigned, **urgent**, completed.
- `PriorityLevel`: none, low, medium, high.
- `LocationTriggerEvent`: arrive, depart.
- `VehicleTrigger`: connected, disconnected.
- `Unit` (early alert): minute, hour, day, week, month.
- `DeleteRecurringRemindersOption`: thisReminder, allFutureReminders.

**EventKit (L1) confirms**
- EKCalendarItem has title, location, notes, a **single** `URL`, read-only lastModifiedDate and creationDate, `timeZone`, `alarms[]`, `recurrenceRules[]`, read-only `attendees`, and `calendarItemExternalIdentifier`.
- EKAlarm has absoluteDate, relativeOffset, `structuredLocation` and `proximity`, plus emailAddress, soundName and url.
- EKEventStore has `saveReminder:commit:`, `removeReminder:commit:`, `commit:`, `reset`, `refreshSourcesIfNecessary`, `defaultCalendarForNewReminders`, `calendarItemsWithExternalIdentifier:`, predicates for incomplete reminders by due-date range and completed reminders by completion-date range, and `EKEventStoreChangedNotification`.
- There is **no** sort-order, section, tag, parent or flag property anywhere in EventKit.

---

## 1. Information architecture (Mac)

### 1.1 Left icon rail ("tab bar")

- **Modules:** Tasks, Calendar, Eisenhower Matrix, Focus (Pomodoro), Habit, Countdown (added 2025), Search, Sync, Notifications, Help (`?`, bottom-left, leads to the Shortcuts sheet), and the avatar, which opens Settings.
  - Help location and the Shortcuts sheet: [VERIFIED: S2].
  - Focus tab added to the desktop sidebar, and tabs reorderable: Jan 2023 [VERIFIED: S27].
  - Search button in the sidebar [VERIFIED: S17].
  - The exact set and order of the Sync and Notifications icons: [UNVERIFIED/INFERENCE, taken from the brief].
- Matrix, Pomodoro and Habit are opt-in under **Avatar → Settings → Features** [VERIFIED: S14, S21, S39].
- **⌘K command menu:** type a module name to jump to it. Mac only, Apr 2024 [VERIFIED: S26]. Also listed in the cheat sheet [FORUM/BLOG: S32].
- **Mini Calendar** in the sidebar: PC only (Settings → More Settings) [VERIFIED: S26].

### 1.2 Sidebar inside Tasks

- **Built-in smart lists:** All, Today, Tomorrow, Next 7 Days, Assigned to Me, Inbox, then Completed, Won't Do, Trash, Summary, plus sections for Tags and Filters [VERIFIED: S7, S14, S15; Summary via the `G B` shortcut in S32].
- **Visibility:** each smart list can be set to Show, Hide, or Show if not empty. **Inbox cannot be hidden or deleted.**
  - Mac path: Avatar → Settings → Features → Smart Lists, or the gear next to "Add List" in the sidebar [VERIFIED: S7, S14].
  - Tags and Filters sections are also toggled to Show there [VERIFIED: S5, S6].
- **Counts:** per-list unfinished counts, which can be hidden (Appearance → Display). "Hide Note" counts tasks only [VERIFIED: S28, S27].
- **Lists:**
  - Fields: name, color (custom hex color codes since 2024), emoji icon (picked from the icon, *or the first character of the name is an emoji*), folder, and a show/hide setting [VERIFIED: S7, S26].
  - Actions: pin, edit, delete, archive, share, duplicate [VERIFIED: S7; archive in S25; duplicate in the Udemy course listing, FORUM/BLOG].
  - List kind: task list or note list [FORUM/BLOG: S42, `kind TASK|NOTE`].
  - The view (list / kanban / timeline) is chosen when the list is created [VERIFIED: S27, Nov 2023].
  - Backgrounds: mobile only [VERIFIED: S7].
- **Folders:** created by dragging one list onto another. They collapse and expand. Hierarchy is Folder → List → Section → Task → Subtask [VERIFIED: S14; S36 FORUM/BLOG].
- **Tags:**
  - Shown in the sidebar, with color, a **parent tag (two levels)**, pin, edit and delete. Deleting a tag removes it from tasks but keeps the tasks.
  - Reorder tags by dragging; drag a tag under another tag to nest it [VERIFIED: S6].
- **Filters (custom smart lists):** created with Add → Filter at the bottom of the sidebar. They appear under Lists. Details in §11 [VERIFIED: S5].
- **"+" Add menu** at the bottom of the sidebar: List, Filter, and probably Folder and Tag [VERIFIED: S5, S7; Folder/Tag UNVERIFIED].

---

## 2. Layout and the detail pane

- **Three panes:** sidebar, task list, and a detail pane on the right.
  - Desktop 6.0 (Jul 2024) added "tasks and calendar in one view": a list beside the calendar, with drag from list to calendar [VERIFIED: S26].
  - "Open your task list and calendar side by side" [VERIFIED: S30].
  - "Open in a new window" from the right-click menu creates independent windows [VERIFIED: S27; added on Windows, Mac UNVERIFIED].
- **Detail pane, top to bottom** [VERIFIED: S15]:
  1. **Header row:** completion checkbox, then the "Due Date" / Date & Reminder control (a popover with **Date | Duration** tabs, time, reminder, repeat), then priority flag.
     - Progress bar: hover the line under Due Date to set a percentage. With check items, progress is computed automatically [VERIFIED: S15, S38].
  2. **Title.**
  3. **Body.** One of two modes, switched with a toggle at the top right [VERIFIED: S15]:
     - **Description mode:** a rich editor with Markdown triggered by typing a space after the syntax. Formatting marks are hidden (2026), with highlight colors and collapsible headings [VERIFIED: S24].
       - `/` opens a command menu for headings, lists, attachments and subtasks.
       - `[[` searches for another task and inserts a link to it.
       - Selecting text shows a formatting toolbar.
       - **⌘⇧0** opens immersive full-screen writing [VERIFIED: S2, S26].
     - **Check items mode:** Return adds an item. Each item has a delete button, a drag handle (≡) and a per-item reminder clock [VERIFIED: S15].
  4. **Subtasks block** (nested tasks), attachments, and comments in shared lists [VERIFIED: S15, S16].
  5. **Footer:** a **List selector** at the bottom left that you can type into to search, plus a `…` menu at the bottom right [VERIFIED: S15, S16].
- **`…` menu actions** [VERIFIED: S15; S16; S18; S14; S38 for Status]:
  - Pin, Share, Won't Do (and Restart), Copy Link, Duplicate.
  - Save as Template, Task Activities (change history), Convert to Note, Start Focus.
  - Add Subtask, Link Parent Task, Tags, Attachment.
  - Open as Sticky Note.
  - Print and Delete are unconfirmed [UNVERIFIED].
  - The menu can be customized (pin or reorder actions) [VERIFIED: S15].
- **Right-click context menu on a task** [VERIFIED: S15, S14, S16, S18, S26, S39]:
  - Date shortcuts: Today, Tomorrow, Next Week, Custom, **Clear Date** (Jan 2024).
  - Priority, Move to, Tags, Assign to, Add Subtask, Link Parent Task.
  - Skip the recurrence (for repeating tasks), Won't Do, Start Focus, Open as Sticky Note, Open in new window, Delete, Merge (in the Mac story).

---

## 3. Task model (TickTick)

API field names come from a community reference that copies TickTick's Open API [FORUM/BLOG: S42].

| Attribute | Behavior | Source |
|---|---|---|
| title | Plain text. Date text can be removed after parsing ("Remove Text in Tasks"). | S43, S38 |
| content / desc | Markdown-ish rich text, task links, images inline | S15, S24 |
| kind | TEXT / CHECKLIST / NOTE | S42 [FORUM/BLOG] |
| check items (`items[]`) | Lightweight: title, status, own date/reminder, sortOrder. Only check items drive parent progress. **The parent auto-completes when all check items are done.** | S15, S16, S46 |
| subtasks | Full tasks, **up to 5 levels**. Same properties as tasks (dates, tags, priority, assignee, focus, restore from Trash). Created by drag, ⇧Return, the `/` menu or Link Parent Task. Sorting stays within a level. | S16, S32 |
| start / due | "Date" (single point) or "Duration" (Start Time → End Time, multi-day, all-day spans). Duration was Premium on some platforms. | S15, S31 |
| all-day | Yes. All-day spans across days. | S15, S12 |
| time zone | Fixed vs Floating per task | S38 |
| reminders | Multiple per task (Premium: 5 per task). Presets plus Custom. Default Reminder setting. "At the end" reminder for duration tasks (Jan 2025). Format `TRIGGER:P0DT9H0M0S`. | S3, S31, S25, S42 |
| repeat | Every day/week/month/year/custom. **Repeat type: By Due Date / By Completion Date / By Specific Dates.** Ends On date, or Ends After N times. Skip the recurrence. Edit "Only this Recurrence". Stored as an RRULE `repeatFlag`. Lunar, Ebbinghaus and yearly custom repeats exist; yearly custom is not on Mac. | S4, S14, S26, S42 |
| priority | None / Low / Medium / High. API values 0/1/3/5 ("no 2 or 4"). Colors: high red, medium yellow, low blue, none grey. | S15, S42; colors [UNVERIFIED/INFERENCE] |
| tags | Many per task, two levels of nesting, colors | S6 |
| list / section | One list per task. Section = custom group or kanban column. | S8, S10 |
| location reminder | Arrive at a place. **iOS/Android only, not on Mac.** | S3, S14 |
| pin | Stays at the top of the list | S15 |
| status | open / completed / **Won't Do** (abandoned, can Restart). API: 0 = normal, 2 = completed. Won't Do is reportedly −1. | S15, S42; Won't Do value [UNVERIFIED] |
| progress % | Manual or computed | S38, S15 |
| attachments | Images, recordings, files, video. Free: 1 upload/day, 10 MB. Premium: 199/day, 39 per task, 20 MB. Other sources give 99/day and 20 per task. | S15, S14 (limits conflict) |
| comments, assignee, Task Activities | Collaboration features | S10, S15 |
| estimate | Pomodoros or duration, actual time tracked | S38 |
| timestamps | created, modified, completed. Group by created; sort by created or modified (2026). | S8, S24 |

---

## 4. Views

### 4.1 List view (default)

- Sections come from the grouping (§5).
- "Completed & Won't Do" is a collapsible section at the bottom [VERIFIED: S15, S39].
- An "Overdue" section has a **Postpone** button (§9) [VERIFIED: S34].
- In Today there is a **Suggested Tasks** button at the top right [VERIFIED: S20]. It shows four buckets:
  - **Recently Added:** created just now, today or yesterday, with no date.
  - **Postponed Tasks:** dates changed more than 2, 3 or 5 times.
  - **Long Overdue:** created more than 7, 14 or 30 days ago and still open.
  - **Upcoming:** due tomorrow or within 2 days.
  - Excludes recurring tasks, tasks already in Today, and completed tasks. A `+` adds a task to Today.
- **Plan Your Day** walks through overdue and today's tasks one at a time: complete, move to tomorrow, reschedule, or delete. This is documented for mobile; desktop availability is unverified [VERIFIED: S38, S36].

### 4.2 Kanban

- Kanban is a display mode, not a separate feature. It works in regular lists, **Smart Lists, Folders and Tags** (since Jun 2023) [VERIFIED: S10, S27].
- Columns are **Sections**. To manage columns, Group must be set to "Custom".
  - In smart lists, columns come from the grouping: Date + Priority, List + Date, or Assignee + Date.
- Section actions: `…` on a section to rename, create or delete. `+` in a section header adds a task.
- Drag tasks between columns to change section. Columns can be reordered.
- Column width: S / M / L (desktop) [VERIFIED: S10, S26].
- Sections can be moved to other lists (Mar 2024). Deleting a section can move its tasks elsewhere (Aug 2024) [VERIFIED: S26].

### 4.3 Timeline (Gantt-lite)

- Opened from `…` → View → Timeline. **Regular lists only. Today, Tomorrow and Next 7 Days are not supported** [VERIFIED: S9].
- Only dated tasks appear. Undated tasks sit in a **"Schedule Tasks"** panel on the right and can be dragged onto the timeline [VERIFIED: S9].
- Click empty space to create a task on that date.
- Drag the body to move start and end together. Drag an edge to change the duration.
- Scale: day / week / month. Horizontal scroll.
- Color by list, tag or priority.
- **Recurring cycles are not shown.**
- No dependencies are documented [VERIFIED: S9].
- Timeline is Premium [VERIFIED: S31].

### 4.4 Calendar

- **Views:**
  - Day, Week, Month, Year (heatmap and task previews, 2026), List.
  - Agenda: a linear scrolling timeline, desktop 6.0 [VERIFIED: S29].
  - Multi-Day (1–14 days) and Multi-Week (1–6 weeks): desktop only (Desktop 5.0, Nov 2023) [VERIFIED: S12, S27, S24].
  - 3-Day: mobile [VERIFIED: S12].
- **Creating:**
  - Click the timeline to create a task at that time point; drag to set a duration.
  - Click next to a date for an all-day task.
  - Drag across the date grid for a multi-day task [VERIFIED: S12].
- **Editing:**
  - Drag a block to reschedule. Hover an edge until the arrows appear, then drag to resize.
  - **Option-drag duplicates (Mac).**
  - Holding Option reveals checkboxes so you can complete from the calendar.
  - Calendar checkboxes view option (Oct 2024) [VERIFIED: S2, S12, S26].
- **Mac gaps:**
  - Calendar multi-select by Cmd-click or rubber band: Windows and Web; "macOS version under development" [VERIFIED: S2, S25, S11].
  - Bulk Postpone: Windows and Web only [VERIFIED: S25, S11].
  - Dragging task edges to make multi-day spans: "not on Mac" [VERIFIED: S26].
- **Arrange Tasks panel:** undated tasks, dragged into the calendar [VERIFIED: S12, S14].
- **Navigation:**
  - Arrow keys, two-finger swipe, and the Today button.
  - Double-click the month title to return to the current week.
  - ⌘-scroll or pinch to zoom the timeline; Shift-scroll for horizontal.
  - Drag the bottom edge of the all-day area to make it taller [VERIFIED: S2, S12].
  - Hours 00:00–07:00 and 21:00–24:00 are hidden by default and can be adjusted [VERIFIED: S14, S38].
- **View options** [VERIFIED: S11, S26]:
  - Color: tasks by List / Tag / Priority; habits and countdowns fixed or individual.
  - Filter View Range: which lists appear (icon at top left on desktop).
  - Style: Modern / Classic; Show Item Icons.
  - Up to 5 time zones.
  - Show Completed, Show Check Item, Show Future Cycles (repeats), Show Habit, Show Focus Records.
- **Calendar sources** [VERIFIED: S13, S14]:
  - Local Calendar, Google, iCloud, Outlook, Exchange, CalDAV, URL.
  - Google has two-way integration.
  - Subscribed events were reported as not editable [FORUM/BLOG].
- Apple Health data on the calendar (iOS) [VERIFIED: S25].

### 4.5 Eisenhower Matrix

- Four quadrants: Urgent & Important, Not Urgent & Important, Urgent & Unimportant, Not Urgent & Unimportant [VERIFIED: S21].
- Tasks are placed by **priority** by default. Adding a task in Q1 sets it to Today + High.
- Rules per quadrant are editable by List / Tag / Date / Priority / Task, via hover → `…` → Edit.
- Drag between quadrants. Which fields change on drop is not documented [VERIFIED: S21; field changes UNVERIFIED].
- Desktop quadrant menu: Sort only [VERIFIED: S21].
- 8.2.40 adds **multiple matrix views** (for example work vs personal) and an assignee filter [VERIFIED: S31].

### 4.6 Other modules (app-local by nature)

- **Focus / Pomodoro:** floating timer window; menu-bar countdown while running; estimate vs actual; `⌘⌥⇧P` starts or abandons [VERIFIED: S39, S38, S32].
- **Habits:** check-ins, streaks, heatmap [VERIFIED: S38].
- **Countdowns:** May 2025, shown in Smart Lists and the Calendar [VERIFIED: S25].
- **Summary:** a report of completed and incomplete work filtered by list, tag or date, which can be inserted into notes [VERIFIED: S38, S26].
- **AI Assistant:** Sep–Oct 2026. Desktop: Settings → Features [VERIFIED: S24].

---

## 5. Grouping, sorting and view options

On desktop, these are under the **Sort** button at the top right of a list [VERIFIED: S8].

- **Group by:**
  - List (smart lists and folders only).
  - **Time:** Overdue, Today, Tomorrow, Next 7 Days, Later.
  - Priority: High / Medium / Low / No Priority.
  - Tag.
  - Assignee (shared lists only).
  - Created Time (2026).
  - **Custom** (user sections; regular lists only).
  - None [UNVERIFIED].
- **Sort by:** Date (due), Priority, Title, Created Time, Modified Time. Created and Modified offer Newest First or Oldest First. Manual drag order exists [VERIFIED: S8, S24; Title in S36 and S31 "order, date, name, priority"].
  - "Restore default date order" button [VERIFIED: S8].
  - There are 20+ group-and-sort combinations, for example group by List and sort by Date in Today [VERIFIED: S27].
- **Subtask hierarchy is preserved under every sort** [VERIFIED: S16].
- **View options:**
  - Hide/Show Completed, Show/Hide Details (shows notes and check-item previews under titles) [FORUM/BLOG: S36; S39].
  - Kanban size [VERIFIED: S10].
  - Separate list views per device type (Jun 2026) [VERIFIED: S24].
- **Completed tasks:** strikethrough style option (Jan 2023) [VERIFIED: S27, S28].

---

## 6. Quick Add and smart recognition

- **Entry points** [VERIFIED: S1, S30, S31, S26; S32]:
  - The inline "Add task" bar at the top of the list.
  - `⌘N`.
  - `Return` adds a task below the current one; `⇧Return` adds a subtask.
  - A global Quick Add window (hotkey in §8). In that window, **⇧Return adds a description and ⌘Return creates the task.**
  - The input-box style can be switched to make setting date, priority and list faster.
- **Tokens.** No current official page lists these; the in-app Shortcuts sheet shows them according to S32 [FORUM/BLOG: S32, S36, S37].

| Token | Meaning | Notes |
|---|---|---|
| `*` | Date picker | Natural-language date text also works without `*` |
| `!` | Priority picker | The value format after `!` is unverified (`!1/!3/!5`, `!high`?) |
| `#` | Tag (pick or create) | Officially confirmed [VERIFIED: S6] |
| `~` or `^` | Add or move to a list | `~` is current per MakeUseOf; `^` per the 2020 post; the cheat sheet lists both |
| `@` | Assign to a member | Shared lists only |

- **Natural-language dates:**
  - "Meeting at 9 tomorrow" sets the date and the reminder.
  - Recognized words are **highlighted in blue**. Click a highlight, or press Delete, to turn it back into plain text.
  - Settings → General → Smart Recognition → **Smart Date Parsing** toggle, and **Remove Text in Tasks** (removes the date text from the title) [VERIFIED: S1, S38, S43].
  - Repeat phrases ("every Monday") are probably recognized [UNVERIFIED].
- The toolbar dropdown next to the input offers priority, attachments and "Add from Template". The toolbar can be customized (Aug 2024) [VERIFIED: S1, S14, S26].
- The "Add" menu has **Convert to Event** and **Convert to Note** (Aug 2026) [VERIFIED: S24].
- **Weaknesses on Mac:**
  - Duration can't be set in quick entry.
  - Moving tasks between lists needs the mouse; there's no full keyboard flow like OmniFocus or Things [FORUM/BLOG: S44, 2020].

---

## 7. macOS system integration

| Feature | Details | Source |
|---|---|---|
| Global Quick Add | Default is **conflicting**: ⌘⇧A (official Mac page and App Store), Shift+Alt+A (help S1, which covers "Windows and Mac"), Ctrl⇧A (cheat sheet). Configurable in Settings → Hotkeys (Global Actions / Common Operations). Implemented with MASShortcut. | S30, S31, S1, S32, S18, S40 |
| Mini window / menu bar extra | ⌘⇧O shows or hides it. Shows tasks and can start focus. The remaining Pomodoro time appears in the menu bar. | S30, S32, S39 |
| Sticky notes | Right-click → Open as Sticky Note (or several at once). New Sticky Note hotkey. ⌘W closes. ⇧⌘C sets color. **F12 pins** (always on top); "Pin by Default". ⌥⌘↑/←/→ arranges notes to the top, left or right. ⌘E expands or collapses all. Double-click the title bar for single-line mode. Settings: default color, font size, grid spacing, opacity, dark backgrounds. **Desktop only, not synced.** | S18, S27, S32 |
| Widgets (macOS 14+) | Tasks, Calendar, Matrix, Pomodoro, Habits, Countdowns. Interactive: habit check-in and focus start. Interactive task check-off on Mac is unverified. | S19, S27 |
| Dock badge | Settings → General → "Choose task to be counted in Dock" | S14 |
| Siri / App Intents | 8.2.10 adds "Siri AI" task creation, **macOS 27 only**. Shortcuts support since Sonoma. | S31 |
| URL scheme | `ticktick://x-callback-url/v1/add_task?title,startDate,endDate,allDay,priority(0/1/3/5),content,list,subtasks` with x-success returning taskID. `ticktick://v1/show?smartlist=all|today|tomorrow|next_7_days|assign_to_me`. `ticktick://v1/search?keyword=`. | S22 |
| Notifications | Reminder pop-up with Dismiss / Start Focus / Done / Snooze. Redesigned in Desktop 5.0. Shows in-app, outside the app, and on the lock screen. | S3, S27 |
| Print | ⌘P | S32 |
| Updates | Sparkle (direct download) plus the Mac App Store | S40 |
| Tech stack | Native Swift/AppKit (SnapKit), GRDB/SQLite local store, Alamofire/Starscream sync, possibly Kotlin Multiplatform. Low-confidence third-party detection. | S40 [FORUM/BLOG] |

---

## 8. Keyboard shortcuts (Mac)

Primary source is the cheat sheet S32, which mirrors the in-app `?` → Shortcuts sheet [FORUM/BLOG]. Items marked † are confirmed by official help.

| Area | Shortcuts |
|---|---|
| General | ⌘S sync · Esc cancel · ⌘Z undo · ⌘⇧Z redo · ⌘P print · ⌘K command menu† (S26) · `?` shortcuts sheet† (S2) · ⌘, settings |
| Global | Quick add (see §7) · ⌘⇧O mini window† (S30) · ⌘⌥⇧P start or abandon Pomodoro · New Sticky Note (user-assigned)† (S18) |
| Go to (G then key) | `G A` All · `G T` Today · `G R` Tomorrow · `G N` Next 7 days · `G M` Assigned to me · `G I` Inbox · `G C` Completed · `G W` Won't do · `G B` Summary · `G G` Trash · `G S` Settings |
| Task | ⌘N add · Return add below · ⇧Return add subtask · ↑/↓ move selection† (S2) · ⇧↑/↓ extend selection† (S2) |
| Edit | ⌘⇧M complete · ⌘⌫ delete · ⌘D set date · ⌘0 clear date · ⌘1 today · ⌘2 tomorrow · ⌘3 next week · ⌃0 / ⌃1 / ⌃2 / ⌃3 priority none / low / medium / high. **Conflict:** S2 says "Ctrl+0 sets all selected to today". |
| Views | `V L` list · `V K` kanban · Timeline (the cheat sheet says `G T`, which collides with Today; likely `V T` [UNVERIFIED]) · Calendar: `D`/`1` day · `W`/`2` week · `M`/`3` month · `T` today · ←/→/↑/↓ move through dates† (S2) |
| Editor | ⌘⇧0 immersive mode† · `/` command menu† · `[[` task link† · ⇧←/→ select by character · ⌥⇧←/→ select by word (S2) |
| Calendar | ⌥-drag duplicate† · hold ⌥ to show checkboxes and icons† · ⌘-scroll zoom† · ⌘+ / ⌘− / ⌘0 font size† (S2, S11) |
| Sticky note | F12 pin · ⇧⌘C color · ⌘E expand or collapse all · ⌥⌘↑/←/→ arrange† (S18) |
| Desktop 2025 | Option/Alt modifier shortcuts were added (Jul 2025) but are not listed [VERIFIED: S25] |

---

## 9. Multi-select, batch edit, drag and drop, overdue handling

- **Multi-select in lists:** ⌘-click, ⇧-click for a range, ⇧↑/↓, or rubber-band drag. A **batch toolbar on the right** edits date, priority, list and tags. Right-click also edits the selection, and Link Parent Task works on many tasks at once [VERIFIED: S2, S14, S16].
- **Drag and drop** [VERIFIED: S2, S6, S16, S12, S10, S26]:
  - Drag the task handle (≡) onto a sidebar **list** to move it.
  - Onto a **smart list** (Today, Tomorrow, …) to set the due date.
  - Onto a **tag** to add the tag.
  - Works with a multi-selection.
  - **Down and to the right** of another task makes it a subtask; drag back out to unnest.
  - Reorder within a list (manual order).
  - Drag onto calendar or timeline slots to schedule; between kanban columns to change section; from the list to the calendar in side-by-side mode.
- **Overdue handling:**
  - With Today, Next 7 Days or All grouped by Time, the **Overdue section header has "Postpone"**, which moves all overdue tasks to today in one click [VERIFIED: S34, 2021].
  - Multi-select "Postpone" shifts dates forward in bulk: Windows and Web only [VERIFIED: S11, S25].
  - Plan Your Day and Suggested Tasks (§4.1).
  - The right-click Date submenu has Today / Tomorrow / Next Week / Custom / Clear [VERIFIED: S15, S26].
  - A "Smart Postpone" feature name was **not found** [UNVERIFIED].
- **Undo:** ⌘Z / ⌘⇧Z [FORUM/BLOG: S32]. Whether completing or deleting shows an undo toast is unverified.

## 10. Completed, Won't Do and Trash

- Completed and Won't Do are smart lists. Both also appear as a "Completed & Won't Do" section in each list [VERIFIED: S15, S14].
- Won't Do tasks can be Restarted [VERIFIED: S15].
- Trash: subtasks "can be recovered from Trash" [VERIFIED: S16]. Retention period and Empty Trash were not found [UNVERIFIED].

## 11. Search and filters

- **Search:** a sidebar button. Types are Tasks / Lists / Tags / Filters. Task results can be filtered by lists, tags, priorities and dates, and a search can be saved as a Filter.
  - The new filtered search (Jun 2026) is **"not currently supported on Mac"** [VERIFIED: S17, S24].
  - ⌘F is a Windows shortcut; the Mac equivalent is unverified [FORUM/BLOG: S32].
- **Filters:**
  - **Normal mode:** lists, tags, date, priority, plus a content keyword.
  - **Advanced mode:** multiple statements joined by AND / OR over lists, dates, priorities and tags, with Preview before saving [VERIFIED: S5].
  - Assignee and type conditions are probably available [UNVERIFIED].
  - Custom smart lists (filters) are Premium [VERIFIED: S31].

## 12. Notifications and snooze

- Pop-up actions: Dismiss / Start Focus / Done / Snooze [VERIFIED: S3].
- Snooze presets: "minutes, hours, next day" plus custom [FORUM/BLOG]. Exact values unverified.
- **Constant Reminder:** repeats every minute until handled. Per-type toggles for tasks, habits and anniversaries (Jun 2026). On iOS 26 it rings like an alarm. The FAQ says mobile only, so desktop availability is unclear [VERIFIED: S24, S25, S14; S33].
- **Daily Notification:** a summary at a set time, with skip-weekends [VERIFIED: S38].
- **Ringtones:** per-priority ringtone option [VERIFIED: S3].
- **Email notifications:** web setting, up to 50 per day [VERIFIED: S3; S33].
- **Do Not Disturb per shared list** [VERIFIED: S14].

## 13. Appearance

Settings → Appearance [VERIFIED: S28, S24, S26]:
- Themes: color, seasonal, city, photo, and custom image with color, brightness, blur and opacity. Custom dark theme (2026).
- Auto dark mode following the system.
- Ten app icons.
- Font size (Display). The font follows the system.
- Hide counts; strikethrough for completed tasks.
- Card style (8.0); calendar Modern style.

## 14. Sync and offline

- TickTick uses its own cloud. The local SQLite (GRDB) store lets it work offline [FORUM/BLOG: S40].
- Known gaps: task reordering and event archiving don't sync between iPhone and Mac [FORUM/BLOG: S33]. "Archive together with other members" is not yet on macOS [VERIFIED: S25].

---

## 15. Prior art: TickTick and Apple Reminders

- **One-time import from Reminders:** iOS only, under Settings → "Import & Integration" [VERIFIED: S23]. No Mac or web equivalent was found. Web imports cover Todoist, MS To Do, Wunderlist, OmniFocus, Toodledo and iCal [VERIFIED: S23].
- **"Auto-import from Reminders"** (iOS; under Siri settings) [VERIFIED: S1, S35]:
  - Every time TickTick opens, it imports from the **default Reminders list only**, then **deletes the originals in Reminders** so you don't get two alerts.
  - It exists so that "Hey Siri, remind me to…" (which always goes to Reminders) ends up in TickTick.
  - It is **one-way** [FORUM/BLOG: S33, S45].
  - Only title and due date carry over; subtasks, tags and priority are lost [FORUM/BLOG: S41].
- **Calendar side:** TickTick can subscribe to a "Local Calendar" (the device's calendars, presumably through EventKit) and iCloud [VERIFIED: S13]. Reminders is never used as a live backend.
- **Lessons for this project** [UNVERIFIED/INFERENCE]:
  1. TickTick treats Reminders as an inbox to drain, not a store, because Reminders' public data model is too thin. This app accepts that ceiling in exchange for real two-way data.
  2. Siri, Apple Watch, HomePod and shared Reminders lists all write straight into our backend with no import hack. That is a key selling point over TickTick.
  3. TickTick's own App Intents and Siri AI work on macOS 27 shows the bar to meet: ship App Intents (AppEntity for reminders and lists) in this app too.
  4. Another Reminders-backed app exists: GoodTask, mentioned by a TidBITS reader as the iCloud-native alternative [FORUM/BLOG: S33 comments].

---

## 16. Mapping to an Apple Reminders backend

**Column meanings**
- **EK** = EventKit-native (public API).
- **ALT** = needs the AppleScript sdef path (Apple Events / scripting-targets entitlement) or the Shortcuts / App Intents path. The Shortcuts path means running user-installed shortcuts; a third-party app cannot call Reminders' intents directly [UNVERIFIED/INFERENCE].
- **LOCAL** = app-local metadata only. It does not show up in Reminders.app or on other devices unless a sync channel is added.
- **NF** = not feasible.

**Cell values:** ✔ = full, ◐ = partial, blank = no.

**Basis.** EK cells rest on L1 and the established header facts. ALT cells rest on the sdef and L2. LOCAL and NF cells are inference unless they say otherwise.

### 16.1 Tasks: core fields

| Feature | EK | ALT | LOCAL | NF |
|---|---|---|---|---|
| Create / edit / delete reminder | ✔ save/removeReminder | | | |
| Title | ✔ title | | | |
| Description / notes (plain) | ✔ notes | ✔ body | | |
| Markdown rendering of notes | ◐ stored as plain text; Reminders shows raw syntax | | ✔ renderer | Real rich text in Reminders |
| Due date / time, all-day | ✔ dueDateComponents (no hour = all-day) | ✔ due date / allday due date | | |
| Start date | ✔ startDateComponents (Reminders.app display unclear) | | | |
| Duration / end time / time range | | | ✔ store duration; derive end | No native end time |
| Fixed vs floating time zone | ✔ timeZone (nil = floating) | | | |
| Priority none / low / medium / high | ✔ 0 / 9 / 5 / 1 (TickTick API 0/1/3/5) | ✔ priorityLevel | | |
| Completed / completion date | ✔ completed, completionDate | | | |
| Won't Do status | | ◐ tag `#wontdo` via intents | ✔ flag (+ complete or hide) | No native status |
| Pin task | | ◐ reuse Reminders **flagged** | ✔ | |
| Flagged (Reminders-native) | | ✔ sdef `flagged` rw; intent isFlagged | | |
| Progress % | | | ✔ (or computed from subtasks) | |
| Created / modified / completed timestamps | ✔ read-only | | | |
| URL link | ✔ single URL | ✔ urls[] (several) via intents | | |
| Attachments: images | | ✔ images (intents) | | |
| Attachments: files, audio, video | | | ◐ local only | ✔ (not in Reminders) |
| Comments | | | ◐ local notes | ✔ |
| Assignee / Assigned to Me | | ✔ assignedPerson (read/write via intents) | | Inviting participants |
| Task Activities (history) | ◐ lastModifiedDate | | ◐ log of this app's own edits | Full history |
| Task links `[[ ]]` | ◐ store a link in notes/URL using calendarItemExternalIdentifier | | ✔ resolver | |
| Templates | | | ✔ | |
| Duplicate | ✔ copy fields | ◐ also tags / subtasks | | |
| Convert to Note / note lists | | | | ✔ |
| Contact person ("when messaging") | | ✔ contactPerson | | |

### 16.2 Hierarchy, tags and sections

| Feature | EK | ALT | LOCAL | NF |
|---|---|---|---|---|
| Checklist items | ◐ encode as `- [ ]` lines in notes | ◐ map to Reminders subtasks | ✔ per-item reminders | Per-item native reminders |
| Subtasks, 1 level | | ✔ parentReminder, subtasks, isSubtask (read and write via intents; sdef exposes container = reminder) | | |
| Subtasks, 2–5 levels | | | ◐ local overlay | ✔ Reminders is single-level |
| Tags (flat) | | ✔ AddOrRemoveTags, ReminderEntity.tags | | |
| Nested tags, tag colors | | | ✔ | Native nesting |
| Sections / custom groups | | ✔ Create/Update/DeleteSection, MoveToSection, SectionEntity | | |

### 16.3 Reminders, alerts and repeats

| Feature | EK | ALT | LOCAL | NF |
|---|---|---|---|---|
| Multiple reminders / offsets | ✔ alarms[] (absolute or relative). How many Reminders.app shows is unclear. | ✔ earlyAlert (unit, interval) | | |
| Default reminder | ✔ apply at creation | | ✔ setting | |
| End-time reminder | ◐ extra absolute alarm | | ✔ needs duration | |
| Location reminder (arrive/depart) | ✔ EKAlarm structuredLocation + proximity. Better than TickTick Mac, which has none. | ✔ locationTrigger | | |
| Vehicle trigger | | ✔ vehicleTrigger | | |
| Constant / urgent alarm | | ✔ isUrgent (Reminders "Urgent") | ◐ own repeating notifications | |
| Snooze | ◐ move alarm absoluteDate / due | ✔ SnoozeReminders(nextTriggerTime) | | Intercepting Reminders' own alert buttons |
| Email notifications | | | | ✔ |
| Daily summary notification | | | ✔ | |
| Repeat daily / weekly / monthly / yearly / custom; end on date / after N | ✔ EKRecurrenceRule + EKRecurrenceEnd | ✔ recurrence | | |
| Repeat **after completion** | | | ◐ emulate on completion inside this app only | Reminders-side semantics |
| Skip occurrence | ◐ write the next due date | | ✔ needs own RRULE next-occurrence math | |
| Edit only this occurrence | | ◐ DeleteRecurring thisReminder (delete only) | | ◐ |
| Specific-dates / lunar / Ebbinghaus repeats | | | ◐ | ✔ natively |
| Show future cycles in calendar | ◐ expand the RRULE yourself | | ✔ | |

### 16.4 Lists, folders and smart lists

| Feature | EK | ALT | LOCAL | NF |
|---|---|---|---|---|
| Create / rename / delete list, color | ✔ EKCalendar + EKSource | ✔ name, color rw | | |
| List emoji icon | ◐ emoji as the first character of the title (TickTick's own trick) | ✔ emblem (sdef) / badge (intents) | | |
| Folders ↔ Reminders groups | | ✔ CreateGroup, UpdateList parent, GroupEntity | | |
| Pin list | | ✔ isPinned | | |
| Archive list | | | ✔ hide | Native archive |
| Share list / collaborators | ◐ read attendees? | ◐ read participants / owner | | Invite through the API (use `show` to open Reminders) |
| List type: groceries vs standard | | ✔ ListType | | |
| Inbox | ✔ defaultCalendarForNewReminders | ✔ GetDefaultList | | |
| Today / Tomorrow / Next 7 / All / Overdue smart lists | ✔ due-date-range predicates | | ✔ view definitions | |
| Completed smart list | ✔ completed predicate | | | |
| Trash / restore | ◐ re-create from snapshot (new ID; loses tags/subtasks unless ALT) | | ✔ snapshot | Native "Recently Deleted" (unconfirmed) |
| Summary report | ✔ data | | ✔ | |
| Custom filters (AND/OR) | ✔ data | ◐ CreateCustomSmartList(name only; criteria can't be set) | ✔ filter engine | Writing filter criteria to Reminders |
| Show / hide smart lists | | ◐ UpdateSmartList isHidden (Reminders' own) | ✔ | |
| Sidebar counts / Dock badge | ✔ data | | ✔ NSDockTile | |

### 16.5 Views and organization

| Feature | EK | ALT | LOCAL | NF |
|---|---|---|---|---|
| Group by Time / Priority / List / Tag / Created / Assignee | ✔ (Time, Priority, List, Created) | ◐ (Tag, Assignee) | ✔ grouping | |
| Sort by date / priority / title / created / modified | ✔ data | ✔ mirror via sortingStyle | ✔ | |
| Manual order | | ◐ Move position **top/bottom only** | ✔ order store | Arbitrary-index write |
| Show completed per list | | ✔ showsCompleted | ✔ | |
| Kanban (list's sections as columns) | | ✔ listLayout = columns + sections | | |
| Kanban by grouping (date / priority) | ✔ drop updates the field | | ✔ | |
| Timeline / Gantt | ◐ start/due native | | ✔ duration | Dependencies |
| Calendar: day / week / multi-day / month / year / agenda | ✔ data | | ✔ UI | |
| Calendar drag-to-reschedule | ✔ | | | |
| Calendar resize (duration) | | | ✔ | |
| ⌥-drag duplicate | ✔ | | | |
| Show Calendar events alongside tasks | ✔ EKEvent (requestFullAccessToEvents) | | | |
| Arrange Tasks (undated) panel | ✔ incomplete-reminders query; filter for no due date | | | |
| Eisenhower Matrix | ✔ priority/date writes | | ✔ rules, multiple matrices | |
| Suggested Tasks / Plan Your Day | ✔ creationDate, due | | ◐ "postponed N times" counted only from edits seen by this app | |

### 16.6 Input, interaction and system integration

| Feature | EK | ALT | LOCAL | NF |
|---|---|---|---|---|
| Quick Add natural language (`*` date, `!` priority, `~`/`^` list) | ✔ resulting fields | | ✔ parser (NSDataDetector / FoundationModels) | |
| Quick Add `#tag` | | ✔ | | |
| Quick Add `@assignee` | | ◐ assignedPerson | | |
| Global hotkey Quick Add window | | | ✔ | |
| Menu bar extra (mini window) | ✔ data | | ✔ MenuBarExtra | |
| Sticky notes (floating, pinned) | ✔ data | | ✔ NSPanel | |
| Widgets (interactive) | ◐ extension access to EventKit needs checking | | ✔ WidgetKit + AppIntents | |
| Siri / Shortcuts for this app | | | ✔ own App Intents | |
| URL scheme / x-callback | | | ✔ | |
| Open item in Reminders.app | | ✔ sdef `show`; Open*AppIntent | | |
| Multi-select batch edit | ✔ commit:false then commit() | ✔ for tags / sections | | |
| Drag to sidebar list = move | ✔ set calendar (moving across accounts unverified) | ✔ MoveRemindersToList | | |
| Drag to smart list = set date | ✔ | | | |
| Drag to tag = add tag | | ✔ | | |
| Drag to nest = make subtask | | ✔ MoveToParentReminder | | Deeper than 1 level |
| Bulk Postpone overdue | ✔ | | | |
| Undo / redo | ◐ EKEventStore.reset before commit | | ✔ command stack with snapshots | |
| Search (keyword + facets) | ✔ data (fetch then filter in memory) | ◐ TTRSearchReminders | ✔ | |
| Command menu (⌘K), shortcuts, `G` / `V` chords | | | ✔ | |
| Sync across devices | ✔ via iCloud / CalDAV; EKEventStoreChangedNotification; refreshSourcesIfNecessary | | | Syncing LOCAL metadata (unless a second channel is added) |
| Offline | ✔ local store | | | |
| Themes, compact mode, strikethrough | | | ✔ | |
| Focus / Pomodoro, Habits, Countdowns, AI assistant | | | ✔ (out of scope for the Reminders backend) | |

---

## 17. Open questions

1. **Where LOCAL metadata lives.** "Reminders as the ONLY backend" rules out syncing it. Options are: local only, accepting that it doesn't sync between Macs; CloudKit or iCloud key-value storage, which is a second backend; or hidden encoding in notes or the URL, which is visible and fragile in Reminders.app. This is a product decision.
2. **Is the ALT path acceptable at all?**
   - AppleScript: needs `com.apple.security.automation.apple-events` or scripting-targets entitlements using the sdef access groups (note the inconsistent `com.apple.Reminders.*` capitalization), plus a TCC Automation prompt. Is it allowed in the Mac App Store?
   - Shortcuts: needs user-installed shortcuts, run through `shortcuts://` or `/usr/bin/shortcuts`, which is sandbox-hostile. That is slow and needs user setup.
   - Decide whether tags, sections, subtasks, flags and groups are MVP or later.
3. **How EventKit shows Reminders subtasks.** Do child reminders appear as flat reminders? Can EventKit-only edits (moving a calendar, deleting) orphan or break parent links? This has to be checked against a test account.
4. **Does sdef `make new reminder at <reminder>` create a subtask?** The sdef says container is read-only.
5. Does Reminders.app on macOS 27 display **startDateComponents** and **multiple EKAlarms**? Does an EventKit relative alarm round-trip as an "early alert"?
6. **Does moving a reminder between accounts** (iCloud ↔ local ↔ Exchange) work through `reminder.calendar = …`, or does it need copy-and-delete?
7. **Does Reminders on macOS 27 have "Recently Deleted"?** That decides whether a native Trash is possible.
8. **Mapping a TickTick Duration to Reminders:** due = start (alerts fire at start) with a LOCAL duration, or start = start and due = end?
9. **Notification ownership.** Reminders' system notifications always fire. Should this app post its own (snooze UI, constant reminders), which risks double alerts like the ones TickTick deletes originals to avoid? Or rely on Reminders plus the isUrgent ALT path?
10. **Can a WidgetKit extension read EventKit on macOS** under the app's TCC grant, or does it need its own prompt or an App Group cache?
11. **How should "Won't Do" be represented** so Reminders.app and iOS show something sensible: complete + tag, a dedicated list, or a local flag?
12. **Unconfirmed TickTick details** (no app installed to check): the exact `!` priority value syntax; the current Mac default global hotkey (⌘⇧A vs ⇧⌥A vs ⌃⇧A); the Timeline view shortcut; snooze presets; Trash retention; whether Plan Your Day and Constant Reminder exist on desktop; exact rail icon order; which fields change when a task is dragged between Eisenhower quadrants; whether "Smart Postpone" exists at all.
13. **Reminders "Recently Added" and "postponed count"** (needed for Suggested Tasks) can only be tracked for edits this app observes, unless lastModifiedDate diffs are logged on every EKEventStoreChanged.