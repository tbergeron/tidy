# Todoist for macOS (2025–2026): product and UX research, mapped to an Apple Reminders backend

## 0. Key takeaways for the planner

- **One shared codebase.** Todoist's changelog groups "Web, macOS, Windows, and Linux" under a single "Desktop" entry. That points to one web-tech client, not native AppKit. [VERIFIED: https://www.todoist.com/help/articles/changelog-HD3jJAtLd]. That it is specifically Electron is [UNVERIFIED/INFERENCE]. A native SwiftUI app can beat it on Mac idioms: menu bar, global hotkey, multiple windows, App Intents, widgets.
- **Labels are moving from `@` to `%`.** Quick Add and filters now use `%` for labels. `@` "is planned to be retired by the end of 2026". [VERIFIED: https://www.todoist.com/help/articles/use-task-quick-add-in-todoist-va4Lhpzz ; https://www.todoist.com/help/articles/introduction-to-filters-V98wIH]. iOS started recognizing `%` on 2026‑08‑20. [VERIFIED: changelog]
- **Quick Add was redesigned (rolled out to everyone 2026‑10‑08).** The empty state is clean and action chips appear only once you type. `↓` opens the description, `Shift+↓` shows more actions, `{` opens the deadline picker. It also captures multiple tasks and has an "Extract tasks…" option. [VERIFIED: changelog 2026‑08‑20 and 2026‑10‑08; https://www.todoist.com/help/articles/a-cleaner-simpler-quick-add-june-29-PuIpiLmLh]
- **Durations no longer need a date** (since 2026‑10‑01), e.g. "Write paper for 1h". The maximum is 24 h. [VERIFIED: changelog; https://todoist.com/help/articles/set-a-task-duration-L1kYkZv8d]
- **Biggest data-model gaps against Reminders:**
  - deadline as a separate field from date
  - duration
  - comments
  - sub-task depth: Todoist allows 4 indent levels; Reminders effectively allows 1 (see §16)
  - sub-project depth: Todoist allows 3; Reminders groups are 1 level
  - "every!" (repeat from completion date)
  - hourly recurrence through EventKit
  - manual ordering
  - labels, sections and sub-tasks are not in public EventKit and can only be written through Shortcuts / App Intents
- **New local finding (read from `extract.actionsdata`).** The App Intents layer exposes these enums:
  - `AccountCapabilities`: supportsSubtasks, supportsAttachments, supportsListAppearance, supportsGroups, supportsFlagged, supportsPersonTrigger, supportsLocation, supportsHourlyRecurrence, supportsTemplates, supportsListSharees, supportsListShareesMutation, supportsMoveAcrossLists, supportsMoveAcrossSharedLists, supportsMultipleDateAlarmsOnRecurrence, supportsSections, supportsDueDateDeltaAlerts, defaultPriorityLevel, supportsHandoff, supportsReminderActions, supportsAssignments, supportsHashtags, supportsCustomSmartLists, supportsPinnedLists, supportsTextStyling, supportsGroceriesList, supportsRecentlyDeletedList, supportsUrgentAlarm
  - `ListLayout` = list | columns
  - `SortingStyle` = default, manual, displayDateOldestFirst/NewestFirst, priorityLowestFirst/HighestFirst, creationDateOldestFirst/NewestFirst, titleAscending/Descending
  - `ReminderInsertionPosition` = top | bottom. So MoveReminders can't target an arbitrary index.
  - `SmartListType` = today, scheduled, all, flagged, assigned, urgent, completed
  - `PriorityLevel` = none, low, medium, high
  - `LocationTriggerEvent` = arrive | depart
  - `VehicleTrigger` = connected | disconnected
  - EarlyAlert `Unit` = minute, hour, day, week, month
  - `DeleteRecurringRemindersOption` = thisReminder | allFutureReminders
  - `ListType` = standard | groceries
  
  [VERIFIED: /System/Library/PrivateFrameworks/RemindersAppIntents.framework/Versions/A/Resources/Metadata.appintents/extract.actionsdata]
- **Public EventKit recurrence** has only Daily, Weekly, Monthly and Yearly frequencies. It does support `setPositions`, `daysOfTheWeek` with week numbers, `daysOfTheMonth`, `monthsOfTheYear`, and an end by date or by count. [VERIFIED: MacOSX.sdk EventKit.framework/Headers/EKTypes.h:64-67, EKRecurrenceRule.h:42-189, EKRecurrenceEnd.h:45]
- **Location alarms:** `EKAlarm.proximity` takes Enter or Leave, and `EKStructuredLocation.radius` is in meters (0 = default). [VERIFIED: EKTypes.h:204-214, EKAlarm.h:73, EKStructuredLocation.h:24]
- **URL field:** `EKCalendarItem.URL` exists (EKCalendarItem.h:80), but it reportedly does not read or write the URL field the Reminders app shows. [FORUM: https://developer.apple.com/forums/thread/128140 ; https://developer.apple.com/forums/thread/739541 ; https://feedback.mailbutler.io/board/p/creating-task-in-apple-reminders-writes-link-to-notes--]

---

## 1. Navigation and sidebar

| Item | Behavior | Tag |
|---|---|---|
| Add task | Button at the top of the sidebar; opens Quick Add. `q` in-app, `Cmd+N` keyboard-only | [VERIFIED: shortcuts article https://www.todoist.com/help/articles/use-keyboard-shortcuts-in-todoist-Wyovn2] |
| Search | `/` or `F`, `Cmd+F`. Typing `@` (or `%`) in search lists labels | [VERIFIED: shortcuts; labels article https://www.todoist.com/help/articles/introduction-to-labels-dSo2eE] |
| Inbox | Default capture project. `Cmd+1`, `g i` | [VERIFIED: shortcuts] |
| Today | `Cmd+2`, `g t` | [VERIFIED] |
| Upcoming | `Cmd+3`, `g u` | [VERIFIED] |
| Filters & Labels | One page with filter and label lists. `g v` | [VERIFIED: shortcuts; labels article] |
| Reporting (formerly Activity log) | `g a` | [VERIFIED: shortcuts; https://www.todoist.com/help/articles/view-reporting-in-todoist-oOra6D] |
| More | Holds views hidden from the sidebar | [VERIFIED: https://www.todoist.com/help/todoist/features/customize-the-sidebar-and-navigation-menu-in-todoist-S9JLTYqZV] |
| Favorites | Section holding favorited projects, labels and filters; syncs across devices | [VERIFIED: https://todoist.com/help/articles/360000358065] |
| My Projects / team workspace sections | Personal projects are separate from workspace (team) projects. Team projects sort alphabetically and can't be reordered manually | [VERIFIED: favorites article] |
| Folders | Team workspaces only; projects only, no nesting; available on every plan that has a team workspace (an older article said Business only) | [VERIFIED/conflicting: https://todoist.com/help/articles/use-folders-to-organize-team-projects-uoElGQdbb] |
| Sidebar settings | Show or hide each view ("Show in sidebar"); "Show task count" toggle; toggle sidebar with `m`; "mini mode" exists | [VERIFIED: sidebar article; changelog 2026‑04‑02 mentions mini mode] |
| Home view | Settings › General › Home view: Today (default), Inbox, Upcoming, or any project, label or filter. `h` or `g h` | [VERIFIED: https://todoist.com/help/articles/change-your-home-view-OKOgnH4r ; shortcuts] |
| Go-to sequences | `g` then `i`, `t`, `u`, `l` (labels), `p` (projects), `/` (section), `a`, `v`, `h`. `o` then `p` (productivity), `h` (help), `n` (notifications), `u` (profile), `s` (settings), `t` (theme) | [VERIFIED: shortcuts] |

## 2. Views

### 2.1 Today
- Shows every dated task due today across all projects. Undated tasks are excluded. [VERIFIED: https://www.todoist.com/help/articles/plan-your-day-with-the-today-view-UVUXaiSs]
- Overdue tasks appear in their own section with a **Reschedule** action. [FORUM: https://blog.vghaisas.com/til-todoist-overdue/] The same action is documented for Upcoming ("Click Reschedule at the top-right") and for filter/label views when grouped by Date. [VERIFIED: https://todoist.com/help/articles/how-to-plan-your-week-OKOg1mR8]
  - The 2016 "Smart Schedule" ML suggestions are historical. [FORUM: https://www.macstories.net/news/todoist-launches-smart-schedule-an-ai-based-feature-to-reschedule-overdue-tasks/] The current bulk Reschedule most likely opens a single date picker for all overdue tasks. [UNVERIFIED/INFERENCE]
- Overdue tasks can't be manually sorted. [VERIFIED: https://www.todoist.com/help/articles/default-sorting-order-in-todoist-mqmgerY7] A 2026‑02‑26 change sorts them chronologically when manual sort is on. [VERIFIED: changelog]
- **Smart sort** (default in Today and Upcoming): date+time (or deadline if no date) → priority → deadline → manual order → creation time. You can only drag tasks that share the same time and priority. [VERIFIED: default sorting article]
- Postpone by dragging a task to the bottom of Today (moves it to tomorrow; needs no sort or grouping). Postponing an overdue recurring task always moves it to tomorrow. [VERIFIED: Today article]
- Calendar events from Google or Outlook appear read-only in Today and Upcoming, interleaved chronologically. [VERIFIED: https://www.todoist.com/help/todoist/integrations/use-the-calendar-integration-rCqwLCt3G ; changelog 2026‑08‑27]
- Completed occurrences of recurring tasks now show in Today and Upcoming. [VERIFIED: changelog 2026‑09‑10]
- Grouping by project in Today: the help article only lists Date, Date added, Deadline, Priority and Label, but one help example mentions grouping by project. [UNVERIFIED — check in the app]

### 2.2 Upcoming
- Shows the next 7 days and can look up to two years ahead. [VERIFIED: Upcoming article]
- Desktop UI: a "Week Navigator" strip with left/right arrows, a month picker at top-left to jump to any day, month or year, a Today button, and dots marking busy days. Drag the add button onto a date to create a task there, or drag a task to another day to reschedule it. [VERIFIED: https://todoist.com/inspiration/todoist-upcoming-view]
- Shortcuts: `Shift+→` / `Shift+←` move a week; `Option+Shift+Y` jumps to today. [VERIFIED: shortcuts]
- Layouts:
  - **List:** a continuous scroll of days, each with "Add task". [VERIFIED]
  - **Board:** one column per day, "Add task" at the bottom of each. [VERIFIED]
  - **Calendar (Pro/Business):** week or month, with a **Plan** sidebar listing overdue, all-day, time-blocked and unscheduled-with-deadline (≤7 days) tasks, draggable into time slots. [VERIFIED: Upcoming article]
- Future occurrences of recurring tasks show only in Calendar layout, via the "Future occurrences" toggle in Display. [VERIFIED]
- Dropping a task on a day now lands it exactly where released. [VERIFIED: changelog 2026‑09‑17 / 10‑01]

### 2.3 Project view
- Sections, sub-tasks, a Display menu, and project comments (`c`, since 2026‑07‑02). [VERIFIED: changelog]
- Project and section descriptions show as a preview under the name (2026‑07‑09). [VERIFIED: changelog]
- Insights sidebar toggled with `i` (Pro since 2026‑07‑16). [VERIFIED: changelog]

### 2.4 Labels and filters
- Label and filter views always use their default sort and can't be reordered manually. [VERIFIED: https://todoist.com/help/articles/sort-or-group-tasks-in-todoist-WFWD0hrb]
- Comma-separated filter queries render as several stacked lists. [VERIFIED: filters article]

### 2.5 Other
- Search results, the Reporting log and the Productivity view are covered in §12.
- Multi-window: `Shift+Cmd+N` opens the current view in a new window; `Shift+Option+Cmd+N` opens a new Home window; `Option+Cmd+F` floats a window on top. [VERIFIED: shortcuts]

## 3. Layouts and the Display menu

- **Layouts:** List, Board, and Calendar in Day, Week (7 days on desktop) or Month views. Calendar is Pro/Business. `Shift+V` cycles layouts. [VERIFIED: https://todoist.com/help/articles/customize-views-in-todoist-AoHhBxFdZ ; shortcuts]
- **Calendar layout:**
  - Coloring by priority (default), project or label. [VERIFIED: customize views; changelog 2026‑08‑20]
  - Drag a task to an hour to time-block it; drag its bottom edge to set duration.
  - Clicking an empty slot opens Quick Add with a 30-minute duration. Dropping an all-day task into a slot gives it 30 minutes. Dragging within one slot creates a 15-minute task. [VERIFIED: duration article; changelog 2026‑08‑20]
  - The Plan sidebar can be filtered by project or label (2026‑09‑10). [VERIFIED]
  - Sorting and grouping aren't available in calendar layout. [VERIFIED: sort/group article]
- **Board layout:**
  - Columns are sections, plus a "No Section" column. Drag cards between columns; drag column headers to reorder; `S` adds a section; you can drag several cards at once. [VERIFIED: https://www.todoist.com/help/articles/use-the-board-layout-in-todoist-AiAVsyEI]
  - Sub-tasks expand on cards: in projects since 2026‑10‑01, and in Today, Upcoming, label and filter boards since 2026‑10‑08. [VERIFIED: changelog]
- **Display menu contents:**
  - Layout
  - Grouping: None, Date, Date added, Deadline, Priority, Label
  - Sorting: Manual, Name, Date, Date added, Deadline, Priority, plus Assignee and Project in some views
  - Direction: ascending/descending. Priority defaults to descending (P1 first); reversing applies only to the primary key.
  - Filter by: Assignee (me, a person, nobody), Date range, Deadline, Priority, Label, Workspace
  - Completed tasks toggle
  - Future occurrences toggle (calendar)
  - Coloring (calendar)
  - Reset all
  
  [VERIFIED: customize views; sort/group; default sorting; https://todoist.com/help/articles/205847912 for the completed toggle]
- Sort shortcuts: `Option+D/P/N/R` (date, priority, name, assignee); in a project, `D/P/N/R`. [VERIFIED: shortcuts]
- An orange dot on Display means the view differs from default. "Save for everyone" shares a view in shared projects; otherwise sort and group changes are personal. [VERIFIED: customize views]
- Grouping in a project disables drag reordering. [VERIFIED: sort/group]

## 4. Task data model (Todoist)

| Field | Semantics | Tag |
|---|---|---|
| Title (content) | Inline markdown. A `* ` prefix makes the task **uncompletable**: no checkbox, still allows dates, comments and assignee | [VERIFIED: https://todoist.com/help/articles/360017225259] |
| Description | Multi-line markdown, including tables (Android renders them since 2026‑09‑24) | [VERIFIED: changelog] |
| Date ("due") | When you plan to work on it. Optional time. Can recur | [VERIFIED: https://www.todoist.com/help/articles/introduction-to-deadlines-uMqbSLM6U] |
| Deadline | Hard cutoff, separate from date. Date only (no time documented). Can't recur. Pro/Business. `{…}` syntax, `d` / `Shift+D` shortcuts. Stays fixed while a recurring date advances | [VERIFIED: deadlines article; recurring article; changelog 2026‑03‑05] |
| Duration | `for 1h`, `for 10m`, `for 1h15m`, `for 25 minutes`, or a range `from 21:00 to 22:00` / `9:30-10:00`. Max 24 h, no multi-day. Pro/Business. No date needed since 2026‑10‑01 | [VERIFIED: duration article; https://todoist.com/help/articles/time-blocking-in-todoist-d6Pf1uTpc] |
| Priority | P1 red, P2 orange, P3 blue, P4 none (default). Names and colors not customizable | [VERIFIED: https://www.todoist.com/help/articles/set-a-priority-in-todoist-Wy82Jp] |
| Labels | Many per task. Personal labels have colors; shared labels are grey and transient. Wildcards allowed in filters | [VERIFIED: labels article] |
| Reminders | Automatic, custom absolute, custom relative ("before task"), recurring, and location (arrive/leave plus radius). See §7 | [VERIFIED] |
| Assignee | Shared projects only; `+Name` | [VERIFIED: Quick Add article] |
| Comments | Task and project comments with files, voice notes and emoji reactions. 5 MB free / 100 MB Pro per file; Quick Add accepts one attachment | [VERIFIED/conflicting: https://todoist.com/help/articles/205064592 ; https://www.todoist.com/help/articles/attach-files-when-creating-tasks-in-todoist-JkTC1kJXh] |
| Sub-tasks | Up to 4 indent levels; each has its own date, priority and so on | [VERIFIED: https://todoist.com/help/articles/introduction-to-sub-tasks-kMamDo] |
| Project / section | Each task belongs to exactly one project and at most one section | [VERIFIED] |
| Order | Manual order within a project or section; Today and Upcoming have their own manual order | [VERIFIED: sort/group] |
| Created / added-by / completed-at | Usable in filters and Reporting | [VERIFIED: filters article] |
| Location | Address plus arrive/leave plus radius; notifications fire on mobile only | [VERIFIED: https://todoist.com/help/articles/use-location-reminders-in-todoist-uGcwH2AJ6] |

## 5. Projects, sections, sub-projects

- **Sub-projects:** up to 3 indent levels, personal projects only. Team projects use folders instead. [VERIFIED: https://www.todoist.com/help/articles/create-a-sub-project-in-todoist-aTA15C70]
- **Project actions:** color, favorite, archive and restore, layout per project, comments, Insights, Save as template, Import/Export CSV, share. [VERIFIED: favorites, templates and CSV articles]
- **Sections:**
  - Add with `S`; reorder by drag; rename; archive (archived sections reappear grayed out when "Completed tasks" is on; unarchiving keeps their tasks completed).
  - "Move to…" another project; "Copy link to section". [VERIFIED: https://todoist.com/help/articles/introduction-to-sections ; changelog 2026‑03‑05]
  - "Add section" is hidden in grouped projects and in calendar layout. [VERIFIED: changelog 2026‑05‑28 / 10‑01]

## 6. Dates, colors and recurrence

### 6.1 Natural-language dates
[VERIFIED: https://www.todoist.com/hc/en-us/articles/205325931]

| Kind | Examples |
|---|---|
| Relative days | `today`/`tod`, `tomorrow`/`tom`, `later this week`, `in 5 days` / `+5 days`, `in 3 weeks`, `someday` (two months out) |
| Weeks, months | `next week` (Monday by default, configurable), `this weekend`, `next weekend`, `next month`, `next year`, `end of month` |
| Named days | `Friday` (next occurrence), `next Friday` (the one after), `next weekday` |
| Specific dates | `jan 27`, `27/1`, `27th`, `mid January` |
| Offsets | `6 weeks before 21 Jul`, `28 days after 21 July` |
| Times | `6pm`, `today at 10`, `Fri 7pm`, `in 2 hours`, `Fri at 1900` |
| Parts of day | `in the morning` (9am), `afternoon` (12pm), `evening` (7pm), `tom night` (10pm) |
| Remove | `no date`, `no due date` |

- A time on its own means today, or tomorrow if that time has passed.
- Czech and Turkish smart dates were added 2026‑05‑07. [VERIFIED: changelog]

### 6.2 Date chip colors
- Red = overdue
- Green = today, before the due time
- **Brown** = tomorrow (often perceived as orange)
- Purple = in 2–7 days
- No color = 8 or more days out

Not customizable. [VERIFIED: same article]

### 6.3 Recurrence grammar
[VERIFIED: https://www.todoist.com/help/articles/introduction-to-recurring-dates-YUYVJJAV]

| Pattern | Examples | Meaning |
|---|---|---|
| Basic | `every day`/`daily`, `every weekday`/`every workday`, `weekly`, `monthly`, `yearly`, `every quarter` | Fixed intervals from today |
| Interval | `every 3 months`, `every other week`, `every other fri` | `every other fri` starts on the 2nd Friday from now |
| From completion | `every! 3 months`, `every! week`, `after 10 days` | `after 10 days` becomes `every! 10 days`. Since Mar 2026, postponing `every!` reschedules from today |
| Weekdays | `every mon, fri`, `every Wednesday, Friday, Saturday ending Saturday` | |
| Month days | `every 2, 15, 27`, `every 15th workday`, `every last workday`, `every 3 workday` | |
| Ordinal weekday | `every 1st wed jan, 3rd thu jul` | `every 3rd friday` is not literally documented; the ordinal form `every 1st wed` is [UNVERIFIED that the bare form parses] |
| Month-day pairs | `every 14 jan, 14 apr, 15 jun, 15 sep` | |
| Hourly | `every hour`, `every 12 hours starting at 9pm`, `every! 3 hours` | |
| Bounds | `starting`/`from`, `ending`/`until`, `for 3 weeks`, `everyday from 10 May until 20 May` | |
| With time | `every mon, fri at 20:00`, `every fri at noon` | One time applies to every listed day |
| Holidays | `new year day`, `valentine`, `halloween`, `new year eve` | |
| With deadline | `every 2 days at 12:00 {Feb 28}` | |
| Unsupported | different times per day; "every X months on first Friday"; "every day except" | |

**Completion and postpone semantics:**
- Completing always moves the task to a *future* occurrence. A late "every day" moves to tomorrow.
- Postpone moves to the next future occurrence (tomorrow if overdue).
- Rescheduling one occurrence: absolute patterns snap back to the schedule; relative patterns recompute from the new date.
- Typing a plain date replaces the recurrence.
- `Shift+click` on the checkbox completes forever ("complete and archive"). [VERIFIED: recurring article; shortcuts]

## 7. Reminders (Todoist sense)
[VERIFIED: https://todoist.com/help/articles/205348301]

- **Types:**
  - automatic (relative to due time; lead time set in Settings › Reminders)
  - custom absolute
  - custom relative ("Before task" tab, desktop and web)
  - recurring (e.g. every Monday 8:00, not tied to the task date)
  - location (arrive/leave, map radius; mobile delivery only)
  - urgent (full-screen alarm through Silent and Do Not Disturb; iOS 26+ and Android)
- **`!` grammar:**
  - `!30m` = 30 minutes from now; `!2h30m`
  - `!30mb` / `!30m before` = relative to the due time
  - `!later` = about 4 hours later, rounded down
  - `!tmr 3pm`, `!Mon 9am`
  - `!every 5pm`, `!every sat 9am`, `!every 2 hours`
  - several can be combined: `!11am !1hb !3hb`
  - multiple reminders and `!` require Pro
- **Channels:** desktop notification, mobile push, email.
- **Snooze:** mobile only.

## 8. Quick Add

### 8.1 Grammar (consolidated, exact tokens)

| Token | Effect | Notes / tag |
|---|---|---|
| Natural-language date/time anywhere | Sets date; recurrence when it starts with `every` / `every!` / `after` | Highlighted inline; click the highlight or Backspace once to keep it as plain text; global off switch in Settings › General [VERIFIED: https://todoist.com/help/articles/turn-smart-date-recognition-on-or-off-63WfIr] |
| `#Project` | Project | `#` must be followed directly by the name [VERIFIED] |
| `/Section` | Section; set project first | iOS no longer offers a nameless section (2026‑09‑03) [VERIFIED] |
| `%label` | Label | `@label` still works until end of 2026 [VERIFIED] |
| `p1` `p2` `p3` (`p4`) | Priority | Help lists p1–p3 (p4 is the default); shortcut table lists p1–p4 [VERIFIED] |
| `!<time>` | Reminder | Grammar in §7 [VERIFIED] |
| `{date}` | Deadline | Typing `{` shows suggestions (2026‑06‑25) and opens the picker [VERIFIED] |
| `+Name` | Assignee | Shared projects; set `#` first [VERIFIED] |
| `for 45 min` / `for 1h15m` / `9:30-10:00` | Duration | Documented forms are `for 1h`, `for 10m`, `for 25 minutes` and ranges. `for 45 min` is [UNVERIFIED but likely] |
| `* ` prefix | Uncompletable task | [VERIFIED] |
| No location token | Location only through the chip | [INFERENCE: none documented] |
| No escape character | Click the highlighted token instead | `\` escaping exists only in filters [VERIFIED] |

### 8.2 Behavior
- Inline highlighting of parsed date text is VERIFIED. The highlight color is [UNVERIFIED].
- **Chips under the input:** customizable in Settings › Quick Add. Actions are priority, date, deadline, assignee, reminders, labels, location and attachment. You can add, remove or reorder them with a "Show action labels" toggle; hidden ones stay reachable through `…`. Settings sync. [VERIFIED: https://todoist.com/help/articles/customize-quick-add-in-todoist-eqRRlZJNN]
- **Redesign:**
  - project inline with the other chips
  - project and date shown by default
  - description hidden until `↓`
  - `Shift+↓` for more actions
  - `{` for deadline
  - "Extract tasks…" from pasted text, images or documents
  - multi-task capture with a "split into several tasks" suggestion
  
  [VERIFIED: changelog 2026‑08‑20 / 10‑08]
- **Multi-line paste:** a dialog asks "Add X tasks?" with options Cancel, add as one task, or add each line as a task. `Cmd+Shift+V` pastes plain text. [VERIFIED: https://www.todoist.com/help/articles/add-or-manage-multiple-tasks-in-todoist-PcPoskdUp]
- **Inline add in a list:**
  - `a` adds to the bottom, `Shift+A` to the top.
  - `Enter` saves and opens a new task below, `Ctrl+Enter` above, `Shift+Enter` saves edits and adds below.
  - `Cmd+V` of a file creates a task with it attached.
  
  [VERIFIED: shortcuts]
- **Context defaults:** adding from inside a view pre-fills it (project, section, label, Today's date). Ramble does the same. [VERIFIED: changelog 2026‑02‑06 for Ramble; INFERENCE for plain Quick Add]
- **Ramble:** voice capture powered by an LLM. It turns speech into structured tasks with dates, priorities, projects and assignees, which you review before adding. Free tier is 10 sessions a month; Pro is unlimited. Global shortcut `Option+Shift+R`. [VERIFIED: https://www.todoist.com/help/articles/from-voice-to-tasks-ramble-july-1 ; shortcuts; pricing https://www.todoist.com/help/articles/todoist-plans-pricing]

### 8.3 Mac-level capture
- **Global Quick Add:** `Option+Space` (customizable in Settings › Desktop/Advanced; more key options added 2026‑05‑14). Works while the app is minimized. A "Reload after each use" option exists. [VERIFIED: shortcuts; Quick Add article; changelog 2026‑07‑02]
- Global show/hide: `Cmd+Ctrl+T`. [VERIFIED]
- **Menu bar extra on macOS:** no evidence found. Linux has a tray icon. [UNVERIFIED — open question]
- Mac App Store listing: Siri, a Today widget, a share extension and quick actions. Safari extension opens Quick Add with the page link. [VERIFIED: https://apps.apple.com/us/app/todoist-to-do-list-calendar/id585829637?mt=12 ; https://todoist.com/help/articles/360000538429]

## 9. Filter query language
[VERIFIED: https://www.todoist.com/help/articles/introduction-to-filters-V98wIH unless noted]

| Category | Syntax |
|---|---|
| Boolean | `\|` OR, `&` AND, `!` NOT, `( )` grouping, `,` separate lists in one view |
| Escape / wildcard | `\` (e.g. `#One \& Two`, `#Shopping\ list`); `*` (e.g. `%home*`); search wildcards since 2026‑02‑13 |
| Scope | `#Project`, `##Project` (includes sub-projects), `/Section`, `%label` / `@label`, `workspace: Doist` |
| Text | `search: Meeting` |
| Structure | `subtask`, `!subtask`, `recurring`, `shared`, `assigned`, `!assigned`, `view all`, `uncompletable` |
| Dates | `today`, `tomorrow`, `yesterday`, `Monday`, `date: Jan 3`, `date before: May 5`, `date after: 5/5`, `date before: +4 hours`, `3 days` / `next 5 days`, `-3 days`, `overdue` / `over due` / `od`, `no date`, `!no date`, `no time` |
| Due/deadline | `due before: 5/5` (checks date *and* deadline), `deadline: today`, `deadline before:` / `deadline after:`, `no deadline`, `!no deadline` |
| Priority | `p1`–`p3`; `p4` = `No priority` |
| Created | `created: Jan 3 2023`, `created: today`, `created before: -365 days`, `created after: -365 days` |
| People | `assigned to: me` / `others` / `<name>`, `assigned by: me` / `<name>`, `added by: <name>` |
| Unsupported | Searching comments; completed tasks; `assigned to: nobody` (use `!assigned`) |

- Example: `(today | overdue) & #Work`.
- Filters have a name, a color and a favorite flag. Free plan allows 3 filters. "Filter Assist" (AI-written queries) is free. [VERIFIED: pricing; FORUM: https://www.asianefficiency.com/task-management/todoist-ai-setup-guide/]

## 10. Keyboard shortcuts (macOS, comprehensive)
[VERIFIED: https://www.todoist.com/help/articles/use-keyboard-shortcuts-in-todoist-Wyovn2 plus changelog additions]

| Category | Shortcuts |
|---|---|
| General | `q` Quick Add · `Cmd+N` Quick Add · `Option+P` / `Shift+Cmd+P` new project · `Shift+Cmd+L` new label · `Shift+Cmd+F` new filter · `/`, `f`, `Cmd+F` search · `Cmd+K` command menu ("Quick Find"; navigation and actions) · `?` shortcut list · `Esc` · `Cmd+Z` undo (now also restores reset view options) · `m` sidebar · `Cmd+P` print · `Cmd+=` / `-` / `0` zoom · `Cmd+Option+0` collapse/expand all · `Cmd+Option+T` collapse/expand view (2026‑10‑01) · `Cmd+,` settings · `Cmd+S` sync · `Cmd+1`/`2`/`3` Inbox/Today/Upcoming · `Cmd+4`/`5` expand projects / labels / filters · `Shift+Cmd+C` copy view link (2026‑10‑01) |
| Navigation | `j`/`k` or arrows · `←`/`→` · `Tab` / `Shift+Tab` · `Cmd+[` / `]` back/forward · `h` home · `g`- and `o`-sequences (§1) · `Shift+G` open task in its project |
| Task | `e` complete · `Shift`-click checkbox completes a recurring task forever · `Enter` open · `Cmd+E` or `Option`-click edit inline · `Cmd+Enter` save · `t` date · `Shift+T` remove date · `d` deadline · `Shift+D` remove deadline · `1`–`4` priority · `y` change priority · `c` comment · `l` label · `Shift+R` assign · `v` move to project/section · `.` more actions · `Cmd+↑` / `Cmd+↓` previous/next task while editing · `Shift+Cmd+C` copy task link · `Cmd+Delete` delete |
| Sub-tasks | `Ctrl+]` indent · `Ctrl+[` outdent · `Shift+E` show/hide sub-tasks |
| Multi-select | `x` or `Cmd`-click toggle · `Shift`-click range · `,` focus the toolbar |
| Project | `Shift+V` layout · `s` add section · `Shift+S` share · `d`/`p`/`n`/`r` sort · `w` project actions · `i` Insights · `c` project comments |
| Upcoming / calendar | `Shift+→` / `Shift+←` change week · `Option+Shift+Y` or `t` (calendar) go to today |
| Global | `Option+Space` Quick Add · `Option+Shift+R` Ramble · `Cmd+Ctrl+T` show/hide |

Note: the help page lists `Cmd+5` for both labels and filters, which is likely a typo. [VERIFIED as published]

## 11. Multi-select, bulk actions, drag and drop

- **Selection:** `Cmd`-click, `Shift`-click, `Cmd+Shift` first+last, `x`. [VERIFIED: shortcuts; multiple-tasks article]
- **Bulk toolbar** (moved to the bottom of the screen 2026‑01‑07): Date, Move to, Labels, Delete, Priority (Delete and Priority promoted 2026‑10‑08). Overflow menu: Assign to, Deadline, Complete/Uncomplete, Duplicate, Open in new window. [VERIFIED: multiple-tasks article; changelog]
- **Limits:**
  - "Move to" is disabled when the selection spans workspaces in Today or Upcoming.
  - You can't drag tasks under other tasks in Today, Upcoming, filters or labels.
  - You can only drag-reorder several tasks at once inside a project. [VERIFIED]
- **Drag and drop:**
  - Reorder with the left-side handle in lists; press and hold in boards. [VERIFIED: https://todoist.com/help/articles/360000139405]
  - Drag right to indent (make a sub-task), left to outdent; requires no sorting, projects only. [VERIFIED: sub-tasks article]
  - Drag between sections and board columns. [VERIFIED]
  - Drag to another day in Upcoming, or into calendar time slots. [VERIFIED]
  - Drag to the bottom of Today to postpone. [VERIFIED]
  - Drag a task onto a sidebar project to move it: [UNVERIFIED; not documented]

## 12. Task detail, completed tasks, history, stats, templates

- **Task view (modal):**
  - Breadcrumb (project › section); previous/next chevrons
  - Title and description
  - Sub-tasks list with a completed toggle
  - Comments
  - Right rail: Project, Date (with time and duration), Deadline, Priority, Labels, Reminders, Location, Assignee
  - `…` menu: duplicate, copy link, forward-by-email address, activity, delete, open in new window, recurring "complete forever"
  
  [VERIFIED: https://todoist.com/help/articles/use-the-task-view-to-manage-tasks-in-todoist-eDeRDO0C]
- **Completed tasks:**
  - Display › Completed tasks per project shows them at the bottom of each section; you can restore them there.
  - Reporting › Completed covers all projects.
  - Recurring completions are logged but don't go to the project's completed list.
  - Free plan: 7 days of history. [VERIFIED: https://todoist.com/help/articles/205847912 ; Reporting article]
- **Reporting:** gained 15 new event types on 2026‑04‑30 (priority, duration, moves, archive, share). [VERIFIED: changelog]
- **Insights:** project widgets for Health, Progress, Completed, Assignees and Activity. [VERIFIED: https://www.todoist.com/help/articles/introduction-to-project-insights-mK9DieWyP]
- **Karma / Productivity:**
  - daily goal 5 and weekly goal 25 by default (0 disables)
  - streaks, days off, vacation mode
  - Karma penalty for tasks 4 (or 5) or more days overdue — help pages conflict
  - widgets in the Productivity view
  
  [VERIFIED: https://todoist.com/help/articles/introduction-to-karma ; https://www.todoist.com/help/articles/use-the-productivity-view-in-todoist-6S63uAa9]
- **Templates:**
  - Gallery ("Browse templates" in the sidebar and Add menu).
  - "Save as template" from a project, with name, description and color; share by link with team permissions; desktop and web only.
  - CSV import/export with TYPE task|section|note, "Use relative dates"; CSV excludes labels, deadlines, comments, attachments and reminders.
  
  [VERIFIED: https://www.todoist.com/help/articles/introduction-to-templates-in-todoist-uofJ8i40M ; https://todoist.com/help/articles/208821185 ; changelog 2026‑06‑18]

## 13. Design language

| Element | Observation | Tag |
|---|---|---|
| Checkbox | Circular; ring in the priority color (grey for P4) with a light tint fill; filled when complete. Uncompletable tasks have no circle | Round checkboxes since the 2015 redesign [FORUM: https://techcrunch.com/2015/09/16/todoist-updates-its-web-app-with-new-features-and-design/]; ring and tint [FORUM: https://www.oppadu.com/tools/design-systems-site/brand/todoist.html] |
| Priority hex | Third-party: P1 `#E44332`, P2 `#FA8A00`, P3 `#246FE0`, P4 `#808080`. Values from memory: P1 `#D1453B`, P2 `#EB8909`, P3 `#246FE0` | [FORUM] / [UNVERIFIED]. Sample the live app |
| Accent red | `#E44332` (third-party) vs `#DC4C3E` (memory) | [FORUM] / [UNVERIFIED] |
| Sidebar | Warm off-white (about `#FCFAF8`, from memory). Third-party says `#FAFAFA`. Active item has a red-tinted background and red text | [UNVERIFIED] / [FORUM] |
| Date chips | Red, green, brown, purple, or none (§6.2), with a calendar icon; recurring tasks show a repeat icon | Colors [VERIFIED]; icons [UNVERIFIED] |
| Row anatomy | Checkbox · title (14 px, weight 500) · description first line (muted) · metadata row (date chip, sub-task count, comment count, labels, deadline) · project name with `#` and color, **right-aligned** in cross-project views | Typography [FORUM: oppadu]; layout [UNVERIFIED/INFERENCE] |
| Spacing | Roomy rows (about 10 px vertical padding); 280 px sidebar; 4 px grid | [FORUM: oppadu] |
| Project colors | About 20 named colors (berry red, red, orange, yellow, olive green, lime green, green, mint green, teal, sky blue, light blue, blue, grape, violet, lavender, magenta, salmon, charcoal, grey, taupe) | [UNVERIFIED: from Todoist API memory] |
| Themes | Several themes plus dark mode; `o t` opens theme | [VERIFIED: shortcuts] |

## 14. Plans (feature gating that affects the clone's scope)
- **Beginner (free):** 5 personal projects, 3 filters, 7-day activity history, 5 MB uploads, automatic reminders only, 10 AI sessions a month.
- **Pro and Business:** calendar layout, deadlines, durations, custom/location/recurring reminders, full history.
- **Price:** Pro $7/month or $60/year. Third-party guides say prices rose in December 2025.

[VERIFIED: https://www.todoist.com/help/articles/todoist-plans-pricing ; FORUM: https://routine.co/blog/posts/todoist-pricing]

---

## 15. Mapping to Apple Reminders backend

Legend:
- **Native** = public EventKit (SDK 27.0).
- **Alt path** = Reminders.sdef AppleScript (Apple Events entitlement plus access groups) or the Reminders App Intents. Third-party code can't call those intents directly; they run only through user-installed Shortcuts (`shortcuts run` / `NSUserScriptTask`) [INFERENCE].
- **App-local** = sidecar store keyed by `calendarItemIdentifier` / `calendarIdentifier`; other clients won't see it.
- **N/F** = not feasible.

| Feature | Reminders/EventKit-native (public API) | Needs alternate path (AppleScript/Shortcuts) | App-local metadata only | Not feasible |
|---|---|---|---|---|
| Create, edit, delete task (title, notes) | YES: `EKReminder` title, notes; `save` / `remove(_:commit:)` | — | — | — |
| Complete / uncomplete | YES: `isCompleted`, `completionDate` | CompleteReminder(s)AppIntent adds `completeSubtasks` | — | — |
| "Complete forever" (end a recurrence) | YES: remove or end the recurrence rule, then complete | DeleteReminders with `allFutureReminders` | — | — |
| Markdown description | Partial: stored as plain text in `notes` (Reminders shows it raw) | — | Rendering is local | Rich text in Reminders (`supportsTextStyling` exists only in intents [VERIFIED]) |
| Uncompletable `* ` task | — | — | YES: title prefix convention or sidecar flag | Hiding the checkbox in Reminders.app |
| Projects = lists: create, rename, color, delete | YES: `EKCalendar(for: .reminder)`, `title`, `cgColor`, `source`, `removeCalendar` | List emblem/icon: sdef `emblem` rw, UpdateList `badge` | — | — |
| Move task to another list | YES: set `reminder.calendar` (cross-account behavior unverified) | MoveRemindersToList | — | — |
| Sub-projects (3 levels) | — | Groups (one level: group › lists) via CreateGroup / UpdateGroup / TTRCreateList(group) | Deeper nesting: local only | True 3-level nesting in Reminders |
| Favorites | — | Pinned lists: UpdateList `isPinned` | YES: favorites for filters and labels | — |
| Archive project | — | — | YES: local "archived" flag hides the list | Real archive in Reminders |
| Sections | — | CreateSection, UpdateSection (name, isCollapsed), DeleteSections, MoveRemindersToSection | Reading section membership via EventKit: no [INFERENCE] | — |
| Board layout (sections as columns) | — | UpdateList `listLayout` = columns (syncs Reminders' own layout) | YES: local presentation | — |
| Sub-tasks | — | Create with `parentReminder` / `subtasks`; MoveRemindersToParentReminder. Read the parent via sdef `container` | Deeper than 1 level: local only | 4-level nesting in Reminders (1 level only; see §16) |
| Labels | — | Tags via AddOrRemoveTagsAppIntent; `tags` on create/update | Fallback: local labels; label colors always local | Label colors in Reminders |
| Priority p1–p4 | YES: `priority` 1 = high, 5 = medium, 9 = low, 0 = none (4 levels match exactly) | — | Todoist colors are a UI choice | — |
| Flag | — | sdef `flagged` rw; `isFlagged` | Could map to a label or "starred" | — |
| Date with optional time | YES: `dueDateComponents` (with or without hour/minute); `timeZone` | — | — | — |
| Deadline (separate from date) | Partial: `startDateComponents` exists but Reminders.app doesn't show it [INFERENCE] | — | YES (recommended) | A second visible date in Reminders |
| Duration | — | — | YES | Showing it in Reminders |
| Time reminders (absolute or "x before") | YES: `EKAlarm(absoluteDate:)`, `EKAlarm(relativeOffset:)`, several alarms | `earlyAlert` (minute … month) in intents | — | — |
| Automatic reminder for timed tasks | YES: add a relative alarm on save | — | Default lead time stored locally | — |
| Recurring reminder independent of the task date | — | — | Approximate with extra alarms | True independent repeating alarm |
| Location reminder (arrive/leave, radius) | YES: `EKStructuredLocation` + `radius` + `proximity` Enter/Leave | `locationTrigger` | — | — |
| Car connect/disconnect trigger | — | `vehicleTrigger` | — | — |
| Urgent (full-screen) alarm | — | `isUrgent` (`supportsUrgentAlarm`) | — | — |
| Recurrence: daily, weekly, monthly, yearly, interval, "every other", weekdays, multiple weekdays, Nth weekday, last workday (setPositions), month days, until / for N | YES: `EKRecurrenceRule` with all of these (Reminders.app's display of complex rules unverified) | `recurrence` | — | — |
| Hourly ("every 12 hours") | NO: no hourly frequency in EventKit | Maybe via intents (`supportsHourlyRecurrence` exists) | YES: local engine | Through EventKit |
| `every!` / `after N days` (from completion) | — | — | YES: on completion, compute the next date and write a new due date (or clone) | Native Reminders semantics |
| Month-day pairs ("14 jan, 14 apr, 15 jun") and holidays | Partial: only if they reduce to one RRULE | — | YES: local engine with materialized dates | — |
| Postpone / reschedule (single or bulk overdue) | YES: batch `save(commit:false)` then `commit()` | SnoozeReminders(nextTriggerTime) | — | — |
| Today, Upcoming, Overdue views | YES: `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)` | Open Reminders smart lists via OpenSmartList | Presentation is local | — |
| Manual ordering | — | MoveReminders `position` = top or bottom only [VERIFIED enum] | YES: local order (doesn't sync with Reminders) | Arbitrary-index order in Reminders |
| Sort/group options per list | — | UpdateList `sortingStyle`, `showsCompleted` | YES: grouping is local | — |
| Filter query language and saved filters | YES: fetch predicates; evaluate locally | CreateCustomSmartList (name only; criteria not settable [INFERENCE]) | YES: parser, evaluator, stored filters | Creating Reminders smart lists with criteria |
| Search | YES: fetch plus in-memory match | TTRSearchRemindersAppIntent | — | — |
| Completed tasks view | YES: `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)` | — | — | — |
| Activity log / change history | Only `EKEventStoreChanged` notifications, no history | — | YES: local journal of own edits | History of edits made elsewhere |
| Undo | — | — | YES: inverse ops; restoring a deleted reminder makes a new ID | — |
| Comments | — | — | YES (or append to notes) | Native comments |
| Attachments / images | — | `images` on create/update (`supportsAttachments`) | Local files | Arbitrary file attachments |
| URL | Partial: `EKCalendarItem.URL` doesn't show in Reminders' URL field [FORUM] | `urls` | Or put it in notes | — |
| Assignee / shared lists | Read-only signals (`allowsContentModifications`) | `assignedPerson`; `supportsAssignments` / `supportsListSharees` | — | Sharing or inviting to a list programmatically |
| Contact ("when messaging person") | — | `contactPerson` (`supportsPersonTrigger`) | — | — |
| Default list | YES (read): `defaultCalendarForNewReminders()` | GetDefaultListAppIntent | Our own default | Setting Reminders' default list |
| Groceries list type | — | TTRCreateList `type` = groceries; `autoCategorize` | — | — |
| Templates | — | Reminders has templates (`supportsTemplates`), no intent for them [INFERENCE] | YES: our own templates and CSV | Reading Reminders templates |
| Karma / goals / streaks | Uses completion dates (native data) | — | YES | — |
| Calendar layout with events | YES: `EKEvent` read with a separate calendar permission | — | Time blocks need duration (local) | — |
| Quick Add NL parsing and token chips | — | — | YES: custom grammar plus `NSDataDetector` | — |
| Ramble / AI extraction | — | — | YES: FoundationModels on-device + Speech | — |
| Global hotkey, menu bar extra, multi-window, float on top | n/a: AppKit/SwiftUI (`MenuBarExtra`, `NSWindow.level`, hotkey API) | — | YES (app feature) | — |
| Open an item in Reminders.app | — | sdef `show`; Open*AppIntent | — | — |
| Recently Deleted (restore) | — | `supportsRecentlyDeletedList` (no restore intent seen) | — | Restoring through our app [INFERENCE] |
| Workspaces / teams / folders / Insights / People | — | — | Local grouping at most | Multi-user team features |
| Location reminder delivery | Delivered by the Reminders/OS stack on device [INFERENCE] | — | — | — |

## 16. Reminders-side facts discovered here that affect the mapping

- **Sub-tasks:**
  - Apple's Mac guide: indent with `Cmd+]`, drag one reminder onto another, or Edit › Indent Reminder.
  - No sub-tasks inside the Today, Scheduled, Flagged or custom smart lists.
  - Non-iCloud accounts (CalDAV) gray the option out.
  
  [VERIFIED: https://support.apple.com/en-nz/guide/reminders/remn32a9622b/mac ; FORUM: https://help.nextcloud.com/t/sub-tasks-in-apple-reminders/167668]
  - Depth limit is not documented. One user reports a 2-level ceiling. [FORUM: https://talk.macpowerusers.com/t/hit-a-wall-in-reminders-any-way-around-over-or-under-it/31780] Treat it as one level and confirm empirically.
- **Capabilities are per account.** The App Intents layer carries a per-account `AccountCapabilities` entity, so iCloud and Exchange/CalDAV accounts differ. The UI should gate sections, sub-tasks, tags, flag and groups on capability. EventKit's `EKSource.sourceType` is a rough proxy. [VERIFIED for the entity / INFERENCE for the proxy]
- **No sections or groups in EventKit.** A developer forum thread ("How to access Reminder sections and list groups via EventKit?") confirms the gap is known. [FORUM: https://developer.apple.com/forums/thread/820848]

## 17. Open questions

1. Does Todoist's macOS app have a menu bar or status item? Nothing found; Linux has a tray icon.
2. Exact Todoist UI hex values for 2026: accent, sidebar, P1–P3, date chips. Sources conflict (`#E44332` vs `#DC4C3E`, `#FAFAFA` vs `#FCFAF8`). Screenshot-sample the live app.
3. Do the bare forms `every 3rd friday` and `every last day` parse in Todoist? Only `every 1st wed jan` and `every last workday` are documented.
4. Does `for 45 min` parse? Documented forms are `for 1h`, `for 10m`, `for 25 minutes`.
5. Does Today and filter grouping offer **Project** and **Assignee**? Help lists only Date, Date added, Deadline, Priority, Label; the shortcuts and customize-views pages imply more.
6. What does the current Today/Upcoming bulk "Reschedule" open: a single date picker or suggestions?
7. Can you drag a task onto a sidebar project in Todoist desktop? Not documented.
8. What does the changelog's "grouped by custom properties" (2026‑04‑30) mean? Custom task fields would be a new data dimension.
9. On the Reminders side:
   - Does Reminders.app render EventKit rules that use `setPositions` or Nth-weekday correctly?
   - How does an hourly rule created in Reminders.app look when read through EventKit?
   - Does setting `reminder.calendar` to a list in another account preserve the item ID?
   - Does the AppleScript `id` relate to `calendarItemIdentifier` or `calendarItemExternalIdentifier`?
   - Can Shortcuts' `recurrence` parameter express hourly or "after completion"?
10. Can a sandboxed Mac App Store app run user Shortcuts reliably (`NSUserScriptTask` vs the `shortcuts` CLI)? What are the Apple Events entitlement and scripting-target constraints for the `com.apple.reminders.*` access groups (note the inconsistent capitalization)?
11. Does Reminders' "early alert" (`earlyAlert` / `supportsDueDateDeltaAlerts`) correspond to a relative `EKAlarm`, or is it a separate field that EventKit can't see?