# macOS platform and architecture research: a Swift/SwiftUI client for Apple Reminders (macOS 26/27, Xcode 27)

The shared web-search budget ran out near the end of this run. The FoundationModels latency figures and Things/TickTick/Todoist UX details are therefore from my own knowledge and tagged UNVERIFIED. Everything tagged `[VERIFIED: SDK]` was read from `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/...` (Xcode 27.0, SDK 27.0; the interfaces were built with Swift 6.4).

Abbreviations: **SUI** = `System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`; **SUICore** = `SwiftUICore.framework/.../arm64e-apple-macos.swiftinterface`.

---

## 0. Top-line recommendations

| Decision | Recommendation | Why |
|---|---|---|
| Deployment target | **macOS 26.0**. Gate macOS 27 APIs with `if #available(macOS 27, *)`. | macOS 26 brings FoundationModels, `TextEditor(AttributedString)`, DataDetection, `DropSession`/drag-container APIs, the `EKEventStore.EventStoreChanged` main-actor message, Liquid Glass APIs and the List performance work. macOS 27 adds only `reorderable()`, `swipeActions` on any view, PCC and `IndexedEntityQuery`, and `reorderable` has crash reports. |
| Layout | `NavigationSplitView` with 2 columns (sidebar + list), plus `.inspector(isPresented:)` for the detail editor. | A 3-column split view cannot hide its detail column. The inspector can be toggled, so one layout serves both a Things-like mode (no detail pane, inline editing) and a TickTick-like mode (detail pane on the right). |
| Store isolation | A `@MainActor @Observable final class ReminderStore` owns one `EKEventStore`. Fetch results are mapped to `Sendable` value snapshots. | `UndoManager` is `NS_SWIFT_UI_ACTOR`, its handlers are `@MainActor`, and macOS 26's `EKEventStore.EventStoreChanged` is a `MainActorMessage` (all [VERIFIED: SDK]). Local writes are fast. |
| Concurrency settings | Swift 6 language mode. App target: Default Actor Isolation = MainActor, Approachable Concurrency on. Core package: nonisolated. | These are the Xcode 26+ defaults for new projects [BLOG: donnywals.com/setting-default-actor-isolation-in-xcode-26]. Pure logic stays usable off the main actor. |
| Local metadata | One Codable JSON file, written atomically with debounce. Put it in the App Group container if widgets ship. Key reminders by `{calendarItemIdentifier, calendarItemExternalIdentifier}`. | No query needs justify SwiftData or Core Data. SwiftData's `ModelContext` adds isolation friction. Move to GRDB/SQLite only if metadata gets past roughly 10k rows or needs querying. |
| Quick entry | `sindresorhus/KeyboardShortcuts` for the global hotkey. An `NSPanel` subclass with `.nonactivatingPanel` hosts the SwiftUI view in `NSHostingView`. | The package works in the sandbox and on the Mac App Store, and includes a recorder UI. A non-activating panel leaves the user's current app active. |
| Natural-language input | A deterministic token grammar plus `DataDetection` (macOS 26) for dates, and our own recurrence grammar. FoundationModels is an optional second pass with deterministic resolution and a fallback. | Always available, instant and testable. The LLM depends on Apple Intelligence being present and enabled. |
| Distribution | Sandboxed and hardened-runtime builds from day 1. Primary channel: Mac App Store with TestFlight. Fallback: Developer ID + Sparkle. | Both bridge mechanisms (AppleScript to Reminders, running shortcuts via Shortcuts Events) have scripting-target access groups, so the Mac App Store stays possible (see §6). |
| Project | An Xcode project for the app and extensions, plus one local Swift package `Core` for pure logic. Test with Swift Testing. | Entitlements, Info.plist, App Intents metadata and extensions need an Xcode target. `swift test` gives a fast loop for the logic. |

---

## 1. SwiftUI app structure

### 1.1 Three panes: NavigationSplitView vs 2 columns + inspector
- `inspector(isPresented:content:)`, `inspectorColumnWidth(min:ideal:max:)` and `inspectorColumnWidth(_:)` exist (SUI:14965-14969, macOS 14+) [VERIFIED: SDK].
- On macOS 26, sidebars float as Liquid Glass. Inspectors get a blurred background but do not float. `.searchable` on a `NavigationSplitView` places search at the top trailing edge on Mac [DOCS: WWDC25-323 via wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design].
- `NavigationSplitViewVisibility` (`.all`, `.doubleColumn`, `.detailOnly`) only hides leading columns, never the detail column [UNVERIFIED/INFERENCE from API shape]. That is the reason to use an inspector.
- **Recommendation:**
  ```swift
  NavigationSplitView {
      Sidebar(selection: $nav)
  } detail: {
      TaskList(nav)
  }
  .inspector(isPresented: $showInspector) {
      ReminderInspector(ids: selection)
  }
  ```
  - Toggle the inspector with ⌥⌘I. Persist `showInspector` with `@SceneStorage`.
  - How the competitors do it [UNVERIFIED]: Things uses 2 panes with inline expanding cards. TickTick uses 3 panes. Todoist uses 2 panes plus a detail modal or side panel.

### 1.2 List selection and multi-select
- Use `List(selection: Binding<Set<ReminderID>>)`. ⌘-click, ⇧-click and arrow-key navigation are built in on macOS.
- Use `contextMenu(forSelectionType:menu:primaryAction:)` (SUI:28846, macOS 13) [VERIFIED: SDK]:
  - right-click acts on the whole selection;
  - `primaryAction` handles double-click and Return, which open the inspector or inline editing.
