#import "TTRBridge.h"
#import <dlfcn.h>

// Private ReminderKit declarations. Messaged through protocols (correct ARC/ABI), never perform:.
// Every call is wrapped in @try; exceptions never cross into Swift.

@protocol TTR_EKEventStore <NSObject>
- (nullable id)reminderStore;
@end
@protocol TTR_EKReminderStore <NSObject>
- (nullable id)remStore;
@end
@protocol TTR_REMStore <NSObject>
- (nullable NSArray *)fetchAccountsWithError:(NSError **)error;
- (nullable id)fetchRemindersWithObjectIDs:(NSArray *)ids fetchOptions:(id)options error:(NSError **)error;
- (nullable id)fetchRemindersWithObjectIDs:(NSArray *)ids error:(NSError **)error;
- (nullable NSArray *)fetchListSectionsWithListObjectID:(id)objectID error:(NSError **)error;
@end
@protocol TTR_REMAccount <NSObject>
- (nullable NSArray *)fetchListsAndSublistsWithError:(NSError **)error;
- (nullable id)groupContext;
@end
@protocol TTR_GroupContext <NSObject>
- (nullable NSArray *)fetchGroupsWithError:(NSError **)error;
@end
@protocol TTR_ObjectIDFactory <NSObject>
+ (id)objectIDWithUUID:(NSUUID *)uuid;
@end
@protocol TTR_FetchOptions <NSObject>
+ (id)fetchOptionsIncludingDueDateDeltaAlerts;
@end
@protocol TTR_REMStoreFetch <NSObject>
- (nullable id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (nullable id)fetchReminderIncludingMarkedForDeleteWithObjectID:(id)objectID error:(NSError **)error;
@end
@protocol TTR_SaveRequest <NSObject>
- (instancetype)initWithStore:(id)store;
- (id)updateReminder:(id)reminder;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end
@protocol TTR_ReminderChangeItem <NSObject>
- (nullable id)urgentAlarmContext;
@end
@protocol TTR_UrgentContext <NSObject>
- (void)setIsUrgentStateEnabledForCurrentUser:(BOOL)enabled;
@end
@protocol TTR_SectionsDataView <NSObject>
- (instancetype)initWithStore:(id)store;
- (nullable id)fetchListSectionWithReminderID:(id)objectID error:(NSError **)error;
@end

static NSString *const TTRErrorDomain = @"TTRBridge";

static NSError *TTRError(NSString *message) {
    return [NSError errorWithDomain:TTRErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *TTRErrorFromException(NSException *x) {
    return [NSError errorWithDomain:TTRErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", x.name, x.reason ?: @""]}];
}

static Class TTRClass(NSString *name) { return NSClassFromString(name); }

/// KVC read that never throws (REM objects forward unknown keys to their storage).
static id TTRValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *x) { return nil; }
}
static BOOL TTRBool(id obj, NSString *key) {
    id v = TTRValue(obj, key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}
static NSString *TTRString(id obj, NSString *key) {
    id v = TTRValue(obj, key);
    return [v isKindOfClass:NSString.class] && [v length] ? v : nil;
}
/// REM object, REMObjectID, or NSUUID → upper-case UUID string.
static NSString *TTRUUID(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:NSUUID.class]) return [[obj UUIDString] uppercaseString];
    id oid = [obj respondsToSelector:NSSelectorFromString(@"uuid")] ? obj : TTRValue(obj, @"objectID");
    id uuid = TTRValue(oid, @"uuid");
    return [uuid isKindOfClass:NSUUID.class] ? [[uuid UUIDString] uppercaseString] : nil;
}
static NSArray<NSString *> *TTRUUIDs(id collection) {
    NSMutableArray *out = [NSMutableArray array];
    if (![collection conformsToProtocol:@protocol(NSFastEnumeration)]) return out;
    for (id e in (id<NSFastEnumeration>)collection) { NSString *u = TTRUUID(e); if (u) [out addObject:u]; }
    return out;
}
static NSArray *TTRArray(id collection) {
    if ([collection isKindOfClass:NSArray.class]) return collection;
    if ([collection isKindOfClass:NSDictionary.class]) return [collection allValues];
    if ([collection isKindOfClass:NSSet.class]) return [collection allObjects];
    if ([collection isKindOfClass:NSOrderedSet.class]) return [collection array];
    return @[];
}
static id TTRObjectID(NSString *className, NSString *uuidString) {
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:uuidString];
    Class c = TTRClass(className);
    if (!u || ![c respondsToSelector:@selector(objectIDWithUUID:)]) return nil;
    return [(Class<TTR_ObjectIDFactory>)c objectIDWithUUID:u];
}

