# Tidy

A Things-style macOS app for **Apple Reminders**. Tidy has no backend of its own: every list and reminder lives in Reminders and syncs to your iPhone, iPad and other Macs through iCloud as usual.

- Smart lists (Today, Scheduled, All, Flagged, Completed, Assigned to Me, Urgent), lists, groups, sections and subtasks
- Inline card editor, quick entry, drag and drop, full keyboard control
- Natural-language dates in titles ("Do dishes tonight", "Pay rent every month on the 1st")
- Custom repeats, Reminders-style Dock badge, hide and reorder lists

macOS 27 only. Tidy uses EventKit for everything it can. For data EventKit doesn't expose (tags, flags, subtasks, sections, groups, urgent…) it reads Reminders' private ReminderKit framework in-process; the only private *write* so far is "Mark as Urgent", verified by read-back. Private APIs can break with any macOS update, so this is not App Store material.

## Build

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig   # optional: your own signing identities
xcodegen generate
xcodebuild -project Tidy.xcodeproj -scheme Tidy -destination 'platform=macOS' build
xcodebuild test -project Tidy.xcodeproj -scheme Tidy -destination 'platform=macOS' -only-testing:Tests/LogicTests
```

Without `Signing.local.xcconfig` the app is signed ad-hoc, and macOS asks for Reminders access again after every build.

`docs/` holds the research and the plan behind the design; `SPIKES.md` lists the experiments to run in a throwaway account before enabling more private writes.