- Other built-in hooks [VERIFIED: SDK]:
  - `onDeleteCommand` (17018), `onMoveCommand` (17001) and `onExitCommand` (17006) for Delete, arrow keys and Esc.
  - `copyable`, `cuttable` and `pasteDestination` (13910-13922, macOS 13) for ⌘C/⌘X/⌘V of reminders.

### 1.3 Inline editable rows
- **Recommended pattern:** rows show `Text`. Return, double-click or `primaryAction` swaps the row into a `TextField` focused with `@FocusState var editing: ReminderID?` and `.focused($editing, equals: id)`.
  - `.onSubmit` commits, inserts a new reminder after this one, then sets `editing = newID` on the next runloop. The new row must exist before it can take focus [UNVERIFIED/FORUM-common].
  - Keeping a `TextField` in every row fights List selection: clicking the field starts editing instead of selecting the row [INFERENCE].
- **Tab to indent:** EventKit has no subtasks (established), so a parent/child relationship cannot be written through public API.
  - Options: no indent in v1; an app-local fake hierarchy (invisible in Reminders); or the Shortcuts bridge using `MoveRemindersToParentReminder`.
  - If inline Tab, Esc or arrow handling is needed while editing, use an `NSTextField` representable and handle `insertTab:`, `insertBacktab:`, `cancelOperation:`, `moveUp:` and `moveDown:` in `control(_:textView:doCommandBy:)`. That is reliable; SwiftUI `onKeyPress` on a focused `TextField` loses keys the field editor consumes [UNVERIFIED/INFERENCE].
- `onKeyPress(_:action:)`, `onKeyPress(keys:phases:)` and `onKeyPress(characters:phases:)` are macOS 14+ (SUI:25732-25743) [VERIFIED: SDK]. Attach them to the List (which is focusable) for single-key commands while not editing.

### 1.4 Reordering and drag and drop
- EventKit has no manual sort order. Reminders' own manual order is not exposed (established), so manual order lives in app metadata. Use fractional or LexoRank string keys per list. Our order will differ from Reminders.app's order (open question Q3).
- Availability [VERIFIED: SDK unless noted]:

| API | macOS | Line / source | Use |
|---|---|---|---|
| `ForEach.onMove(perform:)` | 10.15 | SUI:14183 | Reorder within a list (v1). |
| `dropDestination(for:action:isTargeted:)` (old) | 13 | SUI:2710-2713 | Marked to be deprecated (`deprecated: 100000.0`) in favour of the `DropSession` form. |
| `dropDestination(for:isEnabled:action: (items, DropSession))` | 26 | SUI:2714-2720 | Drop onto sidebar lists (move to list) and onto date headers (reschedule). |
| `draggable(containerItemID:)`, `draggable(_:item:)`, `dragContainer(for:...)`, `dragContainerSelection(_:)` | 26 (iOS 27) | SUI:32478-32502 | Native multi-item drag of a selection. |
| `onDragSessionUpdated` | 26 | SUI:32506 | Drag feedback. |
| `reorderable()`, `reorderable(collectionID:)`, `reorderContainer(for:in:isEnabled:move:)`, `DropSession.reorderDestination`, `ReorderDifference{sources, destination{collectionID, position .before(id) / .end}}` | **27** | SUI:12901-13002 | Cross-section reordering (drag between date sections = reschedule). |
| `TableRowContent.draggable` / `.dropDestination` | 14 | SUI:4522-4527 | Table rows. |

- Known 27 bugs [BLOG: mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27]:
  - `reorderable()` crashes if the body contains `if #available`;
  - a `.popover` on an item crashes during reorder;
  - `.dropDestination` on list items "now works" in 27, which implies it was unreliable before.
- **Recommendation:** on 26, use `.onMove` plus `dropDestination` on sidebar rows and section headers. On 27, adopt `reorderContainer` behind `#available` only after a spike.
- Transferable: one custom type, so payloads never carry EventKit objects.
  ```swift
  extension UTType { static let reminderRef = UTType(exportedAs: "<bundle>.reminder-ref") }
  struct ReminderRef: Codable, Transferable {
      var ids: [String]
      static var transferRepresentation: some TransferRepresentation {
          CodableRepresentation(contentType: .reminderRef)
      }
  }
  ```
  - Add `UTExportedTypeDeclarations` to Info.plist.
  - Add a `ProxyRepresentation` to plain text only if dragging out to other apps is wanted.
  - For multi-drag on 26, the simplest trick is a payload of the whole selection when the dragged row is selected, otherwise that row alone. Use `dragContainer` only if the trick feels wrong [INFERENCE].

### 1.5 Commands, keyboard and focused values
- `focusedSceneValue<T: AnyObject & Observable>(_:)` and `@FocusedValue(Type.self)` are macOS 14+ (SUI:4745-4757) [VERIFIED: SDK]. Pattern:
  ```swift
  @Observable final class SelectionModel { var ids: Set<ReminderID> = [] }
  // in the window: .focusedSceneValue(selectionModel)
  // in Commands:   @FocusedValue(SelectionModel.self) var sel
  CommandMenu("Reminder") {
      Button("Complete") { … }.keyboardShortcut("k").disabled(sel?.ids.isEmpty ?? true)
  }
  CommandGroup(replacing: .newItem) { … }
  ```
