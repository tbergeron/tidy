# Things 3 for macOS: product and UX research, mapped onto an Apple Reminders backend

Research date: 2026-10-21. Current version is Things 3.24.1 (Mac App Store, Sep 30 2026), $49.99, needs macOS 13.3 or later. Things 3 is not installed on this machine, so the UI was not inspected directly. Everything below comes from Cultured Code docs, third-party sources, and read-only checks of the local SDK and /System metadata.

**Source tags:** [VERIFIED: src] means confirmed in an official page or a local file. [DOCS] means vendor docs. [FORUM/BLOG] means a third-party source. [UNVERIFIED/INFERENCE] means memory or reasoning only.

---

## 0. Version timeline (recent releases)

| Ver | Date | Mac-relevant changes | Source |
|---|---|---|---|
| Things Cloud rebuilt in Swift | May 2025 | Sync backend only | [VERIFIED: culturedcode.com/things/blog/2025/05/a-swift-cloud/] |
| 3.22 | Sep 15 2025 | OS 26 redesign: glass sidebar, wider spacing, new icon (Default/Dark/Tinted/Clear). Mac widget styles (Dark/Tinted/Clear). **Control Center / menu-bar controls** ("New To-Do", "List"). **Spotlight "Create To-Do"** goes to the Inbox even if the app isn't running. Shortcuts "Use Model" action to write to-dos with AI. | [VERIFIED: culturedcode.com/things/blog/2025/09/things-for-os-26/] |
| 3.23 | Aug 19 2026 | Repeating overhaul: complete early, Make Exception vs Update Rule, Create Next Copy, batch pause/resume/stop, grey repeat icon on copies, redesigned repeat dialog. Mac and iOS share to-do display/edit code. | [VERIFIED: culturedcode.com/things/blog/2026/08/repeating-to-dos-refined/], [FORUM/BLOG: macrumors.com/2026/08/19/...] |
| 3.24 / 3.24.1 | Sep 14 / Sep 30 2026 | Siri AI (beta, OS 27), **Spotlight indexing of to-dos/projects (OS 27, can be turned off)**, notification snooze (15m / 1h / 3h / "Tomorrow at 9:00 AM", synced), extra-tall widget, glass tweaks for OS 27 | [VERIFIED: culturedcode.com/things/blog/2026/09/things-for-os-27-and-siri-ai/], [VERIFIED: apps.apple.com/us/app/things-3/id904280696] |

---

## 1. Object model

| Entity | Contains | Key fields | Notes |
|---|---|---|---|
| **Area** | loose to-dos and projects | title, tags | No status and can't be completed. Tags are inherited by children. Shown bold in the sidebar with projects below, and collapsible (Cmd+click expands/collapses all). [VERIFIED: support 2803581, 2785159], [FORUM/BLOG: MacStories review]. AppleScript areas have only name and tag names. [VERIFIED: support 4562654] |
| **Project** | headings and to-dos | title, notes, When, Deadline, tags, status, repeat | The sidebar shows a progress pie [VERIFIED: things/features]. Hidden from the sidebar while it has a future start date or is in Someday [VERIFIED: support 4001304]. Completing it via URL requires every child to be done or canceled and every heading archived [VERIFIED: support 2803573]. "Show/hide later items" Shift+Cmd+E [VERIFIED: 2785159]. |
| **Heading** | to-dos (projects only) | title, archived | Archive, Duplicate (Cmd+D), Move (carries its to-dos), Convert to Project, "New Heading with Selection" (Opt+Shift+Cmd+N). Archived headings go to the logged items at the bottom of the project. [VERIFIED: support 2803577] |
| **To-Do** | checklist items | title, notes (Markdown, 10k chars via URL), When (date / Evening / Anytime / Someday), one reminder time, Deadline, tags, status, repeat, creation/modification/completion dates | Can be loose, in an area, in a project, or under a heading. No nesting. [VERIFIED: support 9596775, 2803573] |
| **Checklist item** | none | title, status (open / completed / canceled) | Round checkbox. Drag grip to reorder. Pasting a bulleted list creates a checklist. Up to 100 via URL scheme. [VERIFIED: support 2803582, things/features, 2803573] |
| **Tag** | child tags | title, parent, keyboard shortcut, order | Built-in tags: Home, Office, Errand, Important, Pending. [VERIFIED: support 2803581] |

- **Statuses:** Open, Completed, Canceled. Canceled is a first-class status for to-dos, projects and checklist items (Opt+Cmd+K). [VERIFIED: support 9596775, 2785159]
- **Internal DB**, reverse-engineered by things.py:
  - `TMTask.type`: 0 = to-do, 1 = project, 2 = heading.
  - `status`: 0 = open, 2 = canceled, 3 = completed.
  - `start`: 0 = Inbox, 1 = Anytime, 2 = Someday.
  - `startDate` and `deadline` are bit-packed day integers.
  - `reminderTime` is packed hour:minute.
  - `index` and `todayIndex` are separate manual sort orders.
  - `rt1_recurrenceRule` holds the repeat rule. `trashed` is a flag.
  - [FORUM/BLOG: github.com/thingsapi/things.py/blob/main/things/database.py]
- **Separate manual order for Today:** Today has its own sort order (`todayIndex`), independent of the project order. [FORUM/BLOG: things.py api.py]

---

## 2. Date semantics: When (start) vs Deadline vs reminder

- **When** is the day you intend to start, not a time block. [VERIFIED: support 2803579] Values:
  - Today
  - This Evening (Today plus an evening bucket)
  - a specific date (the item sits in Upcoming until then)
  - Anytime (cleared)
  - Someday
- **Flow:** a future-dated item stays hidden in Upcoming, then moves into Today automatically when the date arrives. [VERIFIED: 2803579]
- **When can't be overdue. Deadlines can.** [FORUM/BLOG: talk.macpowerusers.com/t/.../19654]
- **Storage, as modelled by things.py:**
  - Scheduled items are stored as `start = Someday` plus a future `startDate`.
  - Today = `start = Anytime` with a startDate, plus "unconfirmed" items whose date has passed. The library comment describes these as "Predictions of new to-dos indicated by a yellow dot in the app".
  - Overdue-deadline items are also pulled into Today.
  - [FORUM/BLOG: things.py api.py] So new arrivals in Today get a **yellow dot** until acknowledged.