static NSArray<NSString *> *TTRCapabilityKeys(void) {
    return @[@"supportsSubtasks", @"supportsAttachments", @"supportsListAppearance", @"supportsGroups",
             @"supportsFlagged", @"supportsPersonTrigger", @"supportsLocation", @"supportsHourlyRecurrence",
             @"supportsTemplates", @"supportsListSharees", @"supportsListShareesMutation", @"supportsMoveAcrossLists",
             @"supportsMoveAcrossSharedLists", @"supportsMultipleDateAlarmsOnRecurrence", @"supportsSections",
             @"supportsDueDateDeltaAlerts", @"supportsAssignments", @"supportsHashtags", @"supportsCustomSmartLists",
             @"supportsPinnedLists", @"supportsTextStyling", @"supportsGroceriesList", @"supportsRecentlyDeletedList",
             @"supportsUrgentAlarm", @"supportsCloudKitSync"];
}

#pragma mark - Info records

@interface TTRAccountInfo ()
@property (readwrite, copy) NSString *identifier, *name;
@property (readwrite, copy) NSSet<NSString *> *capabilities;
@property (readwrite, copy) NSArray<NSString *> *listOrder;
@end
@implementation TTRAccountInfo
@end

@interface TTRListInfo ()
@property (readwrite, copy) NSString *identifier, *name, *accountID;
@property (readwrite) BOOL isGroup, isPinned, isGroceries, isShared;
@property (readwrite, copy, nullable) NSString *parentID, *emblem, *emoji, *sortingStyle, *currentUserParticipantID;
@property (readwrite, copy) NSArray<NSString *> *manualOrder;
@end
@implementation TTRListInfo
@end

@interface TTRReminderInfo ()
@property (readwrite, copy) NSString *identifier;
@property (readwrite, copy) NSArray<NSString *> *tags;
@property (readwrite) BOOL flagged, urgent, hourly;
@property (readwrite, copy, nullable) NSString *parentID, *assigneeID;
@property (readwrite, copy) NSArray<NSURL *> *urls;
@property (readwrite, copy) NSArray<NSArray<id> *> *images;
@property (readwrite, copy) NSArray<NSArray<NSNumber *> *> *earlyAlerts;
@end
@implementation TTRReminderInfo
@end

@interface TTRSectionInfo ()
@property (readwrite, copy) NSString *identifier, *name;
@end
@implementation TTRSectionInfo
@end

#pragma mark - Bridge

@implementation TTRBridge {
    id _store; // REMStore owned by EventKit
}

+ (instancetype)bridgeWithEventStore:(EKEventStore *)ek report:(NSMutableArray<NSString *> *)report {
    if (!dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW)) {
        [report addObject:@"ReminderKit: dlopen failed"];
        return nil;
    }
    for (NSString *name in @[@"REMStore", @"REMReminder", @"REMList", @"REMAccount", @"REMListSectionsDataView"]) {
        if (!TTRClass(name)) { [report addObject:[@"missing class " stringByAppendingString:name]]; return nil; }
    }
    id store = nil;
    @try {
        id rs = [ek respondsToSelector:@selector(reminderStore)] ? [(id<TTR_EKEventStore>)ek reminderStore] : nil;
        store = [rs respondsToSelector:@selector(remStore)] ? [(id<TTR_EKReminderStore>)rs remStore] : nil;
    } @catch (NSException *x) {
        [report addObject:[@"store: " stringByAppendingString:x.reason ?: x.name]];
    }
    if (![store isKindOfClass:TTRClass(@"REMStore")]) {
        [report addObject:@"EventKit's REMStore not reachable (EKEventStore.reminderStore.remStore)"];
        return nil;
    }
    for (NSString *sel in @[@"fetchAccountsWithError:", @"fetchRemindersWithObjectIDs:error:",
                            @"fetchListSectionsWithListObjectID:error:"]) {
        if (![store respondsToSelector:NSSelectorFromString(sel)]) {
            [report addObject:[@"REMStore missing " stringByAppendingString:sel]];
            return nil;
        }
    }
    TTRBridge *b = [self new];
    b->_store = store;
    [report addObject:@"ReminderKit loaded; EventKit store reachable"];
    return b;
}

- (NSArray *)rawAccounts:(NSError **)error {
    NSArray *accts = [(id<TTR_REMStore>)_store fetchAccountsWithError:error];
    return accts ?: (error && *error ? nil : @[]);
}