- Caveat [BLOG: mjtsai 2026-06-19]: SwiftUI cannot build submenus dynamically when the parent opens, and the app menu is computed only once. Use a "Move to…" picker sheet (⇧⌘M, Things-style [UNVERIFIED]) instead of a dynamic list-of-lists submenu.
- `modifierKeyAlternate(_:_:)` (macOS 15, SUI:26744) gives ⌥-alternate menu items [VERIFIED: SDK].

### 1.6 Search, Table, sections, toolbar, Settings, windows, menu bar
- **Search:**
  - `.searchable(text:placement:prompt:)` (SUI:7272) [VERIFIED: SDK].
  - `.searchFocused(_:)` (macOS 15, SUI:7494) [VERIFIED: SDK] wires ⌘F through a `CommandGroup` button.
  - Tokens: `searchable(text:tokens:...)` (macOS 13) [VERIFIED: SDK, ~15159].
  - EventKit has no text predicate, so filter the in-memory snapshots.
- **Table:**
  - `Table` with `DisclosureTableRow` (macOS 14, SUI:31330) [VERIFIED: SDK] supports multi-select, sort descriptors and column customization.
  - **Recommendation:** use it only for an optional "All / Search results" power view. Use List everywhere else.
- **Collapsible sections:** `Section(isExpanded:)` (macOS 14, SUI:14568) [VERIFIED: SDK]. Persist the expansion set in `@SceneStorage` or `@AppStorage`. Use `DisclosureGroup` for sidebar folders (app-local list groups).
- **Toolbar:**
  - macOS 26: `ToolbarSpacer(.fixed / .flexible)` and `.sharedBackgroundVisibility(.hidden)`. Items are grouped into glass automatically [DOCS: WWDC25-323].
  - macOS 27: `visibilityPriority` (`ToolbarItemVisibilityPriority.high` is macOS 26.1, SUI:13372) and `ToolbarOverflowMenu` [VERIFIED: SDK / DOCS: wwdcnotes WWDC26-269].
- **Settings:** a `Settings { TabView {…} }` scene with `@AppStorage`, including `KeyboardShortcuts.Recorder`.
- **Windows** [VERIFIED: SDK]:
  - `WindowGroup(for: ListID.self)` plus `openWindow(value:)` (`OpenWindowAction`, macOS 13, SUI:3777) for "Open list in new window".
  - `UtilityWindow` (macOS 15, SUI:19382).
  - `windowLevel(_:)` and `WindowLevel` (macOS 15, SUI:684/709).
  - `PlainWindowStyle` (macOS 15, SUI:18552).
  - `defaultWindowPlacement`, `restorationBehavior` and `defaultLaunchBehavior` (SUI:11616/279/11543).
  - `NSHostingSceneRepresentation` (macOS 26, SUI:10390).
- **Menu bar:** `MenuBarExtra(…, isInserted: $flag)` with `.menuBarExtraStyle(.window)` (macOS 13, SUI:2092/21780) [VERIFIED: SDK] for an optional Today popover. Programmatic open/close is limited [UNVERIFIED]. Switch to `NSStatusItem` + `NSPopover` only if that bites.
- **macOS 27 risk:** popovers shown more than once can crash [BLOG: mjtsai 2026-06-19]. Inline date-picker popovers in rows are exactly that pattern, so test them early on 27.

### 1.7 Liquid Glass and SF Symbols
- What happens automatically when built with the 26/27 SDK [DOCS: WWDC25-323; WWDC26-269 notes]:
  - floating glass sidebar and toolbar glass grouping;
  - capsule bordered buttons (mini/small/medium stay rounded rectangles on Mac) and slightly taller controls;
  - search at the top trailing edge, and menus and popovers that morph out of their buttons;
  - on 27, a refined glass look, the `.appearsActive` environment value, and fewer icons in menus.
- The compatibility opt-out (`UIDesignRequiresCompatibility` and its Mac equivalent) **is ignored when building with the 27 SDKs**, including macOS 27, whatever the deployment target [FORUM: Apple engineer, developer.apple.com/forums/thread/832543]. Design for glass.
- APIs [VERIFIED: SUICore]: `glassEffect(_:in:)` (3064), `Glass` (7245), `GlassEffectContainer` (11523), `glassEffectID` (22411), `glassEffectUnion` (12644), `glassEffectTransition` (3512). Also `backgroundExtensionEffect()` (macOS 26, SUI:15831) and `scrollEdgeEffectStyle(_:for:)` (SUI:15924).
- **Recommendation:**
  - No custom backgrounds behind the sidebar or toolbar. Use `.listStyle(.sidebar)` and per-list `.tint` from `EKCalendar.cgColor`.
  - Use `glassEffect` only on the quick-entry panel and any floating "+" button, inside a `GlassEffectContainer`.
  - Animate completion with `.contentTransition(.symbolEffect(.replace))` on the `circle` ↔ `checkmark.circle.fill` toggle.
  - Only the key panel gets the active glass look [FORUM: developer.apple.com/forums/thread/818901].

