// The only private-API surface Swift sees. Also the target's bridging header.
// Everything here reads ReminderKit (Reminders' private framework) through EventKit's own store.
// Selector names/encodings verified statically on macOS 27.2: docs/research/bridge-verify-27.2.md

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTRAccountInfo : NSObject
@property (readonly, copy) NSString *identifier;            // == EKSource.sourceIdentifier
@property (readonly, copy) NSString *name;
@property (readonly, copy) NSSet<NSString *> *capabilities; // REMAccountCapabilities keys that are YES
@property (readonly, copy) NSArray<NSString *> *listOrder;  // sidebar order (list/group UUIDs)
@end

@interface TTRListInfo : NSObject
@property (readonly, copy) NSString *identifier;            // == EKCalendar.calendarIdentifier (lists)
@property (readonly, copy) NSString *name;
@property (readonly, copy) NSString *accountID;
@property (readonly) BOOL isGroup;
@property (readonly, copy, nullable) NSString *parentID;    // group
@property (readonly, copy, nullable) NSString *emblem;
@property (readonly, copy, nullable) NSString *emoji;
@property (readonly) BOOL isPinned;
@property (readonly, copy, nullable) NSString *sortingStyle;
@property (readonly) BOOL isGroceries;
@property (readonly) BOOL isShared;
@property (readonly, copy) NSArray<NSString *> *manualOrder; // reminder UUIDs
@property (readonly, copy, nullable) NSString *currentUserParticipantID;
@end

@interface TTRReminderInfo : NSObject
@property (readonly, copy) NSString *identifier;            // == calendarItemIdentifier
@property (readonly, copy) NSArray<NSString *> *tags;
@property (readonly) BOOL flagged;
@property (readonly) BOOL urgent;
@property (readonly) BOOL hourly;
@property (readonly, copy, nullable) NSString *parentID;
@property (readonly, copy) NSArray<NSURL *> *urls;
@property (readonly, copy) NSArray<NSArray<id> *> *images;  // [width, height, uti?]
@property (readonly, copy) NSArray<NSArray<NSNumber *> *> *earlyAlerts; // [unit, count]
@property (readonly, copy, nullable) NSString *assigneeID;
@end

@interface TTRSectionInfo : NSObject
@property (readonly, copy) NSString *identifier;
@property (readonly, copy) NSString *name;
@end

@interface TTRBridge : NSObject
/// nil when ReminderKit can't be loaded or EventKit's store isn't reachable. `report` collects probe notes.
+ (nullable instancetype)bridgeWithEventStore:(EKEventStore *)store report:(NSMutableArray<NSString *> *)report;

- (nullable NSArray<TTRAccountInfo *> *)accounts:(NSError **)error;
/// Lists and groups of every account.
- (nullable NSArray<TTRListInfo *> *)lists:(NSError **)error;
- (nullable NSArray<TTRReminderInfo *> *)remindersWithIDs:(NSArray<NSString *> *)ids error:(NSError **)error;
- (nullable NSArray<TTRSectionInfo *> *)sectionsInList:(NSString *)listID error:(NSError **)error;
/// reminder ID → section ID, for reminders that are in a section. ponytail: one XPC call per reminder.
- (nullable NSDictionary<NSString *, NSString *> *)sectionIDsForReminders:(NSArray<NSString *> *)ids error:(NSError **)error;

// MARK: Writes (private). Each is one REMSaveRequest on a freshly fetched object, with the save result checked
// and the reminder read back: the changed field must hold the new value and every other field must be unchanged.

/// Reminders' "Mark as Urgent". Fails (and changes nothing visible) if the reminder or account doesn't support it.
- (BOOL)setUrgent:(BOOL)urgent reminder:(NSString *)reminderID error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