- **Deadline** (flag icon, Shift+Cmd+D) is when work must be finished.
  - A to-do with a deadline but no When stays in **Anytime**.
  - Today shows anything whose start date, deadline, or repeat matches today. [VERIFIED: support 4001304]
  - A deadline on a Someday item pulls it into Today on that date. [FORUM/BLOG: MPU forum]
  - Overdue is shown in red. [FORUM/BLOG: iamfran.com/notes/things-repeating-tasks] A "N days left" label is [UNVERIFIED].
- **Reminder** (notification):
  - Set through When ("tomorrow at 2pm", or Cmd+S, then Add Reminder).
  - Exactly one per to-do, tied to the When date.
  - One-time, not repeating. Sound can't be customized. You can't sort by reminder time.
  - **Deadlines can't have reminders.** [VERIFIED: support 2803585]
  - Snooze: 15m / 1h / 3h / next day, extended in 3.24. [VERIFIED: 2803585, blog 2026/09]
  - "Fastlane" pushes reminders to all devices immediately. [VERIFIED: things/features]
- **Natural-language dates** in the When, Deadline and reminder fields:
  - English, German, French, Italian, Spanish, Russian, Chinese, Japanese.
  - Examples: `tod`, `tomorrow`, `next week`, `10-3`, `10-3 9`, `2p`, `17d` (also `w`/`mo`/`y`), `17d from jul9`, `jul9 + 17d`, `3rd wed jul 2026`, `last fri jul`.
  - The format follows the region setting.
  - Deadline NL is Mac-only (or iPad/Vision with a keyboard).
  - [VERIFIED: support 9780167]
- **"Jump Start"** is the When popover: Today, This Evening, reminder, calendar, Someday. On Mac, open it by hovering a row and clicking the calendar button. [VERIFIED: things/features]

---

## 3. Default lists

| List | Rule | UI details |
|---|---|---|
| **Inbox** (Cmd+1) | `start = Inbox`. Capture staging (Quick Entry, Mail to Things, Share, Reminders Inbox). Once an item gets a list or a date it leaves, and a temporary "moved to X" note shows at the bottom until you change lists. | A "From Reminders" section appears if Reminders Inbox is on. [VERIFIED: 4001304, 2803561] |
| **Today** (Cmd+2) | When ≤ today, deadline today or overdue, or a repeat due. Calendar events at the top. **This Evening** section at the bottom. Optional grouping by project/area (Settings → General, synced). | Past events turn grey [FORUM/BLOG: MacStories]. Yellow star icon. Manual order. [VERIFIED: 4001304] |
| **Upcoming** (Cmd+3) | Future When dates. The next 7 days each get their own section starting tomorrow, then later items are grouped by week/month. Shows scheduled to-dos, repeating templates and copies, deadlines, and calendar events. **Drag to a day to reschedule.** Magic Plus dropped on a day creates a to-do for that date. | [VERIFIED: 4001304, things/features], [FORUM/BLOG: MacStories for the week/month grouping and Magic Plus on a day] |
| **Anytime** (Cmd+4) | Every active (startable) to-do, including Today's (marked with a yellow star). Loose to-dos first, then grouped by project/area. Parents with no active to-dos are hidden. | [VERIFIED: 4001304] |
| **Someday** (Cmd+5) | Not scheduled and parked. Someday projects disappear from the sidebar. Items are visually de-emphasized. | [VERIFIED: 4001304] |
| **Logbook** (Cmd+6) | Completed and canceled items, kept forever. Clear it with Cmd+A then Delete. "Move completed items to Logbook" Shift+Cmd+Y. AppleScript `log completed now` works only when logging is set to manual. So a logging-schedule setting exists; the options Immediately / Daily / Manually are [UNVERIFIED]. | [VERIFIED: 4001304, 2785159, 4562654] |
| **Trash** | Mac only (iOS deletes permanently). Empty Trash erases. | [VERIFIED: 9596775, 4001304, 4562654] |
| Hidden Quick Find lists | **Tomorrow, Deadlines, Repeating, All Projects, Logged Projects.** Reached by typing in Quick Find or via View → Go To. Can't be pinned to the sidebar, but can be widgets. | [VERIFIED: 2803584, 2785159] |
| Tag lists | Every to-do with a tag (direct or inherited), grouped by parent list | [VERIFIED: 2803581, 3289315] |

- Default lists can't be renamed, removed or reordered. [VERIFIED: 2803579]
- Things has no priority field. It suggests Today ordering plus an "Important" tag. [VERIFIED: support 3289315]
- Templates: there is no built-in feature. The workaround is a tagged project kept in Someday and duplicated when needed. [VERIFIED: 2693493]
- **Caution:** an aiindigo tutorial claims a "Review" button in the sidebar. No official source confirms it, so treat it as false. [UNVERIFIED]

---

## 4. Repeating to-dos and projects (3.23 model)

- **Types:** a fixed schedule (daily / weekly / monthly / yearly, with selected days), or **after completion** (an interval after you finish).
  - The Mac entry points are File → New Repeating To-Do, Items → Repeat, and Shift+Cmd+R.
  - Not documented: custom numeric intervals, nth-weekday rules, last-day rules, end conditions. [VERIFIED: 2803564], [UNVERIFIED: whether those UI options exist]
- **Template and copy:**
  - The template holds the rule, title, notes, tags and checklist. Each occurrence is a generated copy.
  - Editing the template affects future copies. Editing a copy affects only that copy.
  - Checklist items can only be checked in copies. Each copy links back to its template.
  - Items inside a repeating project can't repeat on their own.
  - [VERIFIED: 2803564]
- **Options:**
  - Reminder time on the day the copy appears.
  - "Add deadlines", with the deadline on the repeat day.
  - "N days earlier": the copy appears in Today N days before its deadline.
  - [VERIFIED: 2803564]
- **Rule menu:** Edit Rule, Create Next Copy, Show Previous Copy, Pause, Resume, Stop (Stop converts the template into a normal to-do). Pause, Resume and Stop work in batches. [VERIFIED: 2803564, blog 2026/08]
- **Completing early** is allowed from 3.23. It schedules the next copy using the rule. [VERIFIED: blog 2026/08]
- **Rescheduling a fixed-schedule item** asks for **Make Exception** (this copy only) or **Update Rule** (the series moves). After-completion items move without a prompt. [VERIFIED: blog 2026/08]
- **Where they appear:** the Repeating list (loose items first, then grouped by parent, sorted by next occurrence, paused templates last), plus Upcoming and the parent project. [VERIFIED: 2803564]
- **URL scheme limit:** `update` can't change when/deadline/completed on repeating to-dos. [VERIFIED: 2803573]