### 1.8 List performance and when to drop to AppKit
- WWDC25 (session 256): macOS lists of 100k+ items load up to 6x faster and update up to 16x faster [VERIFIED via transcript index nonstrict.eu/wwdcindex/wwdc2025/256; macg.co coverage]. Pre-26 reports describe minute-long stalls at 100k (developer.apple.com/forums/thread/761829) [FORUM].
- WWDC26 adds `@Observable` snapshot diffing, lazy `@State` init and `@ContentBuilder` type-checking gains [DOCS: wwdcnotes WWDC26-269]. Practitioners still call AppKit/UIKit far ahead for large custom collections [BLOG: mjtsai 2026-06-19].
- Rules for rows:
  - pass immutable `ReminderSnapshot` values into rows rather than having each row observe the store;
  - use stable IDs and no `.id()` churn;
  - no `GeometryReader` or `AnyView` in rows;
  - precompute section arrays;
  - on reload, replace only changed snapshots (compare by `id` + `lastModifiedDate`).
- Threshold for switching one list to `NSTableView`/`NSOutlineView` via `NSViewRepresentable` [INFERENCE]: profiling shows hitches with more than about 5–10k visible rows, or you need precise field-editor control, type-select, or custom multi-row drag images.
- Note: Instruments may report "Trace file had no SwiftUI data" in Xcode 26/27 [BLOG: mjtsai].

---

## 2. State and concurrency

### 2.1 EventKit facts that drive the design
All from `EventKit.framework/Headers` unless noted [VERIFIED: SDK].

- **No Sendable annotations.** EventKit has no `NS_SWIFT_SENDABLE` or `NS_SWIFT_UI_ACTOR`, so `EKEventStore` and `EKReminder` are non-Sendable.
- **Swift overlay (macOS 26).** `EKEventStore.EventStoreChanged: NotificationCenter.MainActorMessage` with `.changed` (`EventKit.swiftmodule/arm64e-apple-macos.swiftinterface`). Observe with `NotificationCenter.default.addObserver(of: store, for: .changed) { @MainActor msg in … }`; the Foundation `addObserver<Identifier, Message>(of:for:using: @MainActor …)` overload is verified in Foundation's interface (line ~10481).
- **Change notification carries no object IDs.** `EKEventStoreChangedNotification`'s public docs say to treat all objects as invalid and re-fetch, or call `refresh` on objects in use. It fires for external processes, **for another `EKEventStore` in the same process**, and when access changes. No changed-object-IDs key is public, so do a full re-fetch with debounce.
- **Async fetch, no Swift async import.** `fetchRemindersMatchingPredicate:completion:` returns a cancel token (`cancelFetchRequest:`), so Swift does not import it as async. Its completion runs on a background queue [UNVERIFIED/FORUM-common].
- **Identifier stability:**
  - `calendarItemIdentifier`: "not sync-proof… a full sync will lose this identifier".
  - `calendarItemExternalIdentifier`: server-provided and stable across devices; can be nil for new items; can be duplicated; differs per device for Exchange reminders.
  - `EKCalendar.calendarIdentifier`: also lost on full sync, with a fallback "by title, type, color".
- **Lists cannot move between accounts.** An `EKCalendar`'s source is effectively read-only after creation (`EKErrorCalendarSourceCannotBeModified`).
- **Batching and rollback.** `commit:` batches writes made with `commit:NO`. `reset` forgets ALL uncommitted changes and invalidates every fetched object. `refreshSourcesIfNecessary` triggers a remote sync when needed.
- **Undo is main-actor.** `NSUndoManager` is `NS_SWIFT_UI_ACTOR`. Swift `registerUndo(withTarget:handler: @MainActor …)` is in Foundation's interface (line 18032).
- **One store per app.** WWDC23 10052 says to keep one store [FORUM: developer.apple.com/forums/thread/808799, no DTS reply; a community reply suggests wrapping it in an actor].

### 2.2 Recommended store shape
```swift
nonisolated struct ReminderSnapshot: Sendable, Hashable, Identifiable {   // in Core (nonisolated package)
  let id: String              // calendarItemIdentifier
  let externalID: String?
  let listID: String
  var title: String, notes: String?, url: URL?
  var isCompleted: Bool, completionDate: Date?
  var priority: Int           // 0 none, 1-4 high, 5 medium, 6-9 low
  var start: DateComponents?, due: DateComponents?   // all-day = no hour/minute
  var alarms: [AlarmSnapshot], recurrence: RecurrenceSnapshot?
  let created: Date?, modified: Date?
}

@MainActor @Observable final class ReminderStore {
  private let ek = EKEventStore()
  private(set) var byID: [String: ReminderSnapshot] = [:]
  // observe .changed → scheduleReload() (cancel previous Task, sleep ~250 ms, reload)
  // reload: await a nonisolated helper wrapping fetchReminders with a continuation;
  //         map EKReminder → snapshot inside the completion (EventKit's queue); diff-apply on main
  // mutate: ek.calendarItem(withIdentifier:) as? EKReminder → edit → ek.save(r, commit: true)
  //         → patch byID immediately (instant UI) → the later reload reconciles
}
```
- **Swift 6 pitfall** [INFERENCE, a well-known Swift 6 failure class]:
  - Under MainActor default isolation, a closure written inside the `@MainActor` class and passed to an ObjC completion that is not marked `@Sendable` is inferred `@MainActor`. If EventKit calls it off-main, the runtime isolation check traps.
  - Fix: build the completion inside a `nonisolated` helper, or mark the closure `@Sendable`.
  - Make snapshot types `nonisolated` by putting them in the Core package.
- **Reloads:**
  - Incomplete reminders: `predicateForIncompleteReminders(withDueDateStarting:nil, ending:nil, calendars:nil)`.
  - Completed reminders: `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)` in windows (for example the last 30 days, paginated). The completed archive can be huge.