- (NSArray<TTRAccountInfo *> *)accounts:(NSError **)error {
    @try {
        NSArray *accts = [self rawAccounts:error];
        if (!accts) return nil;
        NSMutableArray *out = [NSMutableArray array];
        for (id a in accts) {
            NSString *uuid = TTRUUID(a);
            if (!uuid) continue;
            TTRAccountInfo *i = [TTRAccountInfo new];
            i.identifier = uuid;
            i.name = TTRString(a, @"name") ?: TTRString(a, @"displayName") ?: @"";
            id caps = TTRValue(a, @"capabilities");
            NSMutableSet *set = [NSMutableSet set];
            for (NSString *k in TTRCapabilityKeys()) if (TTRBool(caps, k)) [set addObject:k];
            i.capabilities = set;
            i.listOrder = TTRUUIDs(TTRValue(a, @"listIDsOrdering"));
            [out addObject:i];
        }
        return out;
    } @catch (NSException *x) {
        if (error) *error = TTRErrorFromException(x);
        return nil;
    }
}

- (TTRListInfo *)infoForList:(id)l account:(NSString *)accountID {
    NSString *uuid = TTRUUID(l);
    if (!uuid) return nil;
    TTRListInfo *i = [TTRListInfo new];
    i.identifier = uuid;
    i.accountID = accountID;
    i.name = TTRString(l, @"name") ?: @"";
    i.isGroup = TTRBool(l, @"isGroup");
    i.parentID = TTRUUID(TTRValue(l, @"parentListID")) ?: TTRUUID(TTRValue(l, @"parentList"));
    id badge = TTRValue(TTRValue(l, @"appearanceContext"), @"badge");
    i.emblem = TTRString(badge, @"emblem");
    i.emoji = TTRString(badge, @"emoji");
    i.isPinned = TTRBool(l, @"isPinned");
    i.sortingStyle = TTRString(l, @"sortingStyle");
    i.isGroceries = TTRBool(l, @"shouldCategorizeGroceryItems");
    i.isShared = TTRBool(l, @"isShared");
    i.manualOrder = i.isGroup ? @[] : TTRUUIDs(TTRValue(l, @"reminderIDsOrdering"));
    i.currentUserParticipantID = [TTRString(l, @"currentUserShareParticipantID") uppercaseString]
        ?: TTRUUID(TTRValue(l, @"currentUserShareParticipantID"));
    return i;
}

- (NSArray<TTRListInfo *> *)lists:(NSError **)error {
    @try {
        NSArray *accts = [self rawAccounts:error];
        if (!accts) return nil;
        NSMutableDictionary<NSString *, TTRListInfo *> *byID = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (id a in accts) {
            NSString *accountID = TTRUUID(a);
            if (!accountID) continue;
            NSMutableArray *raw = [NSMutableArray array];
            if ([a respondsToSelector:@selector(fetchListsAndSublistsWithError:)]) {
                NSError *e = nil;
                [raw addObjectsFromArray:TTRArray([(id<TTR_REMAccount>)a fetchListsAndSublistsWithError:&e])];
            }
            id gc = [a respondsToSelector:@selector(groupContext)] ? [(id<TTR_REMAccount>)a groupContext] : nil;
            if ([gc respondsToSelector:@selector(fetchGroupsWithError:)]) {
                NSError *e = nil;
                [raw addObjectsFromArray:TTRArray([(id<TTR_GroupContext>)gc fetchGroupsWithError:&e])];
            }
            for (id l in raw) {
                TTRListInfo *i = [self infoForList:l account:accountID];
                if (!i || byID[i.identifier]) continue;
                byID[i.identifier] = i;
                [order addObject:i.identifier];
            }
        }
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *k in order) [out addObject:byID[k]];
        return out;
    } @catch (NSException *x) {
        if (error) *error = TTRErrorFromException(x);
        return nil;
    }
}