---

## 5. Tags

- **Nesting:** in Window → Tags, drag one tag onto another. The same window handles create, rename, delete and reorder. Tag order is also the order of the filter bar. [VERIFIED: 2803581]
- **Inheritance:** tags on a project or area apply to its children for filtering and search, but aren't shown on the child. [VERIFIED: 2803581]
- **Filter bar:** a row at the top of a list ("All / Important / Diane …") showing only tags used in that list.
  - Click a tag to filter. Cmd+click more tags to combine them with **AND** logic.
  - Ctrl+Esc clears the filter.
  - [VERIFIED: 2803581, 2785159]
- **Keyboard:** each tag can get a one-key shortcut in the tag window.
  - **Ctrl+key** toggles the tag on the selection.
  - **Ctrl+Opt+key** filters the list by it.
  - Shift+Cmd+T opens the tag picker. Ctrl+Cmd+T opens the tag window. You can also drag to-dos onto tags in the tag window.
  - Correction to the brief: **Ctrl+T is not a Things shortcut.** [VERIFIED: 2785159]

---

## 6. Capture

- **Quick Entry** (Ctrl+Space, rebindable):
  - A floating panel available from any app.
  - Most main-app shortcuts work inside it: tags, When, Move or heading via Shift+Cmd+M or the Inbox button.
  - Esc discards. Cmd+Return saves.
  - macOS 15.2+ blocks hotkeys whose only modifier is Shift.
  - [VERIFIED: 2249437]
- **Quick Entry with Autofill** (Ctrl+Opt+Space):
  - Needs a separately installed **Helper application**.
  - Puts a link to the current Safari page, Mail message, or Finder file into **notes**. You still type the title.
  - Other apps may or may not work.
  - [VERIFIED: 2249437]
- **Magic Plus:**
  - A draggable "+". Drop it at a list position to insert a to-do, on the left edge to create a heading, on the Inbox target for an Inbox item, in the sidebar/list area to create a project, or on an Upcoming day for a dated to-do.
  - Mainly an iOS and iPad gesture. On Mac, New To-Do sits in the bottom toolbar; whether it can be dragged on Mac is [UNVERIFIED].
  - [VERIFIED: 2803582], [FORUM/BLOG: MacStories]
- **Other creation paths:**
  - Cmd+N adds a to-do to the current list.
  - Space adds a to-do below the selection.
  - **Cmd+V with multi-line text creates one to-do per line.**
  - [VERIFIED: 2785159]
- **Mail to Things:**
  - A private `@things.email` address. Subject becomes the title, body becomes notes (4k characters).
  - No attachments. Up to 100 emails a day. Everything goes to the Inbox.
  - Needs Things Cloud.
  - [VERIFIED: 2908262]
- **System entry points:**
  - Share extension. [DOCS: 2803566]
  - Spotlight "Create To-Do" (OS 26).
  - Control Center / menu-bar controls (OS 26).
  - Siri.
  - Reminders Inbox (section 13).
  - Microsoft To Do inbox. [DOCS: 7597548]

---

## 7. Navigation and windows

- **Type Travel** (Mac): start typing anywhere to open Quick Find, no shortcut needed. [VERIFIED: things/features]
- **Quick Find** (Cmd+F):
  - Matches names of to-dos, projects, areas, tags, headings, and built-in or hidden lists, then navigates there. Typing "next action" jumps to a heading.
  - "Continue Search" adds notes, checklists and the Logbook.
  - Cmd+Return or Cmd+click opens the result in a new window.
  - [VERIFIED: 2803584, 2785159]
- **Navigation popover:** Shift+Cmd+O. Clicking the list title does the same when the sidebar is hidden. [VERIFIED: 2803584]
- **Multiple windows:**
  - Ctrl+Cmd+N opens a new window. Opt+New Window clones the current list.
  - Cmd+double-click a project opens it in a new window. Opt + "Show in Project" opens the parent in a new window.
  - Each window navigates on its own by typing.
  - You can drag between windows.
  - [VERIFIED: 2785159, 2803580]
- **Slim Mode:** hide the sidebar with Cmd+/ or a two-finger swipe. Opt+Cmd+T toggles the toolbar. [VERIFIED: 2785159, things/features]
- **Show in parent list** Cmd+L. Back Cmd+Left. Enter a project with Return or Cmd+Right. [VERIFIED: 2785159]

---

## 8. Mac keyboard shortcuts (complete, from [VERIFIED: culturedcode.com/things/support/articles/2785159/])

**Create**

| Action | Keys |
|---|---|
| New to-do | Cmd+N |
| New to-do below selection | Space |
| Paste lines as to-dos | Cmd+V |
| New checklist | Shift+Cmd+C |
| New project | Opt+Cmd+N |
| New heading | Shift+Cmd+N |
| Heading with selection | Opt+Shift+Cmd+N |
| Quick Entry | Ctrl+Space |
| Quick Entry with Autofill | Ctrl+Opt+Space |

**Edit**

| Action | Keys |
|---|---|
| Open item | Return |
| Save and close | Cmd+Return |
| Duplicate | Cmd+D |
| Copy / paste | Cmd+C / Cmd+V |
| **Complete** | **Cmd+K** |
| **Cancel** | **Opt+Cmd+K** |
| Log completed | Shift+Cmd+Y |

**Select**

| Action | Keys |
|---|---|
| First / last | Opt+Up / Opt+Down |
| Extend | Shift+Up / Shift+Down |
| Extend to top / bottom | Opt+Shift+Up / Opt+Shift+Down |
| All | Cmd+A |

**Move**

| Action | Keys |
|---|---|
| **Move to list** | **Shift+Cmd+M** |
| Move copied item here | Opt+Cmd+V |
| Up / down | **Cmd+Up / Cmd+Down** |
| To top / bottom | Opt+Cmd+Up / Opt+Cmd+Down |

**Dates**