- **Scale-up path:** if profiling shows main-thread cost (more than about 5k reminders), add a second read-only `EKEventStore` owned by an `actor` for fetches. Two stores in-process are explicitly supported by the change-notification semantics. Keep writes on the main store and cross between stores by identifier only. EventKit objects belong to the store that fetched them [INFERENCE].
- **Optimistic UI:** no separate layer. Local saves are synchronous and fast. Patch the snapshot right after `save`; on error, revert and alert.
- **Completion UX:** keep a just-completed row visible about 1–2 s before it hides, as a UI timer. The data itself is not delayed.
- Call `refreshSourcesIfNecessary()` on `NSApplication.didBecomeActiveNotification`.

### 2.3 Undo
- Pass `@Environment(\.undoManager)` into store methods, for example `complete(_ ids:, undo: UndoManager?)`.
  - Register the inverse with `registerUndo(withTarget: store) { $0.uncomplete(ids, undo: um) }` and call `setActionName`.
  - Use `beginUndoGrouping`/`endUndoGrouping` for multi-select operations.
  - Edit > Undo is wired automatically through the window's undo manager.
- Covered by inverse operations: complete, uncomplete, edit fields, reschedule, move list, priority, and reorder (metadata).
- **Delete is the data-loss case** [INFERENCE]: recreating a deleted reminder through EventKit gives it a new `calendarItemIdentifier`. It also permanently loses Reminders-only data EventKit cannot see: tags, subtasks' parent links, sections, flag, images.
  - **Recommendation:** soft delete. Hide the reminder in the app, show an "Undo" toast, and call `remove(commit:true)` after about 8 s or on `applicationShouldTerminate`.
  - `commit:false` + `reset()` is **not** usable as an undo mechanism: any other `commit:true` flushes the pending delete, and `reset` invalidates every object.

### 2.4 App-local metadata
- **Store:** `AppMetadata: Codable` holding:
  - list order, folders/groups, pinned lists;
  - smart-list definitions;
  - per-list manual order (`[listKey: [reminderKey: rankString]]`);
  - collapsed sections, per-list view prefs;
  - app-local tags, if that is the product decision.
- **Write:** atomically (`Data.write(options: .atomic)`) with debounce, to `Application Support` or the App Group container (`containerURL(forSecurityApplicationGroupIdentifier:)`) if widgets ship.
- **Key resolution:**
  1. look up by `calendarItemIdentifier`;
  2. otherwise `calendarItems(withExternalIdentifier:)`, filtered by list;
  3. otherwise orphan, garbage-collected after N reloads.
  - Rewrite keys when IDs change. Lists: `calendarIdentifier`, falling back to title+source+color.
- **Cross-Mac sync of metadata (later):** key by `externalID` (iCloud CalDAV UIDs are stable across devices; Exchange is not) and sync through CloudKit, or `NSUbiquitousKeyValueStore` for small prefs (1 MB cap) [INFERENCE].
- **Why not SwiftData:** non-Sendable `ModelContext`, migration overhead, and no relational needs. Its only benefit, iCloud sync, also needs a CloudKit schema [INFERENCE]. The upgrade path, if needed, is GRDB/SQLite.

---

## 3. Quick entry

### 3.1 Global hotkey

| Option | Sandbox / MAS | Permission | Verdict |
|---|---|---|---|
| `sindresorhus/KeyboardShortcuts` (v3.1.0; wraps Carbon; SwiftUI `Recorder`; `UserDefaults`; NSMenuItem support) | "fully sandboxed and Mac App Store compatible" [VERIFIED: README github.com/sindresorhus/KeyboardShortcuts] | none | **Use.** |
| Carbon `RegisterEventHotKey` directly | yes | none | About 60 lines, but you build the recorder yourself. |
| `NSEvent.addGlobalMonitorForEvents` | — | Accessibility; cannot consume the event | Reject. |
| `CGEventTap` | sandbox OK since 10.15 [FORUM] | Input Monitoring prompt | Reject. |

- macOS 15 deliberately blocks hotkeys whose only modifiers are ⌥ or ⌥⇧ in sandboxed apps (an anti-keylogging change, per an Apple engineer). Reports conflict on whether 15.2 relaxed it [FORUM: developer.apple.com/forums/thread/763878; shottr.cc/kb/sequoia].
  - **Default:** ⌃⌥Space, user-configurable.
  - Avoid ⌃Space: it conflicts with the input-source switcher on multi-language setups [UNVERIFIED]. Things uses it [UNVERIFIED].

### 3.2 Floating panel
SwiftUI has no panel scene. `Window` plus `.windowLevel(.floating)` activates our app, so use AppKit [FORUM/BLOG: cindori.com/developer/floating-panel; developer.apple.com/forums/thread/826308].
```swift
final class QuickEntryPanel: NSPanel {
  init<V: View>(root: V) {
    super.init(contentRect: .init(x: 0, y: 0, width: 640, height: 120),
               styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
               backing: .buffered, defer: false)
    isFloatingPanel = true; level = .floating; hidesOnDeactivate = false
    titleVisibility = .hidden; titlebarAppearsTransparent = true; isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    backgroundColor = .clear; isOpaque = false
    contentView = NSHostingView(rootView: root)
  }
  override var canBecomeKey: Bool { true }
  override func resignKey() { super.resignKey(); orderOut(nil) }   // click-away dismisses
  override func cancelOperation(_ s: Any?) { orderOut(nil) }       // Esc
}
```
- Show it with `center()` then `makeKeyAndOrderFront(nil)`. Inject the same `ReminderStore` through `.environment(store)`. Own the panel and the hotkey from an `@NSApplicationDelegateAdaptor`.
- Showing the panel over full-screen apps may also need `.accessory` activation policy [FORUM: thread 826308].