- (NSArray<TTRReminderInfo *> *)remindersWithIDs:(NSArray<NSString *> *)ids error:(NSError **)error {
    @try {
        NSMutableArray *oids = [NSMutableArray array];
        for (NSString *s in ids) { id oid = TTRObjectID(@"REMReminder", s); if (oid) [oids addObject:oid]; }
        if (!oids.count) return @[];
        Class opts = TTRClass(@"REMReminderFetchOptions");
        id result;
        if ([opts respondsToSelector:@selector(fetchOptionsIncludingDueDateDeltaAlerts)]
            && [_store respondsToSelector:@selector(fetchRemindersWithObjectIDs:fetchOptions:error:)]) {
            // Early alerts are only populated with these options (verify C1).
            result = [(id<TTR_REMStore>)_store fetchRemindersWithObjectIDs:oids
                                                              fetchOptions:[(Class<TTR_FetchOptions>)opts fetchOptionsIncludingDueDateDeltaAlerts]
                                                                     error:error];
        } else {
            result = [(id<TTR_REMStore>)_store fetchRemindersWithObjectIDs:oids error:error];
        }
        if (!result && error && *error) return nil;
        NSMutableArray *out = [NSMutableArray array];
        for (id rem in TTRArray(result)) {
            TTRReminderInfo *i = [self infoForReminder:rem];
            if (i) [out addObject:i];
        }
        return out;
    } @catch (NSException *x) {
        if (error) *error = TTRErrorFromException(x);
        return nil;
    }
}

