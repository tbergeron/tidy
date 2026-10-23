import EventKit

extension Reminder {
    /// Public EventKit fields only; Backend adds the bridge extras. Also used by the iOS widget.
    init?(_ r: EKReminder) {
        guard let cal = r.calendar else { return nil }   // orphaned
        self.init(
            id: r.calendarItemIdentifier.uppercased(), externalID: r.calendarItemExternalIdentifier,
            listID: cal.calendarIdentifier.uppercased(), title: r.title ?? "", notes: r.notes,
            isCompleted: r.isCompleted, completionDate: r.completionDate, priority: r.priority,
            due: r.dueDateComponents, alarms: (r.alarms ?? []).map(Self.alarm),
            recurrence: r.recurrenceRules?.first.map(RecurrenceMap.recurrence),
            created: r.creationDate, modified: r.lastModifiedDate)
    }

    private static func alarm(_ a: EKAlarm) -> Alarm {
        var loc: LocationAlarm?
        if let s = a.structuredLocation {
            loc = LocationAlarm(title: s.title ?? "", latitude: s.geoLocation?.coordinate.latitude ?? 0,
                                longitude: s.geoLocation?.coordinate.longitude ?? 0, radius: s.radius,
                                leaving: a.proximity == .leave)
        }
        return Alarm(absolute: a.absoluteDate, relative: a.absoluteDate == nil && loc == nil ? a.relativeOffset : nil, location: loc)
    }
}