### 3.3 Adding tasks from other apps
- **Services menu (v1):**
  - Info.plist `NSServices` with `NSMessage`, `NSSendTypes = public.utf8-plain-text`; set `NSApp.servicesProvider`.
  - Runs in our own process, so EventKit access works; sandbox OK [INFERENCE / long-standing AppKit].
- **Share extension (later):** `com.apple.share-services`. Extensions probably do not share the app's EventKit grant (see the §5 widget caveat), so it should hand off through the App Group plus a URL to the app [INFERENCE].
- **Autofill from Safari's current tab (Things-style):** Safari's sdef has no tab or URL access group (only `com.apple.Safari.dispatch-message-to-extension`, `show-extensions-preferences`, `com.apple.private.Safari.sync-plist`) [VERIFIED: `/Applications/Safari.app/Contents/Resources/Safari.sdef`]. It would need `temporary-exception.apple-events`, which is risky on the Mac App Store, so treat it as Developer-ID-only.

---

## 4. Natural-language quick add

### 4.1 Building blocks

| Tool | Status | What it gives | Limits |
|---|---|---|---|
| `DataDetection` framework (macOS 26) | `String.dataDetectorMatches(.calendarEvent, options:)` → `AsyncSequence<Match>`; `Match.range` (String.Index range); `CalendarEvent{allDay, startDate, startTimeZone, endDate, endTimeZone}`; `Options{documentDate, documentTimeZone, documentLanguageCode, documentRegion}` [VERIFIED: SDK `DataDetection.framework/.../arm64e-apple-macos.swiftinterface`] | Dates, ranges, all-day flag, spans to strip or highlight; a reference date can be supplied | No recurrence field. |
| `NSDataDetector(.date)` | [DOCS: developer.apple.com/documentation/foundation/nsdatadetector] | date, duration, timeZone | Drops uncertain matches; no recurrence; natural-language text only. |
| SwiftyChrono (quire-io) | 103 commits, no releases, 6 open issues, README says Swift 5.10+ [VERIFIED: github.com/quire-io/SwiftyChrono] | chrono.js port; ranges | Low maintenance; no recurrence. **Don't depend on it.** |
| Khac (nhannht) | new, about 2 months old, 0 stars [FORUM/BLOG: swiftpackageindex.com] | multi-language | Unproven. |
| FoundationModels | see 4.3 | Structured extraction | Availability-gated. |

### 4.2 Deterministic grammar (always on, instant, unit-tested)
- Tokenizer over the text, in this order:
  1. `#list`, matched to existing lists by fuzzy prefix, with an autocomplete popover.
  2. `!1`/`!2`/`!3`, `!high`/`!med`/`!low` or `!!!` → priority 1 / 5 / 9.
  3. `@tag` → app-local tag. Real tags are not in EventKit.
  4. Recurrence (own grammar): `every [other|N] (day|weekday|week|month|year|mon..sun[,…])`, `daily|weekly|monthly|yearly`, `until <date>` → `EKRecurrenceRule`. A recurring reminder needs a due date (`EKErrorRecurringReminderRequiresDueDate` [VERIFIED: EKError.h]).
  5. Dates via DataDetection with `documentDate = now`.
- Rules:
  - A date without a time is all-day (`dueDateComponents` without hour/minute).
  - A time already past today rolls to tomorrow.
  - Strip matched spans from the title.
- Testing: table-driven tests with a fixed `now`, `TimeZone`, `Locale` and `Calendar`.

### 4.3 FoundationModels (optional second pass)
- **Availability** [VERIFIED: SDK `FoundationModels.swiftinterface`]:
  - `SystemLanguageModel.default.availability`: `.available`, or `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`.
  - Also `supportsLocale(_:)`, `supportedLanguages`, `prewarm(promptPrefix:)`, `UseCase.general` / `.contentTagging`.
  - macOS 27 adds variants `.core3` / `.coreAdvanced3` and `PrivateCloudComputeLanguageModel` (availability `.deviceNotEligible` / `.systemNotReady`, quota API).
- **Macros:** `@Generable(description:)`, `@Guide(description:)`, `@Guide(_ guides: GenerationGuide<T>...)` and `@Guide(_: Regex)` [VERIFIED: SDK lines 1133-1148]. `DynamicGenerationSchema` handles runtime enums such as the user's list names.
- **Requirements:** a device that supports Apple Intelligence. Availability also depends on region [DOCS: developer.apple.com/documentation/foundationmodels].
- **Context and PCC** [DOCS: …/adding-server-side-intelligence-with-private-cloud-compute]:
  - On-device context is 4K tokens; PCC is 32K, needs a network connection, has a daily per-user limit, and needs the **managed entitlement** `com.apple.developer.private-cloud-compute`.
  - Using PCC to parse a one-line task would be overkill.
- **Recommended use:**
  - The model **extracts spans** (`title`, `dateText`, `listName` from the provided `anyOf`, a `priority` enum, a `recurrence` struct: frequency, interval, weekdays).
  - Code **resolves** `dateText` through DataDetection. Do not let the model compute dates. Put today's date, weekday and time zone in the instructions.