- (TTRReminderInfo *)infoForReminder:(id)rem {
    NSString *uuid = TTRUUID(rem);
    if (!uuid) return nil;
    TTRReminderInfo *i = [TTRReminderInfo new];
    i.identifier = uuid;

    NSMutableArray *tags = [NSMutableArray array];
    for (id h in TTRArray(TTRValue(rem, @"hashtags"))) { NSString *n = TTRString(h, @"name"); if (n) [tags addObject:n]; }
    i.tags = [tags sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    i.flagged = [TTRValue(rem, @"flagged") integerValue] != 0;
    i.urgent = TTRBool(rem, @"isUrgentStateEnabledForCurrentUser");
    i.parentID = TTRUUID(TTRValue(rem, @"parentReminderID"));

    id attachments = TTRValue(rem, @"attachmentContext");
    NSMutableArray *urls = [NSMutableArray array];
    for (id a in TTRArray(TTRValue(attachments, @"urlAttachments"))) {
        id u = TTRValue(a, @"url");
        if ([u isKindOfClass:NSURL.class]) [urls addObject:u];
    }
    i.urls = urls;
    NSMutableArray *images = [NSMutableArray array];
    for (id a in TTRArray(TTRValue(attachments, @"imageAttachments"))) {
        [images addObject:@[TTRValue(a, @"width") ?: @0, TTRValue(a, @"height") ?: @0, TTRString(a, @"uti") ?: NSNull.null]];
    }
    i.images = images;

    NSMutableArray *alerts = [NSMutableArray array];
    for (id a in TTRArray(TTRValue(TTRValue(rem, @"dueDateDeltaAlertContext"), @"dueDateDeltaAlerts"))) {
        id delta = TTRValue(a, @"dueDateDelta");
        id unit = TTRValue(delta, @"unit"), count = TTRValue(delta, @"count");
        if ([unit isKindOfClass:NSNumber.class] && [count isKindOfClass:NSNumber.class]) [alerts addObject:@[unit, count]];
    }
    i.earlyAlerts = alerts;

    i.assigneeID = TTRUUID(TTRValue(TTRValue(TTRValue(rem, @"assignmentContext"), @"currentAssignment"), @"assigneeID"));

    BOOL hourly = NO;
    for (id rule in TTRArray(TTRValue(rem, @"recurrenceRules"))) {
        if ([TTRValue(rule, @"frequency") integerValue] == 4) hourly = YES; // inferred (verify C7); S8 confirms
    }
    i.hourly = hourly;
    return i;
}

#pragma mark - Writes

/// Everything that must NOT change when one field is written (compared before/after as descriptions).
- (NSDictionary<NSString *, NSString *> *)fingerprint:(id)rem {
    NSMutableDictionary *f = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"title", @"notes", @"dueDateComponents", @"startDateComponents", @"completed", @"completionDate",
                          @"flagged", @"priority", @"timeZone"]) {
        f[k] = [TTRValue(rem, k) description] ?: @"nil";
    }
    f[@"list"] = TTRUUID(TTRValue(rem, @"listID")) ?: @"nil";
    f[@"parent"] = TTRUUID(TTRValue(rem, @"parentReminderID")) ?: @"nil";
    NSMutableArray *tags = [NSMutableArray array];
    for (id h in TTRArray(TTRValue(rem, @"hashtags"))) { NSString *n = TTRString(h, @"name"); if (n) [tags addObject:n]; }
    f[@"tags"] = [[tags sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
    return f;
}

- (BOOL)setUrgent:(BOOL)urgent reminder:(NSString *)reminderID error:(NSError **)error {
    @try {
        id oid = TTRObjectID(@"REMReminder", reminderID);
        Class saveClass = TTRClass(@"REMSaveRequest");
        if (!oid || !saveClass || ![_store respondsToSelector:@selector(fetchReminderWithObjectID:error:)]) {
            if (error) *error = TTRError(@"Urgent isn't available on this macOS version.");
            return NO;
        }
        id<TTR_REMStoreFetch> store = (id<TTR_REMStoreFetch>)_store;
        id rem = [store fetchReminderWithObjectID:oid error:error];
        if (!rem) return NO;
        NSDictionary *before = [self fingerprint:rem];

        id<TTR_SaveRequest> request = [(id<TTR_SaveRequest>)[saveClass alloc] initWithStore:_store];
        id change = [request updateReminder:rem];
        id context = [change respondsToSelector:@selector(urgentAlarmContext)] ? [(id<TTR_ReminderChangeItem>)change urgentAlarmContext] : nil;
        if (![context respondsToSelector:@selector(setIsUrgentStateEnabledForCurrentUser:)]) {
            if (error) *error = TTRError(@"This reminder's account doesn't support Urgent.");
            return NO;   // nothing saved
        }
        [(id<TTR_UrgentContext>)context setIsUrgentStateEnabledForCurrentUser:urgent];
        NSError *saveError = nil;
        if (![request saveSynchronouslyWithError:&saveError]) {
            if (error) *error = saveError ?: TTRError(@"Reminders didn't save the change.");
            return NO;
        }

        // Read back: the value took, nothing else moved, and the reminder still exists.
        id fresh = [store fetchReminderWithObjectID:oid error:nil];
        if (!fresh) {
            BOOL tombstoned = [store respondsToSelector:@selector(fetchReminderIncludingMarkedForDeleteWithObjectID:error:)]
                && [store fetchReminderIncludingMarkedForDeleteWithObjectID:oid error:nil] != nil;
            if (error) *error = TTRError(tombstoned ? @"VERIFY: the reminder was moved to Recently Deleted by the change. Recover it in Reminders."
                                                    : @"VERIFY: the reminder can't be read back.");
            return NO;
        }
        if (TTRBool(fresh, @"isUrgentStateEnabledForCurrentUser") != urgent) {
            if (error) *error = TTRError(@"VERIFY: Reminders didn't keep the Urgent change.");
            return NO;
        }
        NSDictionary *after = [self fingerprint:fresh];
        for (NSString *k in before) {
            if (![before[k] isEqualToString:after[k]]) {
                if (error) *error = TTRError([NSString stringWithFormat:@"VERIFY: setting Urgent also changed “%@”.", k]);
                return NO;
            }
        }
        return YES;
    } @catch (NSException *x) {
        if (error) *error = TTRErrorFromException(x);
        return NO;
    }
}

- (NSArray<TTRSectionInfo *> *)sectionsInList:(NSString *)listID error:(NSError **)error {
    @try {
        id oid = TTRObjectID(@"REMList", listID);
        if (!oid) return @[];
        NSArray *raw = [(id<TTR_REMStore>)_store fetchListSectionsWithListObjectID:oid error:error];
        if (!raw && error && *error) return nil;
        NSMutableArray *out = [NSMutableArray array];
        for (id s in TTRArray(raw)) {
            NSString *uuid = TTRUUID(s);
            if (!uuid) continue;
            TTRSectionInfo *i = [TTRSectionInfo new];
            i.identifier = uuid;
            i.name = TTRString(s, @"displayName") ?: @"";
            [out addObject:i];
        }
        return out;
    } @catch (NSException *x) {
        if (error) *error = TTRErrorFromException(x);
        return nil;
    }
}

- (NSDictionary<NSString *, NSString *> *)sectionIDsForReminders:(NSArray<NSString *> *)ids error:(NSError **)error {
    @try {
        Class cls = TTRClass(@"REMListSectionsDataView");
        id<TTR_SectionsDataView> view = [(id<TTR_SectionsDataView>)[cls alloc] initWithStore:_store];
        if (![view respondsToSelector:@selector(fetchListSectionWithReminderID:error:)]) return @{};
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *s in ids) {
            id oid = TTRObjectID(@"REMReminder", s);
            if (!oid) continue;
            NSError *e = nil;
            NSString *sec = TTRUUID([view fetchListSectionWithReminderID:oid error:&e]);
            if (sec) out[s] = sec;
        }
        return out;
    } @catch (NSException *x) {
        if (error) *error = TTRErrorFromException(x);
        return nil;
    }
}

@end
