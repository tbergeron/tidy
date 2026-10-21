# EventKit Reminders API audit (macOS SDK 27.0, Xcode 27.0): reference, semantics, capabilities, pitfalls

Path abbreviations used below:
- `$EK` = `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/EventKit.framework`
- Headers are in `$EK/Headers/`.
- The Swift overlay is `$EK/Versions/A/Modules/EventKit.swiftmodule/arm64e-apple-macos.swiftinterface` (Swift 6.4, `-language-mode 6`, target macos27.0).

Tags used throughout: [VERIFIED: path/URL], [DOCS], [FORUM/BLOG], [UNVERIFIED/INFERENCE].

---

## 0. Headline findings

1. **No new reminder data APIs since macOS 14.**
   - No header in SDK 27 has a `macos(15+)` annotation [VERIFIED: grep over `$EK/Headers/*.h`].
   - The only macOS 26+ addition is a Swift-overlay struct, `EKEventStore.EventStoreChanged: NotificationCenter.MainActorMessage`, used via `NotificationCenter.default.addObserver(of: store, for: .changed) { … }`. It is `@available(macOS 26)`, has no payload and only an empty `init()` [VERIFIED: swiftinterface; DOCS https://developer.apple.com/documentation/eventkit/ekeventstore/eventstorechanged].
2. **One undocumented error code is new in the header:** `EKErrorReminderAlarmContainsEmailOrUrl` (raw value 36). It has no `@constant` doc comment. It implies email and URL alarms are rejected on reminders [VERIFIED: `EKError.h`; meaning is INFERENCE].
3. **Nothing in EventKit is `Sendable`.**
   - The headers have no `NS_SWIFT_SENDABLE` annotations [VERIFIED: grep].
   - The DocC "Conforms To" lists for `EKEventStore` and `EKReminder` do not include Sendable [DOCS].
   - `fetchReminders(matching:completion:)` takes a **non-`@Sendable`** completion closure and returns `Any`, so it gets **no auto-generated async variant** (ObjC methods with a non-void return are not imported as async) [DOCS signature; INFERENCE from SE-0297 import rules].
   - `requestFullAccessToReminders()` **does** have an `async throws -> Bool` variant, and its completion handler is `@Sendable` [DOCS].
4. **Entitlements:**
   - There is **no reminders-specific sandbox or hardened-runtime entitlement**. Reminders use `com.apple.security.personal-information.calendars`.
     - Xcode's entitlement schema lists only `personal-information.{location,addressbook,calendars,photos-library}` [VERIFIED: `/Applications/Xcode.app/Contents/PlugIns/DVTCorePlistStructDefs.dvtplugin/Contents/Resources/DVTCorePlistStructDefs.xcplugindata`].
     - The matching build setting is `ENABLE_RESOURCE_ACCESS_CALENDARS` [VERIFIED: `.../SWBCore.framework/Versions/A/Resources/CoreBuildSystem.xcspec`; SWBCore strings].
   - Without the entitlement, a sandboxed app calling `requestFullAccessToReminders` gets `granted=false, error=nil` with **no prompt**. The log shows `com.apple.CalendarAgent ... Sandbox restriction` [FORUM: https://developer.apple.com/forums/thread/745752].
5. **EventKitUI does not exist for native macOS (AppKit).** It ships only under `MacOSX.sdk/System/iOSSupport/...` for Mac Catalyst, with headers `EKCalendarChooser`, `EKEventEditViewController` and `EKEventViewController`, all of which are event-oriented [VERIFIED: ls]. The app must build every editor itself.
6. **Completing a recurring reminder: EventKit advances the series itself.**
   - Sep–Oct 2026 tests on iCloud found the **same `calendarItemIdentifier` advances in place** to the next due date and stays `isCompleted == false`. iCloud files the finished occurrence as a new reminder with a new identifier.
   - In one edge case (an occurrence in 2099), the whole series was completed instead.
   - Sources: [FORUM/BLOG: https://github.com/PsychQuant/che-ical-mcp/issues/194, https://github.com/Don-Works/reminders-mcp/pull/1].
   - Apple says "only the first incomplete reminder of a recurring set is obtainable … When the reminder is completed, the next reminder in the recurrence set becomes available" [DOCS: https://developer.apple.com/documentation/eventkit/creating-a-recurring-event].
7. **Some writes to iCloud lists are silently ignored.**
   - `EKCalendarItem.location` (plain string) reads back nil after save and refetch [FORUM/BLOG: Don-Works PR #1 (2026-10-13); eventkit-rs docs https://docs.rs/crate/eventkit-rs/latest].
   - `EKCalendarItem.url` does not round-trip with the URL field in Reminders.app: it reads nil for URLs set in the app [FORUM: https://developer.apple.com/forums/thread/739541, thread/128140].
   - Alarm `soundName` and `emailAddress` are reportedly dropped [FORUM: eventkit-rs].
8. **No public API for** tags, subtasks/parent, sections, list groups, flags, smart lists, list emblem/icon, list type (groceries), manual sort order, attachments/images, assignee, urgent, early-alert as a concept, or sharing.
   - Apple DTS (Apr 2026) confirmed there is no subtask API [FORUM: https://developer.apple.com/forums/thread/820848].
   - Private exported symbols hint at internals, for example `_EKDisplayOrderPropertyId` and `_EKChangedShareesAdded` [VERIFIED: `$EK/Versions/A/EventKit.tbd`]. They are not usable.

---

## 1. Header reference (everything relevant to reminders)

### 1.1 `EKEventStore` (`EKEventStore.h`)

| ObjC | Swift | Avail (macOS) | Notes |
|---|---|---|---|
| `+authorizationStatusForEntityType:` | `EKEventStore.authorizationStatus(for: .reminder)` | 10.9 | Class method. |
| `-init` | `EKEventStore()` | 10.9 | Use one long-lived store. Objects from one store must not be used with another, or an exception is raised [VERIFIED]. |
| `-initWithSources:` | `init(sources: [EKSource])` | 10.11 | Store limited to a subset of accounts. Could be used for per-account isolation [VERIFIED]. |
| `-initWithAccessToEntityTypes:` | — | macOS 10.8–10.9 deprecated, macOS-only | Do not use. |
| `-requestFullAccessToRemindersWithCompletion:` | `requestFullAccessToReminders(completion: @Sendable (Bool, Error?) -> Void)` / `requestFullAccessToReminders() async throws -> Bool` | **14.0** | Completion runs on an arbitrary queue [DOCS]. |
| `-requestAccessToEntityType:completion:` | `requestAccess(to:completion:)` | deprecated 14.0 | Legacy. |
| `-requestFullAccessToEvents…` / `-requestWriteOnlyAccessToEvents…` | — | 14.0 | Events only. There is **no write-only option for reminders** [VERIFIED header; DOCS]. |
| `eventStoreIdentifier` (ro String) | same | 10.8 | |
| `sources` (ro `[EKSource]`, unordered) | `sources` | 10.8 | |
| `delegateSources` (ro) | same | 10.11 | Exchange delegates. Mostly event-related. |
| `-sourceWithIdentifier:` → nullable | `source(withIdentifier:)` | 10.8 | |
| `calendars` property | **unavailable on macOS** (iOS 4–6 only) | — | Use `calendars(for:)`. |
| `-calendarsForEntityType:` | `calendars(for: .reminder) -> [EKCalendar]` | 10.8 | Unordered [VERIFIED]. **There is no list order API.** |
| `-defaultCalendarForNewReminders` → nullable | `defaultCalendarForNewReminders() -> EKCalendar?` | 10.8 | May be nil [VERIFIED]. Read-only: it cannot be set via EventKit. |
| `-calendarWithIdentifier:` | `calendar(withIdentifier:)` | 10.8 | |
| `-saveCalendar:commit:error:` | `saveCalendar(_:commit:) throws` | 10.8 | Raises an exception for a foreign-store object. |
| `-removeCalendar:commit:error:` | `removeCalendar(_:commit:) throws` | 10.8 | Deletes the list and **all its reminders**. On a mixed-entity calendar it removes only the entity types you have access to [VERIFIED]. |
| `-calendarItemWithIdentifier:` → nullable | `calendarItem(withIdentifier:) -> EKCalendarItem?` | 10.8 | Cast to `EKReminder`. |
| `-calendarItemsWithExternalIdentifier:` | `calendarItems(withExternalIdentifier:) -> [EKCalendarItem]` | 10.8 | Can return more than one item [VERIFIED]. |
| `-saveReminder:commit:error:` | `save(_ reminder: EKReminder, commit: Bool) throws` | 10.8 | The object is refreshed to the DB values after save [VERIFIED]. |
| `-removeReminder:commit:error:` | `remove(_ reminder: EKReminder, commit: Bool) throws` | 10.8 | No `EKSpan` for reminders. |
| `-fetchRemindersMatchingPredicate:completion:` → `id` | `fetchReminders(matching:completion: @escaping ([EKReminder]?) -> Void) -> Any` | 10.8 | Async. Result can be nil. Only committed reminders are returned [DOCS]. |
| `-cancelFetchRequest:` | `cancelFetchRequest(_:)` | 10.8 | After cancel, the completion is **never** called [VERIFIED]. Continuation wrappers must resume on cancel themselves. |
| `-predicateForRemindersInCalendars:` | `predicateForReminders(in: [EKCalendar]?)` | 10.8 | nil means all calendars. Returns completed **and** incomplete reminders. |
| `-predicateForIncompleteRemindersWithDueDateStarting:ending:calendars:` | `predicateForIncompleteReminders(withDueDateStarting: Date?, ending: Date?, calendars:)` | 10.8 | nil start means everything due before end. nil/nil means **all incomplete**. Whether undated reminders are included when bounds are set is not documented (INFERENCE: probably excluded). |
| `-predicateForCompletedRemindersWithCompletionDateStarting:ending:calendars:` | `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)` | 10.8 | Same nil semantics. |
| `-commit:` | `commit() throws` | 10.8 | Returns YES even if nothing was committed. |
| `-reset` | `reset()` | 10.8 | Invalidates **all** fetched or created objects [VERIFIED]. |
| `-refreshSourcesIfNecessary` | same | 10.8 | Asks for a remote sync "if deemed necessary". Call `refresh()` on held objects afterwards [VERIFIED]. |
| `EKEventStoreChangedNotification` | `Notification.Name.EKEventStoreChanged`; macOS 26+: `EKEventStore.EventStoreChanged` / `.changed` (MainActorMessage) | 10.8 / 26 | No public userInfo keys. Also posted when access changes [VERIFIED]. |
| `EKSpan`, `saveEvent…`, `eventsMatchingPredicate`, `predicateForEvents…`, `eventWithIdentifier` | — | — | **Event-only.** |

The SDK `.tbd` also exports private symbols: `EKEventStoreChangedObjectIDsUserInfoKey`, `EKEventStoreChangeTypeUserInfoKey`, `EKEventStoreRemindersDataChangedUserInfoKey`, `EKEventStoreCalendarDataChangedUserInfoKey`, `EKReminderModifiedNotification`, `EKEventStoreIdleChangeTrackingClientWasPurgedNotification` and `EKReminderURLScheme`/`Host`. None appear in a public header [VERIFIED: `$EK/Versions/A/EventKit.tbd`]. Do not rely on them; at most, read userInfo opportunistically as a hint [FORUM: https://forums.raywenderlich.com/t/userinfo-in-ekeventstorechanged-notification/31511].

### 1.2 `EKObject` (`EKObject.h`)

| Member | Swift | Notes |
|---|---|---|
| `hasChanges` (ro BOOL) | `hasChanges` | Dirty check. |
| `new` / `isNew` (ro) | `isNew` | Not yet saved. |
| `-reset` | `reset()` | Undocumented semantics. INFERENCE: reloads from the DB and drops edits. |
| `-rollback` | `rollback()` | Discards unsaved changes. |
| `-refresh` → BOOL | `refresh() -> Bool` | After a change notification: if NO, the object was deleted or invalidated and must be refetched [VERIFIED comment in `EKEventStore.h`]. |

### 1.3 `EKCalendarItem` (`EKCalendarItem.h`), the superclass of `EKReminder`

| Property / method | Type, access, nullability | Reminder relevance |
|---|---|---|
| `calendar` | `EKCalendar!` rw (null_unspecified) | **The list.** Set it to move a reminder between lists. Required before save. |
| `calendarItemIdentifier` | `String` ro | Local DB id. "Not sync-proof… a full sync will lose this identifier" [VERIFIED]. |
| `calendarItemExternalIdentifier` | `String!` ro | Server id that works across devices. Duplicates possible. Nil before a calendar is set. **For Exchange reminders it differs between devices and between iOS and macOS** [VERIFIED]. |
| `title` | `String!` rw | Empty string for new items. Required. |
| `location` | `String?` rw | Inherited. Can fail with `EKErrorReminderLocationsNotSupported`. **Reportedly dropped by iCloud** [FORUM]. Do not use. |
| `notes` | `String?` rw | Plain text only. No attributed or rich-text API [VERIFIED type]. |
| `URL` | `URL?` rw (Swift `url`) | Does not map to the Reminders.app URL field [FORUM]. Treat as write-only metadata that may not survive or display. |
| `lastModifiedDate` | `Date?` ro | |
| `creationDate` | `Date?` ro | Cannot be backdated. |
| `timeZone` | `TimeZone?` rw | For reminders, independent of `dueDateComponents.timeZone` [DOCS]. |
| `hasAlarms`, `hasRecurrenceRules`, `hasNotes` | ro Bool | Cheap checks. Only `hasRecurrenceRules` has a fast path today [VERIFIED comment]. |
| `hasAttendees` / `attendees` | ro `[EKParticipant]?` | Event concept. Read-only. Not "assigned to" in Reminders [INFERENCE]. |
| `alarms` | `[EKAlarm]?` rw (copy) | "Some calendars can only allow a certain maximum number of alarms… will truncate" [VERIFIED]. |
| `addAlarm(_:)` / `removeAlarm(_:)` | | |
| `recurrenceRules` | `[EKRecurrenceRule]?` rw | Use at most one (INFERENCE: Reminders.app models a single rule). |
| `addRecurrenceRule(_:)` / `removeRecurrenceRule(_:)` | | |
| `UUID` | iOS-only, deprecated | Unavailable on macOS. |

### 1.4 `EKReminder` (`EKReminder.h`)

| Member | Swift | Semantics [VERIFIED header unless tagged] |
|---|---|---|
| `+reminderWithEventStore:` | `EKReminder(eventStore:)` | |
| `startDateComponents` | `DateComponents?` rw | nil `timeZone` means floating. No hour/minute/second means all-day. A non-Gregorian `.calendar` raises an exception. **Reminders.app UI ignores it** [FORUM: https://developer.apple.com/forums/thread/809699, Dec 2025]. |
| `dueDateComponents` | `DateComponents?` rw | Same rules. **On macOS, unlike iOS, a due date does not require a start date** [VERIFIED; DOCS]. By default the due date uses the system time zone [DOCS]. In Reminders.app this one field is the displayed date, the "Today" membership, the overdue state and the default notification time [FORUM thread/809699]. |
| `completed` / `isCompleted` | `Bool` rw | Setting YES sets `completionDate = now`. Setting NO clears it. `isCompleted == true` with a nil `completionDate` is possible when another client completed it. |
| `completionDate` | `Date?` rw | Setting any date sets completed=YES, so backdating is possible. Setting nil sets completed=NO. |
| `priority` | `NSUInteger` → Swift `Int` rw | 0 = none, 1–9 (1 highest). Any other value: save fails with `EKErrorPriorityIsInvalid`. |

There are **no other reminder properties** (flagged, tags, parent, section, order, images, assignee, urgent).

### 1.5 `EKCalendar`, a reminder list (`EKCalendar.h`)

| Member | Type, access | Notes |
|---|---|---|
| `+calendarForEntityType:eventStore:` | `EKCalendar(for: .reminder, eventStore:)` | The API can create only single-entity calendars [VERIFIED]. |
| `+calendarWithEventStore:` | iOS-only, deprecated | |
| `source` | `EKSource!` rw at creation only | "You cannot move it to another source" (`EKErrorCalendarSourceCannotBeModified`). So lists can't move between accounts; recreate instead. |
| `calendarIdentifier` | `String` ro | Not sync-proof [VERIFIED]. There is no public external id for calendars. |
| `title` | `String` rw | Rename. |
| `type` | `EKCalendarType` ro | |
| `allowsContentModifications` | Bool ro | Can items be added, removed or modified. |
| `isSubscribed` | Bool ro | Event-centric. |
| `isImmutable` | Bool ro | YES means you cannot rename, recolor or delete the list. It does **not** prevent adding items. |
| `cgColor` | `CGColor!` rw | macOS 10.15+. |
| `color` | `NSColor!` rw | **macOS-only** (`#if TARGET_OS_OSX`), 10.8+. |
| `supportedEventAvailabilities` | ro | Event-only. |
| `allowedEntityTypes` | `EKEntityMask` ro | Check for `.reminder`. |

There is no API for emblem/icon, list group, list type, sort style, "show completed", pin or sharing. The AppleScript `list.emblem` property is rw (established fact), but that is not EventKit.

### 1.6 `EKSource` (`EKSource.h`), an account

| Member | Notes |
|---|---|
| `sourceIdentifier` (ro) | |
| `sourceType` (ro `EKSourceType`) | |
| `title` (ro) | iCloud appears as `.calDAV` titled "iCloud" [FORUM: https://developer.apple.com/forums/thread/81097]. |
| `calendarsForEntityType:` → `Set<EKCalendar>` | `calendars(for: .reminder)`. A non-empty set is the only public signal that a source supports reminders [INFERENCE]. |
| `isDelegate` (ro) | macOS 13+. |
| `calendars` | iOS-only, deprecated. |

There is no API to create, rename or delete sources (accounts). Accounts are managed in System Settings > Internet Accounts.

### 1.7 `EKAlarm` (`EKAlarm.h`)

| Member | Avail | Notes |
|---|---|---|
| `alarmWithAbsoluteDate:` / `alarmWithRelativeOffset:` | 10.8 | `EKAlarm(absoluteDate:)`, `EKAlarm(relativeOffset:)`. |
| `relativeOffset` (rw TimeInterval) | | Setting it clears the absolute date. The header says it is relative to an event's **start**. For reminders it is effectively relative to the due date; relative alarms without a due date never fire [FORUM: Don-Works PR #1; INFERENCE]. |
| `absoluteDate` (rw Date?) | | Setting it clears the relative offset. This is the "remind me at" time. |
| `structuredLocation` (rw `EKStructuredLocation?`) + `proximity` (rw `EKAlarmProximity`) | | Geofence "arriving/leaving". Can fail with `EKErrorStructuredLocationsNotSupported` or `EKErrorAlarmProximityNotSupported` on some sources. |
| `type` (ro `EKAlarmType`) | **macOS-only** (NA on iOS) | |
| `emailAddress`, `soundName` (rw) | **macOS-only** | Very likely rejected on reminders (`EKErrorReminderAlarmContainsEmailOrUrl`) or dropped on iCloud [INFERENCE + FORUM]. Do not expose. |
| `url` | deprecated 10.9 | Procedure alarms cannot be created or modified (`EKErrorProcedureAlarmsNotMutable`). |

### 1.8 `EKStructuredLocation` (`EKStructuredLocation.h`)

- `+locationWithTitle:` → `EKStructuredLocation(title:)`
- `+locationWithMapItem:` → `EKStructuredLocation(mapItem:)` (macOS 10.11, MapKit)
- `title` (`String?`)
- `geoLocation` (`CLLocation?`)
- `radius` (Double; 0 means the system default; meters)

### 1.9 Recurrence (`EKRecurrenceRule.h`, `EKRecurrenceDayOfWeek.h`, `EKRecurrenceEnd.h`)

- **Rule initializers:**
  - `EKRecurrenceRule(recurrenceWith:interval:end:)`. Interval 0 raises an exception.
  - The designated initializer `(recurrenceWith:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:)`.
- **Rule properties:**
  - Read-only: `calendarIdentifier` (calendar system), `frequency`, `interval`, `firstDayOfTheWeek` (cannot be set), `daysOfTheWeek`, `daysOfTheMonth` (±1–31, monthly), `daysOfTheYear` (±1–366, yearly), `weeksOfTheYear` (±1–53, yearly), `monthsOfTheYear` (1–12, yearly), `setPositions` (±1–366).
  - **Read-write:** `recurrenceEnd`.
  - Otherwise immutable. To edit, replace the rule. Parameters that don't make sense for a frequency are silently ignored [VERIFIED].
- **`EKRecurrenceDayOfWeek`:**
  - Constructors: `EKRecurrenceDayOfWeek(_:)`, `(_:weekNumber:)`, `init(dayOfTheWeek:weekNumber:)`.
  - Week number ±1–53; 0 means every week. It **must be 0 for weekly rules**, otherwise an exception is raised.
  - Conforms to NSCopying and NSSecureCoding.
- **`EKRecurrenceEnd`:**
  - `EKRecurrenceEnd(end: Date)` or `EKRecurrenceEnd(occurrenceCount:)`. A count of 0 or a nil date raises an exception.
  - Properties: `endDate`, `occurrenceCount`.
- **Constraint:** a recurring reminder requires a due date (`EKErrorRecurringReminderRequiresDueDate`) [VERIFIED].

### 1.10 Enums and option sets (`EKTypes.h`)

| Enum | Values (raw) |
|---|---|
| `EKAuthorizationStatus` | notDetermined 0, restricted 1, denied 2, **fullAccess 3** (10.14→macOS 14), writeOnly 4 (events only), authorized = 3 (deprecated alias) |
| `EKEntityType` | event 0, reminder 1 |
| `EKEntityMask` | event 1, reminder 2 |
| `EKSourceType` | local 0, exchange 1, calDAV 2, mobileMe 3, subscribed 4, birthdays 5 |
| `EKCalendarType` | local 0, calDAV 1, exchange 2, subscription 3, birthday 4 |
| `EKAlarmProximity` | none 0, enter 1, leave 2 |
| `EKAlarmType` | display 0, audio 1, procedure 2, email 3 |
| `EKReminderPriority` (UInt) | none 0, high 1, medium 5, low 9 |
| `EKRecurrenceFrequency` | daily 0, weekly 1, monthly 2, yearly 3. An out-of-range raw value stores as DAILY [FORUM: Don-Works PR #1]. |
| `EKWeekday` | sunday 1 … saturday 7. **`NSClosedEnum`** (frozen, exhaustive switch OK) [VERIFIED apinotes]. |
| `EKSpan`, `EKParticipant*`, `EKCalendarEventAvailabilityMask` | Event-only. |

### 1.11 Errors (`EKError.h`). Swift: `EKError` with `EKError.Code` (apinotes `NSErrorDomain: EKErrorDomain`)

Raw values follow declaration order. Reminder-relevant codes are in **bold**.

| # | Code | Meaning |
|---|---|---|
| 0 | eventNotMutable | Item not mutable. |
| 1 | **noCalendar** | No calendar set. |
| 2 | noStartDate | iOS: due date without a start date. Not raised on macOS. |
| 3–4 | noEndDate, datesInverted | Event. |
| 5 | **internalFailure** | |
| 6 | **calendarReadOnly** | Calendar can't take items. |
| 7–8 | durationGreaterThanRecurrence, **alarmGreaterThanRecurrence** | |
| 9–10 | startDateTooFarInFuture, startDateCollidesWithOtherOccurrence | |
| 11 | **objectBelongsToDifferentStore** | |
| 12–13 | invitesCannotBeMoved, invalidSpan | Event. |
| 14 | **calendarHasNoSource** | New list without a source. |
| 15 | **calendarSourceCannotBeModified** | Moving a list to another account. |
| 16 | **calendarIsImmutable** | |
| 17 | **sourceDoesNotAllowCalendarAddDelete** | |
| 18 | **recurringReminderRequiresDueDate** | |
| 19 | **structuredLocationsNotSupported** | |
| 20 | **reminderLocationsNotSupported** | |
| 21 | **alarmProximityNotSupported** | |
| 22 | calendarDoesNotAllowEvents | |
| 23 | **calendarDoesNotAllowReminders** | |
| 24 | **sourceDoesNotAllowReminders** | |
| 25 | sourceDoesNotAllowEvents | |
| 26 | **priorityIsInvalid** | Must be 0–9. |
| 27 | invalidEntityType | |
| 28 | **procedureAlarmsNotMutable** | |
| 29 | **eventStoreNotAuthorized** | |
| 30 | osNotSupported | |
| 31 | invalidInviteReplyCalendar | Undocumented constant. |
| 32–35 | notificationsCollectionFlagNotSet, sourceMismatch, notificationCollectionMismatch, notificationSavedWithoutCollection | Internal or event-related. |
| 36 | **reminderAlarmContainsEmailOrUrl** | Undocumented. INFERENCE: email or URL alarm on a reminder. |
| 37 | last | Internal. |

### 1.12 `EventKit.apinotes` and `EventKitDefines.h`

- `SwiftVersions: 3` nullability overrides (for `calendar`, `title`, `source`, `color`, `defaultCalendarForNewReminders`, …) apply **only in Swift 3 mode**. In Swift 5/6 the header nullability applies: `calendar: EKCalendar!`, `title: String!`, `source: EKSource!`, `cgColor: CGColor!`, `defaultCalendarForNewReminders() -> EKCalendar?` [VERIFIED apinotes structure; mapping is INFERENCE].
- `EventKitDefines.h`: the `DATE_COMPONENTS`, `DATETIME_COMPONENTS` and `EK_LOSE_FRACTIONAL_SECONDS` macros are deprecated since 10.10 (macOS-only). Do not use them.

### 1.13 Event-only APIs that do NOT apply to reminders

- `EKEvent.h` and `EKVirtualConference*`.
- `EKSpan`.
- Attendees and participants (read-only in any case).
- Availability masks.
- `isSubscribed` and the subscription/birthday calendar types.
- Write-only access.
- `predicateForEvents` and its 4-year cap.
- `EKCalendarItem.location`, which exists on the superclass but is unsupported or dropped for reminders on iCloud.

---

## 2. Semantics and pitfalls by topic

### 2.1 Authorization (macOS 14+)

- **The only call** is `try await store.requestFullAccessToReminders()`. Statuses: `.notDetermined`, `.restricted`, `.denied`, `.fullAccess`. `.writeOnly` does not apply: "can't request read-only… write-only access to events" only [DOCS: https://developer.apple.com/documentation/eventkit/accessing-the-event-store].
- The prompt appears only once. After a denial, send the user to System Settings > Privacy & Security > Reminders [DOCS]. The deep-link URL for macOS 27 has not been verified.
- **If reminders were fetched before access was granted,** call `store.reset()` to receive data [DOCS: requestFullAccessToReminders page]. The store also posts `EKEventStoreChanged` when access changes [VERIFIED header].
- **Info.plist:**
  - Required: `NSRemindersFullAccessUsageDescription`.
  - Fallback on 14+: `NSRemindersUsageDescription`. Include it only if deploying below macOS 14.
  - Both exist as `INFOPLIST_KEY_*` build settings [VERIFIED CoreBuildSystem.xcspec; DOCS TN3153 https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos].
  - On iOS 17, a missing key means automatic denial. Missing-key behavior on macOS is not documented (INFERENCE: denial or crash). Always include the key.
- **Entitlements:**
  - Sandboxed app: `com.apple.security.app-sandbox` + `com.apple.security.personal-information.calendars`.
  - Developer ID with hardened runtime: the same `calendars` key, set via Xcode Hardened Runtime > Resource Access > Calendars (`ENABLE_RESOURCE_ACCESS_CALENDARS`).
  - Sources: [DOCS: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars, https://developer.apple.com/documentation/security/hardened-runtime].
  - App Review may question "Calendars" for a reminders app; explain it in the review notes [FORUM thread/745752].
- Dev tip: `tccutil reset Reminders <bundle-id>` resets the prompt during development (not executed here).

### 2.2 Store lifetime, threading, Swift 6

- Create **one** `EKEventStore` and keep it alive. It is expensive to create [FORUM: O'Reilly *Programming iOS*]. "Releasing an event store instance before other EventKit objects may result in an error" [DOCS].
- Nothing is `Sendable`, so confine the store and all `EK*` objects to one isolation domain. Options:
  - A dedicated `actor`, or a global actor whose executor is a serial queue.
  - `@MainActor`, if fetches stay async.
  - Convert to value-type DTOs (struct snapshots) at the boundary [INFERENCE].
- `fetchReminders` completion:
  - It runs on a background/private queue. Apple's sample re-dispatches to main [FORUM/DOCS sample: https://developer.apple.com/library/archive/samplecode/EKReminderSuite/Listings/Shared_Code_EKRSReminderStore_m.html]. This is INFERENCE; the docs say only "asynchronously".
  - **Swift 6 risk:** the closure parameter is not `@Sendable`. A closure written inside a `@MainActor` context is inferred MainActor-isolated, and Swift 6's dynamic isolation checks can **crash** when EventKit calls it off-main [INFERENCE; known pattern for non-annotated ObjC callbacks].
  - Mitigation: call it from a `nonisolated` function, mark the closure `@Sendable`, wrap it in `withCheckedContinuation`, and carry the results out as a DTO. Note: `[EKReminder]` is not Sendable, so map the objects inside the actor that owns the store.
- `save`, `remove` and `commit` are synchronous and do IPC to the calendar daemon. Keep them off the main thread for bulk work [INFERENCE; the sample saves synchronously].
- macOS 26+: `NotificationCenter.default.addObserver(of: store, for: .changed)` delivers on the MainActor. The `MainActorMessage` conformance implies EventKit posts on main [VERIFIED type; INFERENCE on the posting thread]. On older systems, use `.EKEventStoreChanged` with `queue: .main`.

### 2.3 Fetching and performance

- Predicates must come from the store's factory methods. Other NSPredicates raise an exception (stated for events; INFERENCE for reminders). There is no server-side filtering by title, priority or notes. **Filter in memory.**
- `predicateForReminders(in: nil)` loads every completed reminder too. Large iCloud histories mean slow fetches [INFERENCE]. Strategy:
  - incomplete with nil/nil bounds for the main views;
  - completed with a bounded `completionDate` window (for example the last 30 days, extendable when the user scrolls the "Completed" view).
- Results are unordered. Sort client-side (due date, priority, creation date). Reminders.app's manual order is not exposed (private `EKDisplayOrderPropertyId` [VERIFIED tbd]).
- Subtasks: EventKit has no parent API [FORUM DTS thread/820848]. Subtasks very likely appear as ordinary top-level reminders in the same list [UNVERIFIED/INFERENCE; FORUM: BusyCal https://www.busymac.com/docs/busycalios/114474-using-busycal-with-reminders].

### 2.4 Identifiers

- **Reminder:** use `calendarItemIdentifier` as the primary key within this Mac's DB. It can be lost on a full resync [VERIFIED]. Store `calendarItemExternalIdentifier` as a secondary key for re-resolving, and keep a fallback fingerprint (title + list + due date + creation date).
- **Exchange:** the external id differs per device [VERIFIED].
- **Moving between lists:** event ids "most likely change" when the calendar changes [DOCS EKEvent.eventIdentifier]. Expect the same for reminders, especially across sources [UNVERIFIED].
- **List:** use `calendarIdentifier`, which is not sync-proof. Fall back to title + source + color.
- **Recurring completion:** the original id advances in place, and the completed occurrence gets a new id (iCloud) [FORUM 2026].

### 2.5 Change tracking

- `EKEventStoreChanged` is coarse ("something changed"). It is posted for own saves, external changes and access changes. There is no public diff and no "changes since last launch" [VERIFIED header; FORUM: https://developer.apple.com/forums/thread/817054 (Feb 2026, DTS gave no roadmap)].
- Pattern:
  1. Debounce (~250–500 ms).
  2. Refetch the active scopes.
  3. Diff by `calendarItemIdentifier` + `lastModifiedDate` against your snapshot.
  4. For an object being edited, call `refresh()`; if it returns false, the object was deleted, so close the editor.
- The Apple article mistakenly says to call `refreshSourcesIfNecessary()` "on the event" [DOCS: https://developer.apple.com/documentation/eventkit/updating-with-notifications]. The correct call is `EKObject.refresh()`.

### 2.6 Batching

- `save(_:commit: false)` ×N, then `commit()`. Uncommitted items are invisible to `fetchReminders` [DOCS].
- On failure, call `store.reset()` (drops everything) or `rollback()` on individual objects, then refetch.
- Atomicity of `commit()` across many items is not documented [UNVERIFIED].

### 2.7 Lists (calendars) and accounts

- **Create:**
  1. `let c = EKCalendar(for: .reminder, eventStore: s)`; set `title`, `source`, and `color`/`cgColor`.
  2. `try s.saveCalendar(c, commit: true)`.
  3. Choose the source: `s.defaultCalendarForNewReminders()?.source`, otherwise a source whose `calendars(for: .reminder)` is non-empty. Prefer `.calDAV` with title "iCloud" [FORUM thread/81097].
  4. Expect `sourceDoesNotAllowReminders` or `sourceDoesNotAllowCalendarAddDelete` on some account types.
- **Rename/recolor:** mutate `title` and `color`, then `saveCalendar`. Check `isImmutable` first.
  - Whether Reminders.app snaps arbitrary colors to its palette is unverified.
  - The icon/emblem is not settable via EventKit.
- **Delete:** `removeCalendar(_:commit:)` deletes all of its reminders. Show a destructive confirmation.
  - What happens when the user deletes the default list (does the default change, or is it blocked) is unverified.
- **Move a list to another account:** impossible (`calendarSourceCannotBeModified`). Emulate by creating the list in the target account, moving the reminders, then deleting the source list.
- **Default list:** readable only. It cannot be set via EventKit.
- **Accounts:** read-only enumeration. Reminders supports iCloud, Exchange, Google, Yahoo, AOL and On My Mac, but "some features… aren't available when using accounts other than iCloud" [DOCS: https://support.apple.com/guide/reminders/remnd5faf3ad/mac]. Whether a "Local/On My Mac" reminders source exists on macOS 27 is unverified.
- **Shared iCloud lists:** they appear as ordinary calendars. There is no public sharing or sharee API (private `EKChangedSharees*` [VERIFIED tbd]). `allowsContentModifications` for participants is unverified.

### 2.8 Dates

- **Always build components with `Calendar(identifier: .gregorian)`.** Setting a non-Gregorian `.calendar` raises an exception [VERIFIED]. Using `Calendar.current` components from a non-Gregorian user calendar (Japanese, Buddhist) yields wrong year values [INFERENCE].
- **All-day / date-only:** `[.year, .month, .day]` with no time sets all-day; usually floating (no timeZone).
- **Date + time:** include `.hour` and `.minute`, and set `.timeZone` to the current zone, or leave it nil for floating.
- When reading, components may have a nil `.calendar`/`.timeZone`. Resolve with the Gregorian calendar and the current zone when floating.
- `startDateComponents` is ignored by Reminders.app [FORUM]. It can carry a "start/defer date" for this app's own features (TickTick-like start dates), but Reminders won't honor it.

### 2.9 Due date vs alarms vs notifications

- Notifications for reminders come from Reminders.app (system), not from our app [DOCS: https://developer.apple.com/documentation/eventkit/setting-an-alarm].
- A timed due date may act as the notification time in Reminders.app [FORUM thread/809699]. However, the established CLI (keith/reminders-cli) **explicitly adds `EKAlarm(absoluteDate: due)` whenever a time is present**, and none for date-only reminders [FORUM/BLOG: https://github.com/keith/reminders-cli/blob/main/Sources/RemindersLibrary/Reminders.swift]. Recommended: mirror that, and test whether Reminders-created timed reminders expose an alarm (see open questions).
- "Remind me at X but due on Y": set `dueDateComponents` = Y and add an absolute alarm at X. No API marks an alarm as Reminders' "Early Reminder" [INFERENCE]. The AppleScript `remind me date` is separate from `due date` (established fact).
- **Location reminders:**
  - Use `EKAlarm` with `structuredLocation` (title + `CLLocation` + radius) and `proximity` `.enter`/`.leave`. Use relative offset 0 or no time [FORUM: tessl eventkit-patterns].
  - Getting the user's current location for picking requires CoreLocation permission in our app (`NSLocationWhenInUseUsageDescription` plus the `personal-information.location` entitlement if sandboxed). Geofence firing is done by the system [INFERENCE].
- Reminders may effectively support a single date alarm [FORUM: BusyCal "Multiple alarms are not supported"]. Truncation is possible [VERIFIED header].

### 2.10 Recurrence

- Requires a due date (error 18). Use one rule.
- A Reminders "Weekdays" repeat is weekly + Mon–Fri.
- "End repeat" can be by date or count; whether Reminders.app's UI exposes count is unverified.
- **Completing:** set `isCompleted = true` and save. EventKit advances the same id to the next due date; the completed copy gets a new id (iCloud) [FORUM 2026]. Afterwards, re-read the object (incomplete, new due date) and don't treat "still incomplete" as a failure.
- **Deleting:** `remove(_:commit:)` has no span. INFERENCE: it removes the series. "Delete only this occurrence" is impossible; emulate by completing it, or by advancing the due date to the next occurrence via the rule.
- **"Repeat after completion"** (TickTick/Todoist "every! 3 days") is not native. On completion the app must create the next reminder itself [INFERENCE].
- `firstDayOfTheWeek` cannot be set.

### 2.11 Priority

- Reminders.app writes High=1, Medium=5, Low=9, None=0 [FORUM: https://support.hogbaysoftware.com/t/why-do-reminders-with-priorities-get-imported-with-the-values-1-5-9-equating-h-m-l/4447; ekctl].
- Display ranges: 1–4 High, 5 Medium, 6–9 Low [VERIFIED RFC note in header; FORUM: go-eventkit https://pkg.go.dev/github.com/BRO3886/go-eventkit/reminders].
- Read with ranges; write canonical 1/5/9.

### 2.12 Features that can't be replicated via public API

- Tags, subtasks, sections, list groups and flags.
- Smart lists (Today, Scheduled and All can be computed from dates; Flagged and Assigned cannot).
- Images/attachments, Reminders.app URL field, assignee, urgent, grocery auto-categorize, list icon, manual order, "show completed" per list, pinning.
- "Show in Reminders" (an AppleScript `show` exists; there is a private URL scheme `EKReminderURLScheme`).

Alternatives:
- Private `ReminderKit` (used by go-eventkit for `flagged`) is App-Store-incompatible and fragile.
- AppleScript (`flagged` rw, `emblem` rw) or Shortcuts/App Intents (established facts) are possible side channels with their own permission prompts and limits.
- macOS 27 adds a public **AppIntents App Schema domain `.reminders`**: intents createList / createReminder / createSection / deleteReminders / updateReminder; entities group / list / reminder / section / locationTrigger; enums listType / locationTriggerEvent; `@available(anyAppleOS 27.0)`, watchOS/tvOS unavailable [VERIFIED: `MacOSX.sdk/System/Library/Frameworks/AppIntents.framework/Modules/AppIntents.swiftmodule/arm64e-apple-macos.swiftinterface` ~L11718–11840]. It lets **our** app expose its reminder actions to Siri and Apple Intelligence. It does **not** give access to Reminders data [INFERENCE].

---

## 3. (a) Capability checklist (public EventKit, macOS 14+)

**Accounts (EKSource)**
- [x] Enumerate accounts: `sources`, `sourceType`, `title`, `isDelegate`.
- [x] Detect whether an account supports reminders (heuristic: `calendars(for: .reminder)` non-empty).
- [x] Restrict a store to chosen accounts: `init(sources:)`.
- [x] Trigger a sync: `refreshSourcesIfNecessary()`.
- [ ] Add, remove or rename accounts; read capabilities (no API).

**Lists (EKCalendar, `.reminder`)**
- [x] List all lists (unordered) and the default list (read-only).
- [x] Look up a list by id.
- [x] Create a list in a chosen account (title + color).
- [x] Rename, recolor.
- [x] Delete (cascades to its reminders).
- [x] Read flags: `allowsContentModifications`, `isImmutable`, `type`, `allowedEntityTypes`.
- [ ] Move a list across accounts (recreate instead).
- [ ] Set the default list.
- [ ] Icon/emblem, groups, sections, list type, order, sharing, pin, "show completed".

**Reminders (EKReminder)**
- [x] Create, with: title, notes (plain), list, due date (date-only/floating or timed with time zone), start date (UI-ignored), priority 0–9, completed / completion date (including backdating), url (may not display).
- [x] Read: creation date, modification date.
- [x] Edit any of the writable fields above; reschedule (change or clear due date and alarms).
- [x] Move to another list in the same account (set `calendar`).
- [x] Move across accounts (set `calendar`; id may change) [UNVERIFIED that it succeeds on all source pairs].
- [x] Complete / uncomplete (recurring: auto-advance).
- [x] Delete (a recurring reminder deletes the series).
- [x] Batch: `commit:false` + `commit()`; undo via `rollback()`/`reset()` before commit. App-level undo must re-apply inverse operations [INFERENCE].
- [x] Fetch: all; incomplete (optionally a due window); completed (completion window); by list; by id or external id; cancel a fetch.
- [x] Observe changes (coarse) and revalidate (`refresh()`).
- [ ] Tags, subtasks/parent, flags, sections, images, URL field as shown in Reminders.app, assignee, urgent, manual order, smart lists.
- [ ] Plain `location` on iCloud (dropped).

**Alarms**
- [x] Absolute-time alarm.
- [x] Relative-to-due alarm.
- [x] Location alarm (arrive/leave, radius).
- [x] Remove alarms.
- [ ] Sound, email or URL alarms on reminders (rejected or dropped).
- [ ] Mark an alarm as Reminders' "Early Reminder" (no semantic flag).

**Recurrence**
- [x] Daily / weekly / monthly / yearly with any interval; BYDAY (including nth weekday), BYMONTHDAY, BYMONTH, BYWEEKNO, BYYEARDAY, BYSETPOS.
- [x] End by date or by count.
- [x] Replace or remove the rule.
- [ ] Without a due date (error 18).
- [ ] Per-occurrence edit or delete.
- [ ] Repeat after completion (app logic).
- [ ] Set `firstDayOfTheWeek`.

---

## 4. (b) Known pitfalls and mitigations

| # | Pitfall | Mitigation |
|---|---|---|
| 1 | Sandbox without the Calendars entitlement: silent `false`, no prompt. | Add `personal-information.calendars` for both sandbox and hardened runtime. Explain it to App Review. |
| 2 | Missing `NSRemindersFullAccessUsageDescription`. | Always include it. Add the legacy key only if deploying below macOS 14. |
| 3 | Store fetched before access was granted returns empty. | After a grant, call `reset()` (or recreate the store once), then refetch. |
| 4 | Non-Sendable EK types under Swift 6; `fetchReminders` closure not `@Sendable`, so possible isolation crash. | Use a single actor or serial executor that owns the store. Call it from a nonisolated context or mark the closure `@Sendable`. Map to Sendable structs immediately. |
| 5 | `cancelFetchRequest` means the completion is never called. | The continuation wrapper must resume (throwing `CancellationError`) when it cancels. |
| 6 | Change notification is coarse, duplicated and posted for own writes. | Debounce, refetch scoped data, diff by id + `lastModifiedDate`. Suppress echoes of own saves with a short-lived "pending writes" set. |
| 7 | Identifiers not sync-proof; may change on a move or full resync. | Primary key `calendarItemIdentifier`, secondary key external id, plus a fingerprint fallback. After each refetch, rebuild app-side metadata maps keyed by id. |
| 8 | Recurring completion keeps the same id but it is incomplete with a new due date; the completed copy has a new id. | After save, re-read the object. In the UI, animate "completed → next occurrence". Don't show an error. |
| 9 | Recurrence without a due date fails (error 18). | Validate in the editor; default the due date to today when the user adds a repeat. |
| 10 | Non-Gregorian `DateComponents.calendar` raises an exception; `Calendar.current` values can be wrong. | Always use `Calendar(identifier: .gregorian)` and strip `.calendar` before assigning. |
| 11 | All-day vs timed is controlled only by whether hour/minute exist. | One helper builds components; never put `hour = 0` on a date-only reminder. |
| 12 | A timed due date alone may or may not notify. | Add an absolute alarm at due time for timed reminders. Remove or adjust it when rescheduling. Verify on macOS 27. |
| 13 | Relative alarm without a due date never fires. | Only allow relative alarms when a due date exists; otherwise convert to absolute. |
| 14 | `location`, `url`, alarm sound/email dropped or invisible on iCloud. | Don't expose plain location (use location alarms). Treat `url` as best-effort, or store links in `notes`. Hide sound/email alarm options. |
| 15 | Priority values other than 1/5/9 written by other clients. | Read by range (1–4 High, 5 Medium, 6–9 Low); write 1/5/9; validate 0–9. |
| 16 | No ordering API; `calendars(for:)` is unordered. | App-side sort modes. Any manual order must live in app storage keyed by id (it won't sync to Reminders.app). |
| 17 | Subtasks appear as flat, unrelated reminders (likely); deleting or completing a parent elsewhere affects children invisibly. | Document the limitation in the UI. Never fake hierarchy in EventKit itself. App-side hierarchy is possible but local-only. |
| 18 | `removeCalendar` cascades. | Destructive confirmation showing the item count. Optionally offer "move reminders first". |
| 19 | A list's source is immutable. | Cross-account "move list" means create the list, move its reminders, delete the old list, and warn the user that ids change. |
| 20 | `isImmutable`, `allowsContentModifications` and source capabilities vary (Exchange/Google/Yahoo). | Gate the UI per list and source; handle error codes 6, 16, 17, 19–24 with clear messages. |
| 21 | Batch `commit:false` items invisible to fetches; partial failure. | Commit before refetching; on error call `reset()` and refetch. Keep batches small. |
| 22 | Large completed history is slow to fetch. | Fetch incomplete reminders plus a bounded completed window; lazily extend the window. |
| 23 | Edited object deleted externally. | On notification call `refresh()`; if false, close the editor and show "deleted elsewhere". |
| 24 | No EventKitUI on AppKit. | Build all pickers and editors in SwiftUI. |
| 25 | Private symbols (ReminderKit, userInfo keys) are tempting. | Avoid for App Store builds. If at all, only behind a feature flag in a Developer ID build. |
| 26 | `.writeOnly` and `.authorized` enum cases in switches. | Treat only `.fullAccess` as usable; handle `@unknown default`. |
| 27 | `defaultCalendarForNewReminders()` can be nil (no reminders account). | Onboarding state: "No Reminders account — enable iCloud Reminders or create a list". Creating requires a reminders-capable source. |

---

## 5. Open questions (to test empirically on macOS 27 with a throwaway iCloud test account and an "On My Mac"/Exchange account if available)

1. Do reminders created in Reminders.app with date+time expose an `EKAlarm`, and what kind (absolute, or relative 0)? Does an EventKit reminder with a timed `dueDateComponents` and **no** alarm produce a notification? How is Reminders' "Early Reminder" represented: a second relative alarm?
2. How do date-only reminders notify (Reminders' all-day notification time setting)? Is that setting readable? INFERENCE: no.
3. How do subtasks surface via `fetchReminders`: flat siblings, or hidden? What happens to subtasks when a parent is deleted or completed via EventKit?
4. Do reminders inside sections or grocery lists have any observable difference via EventKit?
5. Does `calendarItemIdentifier` change when moving a reminder between two iCloud lists, and across accounts? Does a cross-account move succeed or throw?
6. What is `calendarItemExternalIdentifier` for iCloud reminders, and does it match across Mac and iPhone?
7. On recurring completion on non-iCloud sources (local, Exchange): does the same in-place advance happen, and is a completed copy created? What exactly triggers the "whole series completed" edge case?
8. Does `remove(_:commit:)` on a recurring reminder delete the entire series? Any span-like behavior?
9. Is `EKEventStoreChanged` posted on the main thread on macOS 27, and how many times per single external edit?
10. Is the `fetchReminders` completion queue main or background on macOS 27? Is a non-`@Sendable` closure written in `@MainActor` code crash-prone in Swift 6 mode?
11. Does Reminders.app honor arbitrary `EKCalendar.color` values, or snap them to its palette? Is the emblem preserved when EventKit recolors?
12. Can EventKit delete the default reminders list, and what becomes the default afterwards?
13. For shared iCloud lists (participant): what are `allowsContentModifications` and `isImmutable`? Can a participant rename or delete the list?
14. Does `EKErrorReminderAlarmContainsEmailOrUrl` actually fire on macOS for `soundName`/`emailAddress` alarms on reminders, or are they silently dropped?
15. Is there an "On My Mac" (`.local`) reminders source on macOS 27, and when does it appear?
16. Does the app-level undo of a delete (recreating the reminder) restore enough? Lost: id, creation date, and invisible data (tags, subtasks, images, flags). This suggests a "soft delete" UI with a delay before the real `remove`.
17. Does the macOS 27 AppIntents `.reminders` schema domain have any data-access implications? It currently appears to be adoption-only.
18. What is the performance of `predicateForReminders(in: nil)` on stores with 10k+ completed reminders, compared with bounded completed windows?