- **Latency:** unknown; my rough guess is sub-second to about 2 s after `prewarm` [UNVERIFIED; the search budget ran out before benchmarks].
  - Never block typing. Run the deterministic parse live.
  - Run the LLM pass only after a ~600 ms pause or on explicit ⌘↩. Show result chips the user accepts.
  - Fall back silently on `.unavailable` or guardrail errors.

### 4.4 Highlighting tokens while typing
- `TextField` has no `AttributedString` binding. Only `TextEditor(text: Binding<AttributedString>, selection:)` (macOS 26, SUI:4020-4029) [VERIFIED: SDK].
- **v1 (lazy):** plain `TextField` plus a row of parsed chips below it.
- **v2:** an `NSTextView` single-line representable with attribute ranges and a completion popover. It gives better Return, Tab and Esc control than `TextEditor`.

---

## 5. System integration

| Feature | Recommendation | Evidence |
|---|---|---|
| **Widgets** | A widget extension renders an **App Group JSON snapshot** written by the app, which calls `WidgetCenter.shared.reloadTimelines(ofKind:)` on store change. Interactive `Toggle(isOn:intent:)` / `Button(intent:)`: `perform()` runs **in the widget extension process** unless `openAppWhenRun`, `ForegroundContinuableIntent` or `AudioPlaybackIntent`. `LiveActivityIntent` is **unavailable on macOS**, and `ForegroundContinuableIntent` is unavailable in macOS app extensions. So the extension must write EventKit itself (calendars entitlement plus its own usage string, and the grant may not be inherited), or queue the action in the App Group and open the app. **A spike is required** (Q1). | [DOCS: developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities]; [VERIFIED: SDK AppIntents.swiftinterface:253-257, 3509-3514]; iOS 16.1 regression where widget EventKit status became `.denied`, no DTS answer [FORUM: developer.apple.com/forums/thread/715489] |
| **App Intents (ours)** | Only add intents Reminders lacks: Open Quick Entry, Open Smart List, Add (NL-parsed), Show Today. `AppShortcutsProvider`. Use `supportedModes` (macOS 26) instead of the deprecated `openAppWhenRun`. `SnippetIntent` and `UndoableIntent` are anyAppleOS 26; `IndexedEntity` is macOS 15; `IndexedEntityQuery` is macOS 27. macOS 26 Spotlight runs App Intents as actions with Quick Keys. | [VERIFIED: SDK AppIntents.swiftinterface:2609, 3104-3107, 3663, 3708, 4251]; [BLOG: techcrunch.com/2025/06/09/apple-updates-spotlight-to-take-actions-on-your-mac] |
| **CoreSpotlight** | **Don't index reminders.** Reminders.app already does, so results would duplicate. Index only app-only entities (smart lists), if any. | [INFERENCE] |
| **URL scheme** | `CFBundleURLTypes` plus `.onOpenURL`: `app://reminder/<id>?ext=<externalID>`, `app://list/<id>`, `app://add?title=&list=&due=`. Include the external ID because local IDs can change. | [INFERENCE] |
| **Open in Reminders** | AppleScript `show` (access group `com.apple.Reminders.UI`, established) as the escape hatch for tags, subtasks and images. | established fact |
| **Launch at login** | `SMAppService.mainApp.register()` (macOS 13), sandbox OK, with a Settings toggle. | [VERIFIED: SDK SMAppService.h:65-91] |
| **Notifications** | **Schedule none.** Reminders' own alarm delivery already fires for `EKAlarm`s, so ours would duplicate. Request `UNAuthorizationOptions.badge` only if the dock badge is enabled. | [INFERENCE]; badge needs authorization [FORUM: developer.apple.com/forums/thread/696708] |
| **Dock badge** | Opt-in. `NSApp.dockTile.badgeLabel` or `UNUserNotificationCenter.setBadgeCount` (macOS 13). Count = incomplete today + overdue. Recompute on store change, `NSCalendarDayChanged` and wake. | [VERIFIED: SDK UNUserNotificationCenter.h:77] |
| **Calendar events** | Opt-in. `requestFullAccessToEvents` is a separate prompt and needs `NSCalendarsFullAccessUsageDescription`. Fetch synchronously with `events(matching:)` over a bounded window (about 14 days). Read-only display. | [DOCS: developer.apple.com/documentation/eventkit/accessing-the-event-store] |

---

## 6. Distribution and security

- **Entitlements (app; also any extension touching EventKit):**
  - `com.apple.security.app-sandbox`
  - `com.apple.security.personal-information.calendars`: covers reminders, and is required for sandboxed Mac apps [DOCS: accessing-the-event-store]
  - Hardened runtime on.
  - When sending Apple events: `com.apple.security.automation.apple-events` (hardened-runtime entitlement) [INFERENCE/standard].
  - `com.apple.security.application-groups` if widgets ship.