| Action | Keys |
|---|---|
| **When** | **Cmd+S** |
| **Today** | **Cmd+T** |
| **This Evening** | **Cmd+E** |
| Anytime | Cmd+R |
| **Someday** | **Cmd+O** |
| Start date ±1 day | Ctrl+] / Ctrl+[ |
| Start date ±1 week | Ctrl+Shift+] / Ctrl+Shift+[ |
| Deadline | Shift+Cmd+D |
| Deadline ±1 day | Ctrl+. / Ctrl+, |
| Deadline ±1 week | Ctrl+Shift+. / Ctrl+Shift+, |
| Repeat | Shift+Cmd+R |

**Windows**

| Action | Keys |
|---|---|
| New window | Ctrl+Cmd+N |
| Sidebar | Cmd+/ |
| Toolbar | Opt+Cmd+T |

**Search**

| Action | Keys |
|---|---|
| Search | Cmd+F |
| Find in text | Shift+Cmd+F |
| Find and replace | Opt+Shift+Cmd+F |
| Next / previous | Cmd+G / Shift+Cmd+G |

**Navigate**

| Action | Keys |
|---|---|
| Popover | Shift+Cmd+O |
| **Inbox … Logbook** | **Cmd+1 … Cmd+6** (only 1–6; no number for Trash or areas) |
| Parent list | Cmd+L |
| Enter / back | Return or Cmd+Right / Cmd+Left |
| Scroll | fn+Up / fn+Down |
| Top / bottom | fn+Left / fn+Right |
| Sidebar up / down | Ctrl+Opt+Cmd+Up / Ctrl+Opt+Cmd+Down |

**Tags**

| Action | Keys |
|---|---|
| Tag window | Ctrl+Cmd+T |
| Edit tags | Shift+Cmd+T |
| Toggle tag | Ctrl+key |
| Filter by tag | Ctrl+Opt+key |
| Add to filter | Cmd+click |
| Clear filter | Ctrl+Esc |

**Links**

| Action | Keys |
|---|---|
| Open link | Opt+Cmd+Return |
| Open in background | Cmd+click |

**Other**

| Action | Keys |
|---|---|
| Later items | Shift+Cmd+E |
| Expand/collapse all areas | Cmd+click |
| Expand one, collapse others | Opt+Cmd+click |

**Markdown in notes**

| Action | Keys |
|---|---|
| H1 / H2 | Ctrl+Cmd+1 / Ctrl+Cmd+2 |
| Italic | Cmd+I |
| Bold | Cmd+B |
| Bullets | Shift+Cmd+L |
| Numbered list | Opt+Cmd+L |
| Task list | Ctrl+Cmd+L |
| Complete / cancel task | Cmd+K / Opt+Cmd+K |
| Quote | Cmd+' |
| Highlight | Shift+Cmd+U |
| Link | Shift+Cmd+K |
| Strikethrough | Opt+Cmd+U |
| Code | Shift+Cmd+J |
| Code block | Opt+Shift+Cmd+J |
| Indent / outdent | Cmd+] / Cmd+[ |

---

## 9. Moving items, multi-select, drag and drop

- **Move dialog:** Shift+Cmd+M, or the arrow button in the toolbar.
  - Type to filter destinations. Headings only appear when you type their name; "project + heading" fuzzy matching works ("far prep").
  - "+ New Project" inline. "No Project/Area" detaches.
  - Works on multiple selections and inside Quick Entry.
  - [VERIFIED: 9651894]
- **Drag:** reorder to-dos, headings and checklist items; reorder projects and areas in the sidebar; drop to-dos or headings onto sidebar lists; drag to Upcoming days; drag between windows. [VERIFIED: 9651894, 2803582]
- **Remove from Project/Area:** context menu, Items menu, or Move → No Area for projects. [VERIFIED: 9651894]

---

## 10. Calendar integration

- Apple Calendar only; other providers have to sync into it first.
- Read-only display at the top of Today and Upcoming, in calendar colors.
- Calendars are chosen per device and not synced.
- You can't create events from to-dos (the suggested workaround is a Shortcut).
- Not shown in widgets.
- [VERIFIED: support 2803583]

## 11. Notes and Markdown

- Supported: `#`/`##`/`###` headings, `*italic*`, `**bold**`, `::highlight::`, `~~strike~~`, `>` quote, bullets (`- * + •`), `1.` lists, task lists (`- [ ]`, `- [x]`, `- [~]` for canceled), inline code, fenced code (no syntax highlighting), `[text](url)`, auto-detected links, `---` divider.
- **The syntax always stays visible.**
- No images or attachments.
- Find in Text works within a single note only.
- [VERIFIED: 4651820, 4438545]

---

## 12. Automation surface (Things' own; useful as a parity target)

- **URL scheme `things:///` (v2):**
  - Commands: `add`, `add-project`, `update`, `update-project`, `show`, `search`, `version`, `json`.
  - `update` operations need an `auth-token`.
  - x-callback-url returns `x-things-id`.
  - Built-in show ids: `inbox`, `today`, `anytime`, `upcoming`, `someday`, `logbook`, `tomorrow`, `deadlines`, `repeating`, `all-projects`, `logged-projects`, plus `filter` by tags.
  - Rate limit 250 per 10 s.
  - Date strings accept today, tomorrow, yyyy-mm-dd, NL, and `date@time`.
  - An empty parameter clears a field.
  - [VERIFIED: support 2803573]
- **AppleScript (Mac):**
  - Classes: to do, project, area, tag (with parent tag), the built-in lists Inbox / Today / Anytime / Upcoming / Someday / Logbook / Trash, and selected to dos.
  - Properties: name, notes, **due date (= the deadline)**, completion date, creation, modification and cancellation dates, status, tag names.
  - Commands: make, delete (to Trash), move (to built-in lists; **not** Upcoming), **schedule** (the way to set Upcoming), show, edit, show quick entry panel, empty trash, log completed now.
  - **Headings and checklists can't be accessed.**
  - [VERIFIED: support 4562654, 2803572]
- **Shortcuts (Things 3.17+, macOS 14+), 13 actions:**
  - Create To-Do, Create To-Do with Quick Entry, Create Heading, Create Project, Find Items (max 500), Get Items, Get Selected Items, Edit Items, Duplicate Items, Delete Items (Trash or immediate), Open List, Show Items, Run Things URL.
  - One "Item" entity with these properties: Type, Title, Parent, Heading, Is Inbox, Start (On Date / Anytime / Someday), Start Date, Evening, Reminder Date, Deadline, Tags, All Matching Tags, Status, Completion Date, Is Logged, Notes, Checklist, Creation Date, Modification Date, ID, Parent ID.
  - Find Items can't filter for "no deadline", "no parent" or "no tags".
  - Edits can't be undone. There's a warning above 99 items.
  - [VERIFIED: support 9596775]
- **Siri:**
  - Classic phrasing: "In Things, remind me to…". Lists are called "list", to-dos "task".
  - Siri AI (OS 27) supports only a start date and reminder, not deadlines or date lists.
  - **Things warns that Siri may send requests to Apple Reminders unless the user says "Things", and that the Siri preview "may briefly look like Reminders".** [VERIFIED: support 2877019, blog 2026/09]
  - [INFERENCE] This fits Things adopting the new `.reminders` AppSchema (section 14).
- **Spotlight:** indexing of to-dos and projects on OS 27; the OS picks what appears. Spotlight "Create To-Do" on OS 26. [VERIFIED: blogs 2025/09, 2026/09]
- **Widgets:**
  - Desktop and Notification Center (macOS 14+). Small, medium, large, and the new extra-tall.
  - Any list, project, area, Quick Find list or tag, optionally with a tag filter.
  - **Interactive checkboxes** (can be turned off). The "+" button targets the Inbox or the current list.
  - Styles: Dark, Tinted, Clear.
  - No calendar events.
  - [VERIFIED: support 2803567, blog 2025/09]
- **Control Center / menu-bar controls** (macOS 26): New To-Do, List. [VERIFIED: blog 2025/09]

---

## 13. How Things integrates with Apple Reminders (prior art)

**A. "Reminders Inbox"** [VERIFIED: support 2803561]
- Things → Settings → Reminders Inbox → "Show to-dos from" one chosen Reminders list. It's set up per device and not synced.
- Reminders in that list appear in the Inbox under **"From Reminders"**. They are **display-only** (not in the Things DB) until imported.
- **Importing deletes the reminder from Reminders.** This is a one-way move, not a sync.
- **Hidden** to avoid data loss: location-based reminders, ones with attachments, subtasks, recurrence rules, "when messaging" triggers, and Siri "remind me about this".
- Things says flags and priorities aren't carried over because "Apple does not expose them".
  - [INFERENCE] That's only half true. `EKReminder.priority` *is* public [VERIFIED: SDK EKReminder.h, established fact]. The flag isn't in EventKit (it is in AppleScript `flagged` and Shortcuts `isFlagged`).
- Siri and Watch capture works by setting Reminders' default list to the inbox list.

**B. "Import From Reminders"**, File → Import (Things 3.10+). It's a copy and leaves Reminders untouched. [VERIFIED: support 1477596, FORUM/BLOG: tidbits.com/watchlist/things-3-10/]
- Lists and templates become Projects. **Groups aren't imported, and lists inside groups are excluded** (move them out first).
- Reminders become To-Dos. **Due date becomes the When (start) date**, not the Deadline.
- Repeating reminders lose their rule. **Subtasks are flattened.**
- **The URL field can't be read.** Things provides a Shortcut that copies the URL into notes first.
- Images, flags, priority, and location or messaging alerts are dropped. Tags carry over (mechanism unknown, see the open questions).
- Including completed reminders is optional.

**C. What this tells us** [INFERENCE]
- Cultured Code works only with what EventKit exposes, and it treats Reminders' due date as "When".
- Third-party apps hit the same EventKit limits:
  - no groups
  - no URL (EventKit `URL` is nil or separate from the URL Reminders.app shows) [FORUM/BLOG: developer.apple.com/forums/thread/128140, /739541; forums.getdrafts.com/t/.../7020]
  - no subtasks, tags, flags or images
- Reminders created in Reminders.app come back with `startDateComponents == nil`, which suggests Reminders.app doesn't use start dates. [FORUM/BLOG: developer.apple.com/forums/thread/676018; macscripter.net/t/recurring-reminders/70871]
- On iOS, EventKit requires a start date when a due date is set; macOS doesn't. [DOCS: Apple EKReminder.dueDateComponents]

---

## 14. New local findings (read-only, macOS SDK 27 and /System)

1. **There is a public AppIntents `.reminders` AppSchema domain in SDK 27.0** (`@available(anyAppleOS 27.0, *)`, not on watchOS or tvOS).
   - Intents: `createList`, `createReminder`, `createSection`, `deleteReminders`, `updateReminder`.
   - Entities: `group`, `list`, `reminder`, `section`, `locationTrigger`.
   - Enums: `ListType`, `LocationTriggerEvent`.
   - [VERIFIED: …/AppIntents.framework/Versions/A/Modules/AppIntents.swiftmodule/arm64e-apple-macos.swiftinterface, around lines 11715–11880]
   - What this means: a third-party app can expose Reminders-shaped intents to Siri AI and Apple Intelligence. It doesn't give the app access to Reminders' private data.
2. Reminders' own `ReminderEntity` declares `assistantDefinedSchemas: reminders.reminder` and conforms to Syncable, Collaborative, AssistantEntity and Indexed.
   - Its properties: `title`, `note`, `images`, `subtasks`, `tags`, `urls`, `dueDate`, `recurrence`, `isCompleted`, `isFlagged`, `creationDate`, `completionDate`, `list`, `section`, `locationTrigger`, `lastModifiedDate`, `contactPerson`, `assignedPerson`, `vehicleTrigger`, `earlyAlert`, `isUrgent`, `priorityLevel`, `isSubtask`, `parent`.
   - `ListEntity`: `color`, `badge`, `parent`, `name`, `type`, `participants`, `owner`, `sections`, `isPinned`, `showsCompleted`, `autoCategorize`, `listLayout`, `sortingStyle`.
   - `SectionEntity`: `isCollapsed`, `name`, `list`, `reminders`.
   - `GroupEntity`: `name`, `lists`, `showsCompleted`.
   - `SmartListEntity`: `type`, `isHidden`.
   - Queries exist for each.
   - [VERIFIED: /System/Library/PrivateFrameworks/RemindersAppIntents.framework/…/extract.actionsdata]
   - So Shortcuts can **read** tags, subtasks, sections, flags, URLs, images and groups. EventKit can't.
3. EventKit headers (SDK 27) contain no tag, flag, section or parent properties. `EKCalendar` has no parent or group.
   - `EKCalendarItem.URL` exists but doesn't match what Reminders.app shows (forum reports).
   - There is no API that expands reminder recurrences; only events have the range predicate `predicateForEventsWithStartDate:endDate:calendars:`.
   - [VERIFIED: grep of EventKit.framework/Headers]
   - Available: `EKRecurrenceRule` (frequency, interval, days of week/month, months, weeks/days of year, setPositions, end); `EKAlarm` (absoluteDate, relativeOffset, structuredLocation, proximity); `saveReminder`/`removeReminder` with `commit:` batching; `saveCalendar`/`removeCalendar`; `calendarItemWithIdentifier`; `calendarItemsWithExternalIdentifier`; `defaultCalendarForNewReminders`; `EKEventStoreChangedNotification`; `refreshSourcesIfNecessary`; `reset`. [VERIFIED: EKEventStore.h, EKAlarm.h, EKRecurrenceRule.h]

---

## 15. Design language (for UI replication)

- **Mostly neutral, with color only where it means something:** yellow for Today (star), red for deadline/overdue (flag), indigo/blue for evening (moon), green for completed/Logbook, blue accent for selection, links and Inbox. [FORUM/BLOG: blakecrosley.com/guides/design/things — the hex values there are the author's guesses], [FORUM/BLOG: MacStories "dominated by white space… thoughtful splashes of color"]
- **Sidebar:** fixed lists at the top, then areas in bold with projects below in a lighter weight, each project with a **progress pie**. Glass material from 3.22. [FORUM/BLOG: MacStories], [VERIFIED: things/features, blog 2025/09]
- **Rows:**
  - To-dos have a rounded-square checkbox [UNVERIFIED]. Checklist items have a circle [VERIFIED: 2803582].
  - Metadata trails the title in grey: a date pill such as "Nov 13", tag pills, a red deadline flag, icons for notes, checklist and repeat. [UNVERIFIED/INFERENCE beyond the grey repeat icon VERIFIED in 3.23]
- **To-do expands inline** into a card ("Beautiful To-Dos": details are hidden until needed). Bottom-right buttons inside: When, Tags, Checklist, Deadline. [VERIFIED: things/features], [UNVERIFIED: button placement]
- **Headings:** blue text with a rule and a "…" menu [UNVERIFIED].
- **Motion and sound:** smooth animations and a satisfying completion animation [VERIFIED: features "animations"]. Sound and exact timing are [FORUM/BLOG].
- System font (SF Pro) and generous padding [INFERENCE].

---

## 16. Mapping to Apple Reminders backend

Column legend:
- **EK** = EventKit (public, sandbox-OK with the reminders and events entitlements and TCC prompt).
- **ALT** = an alternate path:
  - AppleScript to Reminders, via `com.apple.security.scripting-targets` using the sdef access groups `com.apple.reminders.read-write` / `com.apple.Reminders.read-write` / `com.apple.reminders.List.read-write` / `com.apple.Reminders.UI`, plus the Automation TCC prompt.
  - Or Shortcuts running Reminders App Intents, which needs user-installed shortcuts triggered via a `shortcuts://` URL or `/usr/bin/shortcuts` (the latter only outside the sandbox).
- **LOCAL** = metadata kept by the app, keyed by `calendarItemIdentifier` with `calendarItemExternalIdentifier` as a fallback. Not visible in Reminders.app or on iOS.
- **NF** = not feasible.

The ✓ marks show where support exists; the notes say how. Unless tagged otherwise, cells are [INFERENCE] built on the verified API facts above.

| Feature | Reminders/EventKit-native (public API) | Needs alternate path (AppleScript/Shortcuts) | App-local metadata only | Not feasible |
|---|---|---|---|---|
| Create / edit / delete to-do (title, notes) | ✓ `EKReminder`, `saveReminder`, `removeReminder` | | | |
| Complete to-do (Cmd+K) | ✓ `isCompleted` / `completionDate` | Shortcuts `completeSubtasks` cascade | | |
| **Canceled** status (Opt+Cmd+K) | partial: store as completed | | ✓ canceled flag; Logbook shows ✕ | native canceled state ✗ |
| Inbox | ✓ map to `defaultCalendarForNewReminders` (as Things' Reminders Inbox does) | Shortcuts `GetDefaultListAppIntent` | "processed" state | |
| **When date** (start) | ✓ Option A: `dueDateComponents` (all-day). Reminders.app and Siri show it and Today/Scheduled match. Option B: `startDateComponents` (Reminders.app ignores it) | | | |
| **Deadline** (separate from When) | partial: Option B above puts the deadline in `dueDateComponents` | | ✓ with Option A, deadline is LOCAL | both dates visible in Reminders.app ✗ |
| Today | ✓ computed: `predicateForIncompleteReminders(due ≤ end of today)` plus overdue deadlines | | ✓ Today manual order (`todayIndex`), "new arrival" yellow dot | |
| **This Evening** | | | ✓ evening bucket flag (or the convention due time ≥ 18:00) | |
| Upcoming (per day, drag to reschedule) | ✓ future due dates; drag rewrites `dueDateComponents` | | week/month grouping is UI | |
| Repeating preview in Upcoming | ✓ rules readable | | ✓ the app must expand `EKRecurrenceRule` itself (no reminder expansion API) | |
| Anytime | ✓ computed: incomplete, no When, not Someday | | | |
| **Someday** | | Shortcuts tag "someday" (if mirroring is wanted) | ✓ someday flag (or a dedicated "Someday" list, which costs list membership) | |
| Logbook | ✓ `predicateForCompletedReminders(…)` | | ✓ logging delay (immediate / daily / manual), canceled marker | |
| Trash / restore | `removeReminder` is permanent from the API's point of view | | ✓ soft-delete: keep a snapshot, delay removal, or re-create on restore (new ID; tags, subtasks and images lost unless captured via Shortcuts) | native Reminders "Recently Deleted" ✗ [UNVERIFIED that it exists] |
| Undo / redo | | | ✓ `UndoManager` with inverse EK ops | |
| **Projects** = lists | ✓ `EKCalendar` (entity reminder) create, rename, delete, color (`NSColor`/`CGColor`) | list emblem/icon: AppleScript `emblem` rw, Shortcuts `badge`; pinned, showsCompleted, sortingStyle, listLayout: Shortcuts `UpdateList*` | project notes, When, Deadline, Someday, project status | project "complete" as a list state ✗ (LOCAL archive) |
| Project progress pie | ✓ computed (completed / total) | | | |
| **Areas** = list groups | | Shortcuts `CreateGroupAppIntent`, `UpdateGroup*`, `DeleteRemindersListGroupsAppIntent`, `ListEntity.parent`, `GroupEntity.lists` (read and write); AppleScript list `container` may show the parent [UNVERIFIED] | ✓ fallback: LOCAL area → list mapping (not synced to Reminders) | EK read of groups ✗ |
| Loose to-dos directly in an area | | | ✓ "area inbox" hidden list or LOCAL | native ✗ (groups can't hold reminders) |
| **Headings** = sections | | Shortcuts `CreateSectionAppIntent`, `MoveRemindersToSection`, `UpdateSection*(name, isCollapsed)`, `DeleteSectionsAppIntent`, `SectionEntity` read | ✓ fallback LOCAL headings | EK ✗ |
| Archive heading / convert heading to project | | sections via Shortcuts; convert = create list and move reminders (EK move works for the reminders themselves) | archived state | |
| **Checklist** | ✓ Option A: Markdown `- [ ]` lines in `notes` (portable, visible in Reminders as text) | Option B: Reminders **subtasks** (`subtasks`, `parentReminder`, `MoveRemindersToParentReminder`, `isSubtask`; AppleScript reminder `container` = reminder, read-only) | | EK subtasks ✗ |
| Checklist item canceled | | | ✓ (`- [~]` in notes for Option A) | |
| Convert to-do to project | ✓ new list, reminders from checklist lines | | | |
| **Tags** (flat) | | Shortcuts `AddOrRemoveTagsAppIntent`, `ReminderEntity.tags` read, `TTRSearchReminders` | ✓ fallback LOCAL tags | EK ✗ |
| Hierarchical tags | | | ✓ parent map over flat names | native ✗ |
| Tag inheritance from project/area | | | ✓ computed | |
| Tag keyboard shortcuts, filter bar, AND multi-filter | | | ✓ UI | |
| Priority (TickTick/Todoist style) | ✓ `priority` 0 / 1–4 / 5 / 6–9 | Shortcuts `priorityLevel` | | |
| Flag (Reminders "Flagged") | | AppleScript `flagged` rw; Shortcuts `isFlagged` | mirror cache | EK ✗ |
| Reminder time (one per to-do) | ✓ `EKAlarm(absoluteDate)` plus a time in `dueDateComponents`. Reminders' notification daemon delivers it on all devices | | | custom notification UI or sound (Reminders' alert, not ours) ✗ |
| Reminders on deadlines | ✓ technically possible (an extra `EKAlarm`), which Things lacks | | | |
| Snooze (15m / 1h / 3h / tomorrow 9) | ✓ rewrite `EKAlarm.absoluteDate` | Shortcuts `SnoozeRemindersAppIntent(nextTriggerTime)` | | snooze buttons inside Reminders' own notification ✗ |
| Early alert / urgent / vehicle / "when messaging" | early alert ≈ second `EKAlarm(relativeOffset)` [UNVERIFIED that it maps] | Shortcuts `earlyAlert`, `isUrgent`, `vehicleTrigger`, `contactPerson` | | EK for urgent / vehicle / messaging ✗ |
| Location reminders (beyond Things) | ✓ `EKAlarm.structuredLocation` and `proximity` | `locationTrigger` | | |
| Repeat, fixed schedule (daily / weekly / monthly / yearly, interval, weekdays, nth, last day, end) | ✓ `EKRecurrenceRule` (setPositions, daysOfTheMonth −1, `EKRecurrenceEnd`) | Shortcuts `recurrence` | | |
| Repeat **after completion** | | | ✓ on complete: strip rule or create the next reminder at completion + interval | native ✗ |
| Complete repeating item early | ✓ completing advances the series (Reminders' semantics) [INFERENCE] | | | |
| Make Exception (one occurrence) | | | approximate: LOCAL override | true per-occurrence exceptions on reminders ✗ (EKSpan is events-only) |
| Update Rule | ✓ replace rule and due date | | | |
| Create Next Copy, Show Previous Copy | | | ✓ emulate: spawn a normal reminder, keep the template | native ✗ |
| Pause / resume / stop repeat | ✓ stop = remove rule | | ✓ pause = stash rule locally, resume = restore | |
| "Add deadline, show N days earlier" | | | ✓ | |
| Manual ordering within a list | | Shortcuts `MoveRemindersAppIntent(position)` [UNVERIFIED that it persists] | ✓ LOCAL order (default) | EK order ✗ |
| Sidebar order of lists and areas | | | ✓ | |
| Move to list (Shift+Cmd+M), drag to sidebar | ✓ set `reminder.calendar` and save (cross-account moves may change the ID) [INFERENCE] | to section or parent: Shortcuts `MoveReminders*` | | |
| Move to heading | | Shortcuts `MoveRemindersToSection` | ✓ fallback | |
| Multi-select and batch edit | ✓ `saveReminder(commit: false)` then `commit()` | | | |
| Duplicate (Cmd+D), copy/paste | ✓ clone EK fields | tags, subtasks, images via Shortcuts | | |
| Paste multi-line text as to-dos | ✓ | | | |
| Notes with Markdown | ✓ `notes` plain text; rendered in-app, raw in Reminders.app | | rendering | |
| URL attachment / link | `EKCalendarItem.URL` exists but is not the Reminders URL field [FORUM/BLOG] | Shortcuts `urls` read/write | ✓ keep links in notes (Things' approach) | EK URL parity ✗ |
| Images / attachments | | Shortcuts `images` | | EK ✗ |
| Calendar events in Today / Upcoming | ✓ `EKEvent`, `predicateForEvents`, `requestFullAccessToEvents` | | per-calendar visibility choice | |
| Time-block a to-do into Calendar (beyond Things) | ✓ `saveEvent` (write-only access is enough) | | link item → event | |
| Quick Entry global hotkey panel | | | ✓ `NSPanel` plus Carbon `RegisterEventHotKey` (sandbox-OK) | |
| Quick Entry Autofill (Safari / Mail / Finder link) | | Apple Events to Safari/Mail/Finder (scripting-targets plus Automation TCC), or a non-sandboxed helper like Things uses | ✓ link goes into notes | |
| Magic Plus (drag to insert to-do, heading or project) | | | ✓ UI | |
| Type Travel, Quick Find, navigation popover | ✓ in-memory search over EK data | Continue Search over tags and sections via Shortcuts cache | ✓ index | |
| Hidden lists: Tomorrow, Deadlines, Repeating, All Projects, Logged Projects | ✓ computed | | | |
| Reminders smart lists (Today, Scheduled, Flagged, All, Assigned) | ✓ computed except Flagged and Assigned | Flagged via AppleScript/Shortcuts; `CreateCustomSmartListAppIntent(name)` only; `OpenSmartList` | ✓ saved filters | defining smart-list filter rules in Reminders ✗ |
| Shared lists, assignees | read: `EKCalendar` participants n/a [INFERENCE] | Shortcuts `assignedPerson`, `participants`, `owner` | | sharing or inviting via API ✗ |
| Multiple windows (Ctrl+Cmd+N, Cmd+double-click) | | | ✓ SwiftUI `WindowGroup(for:)` / `openWindow` | |
| Full keyboard map (section 8) | | | ✓ | |
| Dock badge (Today count) | ✓ computed; `NSApp.dockTile.badgeLabel` | | | |
| Widgets with interactive checkbox | ✓ WidgetKit plus AppIntent buttons calling EK (needs EK access in the extension, see open questions) | | ✓ widget configuration | calendar events in widget (Things also omits them) |
| Control Center / menu-bar controls (macOS 26) | ✓ WidgetKit `ControlWidget` | | | |
| Spotlight (index plus "Create To-Do") | ✓ CoreSpotlight / `IndexedEntity` and App Intents | | | |
| Siri / Apple Intelligence | ✓ App Intents; adopt the **`.reminders` AppSchema** (macOS 27) | | | invoking Reminders.app's own intents programmatically from our app ✗ (Shortcuts only) |
| Our own Shortcuts actions (Things' 13-action parity) | ✓ AppIntents framework | | | |
| Our own URL scheme / x-callback / AppleScript dictionary | | | ✓ the app's own `.sdef`, URL handler, auth token | |
| "Show in Reminders" | | AppleScript `show` (`com.apple.Reminders.UI`); `OpenReminderAppIntent` | | |
| Natural-language dates | | | ✓ own parser, or `NSDataDetector` / FoundationModels (on-device) | |
| AI "Use Model" to write to-dos | ✓ FoundationModels (public in SDK) | | | |
| Live sync and change observation | ✓ `EKEventStoreChangedNotification`, then refetch (no change details) | | ✓ diff cache | |
| Things Cloud features (Fastlane, Mail to Things) | iCloud sync comes free through Reminders | | | `@things.email`-style mail ingestion with no server ✗ |
| Apple Watch / iOS apps | data syncs through Reminders | | LOCAL metadata **won't** reach iOS unless synced (CloudKit) | n/a (macOS only for now) |

---

## 17. Design implications (brief, [INFERENCE])

- **Decide early: When maps to `dueDateComponents`; Deadline is LOCAL.**
  - This keeps Reminders.app, Siri, iOS and notifications consistent with what the user sees in our app.
  - The other choice (When = `startDateComponents`, Deadline = due) is more faithful to Things but invisible in Reminders.app. Reminders.app items also arrive with no start date.
- **Run two tiers.** EventKit is the source of truth for everything public. An optional "Enhanced mode" adds AppleScript (flag, list emblem) and Shortcuts (tags, sections, subtasks, groups, URLs, images) behind explicit Automation consent.
  - Hard rule from Things' own design: **never** drop data the app can't see. Hide or lock items with subtasks, attachments or location like Things' Reminders Inbox does, or edit only the fields we own.
- **Metadata store:** keyed by `calendarItemIdentifier`, with `calendarItemExternalIdentifier` and a title/creation-date fingerprint as fallbacks. If it should follow the user across Macs, it needs its own sync (CloudKit).

---

## Open questions

1. Does the AppleScript `list.container = list` mean Reminders **groups** are visible and readable as list containers through Apple Events? Can AppleScript `make new list at <group>` work? (Needs a test outside planning mode.)
2. How does Things' importer read Reminders **tags** (documented as Tags → Tags) when EventKit has no tag API? Hashtags in the title, a private API, or something else?
3. Does `EKReminder.startDateComponents` show up anywhere in Reminders.app on macOS 26/27, and does setting it change Reminders' Today or Scheduled lists?
4. Does setting `EKCalendarItem.URL` on macOS 27 now fill the Reminders URL field (`ReminderEntity.urls`), or are they still separate?
5. Do Reminders' "early alert" and "urgent" (macOS 26+) map to extra `EKAlarm`s that EventKit can see? Do alarms we write show Reminders' own snooze options?
6. Is `calendarItemIdentifier` stable when a reminder moves between lists in the same iCloud account, and across accounts? Does Reminders' `ReminderEntity` id equal the EK identifier? (This matters for joining Shortcuts and EK data.)
7. Does `MoveRemindersAppIntent(position:)` persist a manual order that EventKit or AppleScript can read back?
8. Can a sandboxed app run user-installed Shortcuts without bringing Shortcuts to the foreground (`shortcuts://x-callback-url/run-shortcut`)? Or is a non-sandboxed helper needed, like Things' Autofill helper, which means distributing outside the Mac App Store?
9. Can a WidgetKit or Control extension on macOS 27 get Reminders full access itself, or does it need the host app to have it, for interactive check-off?
10. What are the exact `.reminders` AppSchema intent parameter shapes (e.g. `CreateReminderIntent`)? Read the full swiftinterface or WWDC26 docs. Does adopting them make Siri AI route requests to our app the way Things 3.24 seems to?
11. Things UI details still unconfirmed: the Logbook setting options (Immediately / Daily / Manually); the "N days left" deadline label; the to-do checkbox shape and heading color; Upcoming grouping after 7 days (rest of month vs weeks); whether Magic Plus can be dragged on Mac; Logbook grouping by date; the Dock badge setting.
12. Does Reminders on macOS 27 have a "Recently Deleted" that our deletions go to? That decides whether a LOCAL Trash is needed or would duplicate it.