- **Bridges via scripting targets (sandbox-legal; QA1888)** [DOCS: developer.apple.com/library/content/qa/qa1888]:
  - Reminders (`com.apple.reminders`): access groups `com.apple.reminders.read-write`, `com.apple.reminders.List.read-write`, `com.apple.Reminders.read-write`, `com.apple.Reminders.UI`. The capitalization really is inconsistent [VERIFIED: local Reminders.sdef counts].
  - **Shortcuts Events** (`com.apple.shortcuts.events`): access group **`com.apple.shortcuts.run`**. Its `run` command takes `with input` and returns a result, and runs "in the background, without opening the Shortcuts app" [VERIFIED: `/System/Library/CoreServices/Shortcuts Events.app/Contents/Resources/Shortcuts.sdef`, lines 14, 73-79].
  - So a sandboxed Mac App Store app can run user-installed helper shortcuts that call Reminders' private App Intents (tags, subtasks, sections, flags).
  - Each bridge triggers an Automation TCC prompt (needs `NSAppleEventsUsageDescription`).
  - Avoid `temporary-exception.apple-events`; App Review scrutinizes it.
- **Developer ID, non-sandboxed, only adds:**
  - `Process("/usr/bin/shortcuts")`;
  - Safari/Mail autofill;
  - `NSEvent` global monitors.
  - It is not needed for the core feature set.
  - Never use the private ReminderKit frameworks or the Reminders DB directly.
- **Updates:** Sparkle 2 supports sandboxed apps through its XPC installer [UNVERIFIED].
- **Info.plist keys:**
  - `NSRemindersFullAccessUsageDescription` (required on 14+);
  - `NSRemindersUsageDescription` (legacy fallback, harmless);
  - `NSCalendarsFullAccessUsageDescription` (if events are shown);
  - `NSAppleEventsUsageDescription` (bridges);
  - `UTExportedTypeDeclarations`, `CFBundleURLTypes`, `NSServices`.
  - Missing usage keys mean automatic denial on 17+-era OSes [DOCS].

---

## 7. Project structure, testing and builds

- **Layout:**
  - `App.xcodeproj` with targets App (+ Widget later); use buildable folders to cut `.pbxproj` conflicts.
  - `Packages/Core`: Swift package, nonisolated default. Holds snapshots, filters (Today/Upcoming/Overdue with injected `now`/`Calendar`), rank keys, the NL parser, the recurrence model and metadata Codable.
  - The App target holds the EventKit store, UI and AppKit bits.
  - One abstraction is justified: `RemindersBackend` with an EventKit implementation and an in-memory implementation. It has two real consumers: SwiftUI previews and UI tests, neither of which can hit TCC. No other protocols.
- **Testing (Swift Testing):**
  - Unit: `@Test(arguments:)` tables for the parser and filters; run with `swift test` in `Packages/Core`.
  - Integration test plan, hosted in the app (`TEST_HOST`) so TCC attributes access to the app [INFERENCE]:
    - `.serialized`;
    - `.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess)`;
    - create a `ZZ-Test-<UUID>` `EKCalendar(for: .reminder, eventStore:)` and remove it in teardown.
  - ⚠️ If the default source is iCloud, the test list **syncs to the real account**. Run integration tests only in a dedicated macOS user or VM with a test Apple Account.
  - macOS 27 moved the user TCC DB into a protected container, so it cannot be pre-seeded on CI [FORUM: developer.apple.com/forums/thread/834560]. XCUITest cannot click TCC prompts [BLOG: tessl xcuitest macOS ref]. UI tests use the in-memory backend via a launch argument.
- **Builds:**
  - `xcodebuild -scheme App -destination 'platform=macOS' build`
  - `xcodebuild test -scheme App -destination 'platform=macOS,arch=arm64' -testPlan Unit -resultBundlePath out.xcresult`
  - `-only-testing:` / `-skip-testing:` select tests; `xcodebuild -showdestinations` lists destinations.
  - Signing is required for runs that need entitlements or TCC.

---

## 8. Open questions (each needs a small spike on macOS 26 and 27)
1. **Q1 — widget and extension EventKit:** Does a macOS widget or share extension inherit the containing app's Reminders grant, or need its own (and how could it get one without UI)? This decides whether interactive widget toggles are direct or queue-and-open.
2. **Q2 — `fetchReminders` completion queue:** Confirm it is off-main, and check whether in-memory `EKReminder(eventStore:)` can be built without authorization (would allow TCC-free mapping tests).
3. **Q3 — manual order:** Is Reminders.app's manual order readable through AppleScript or the Shortcuts bridge? If not, accept divergent ordering.
4. **Q4 — AppleScript IDs:** Does the AppleScript reminder `id` (`x-apple-reminder://…`) embed `calendarItemIdentifier`? Needed to join flagged state and `show` with EventKit snapshots.
5. **Q5 — cross-account moves:** When a reminder is moved across sources (iCloud ↔ Exchange or local) by setting `calendar`, does its identifier change, and is that a delete plus create underneath?
6. **Q6 — option-only hotkeys:** Are ⌥/⌥⇧-only hotkeys still blocked in sandboxed apps on 26/27?
7. **Q7 — FoundationModels latency:** Measure time-to-result for one `@Generable` task parse after `prewarm` on base M1, and accuracy for non-English locales.
8. **Q8 — `reorderable` on macOS 27:** Is it stable with List + sections + `dropDestination`? Also the popover-crash workaround on 27.
9. **Q9 — `onMove` and multi-selection:** Does `.onMove` move all selected rows on macOS 26, or only the dragged one?
10. **Q10 — App Review:** Will Mac App Store review accept scripting-target entitlements for both `com.apple.reminders` and `com.apple.shortcuts.events` in one app, plus a helper-shortcut install flow?
11. **Q11 — tags (product):** App-local tags (invisible in Reminders) vs `#hashtag` text in notes vs the Shortcuts bridge to real tags.