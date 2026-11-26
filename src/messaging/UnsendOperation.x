%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "UnsendOperation.h"
#import "Features.h"
#import "MessageHistory.h"
#import "RetainedMedia.h"
#import "../core/Localization.h"
#import "../core/StartupProfiler.h"
#import "../core/TargetMetadata.h"
#import "../known/MessagingMappings.h"
#import "../known/FeatureImage.h"
#import <CoreData/CoreData.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <mach-o/dyld.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sqlite3.h>
#import <stdatomic.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>

static _Atomic(uintptr_t) imageSlide;
static atomic_bool codeVerified;
static _Atomic(const RUINUnsendOperationMapping *) selectedUnsendMapping;
static _Atomic(const RUINUnsendOperationMapping *) activeUnsendMapping;
// Written/read under installLock. Once published, keep this proof and its
// loader reference for the lifetime of the installed hooks, including failures.
static RUINFeatureImage unsendImage;
static const RUINVersionMapping *unsendImageVersion;
static NSString *imageResolution = @"notAttempted";
static BOOL imageFingerprintVerified;
typedef NS_ENUM(int, OperationHookStatus) {
    OperationHookPending = 0,
    OperationHookGated = 1,
    OperationHookUnavailable = 2,
    OperationHookInstalled = 3
};
static atomic_int fetchStatus, displayStatus, param1Status;
static atomic_uint_fast64_t fetchCalls, scopedLookups, protectedMessages, rejectedLookups, observationErrors;
static atomic_uint_fast64_t markerFailures, historyFreezes, displayReturns;
static atomic_uint_fast64_t capturedOperations, rejectedOperations;
static NSString *const OperationThreadKey = @"RUINUnsendOperation.currentParserIdentity";
static os_unfair_lock installLock = OS_UNFAIR_LOCK_INIT, markerLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock markerCacheLock = OS_UNFAIR_LOCK_INIT;
static sqlite3 *markerDatabase;
static sqlite3 *markerReadDatabase;
static sqlite3_stmt *markerReadStatement;
static NSCache<NSArray<NSString *> *, NSNumber *> *markerLookupCache;
static NSMutableDictionary<NSArray<NSString *> *, NSNumber *> *markerLookupPending;
static dispatch_queue_t markerReadQueue;
static uint64_t markerCacheGeneration;
static _Thread_local unsigned int fetchDepth, displayDepth;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
static BOOL testImageMatches;
static BOOL testUseFeatureImage;
static _Thread_local const uintptr_t *testPCs;
static _Thread_local size_t testPCCount;
static _Thread_local uintptr_t testParam1Caller;
#endif

static BOOL TargetMatches(void) {
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}
static atomic_bool line14Mode;
static NSArray *L14FilterFetch(NSFetchRequest *request, NSArray *actual);
static BOOL Enabled(void) {
    return (atomic_load(&codeVerified) || atomic_load(&line14Mode)) && TargetMatches() &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey];
}
static BOOL VerifyCode(void) {
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
    const RUINUnsendOperationMapping *operation = versionMapping ? &versionMapping->messaging.unsendOperation : NULL;
    selectedUnsendMapping = operation;
    imageFingerprintVerified = NO;
    imageResolution = @"mappingRejected";
    if (!TargetMatches() || !operation ||
        operation->parserStatus != RUINMappingStatusVerified || !operation->parserAnchors ||
        !operation->parserAnchorCount || !operation->parserParam1ReturnAddress ||
        operation->lookupStatus != RUINMappingStatusVerified ||
        !operation->orderedLookupReturnAddresses || !operation->orderedLookupReturnAddressCount) return NO;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    // Preserve the existing native control-flow fixture; focused image tests
    // also exercise the runtime proof/pin path below with injected loader APIs.
    if (!testUseFeatureImage) {
        imageResolution = @"hostFixture";
        if (!testImageMatches) return NO;
        atomic_store(&imageSlide, 0);
        activeUnsendMapping = operation;
        imageFingerprintVerified = YES;
        return YES;
    }
#endif
    if (unsendImageVersion) {
        // No dyld rescan or new loader reference on repeated installs. A later
        // failure gates use but cannot discard the proof backing live hooks.
        imageResolution = @"retainedProofRejected";
        if (unsendImageVersion != versionMapping) return NO;
        RUIN_PROFILE_BEGIN("unsend_verify.image_matches");
        BOOL retainedMatches = RUINFeatureImageMatches(&unsendImage, &versionMapping->host);
        RUIN_PROFILE_END(retainedMatches ? RUINProfileStatusOK : RUINProfileStatusFailed);
        if (!retainedMatches) return NO;
        imageResolution = @"retainedProof";
        RUIN_PROFILE_BEGIN("unsend_verify.verify_instructions");
        imageFingerprintVerified = RUINVerifyFeatureInstructions(&unsendImage,
            operation->parserAnchors, operation->parserAnchorCount);
        RUIN_PROFILE_END(imageFingerprintVerified ? RUINProfileStatusOK : RUINProfileStatusFailed);
        return imageFingerprintVerified;
    }
    RUINFeatureImage candidate = {0};
    // Require the shared owner/path/UUID/CPU and lifetime proof even when the
    // strict main resolver succeeds: LC can rewrite a converted guest's type
    // to MH_EXECUTE, which alone does not prove process lifetime.
    RUIN_PROFILE_BEGIN("unsend_verify.resolve_image");
    BOOL imageResolved = RUINResolveFeatureImage(&versionMapping->host, objc_getClass("LineOperation"), &candidate);
    RUIN_PROFILE_END(imageResolved ? RUINProfileStatusOK : RUINProfileStatusFailed);
    if (!imageResolved) {
        imageResolution = RUINFeatureImageResolutionStatus();
        return NO;
    }
    imageResolution = @"featureImageResolved";
    RUIN_PROFILE_BEGIN("unsend_verify.image_matches");
    BOOL identityMatches = RUINFeatureImageMatches(&candidate, &versionMapping->host);
    RUIN_PROFILE_END(identityMatches ? RUINProfileStatusOK : RUINProfileStatusFailed);
    const RUINVersionMapping *nativeVersion = RUINCurrentMapping();
    if (nativeVersion) {
        // Preserve all of the existing strict native/sideload checks. A native
        // fingerprint failure must not fall through to the converted route.
        RUINMainExecutableImage nativeImage;
        imageResolution = @"nativeImageRejected";
        RUIN_PROFILE_BEGIN("unsend_verify.native_chain");
        imageFingerprintVerified = identityMatches && nativeVersion == versionMapping &&
            RUINResolveMainExecutableImage(&nativeImage) &&
            nativeImage.header == candidate.image.header && nativeImage.slide == candidate.image.slide &&
            RUINCurrentMapping() == versionMapping &&
            RUINVerifyInstructions(nativeImage.header, nativeImage.slide,
                operation->parserAnchors, operation->parserAnchorCount);
        RUIN_PROFILE_END(imageFingerprintVerified ? RUINProfileStatusOK : RUINProfileStatusFailed);
        if (imageFingerprintVerified) imageResolution = @"nativeProcessImage";
    } else {
        RUIN_PROFILE_BEGIN("unsend_verify.verify_instructions");
        imageFingerprintVerified = identityMatches &&
            RUINVerifyFeatureInstructions(&candidate, operation->parserAnchors, operation->parserAnchorCount);
        RUIN_PROFILE_END(imageFingerprintVerified ? RUINProfileStatusOK : RUINProfileStatusFailed);
    }
    if (!imageFingerprintVerified || !TargetMatches() ||
        RUINMappingForInfo(NSBundle.mainBundle.infoDictionary) != versionMapping) {
        imageFingerprintVerified = NO;
        RUINReleaseFeatureImage(&candidate);
        return NO;
    }
    unsendImage = candidate;
    unsendImageVersion = versionMapping;
    atomic_store(&imageSlide, (uintptr_t)candidate.image.slide);
    activeUnsendMapping = operation;
    return YES;
}
static BOOL OrderedScope(const uintptr_t *pcs, size_t count) {
    const RUINUnsendOperationMapping *operation = atomic_load(&activeUnsendMapping);
    if (!operation) return NO;
    size_t matched = 0;
    for (size_t i = 0; i < count && matched < operation->orderedLookupReturnAddressCount; i++)
        if (pcs[i] == operation->orderedLookupReturnAddresses[matched]) matched++;
    return matched == operation->orderedLookupReturnAddressCount;
}
static BOOL InUnsendLookup(void) {
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    return OrderedScope(testPCs, testPCCount);
#else
    void *frames[48]; uintptr_t pcs[48], slide = atomic_load(&imageSlide);
    int count = backtrace(frames, 48);
    for (int i = 0; i < count; i++) pcs[i] = (uintptr_t)frames[i] - slide;
    return OrderedScope(pcs, count > 0 ? (size_t)count : 0);
#endif
}
static NSString *MessageID(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    long long number = 0;
    for (NSUInteger i = 0; i < [value length]; i++) {
        unichar digit = [value characterAtIndex:i];
        if (digit < '0' || digit > '9' || number > (LLONG_MAX - (digit - '0')) / 10) return nil;
        number = number * 10 + digit - '0';
    }
    return number > 0 ? [NSString stringWithFormat:@"%lld", number] : nil;
}
%group RUINUnsendParam1
%hook RUINUnsendParsedOperation
- (id)param1 {
    id object = self;
    id actual = %orig;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    uintptr_t caller = testParam1Caller;
#else
    uintptr_t caller = (uintptr_t)__builtin_return_address(0) - atomic_load(&imageSlide);
#endif
    const RUINUnsendOperationMapping *operation = atomic_load(&activeUnsendMapping);
    if (!operation || caller != operation->parserParam1ReturnAddress) return actual;
    // This is the first field read by the verified parser, after decoding.
    // Replace, then consume this thread-local tuple at its first scoped fetch;
    // never maintain a global/time-window allowlist of message IDs.
    NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
    [thread removeObjectForKey:OperationThreadKey];
    @try {
        if (!Enabled() || ![actual isKindOfClass:NSString.class] || ![actual length]) return actual;
        Class cls = object_getClass(object);
        const char *names[] = {"type", "param2", "param3"}, *types[] = {"q16@0:8", "@16@0:8", "@16@0:8"};
        for (NSUInteger i = 0; i < 3; i++) {
            Method method = class_getInstanceMethod(cls, sel_registerName(names[i]));
            if (!method || strcmp(method_getTypeEncoding(method), types[i])) { atomic_fetch_add(&rejectedOperations, 1); return actual; }
        }
        long long type = [(id<RUINMessagingOperationFields>)object type];
        id rawMessage = [(id<RUINMessagingOperationFields>)object param2];
        NSString *message = MessageID(rawMessage);
        if ((type != 64 && type != 65) || !message) { atomic_fetch_add(&rejectedOperations, 1); return actual; }
        thread[OperationThreadKey] = @{@"chat":[actual copy], @"message":message};
        atomic_fetch_add(&capturedOperations, 1);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&rejectedOperations, 1); }
    return actual;

}
%end
%end
static NSString *RequestedMessage(NSFetchRequest *request) {
    if (request.resultType != NSManagedObjectResultType || ![request.predicate isKindOfClass:NSComparisonPredicate.class]) return nil;
    NSComparisonPredicate *p = (id)request.predicate;
    if (p.comparisonPredicateModifier != NSDirectPredicateModifier || p.predicateOperatorType != NSEqualToPredicateOperatorType || p.options) return nil;
    NSExpression *left = p.leftExpression, *right = p.rightExpression;
    if (left.expressionType == NSConstantValueExpressionType) { NSExpression *swap = left; left = right; right = swap; }
    if (left.expressionType != NSKeyPathExpressionType || ![left.keyPath isEqual:@"id"] || right.expressionType != NSConstantValueExpressionType) return nil;
    return MessageID(right.constantValue);
}
static NSURL *MarkerURL(void) {
    NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return root ? [root URLByAppendingPathComponent:@"RUIN/unsend-operation.sqlite"] : nil;
}
static void InitializeMarkerLookup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markerLookupCache = [NSCache new];
        markerLookupCache.countLimit = 512;
        markerLookupPending = [NSMutableDictionary dictionary];
        markerReadQueue = dispatch_queue_create("com.ruin.unsend-marker-read", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
}
static NSArray<NSString *> *MarkerQueryKey(NSDictionary *messageKey) {
    if (![messageKey isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:4];
    for (NSString *field in @[@"store", @"kind", @"chat"]) {
        id value = messageKey[field];
        if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
        NSString *copy = [value copy];
        NSData *bytes = [copy dataUsingEncoding:NSUTF8StringEncoding];
        if (!bytes || bytes.length > INT_MAX) return nil;
        for (NSUInteger i = 0; i < copy.length; i++) if (![copy characterAtIndex:i]) return nil;
        [values addObject:copy];
    }
    NSString *message = MessageID(messageKey[@"message"]);
    if (!message || ![values[1] isEqual:@"talk"]) return nil;
    [values addObject:message];
    return [values copy];
}
static NSArray<NSString *> *MarkerStoredKey(NSDictionary *messageKey) {
    NSArray<NSString *> *queryKey = MarkerQueryKey(messageKey);
    return queryKey && [messageKey[@"message"] isEqualToString:queryKey[3]] ? queryKey : nil;
}
static BOOL CachedMarker(NSArray<NSString *> *key, BOOL *retained) {
    InitializeMarkerLookup();
    os_unfair_lock_lock(&markerCacheLock);
    NSNumber *value = [markerLookupCache objectForKey:key];
    if (value) *retained = value.boolValue;
    os_unfair_lock_unlock(&markerCacheLock);
    return value != nil;
}
static void InvalidateMarkerCache(NSArray<NSString *> *writtenKey) {
    InitializeMarkerLookup();
    os_unfair_lock_lock(&markerCacheLock);
    markerCacheGeneration++;
    [markerLookupCache removeAllObjects];
    [markerLookupPending removeAllObjects];
    if (writtenKey) [markerLookupCache setObject:@YES forKey:writtenKey];
    os_unfair_lock_unlock(&markerCacheLock);
}
static int ReadMarkerOnQueue(NSArray<NSString *> *key, BOOL *retained) {
    int result = SQLITE_ERROR;
    os_unfair_lock_lock(&markerLock);
    @try {
        if (!markerReadStatement) {
            NSURL *url = MarkerURL();
            if (!url) return SQLITE_CANTOPEN;
            if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return SQLITE_DONE;
            if (sqlite3_open_v2(url.fileSystemRepresentation, &markerReadDatabase,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
                if (markerReadDatabase) sqlite3_close_v2(markerReadDatabase);
                markerReadDatabase = NULL;
                return SQLITE_ERROR;
            }
            sqlite3_busy_timeout(markerReadDatabase, 30);
            if (sqlite3_prepare_v2(markerReadDatabase,
                    "SELECT 1 FROM retained WHERE store=? AND kind=? AND chat=? AND message=?",
                    -1, &markerReadStatement, NULL) != SQLITE_OK) {
                BOOL uninitialized = strstr(sqlite3_errmsg(markerReadDatabase), "no such table: retained") != NULL;
                sqlite3_close_v2(markerReadDatabase);
                markerReadDatabase = NULL;
                markerReadStatement = NULL;
                return uninitialized ? SQLITE_DONE : SQLITE_ERROR;
            }
        }
        sqlite3_reset(markerReadStatement);
        sqlite3_clear_bindings(markerReadStatement);
        result = SQLITE_OK;
        for (NSUInteger i = 0; result == SQLITE_OK && i < key.count; i++) {
            NSData *bytes = [key[i] dataUsingEncoding:NSUTF8StringEncoding];
            result = bytes && bytes.length <= INT_MAX
                ? sqlite3_bind_text(markerReadStatement, (int)i + 1, bytes.bytes ?: "", (int)bytes.length, SQLITE_TRANSIENT)
                : SQLITE_MISMATCH;
        }
        if (result == SQLITE_OK) result = sqlite3_step(markerReadStatement);
        if (result == SQLITE_ROW) *retained = YES;
        else if (result == SQLITE_DONE) *retained = NO;
        sqlite3_reset(markerReadStatement);
        sqlite3_clear_bindings(markerReadStatement);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return result;
}
static void ScheduleMarkerRead(NSArray<NSString *> *key) {
    InitializeMarkerLookup();
    uint64_t generation;
    os_unfair_lock_lock(&markerCacheLock);
    if ([markerLookupCache objectForKey:key]) { os_unfair_lock_unlock(&markerCacheLock); return; }
    generation = markerCacheGeneration;
    NSNumber *pendingGeneration = markerLookupPending[key];
    if ((pendingGeneration && pendingGeneration.unsignedLongLongValue == generation) || markerLookupPending.count >= 128) {
        os_unfair_lock_unlock(&markerCacheLock);
        return;
    }
    markerLookupPending[key] = @(generation);
    os_unfair_lock_unlock(&markerCacheLock);
    dispatch_async(markerReadQueue, ^{
        @autoreleasepool {
            BOOL retained = NO;
            int status = ReadMarkerOnQueue(key, &retained);
            BOOL completed = status == SQLITE_ROW || status == SQLITE_DONE;
            os_unfair_lock_lock(&markerCacheLock);
            if ([markerLookupPending[key] unsignedLongLongValue] == generation) [markerLookupPending removeObjectForKey:key];
            if (completed && markerCacheGeneration == generation) [markerLookupCache setObject:@(retained) forKey:key];
            os_unfair_lock_unlock(&markerCacheLock);
#if TARGET_OS_IPHONE
            if (completed && retained) dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter postNotificationName:RUINRetainedMediaDidChangeNotification object:key];
                });
#endif
        }
    });
}
static BOOL OpenMarkers(BOOL create) {
    if (markerDatabase) return YES;
    NSURL *url = MarkerURL();
    if (!url) return NO;
    if (!create && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
#if TARGET_OS_IPHONE
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
                                 ofItemAtPath:url.URLByDeletingLastPathComponent.path error:NULL];
#endif
    if (sqlite3_open_v2(url.fileSystemRepresentation, &markerDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(markerDatabase, 250);
        if (sqlite3_exec(markerDatabase, "CREATE TABLE IF NOT EXISTS retained(store TEXT,kind TEXT,chat TEXT,message TEXT,PRIMARY KEY(store,kind,chat,message))", NULL, NULL, NULL) == SQLITE_OK) return YES;
    }
    if (markerDatabase) sqlite3_close_v2(markerDatabase);
    markerDatabase = NULL; return NO;
}
static BOOL RetainedMarker(NSDictionary *key, BOOL write) {
    BOOL result = NO;
    os_unfair_lock_lock(&markerLock);
    @try {
        if (!OpenMarkers(write)) return NO;
        sqlite3_stmt *statement = NULL;
        int status = sqlite3_prepare_v2(markerDatabase, write ? "INSERT OR IGNORE INTO retained VALUES(?,?,?,?)" :
            "SELECT 1 FROM retained WHERE store=? AND kind=? AND chat=? AND message=?", -1, &statement, NULL);
        for (NSUInteger i = 0; status == SQLITE_OK && i < 4; i++) {
            NSData *data = [key[@[@"store", @"kind", @"chat", @"message"][i]] dataUsingEncoding:NSUTF8StringEncoding];
            status = data && data.length <= INT_MAX ? sqlite3_bind_text(statement, (int)i + 1, data.bytes ?: "", (int)data.length, SQLITE_TRANSIENT) : SQLITE_MISMATCH;
        }
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        result = status == (write ? SQLITE_DONE : SQLITE_ROW);
        sqlite3_finalize(statement);
        if (write && result) InvalidateMarkerCache(MarkerStoredKey(key));
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return result;
}
%group RUINUnsendFetch
%hook NSManagedObjectContext
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error {
    NSManagedObjectContext *context = self;
    fetchDepth++;
    @try {
        atomic_fetch_add(&fetchCalls, 1);
        NSArray *actual = %orig;
        if (atomic_load(&line14Mode)) return fetchDepth == 1 ? L14FilterFetch(request, actual) : actual;
        if (fetchDepth != 1 || !Enabled() || actual.count != 1) return actual;
        @try {
            NSString *requested = RequestedMessage(request);
            if (!requested || !InUnsendLookup()) return actual;
            atomic_fetch_add(&scopedLookups, 1);
            NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
            NSDictionary *operation = thread[OperationThreadKey];
            [thread removeObjectForKey:OperationThreadKey];
            id object = actual.firstObject;
            Class messageClass = objc_getClass("ManagedMessage");
            if (!messageClass || ![object isKindOfClass:messageClass] || ![object isKindOfClass:NSManagedObject.class] ||
                ((NSManagedObject *)object).managedObjectContext != context || ((NSManagedObject *)object).isDeleted) {
                atomic_fetch_add(&rejectedLookups, 1); return actual;
            }
            NSDictionary *key = RUINHistoryMessageKey(object);
            if (![key[@"kind"] isEqual:@"talk"] || ![key[@"message"] isEqual:requested] ||
                ![operation[@"message"] isEqual:requested] || ![operation[@"chat"] isEqual:key[@"chat"]]) {
                atomic_fetch_add(&rejectedLookups, 1); return actual;
            }
            if (!RetainedMarker(key, YES)) { atomic_fetch_add(&markerFailures, 1); return actual; }
#if TARGET_OS_IPHONE
            RUINCaptureRetainedMedia(object, key);
#endif
            // Freeze any earlier archive. A missing archive is never fabricated;
            // native original text is preserved by bypassing this local destroy.
            @try {
                RUINInstallMessageHistory();
                NSDictionary *snapshot = RUINHistoryRetainUnsentSnapshotForKey(key);
                if (snapshot.count && ![snapshot[@"originalUnavailable"] boolValue]) atomic_fetch_add(&historyFreezes, 1);
            } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
            atomic_fetch_add(&protectedMessages, 1);
            return @[];
        } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
        return actual;
    } @finally { fetchDepth--; }

}
%end
%end
%group RUINUnsendDisplay
%hook RUINUnsendDisplayedMessage
- (id)displayedText {
    id object = self;
    BOOL outermost = displayDepth++ == 0;
    @try {
        id actual = %orig;
        if (!outermost || !Enabled() || ![object isKindOfClass:NSManagedObject.class]) return actual;
        @try {
            NSManagedObject *message = object;
            NSManagedObjectContext *context = message.managedObjectContext;
            if (!context) return actual;
            __block NSString *text;
            [context performBlockAndWait:^{
                NSDictionary *key = RUINHistoryMessageKey(message);
                if (!key.count || !RetainedMarker(key, NO) || message.entity.attributesByName[@"contentType"].attributeType != NSInteger16AttributeType ||
                    [[message valueForKey:@"contentType"] shortValue] != 0) return;
                Method getter = class_getInstanceMethod(object_getClass(message), sel_registerName("plaintext"));
                if (!getter || strcmp(method_getTypeEncoding(getter), "@16@0:8")) return;
                id value = [(id<RUINMessagingMessageFields>)message plaintext];
                if ([value isKindOfClass:NSString.class] && [value length]) text = [value copy];
            }];
            if (text) { atomic_fetch_add(&displayReturns, 1); return [text stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"media.unsent_badge")]; }
        } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
        return actual;
    } @finally { displayDepth--; }

}
%end
%end
static void InstallOperationHook(Class cls, const char *name, const char *encoding, atomic_int *status, void (^initialize)(Class)) {
    if (atomic_load(status) == OperationHookInstalled) return;
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), encoding) || !method_getImplementation(method)) {
        atomic_store(status, OperationHookUnavailable);
        return;
    }
    initialize(cls);
    atomic_store(status, OperationHookInstalled);
}
// ---- LINE 14.6.3 port: unsend retention without address anchors ----
// 14.6.3 has no verified address mapping. The incoming destroy operation
// (type 65, param2 = message ID) is recorded when its Thrift struct finishes
// decoding; for a short window, only fetches that explicitly constrain
// `id` to that message, and deleteObject: of that exact message, are
// intercepted. Everything else (and type 64, own unsend) stays native.
static os_unfair_lock l14Lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSDictionary *> *l14Pending;
static NSMutableArray<NSDictionary *> *l14Events;
static atomic_uint_fast64_t l14PendingCount, l14Ops, l14OwnOps, l14RejectedOps, l14Protected, l14DeleteSkips, l14BatchDeletes, l14Errors;
static atomic_int l14ReadStatus, l14DeleteStatus, l14BatchStatus;
static const void *l14Base;
static uintptr_t l14Slide;
static const double L14PendingSeconds = 120;

static BOOL L14Eligible(void) {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && [version hasPrefix:@"14."] && TargetMatches();
}
static NSString *L14Thread(void) {
    return [NSString stringWithFormat:@"%u%@", (unsigned)pthread_mach_thread_np(pthread_self()), NSThread.isMainThread ? @"m" : @""];
}
static NSArray<NSString *> *L14Frames(void) {
    void *frames[28];
    int count = backtrace(frames, 28);
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 2; i < count; i++) {
        Dl_info info;
        if (!dladdr(frames[i], &info) || !info.dli_fbase) { [out addObject:@"?"]; continue; }
        if (info.dli_fbase == l14Base) {
            [out addObject:[NSString stringWithFormat:@"0x%lx", (unsigned long)((uintptr_t)frames[i] - l14Slide)]];
        } else {
            const char *name = info.dli_fname ? (strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname) : "?";
            [out addObject:[NSString stringWithFormat:@"%s+0x%lx", name, (unsigned long)((uintptr_t)frames[i] - (uintptr_t)info.dli_fbase)]];
        }
    }
    return out;
}
static NSString *L14Redact(NSString *text, NSString *message) {
    if (![text isKindOfClass:NSString.class]) return @"";
    if (message.length) text = [text stringByReplacingOccurrencesOfString:message withString:@"<ID>"];
    static NSRegularExpression *tokens;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tokens = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z0-9]{12,}" options:0 error:NULL]; });
    text = [tokens stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"<X>"];
    return text.length > 300 ? [text substringToIndex:300] : text;
}
static void L14Event(NSDictionary *event) {
    os_unfair_lock_lock(&l14Lock);
    if (!l14Events) l14Events = [NSMutableArray array];
    if (l14Events.count < 30) [l14Events addObject:event];
    os_unfair_lock_unlock(&l14Lock);
}
static NSDictionary *L14PendingFor(NSString *message) {
    if (!message) return nil;
    os_unfair_lock_lock(&l14Lock);
    NSDictionary *entry = l14Pending[message];
    if (entry && CFAbsoluteTimeGetCurrent() - [entry[@"time"] doubleValue] > L14PendingSeconds) {
        [l14Pending removeObjectForKey:message];
        atomic_store(&l14PendingCount, l14Pending.count);
        entry = nil;
    }
    os_unfair_lock_unlock(&l14Lock);
    return entry;
}
static NSArray<NSString *> *L14PendingIDs(void) {
    os_unfair_lock_lock(&l14Lock);
    NSArray *ids = l14Pending.allKeys ?: @[];
    os_unfair_lock_unlock(&l14Lock);
    return ids;
}
static void L14AddPending(NSString *message, NSString *chat, NSString *thread) {
    os_unfair_lock_lock(&l14Lock);
    if (!l14Pending) l14Pending = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (NSString *old in l14Pending.allKeys)
        if (now - [l14Pending[old][@"time"] doubleValue] > L14PendingSeconds) [l14Pending removeObjectForKey:old];
    if (l14Pending.count < 256) l14Pending[message] = @{@"chat":chat ?: @"", @"time":@(now), @"thread":thread ?: @""};
    atomic_store(&l14PendingCount, l14Pending.count);
    os_unfair_lock_unlock(&l14Lock);
}
static NSString *L14MessageID(id value) {
    if ([value isKindOfClass:NSNumber.class]) value = [value stringValue];
    return MessageID(value);
}
static void L14CollectIDs(NSPredicate *predicate, NSMutableSet<NSString *> *ids) {
    if ([predicate isKindOfClass:NSCompoundPredicate.class]) {
        NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
        if (compound.compoundPredicateType != NSAndPredicateType) return;
        for (NSPredicate *sub in compound.subpredicates) L14CollectIDs(sub, ids);
        return;
    }
    if (![predicate isKindOfClass:NSComparisonPredicate.class]) return;
    NSComparisonPredicate *p = (NSComparisonPredicate *)predicate;
    if (p.comparisonPredicateModifier != NSDirectPredicateModifier) return;
    NSExpression *left = p.leftExpression, *right = p.rightExpression;
    if (left.expressionType == NSConstantValueExpressionType) { NSExpression *swap = left; left = right; right = swap; }
    if (left.expressionType != NSKeyPathExpressionType || right.expressionType != NSConstantValueExpressionType ||
        ![left.keyPath isEqual:@"id"]) return;
    id constant = right.constantValue;
    if (p.predicateOperatorType == NSEqualToPredicateOperatorType) {
        NSString *message = L14MessageID(constant);
        if (message) [ids addObject:message];
    } else if (p.predicateOperatorType == NSInPredicateOperatorType &&
               ([constant isKindOfClass:NSArray.class] || [constant isKindOfClass:NSSet.class])) {
        for (id value in constant) { NSString *message = L14MessageID(value); if (message) [ids addObject:message]; }
    }
}
static BOOL L14Protect(NSManagedObject *object, NSDictionary *key, NSDictionary *pending, NSString *how) {
    (void)object;
    BOOL marker = RetainedMarker(key, YES);
    if (!marker) atomic_fetch_add(&markerFailures, 1);
#if TARGET_OS_IPHONE
    @try { RUINCaptureRetainedMedia(object, key); } @catch (__unused NSException *exception) { atomic_fetch_add(&l14Errors, 1); }
#endif
    @try {
        RUINInstallMessageHistory();
        NSDictionary *snapshot = RUINHistoryRetainUnsentSnapshotForKey(key);
        if (snapshot.count && ![snapshot[@"originalUnavailable"] boolValue]) atomic_fetch_add(&historyFreezes, 1);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&l14Errors, 1); }
    NSString *thread = L14Thread();
    L14Event(@{@"ev":how, @"thread":thread, @"sameThreadAsOp":@([pending[@"thread"] isEqual:thread]),
        @"chatMatches":@([pending[@"chat"] isEqual:key[@"chat"]]), @"marker":@(marker), @"frames":L14Frames()});
    return marker;
}
static NSArray *L14FilterFetch(NSFetchRequest *request, NSArray *actual) {
    if (!atomic_load(&l14PendingCount) || !actual.count || !Enabled()) return actual;
    @try {
        if (request.resultType != NSManagedObjectResultType) return actual;
        NSMutableSet<NSString *> *ids = [NSMutableSet set];
        L14CollectIDs(request.predicate, ids);
        if (!ids.count) {
            NSString *format = request.predicate.predicateFormat;
            for (NSString *message in L14PendingIDs()) if ([format containsString:message]) {
                L14Event(@{@"ev":@"fetchNotParsed", @"entity":request.entityName ?: @"", @"pred":L14Redact(format, message),
                    @"count":@(actual.count), @"thread":L14Thread(), @"frames":L14Frames()});
                break;
            }
            return actual;
        }
        Class messageClass = objc_getClass("ManagedMessage");
        NSMutableIndexSet *remove = nil;
        for (NSUInteger i = 0; i < actual.count; i++) {
            id object = actual[i];
            if (!messageClass || ![object isKindOfClass:messageClass] || ((NSManagedObject *)object).isDeleted) continue;
            NSDictionary *key = RUINHistoryMessageKey(object);
            NSString *message = key[@"message"];
            NSDictionary *pending = [ids containsObject:message ?: @""] ? L14PendingFor(message) : nil;
            if (!pending) continue;
            L14Protect(object, key, pending, @"fetchEmptied");
            atomic_fetch_add(&l14Protected, 1);
            if (!remove) remove = [NSMutableIndexSet indexSet];
            [remove addIndex:i];
        }
        if (!remove.count) return actual;
        NSMutableArray *kept = [actual mutableCopy];
        [kept removeObjectsAtIndexes:remove];
        return [kept copy];
    } @catch (__unused NSException *exception) { atomic_fetch_add(&l14Errors, 1); }
    return actual;
}
%group RUINUnsendL14Read
%hook RUINUnsendL14Operation
- (void)read:(id)protocol {
    %orig;
    @try {
        id<RUINMessagingOperationFields> operation = (id)self;
        long long type = [operation type];
        if (type != 64 && type != 65) return;
        if (!Enabled()) return;
        atomic_fetch_add(&l14Ops, 1);
        if (type == 64) { atomic_fetch_add(&l14OwnOps, 1); return; }
        NSString *message = L14MessageID([operation param2]);
        id chat = [operation param1];
        id silent = [operation param3];
        if (!message) { atomic_fetch_add(&l14RejectedOps, 1); return; }
        NSString *thread = L14Thread();
        L14AddPending(message, [chat isKindOfClass:NSString.class] ? [chat copy] : @"", thread);
        L14Event(@{@"ev":@"op65", @"thread":thread,
            @"chatKind":[chat isKindOfClass:NSString.class] && [chat length] ? [chat substringToIndex:1] : @"-",
            @"param3":[silent isKindOfClass:NSString.class] && [silent length] <= 4 ? silent : NSStringFromClass([silent class] ?: NSNull.class)});
    } @catch (__unused NSException *exception) { atomic_fetch_add(&l14Errors, 1); }
}
%end
%end
%group RUINUnsendL14Delete
%hook NSManagedObjectContext
- (void)deleteObject:(NSManagedObject *)object {
    if (atomic_load(&l14PendingCount) && Enabled()) {
        @try {
            Class messageClass = objc_getClass("ManagedMessage");
            if (messageClass && [object isKindOfClass:messageClass]) {
                NSDictionary *key = RUINHistoryMessageKey(object);
                NSDictionary *pending = L14PendingFor(key[@"message"]);
                if (pending) {
                    L14Protect(object, key, pending, @"deleteSkipped");
                    atomic_fetch_add(&l14DeleteSkips, 1);
                    return;
                }
            }
        } @catch (__unused NSException *exception) { atomic_fetch_add(&l14Errors, 1); }
    }
    %orig;
}
%end
%end
%group RUINUnsendL14Batch
%hook NSManagedObjectContext
- (id)executeRequest:(NSPersistentStoreRequest *)request error:(NSError **)error {
    if (atomic_load(&l14PendingCount) && [request isKindOfClass:NSBatchDeleteRequest.class]) {
        @try {
            NSFetchRequest *fetch = ((NSBatchDeleteRequest *)request).fetchRequest;
            atomic_fetch_add(&l14BatchDeletes, 1);
            L14Event(@{@"ev":@"batchDelete", @"entity":fetch.entityName ?: @"", @"pred":L14Redact(fetch.predicate.predicateFormat, nil),
                @"thread":L14Thread(), @"frames":L14Frames()});
        } @catch (__unused NSException *exception) { atomic_fetch_add(&l14Errors, 1); }
    }
    return %orig;
}
%end
%end
static void InitFetchGroup(void) { %init(RUINUnsendFetch); }
static void InitDisplayGroup(Class cls) { %init(RUINUnsendDisplay, RUINUnsendDisplayedMessage = cls); }
static void InstallLine14(void) {
    atomic_store(&line14Mode, YES);
    Class operation = objc_getClass("LineOperation");
    Dl_info info;
    if (operation && dladdr((__bridge const void *)operation, &info) && info.dli_fbase) {
        l14Base = info.dli_fbase;
        l14Slide = (uintptr_t)info.dli_fbase - 0x100000000ULL;
    }
    InstallOperationHook(NSManagedObjectContext.class, "executeFetchRequest:error:", "@32@0:8@16^@24", &fetchStatus, ^(__unused Class cls) { InitFetchGroup(); });
    InstallOperationHook(objc_getClass("ManagedMessage"), "displayedText", "@16@0:8", &displayStatus, ^(Class cls) { InitDisplayGroup(cls); });
    InstallOperationHook(operation, "read:", "v24@0:8@16", &l14ReadStatus, ^(Class cls) {
        %init(RUINUnsendL14Read, RUINUnsendL14Operation = cls);
    });
    InstallOperationHook(NSManagedObjectContext.class, "deleteObject:", "v24@0:8@16", &l14DeleteStatus, ^(__unused Class cls) {
        %init(RUINUnsendL14Delete);
    });
    InstallOperationHook(NSManagedObjectContext.class, "executeRequest:error:", "@32@0:8@16^@24", &l14BatchStatus, ^(__unused Class cls) {
        %init(RUINUnsendL14Batch);
    });
}
static NSDictionary *L14Diagnostics(void) {
    NSArray *statuses = @[@"pending", @"gated", @"missing_or_encoding_mismatch", @"installed"];
    os_unfair_lock_lock(&l14Lock);
    NSArray *events = [l14Events copy] ?: @[];
    os_unfair_lock_unlock(&l14Lock);
    return @{@"mode":@(atomic_load(&line14Mode)), @"readHook":statuses[atomic_load(&l14ReadStatus)],
        @"deleteHook":statuses[atomic_load(&l14DeleteStatus)], @"batchHook":statuses[atomic_load(&l14BatchStatus)],
        @"destroyOps":@(atomic_load(&l14Ops)), @"ownDestroyOps":@(atomic_load(&l14OwnOps)), @"rejectedOps":@(atomic_load(&l14RejectedOps)),
        @"pending":@(atomic_load(&l14PendingCount)), @"fetchProtected":@(atomic_load(&l14Protected)),
        @"deleteSkips":@(atomic_load(&l14DeleteSkips)), @"batchDeletes":@(atomic_load(&l14BatchDeletes)),
        @"errors":@(atomic_load(&l14Errors)), @"events":events};
}
void RUINInstallUnsendOperation(void) {
    os_unfair_lock_lock(&installLock);
    @try {
        RUIN_PROFILE_BEGIN("unsend.verify_code");
        BOOL valid = VerifyCode();
        RUIN_PROFILE_END(valid ? RUINProfileStatusOK : RUINProfileStatusFailed);
        atomic_store(&codeVerified, valid);
        if (!valid) {
            if (atomic_load(&fetchStatus) != OperationHookInstalled) atomic_store(&fetchStatus, OperationHookGated);
            if (atomic_load(&displayStatus) != OperationHookInstalled) atomic_store(&displayStatus, OperationHookGated);
            if (atomic_load(&param1Status) != OperationHookInstalled) atomic_store(&param1Status, OperationHookGated);
            RUIN_PROFILE_INSTANT("unsend.hooks_gated", RUINProfileStatusSkipped);
            if (L14Eligible()) InstallLine14();
            return;
        }
        RUIN_PROFILE_BEGIN("unsend.install_hooks");
        InstallOperationHook(NSManagedObjectContext.class, "executeFetchRequest:error:", "@32@0:8@16^@24", &fetchStatus, ^(__unused Class cls) { InitFetchGroup(); });
        InstallOperationHook(objc_getClass("ManagedMessage"), "displayedText", "@16@0:8", &displayStatus, ^(Class cls) { InitDisplayGroup(cls); });
        InstallOperationHook(objc_getClass("LineOperation"), "param1", "@16@0:8", &param1Status, ^(Class cls) {
            %init(RUINUnsendParam1, RUINUnsendParsedOperation = cls);
        });
        RUIN_PROFILE_END(RUINProfileStatusOK);
    } @finally { os_unfair_lock_unlock(&installLock); }
}
__attribute__((constructor)) static void EarlyUnsendOperation(void) { @autoreleasepool { RUINInstallUnsendOperation(); } }
BOOL RUINClearUnsendOperationMarkers(void) {
    os_unfair_lock_lock(&markerLock);
    @try {
        NSURL *url = MarkerURL();
        if (!url) return NO;
        if (!markerDatabase && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            InvalidateMarkerCache(nil);
            return YES;
        }
        if (!OpenMarkers(NO)) return NO;
        BOOL cleared = sqlite3_exec(markerDatabase, "DELETE FROM retained", NULL, NULL, NULL) == SQLITE_OK;
        if (cleared) InvalidateMarkerCache(nil);
        return cleared;
    } @finally { os_unfair_lock_unlock(&markerLock); }
}
BOOL RUINUnsendOperationHasRetainedMarker(NSDictionary *messageKey) {
    if (!Enabled() || ![messageKey isKindOfClass:NSDictionary.class]) return NO;
    @try {
        NSArray<NSString *> *key = MarkerQueryKey(messageKey);
        if (!key) return NO;
        BOOL retained = NO;
        if (CachedMarker(key, &retained)) return retained;
        ScheduleMarkerRead(key);
        return NO;
    } @catch (__unused NSException *exception) { return NO; }
}
NSDictionary *RUINUnsendOperationDiagnostics(void) {
    long long count = 0;
    // Report feature-local selection, never re-enter the process-main resolver
    // from diagnostics (LC's process executable is not the LINE guest).
    os_unfair_lock_lock(&installLock);
    const RUINUnsendOperationMapping *operationMapping = atomic_load(&selectedUnsendMapping);
    BOOL verified = atomic_load(&codeVerified);
    BOOL scopeVerified = verified && atomic_load(&activeUnsendMapping) != NULL;
    NSString *resolution = imageResolution;
    BOOL fingerprint = imageFingerprintVerified;
    BOOL proofRetained = unsendImageVersion != NULL;
    BOOL loaderPinned = unsendImage.loaderReference != NULL;
    BOOL converted = unsendImage.convertedExecutable;
    os_unfair_lock_unlock(&installLock);
    os_unfair_lock_lock(&markerLock);
    @try {
        sqlite3_stmt *statement = NULL;
        if (markerDatabase && sqlite3_prepare_v2(markerDatabase, "SELECT count(*) FROM retained", -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
            count = sqlite3_column_int64(statement, 0);
        sqlite3_finalize(statement);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    NSArray *statuses = @[@"pending", @"gated", @"missing_or_encoding_mismatch", @"installed"];
    return @{@"enabled":@(Enabled()), @"targetSupported":@(TargetMatches()), @"nativeCodeVerified":@(verified),
        @"featureImageResolution":resolution, @"featureImageProofRetained":@(proofRetained),
        @"featureImageLoaderPinned":@(loaderPinned), @"featureImageConvertedExecutable":@(converted),
        @"featureImageFingerprintVerified":@(fingerprint),
        @"retentionMappingSupported":@(operationMapping && operationMapping->orderedLookupReturnAddressCount != 0),
        @"lookupScopeVerified":@(scopeVerified),
        @"codeAnchorCount":@(operationMapping ? operationMapping->parserAnchorCount : 0),
        @"fetchHook":statuses[atomic_load(&fetchStatus)], @"fetchEncoding":@"@32@0:8@16^@24",
        @"displayHook":statuses[atomic_load(&displayStatus)], @"displayEncoding":@"@16@0:8",
        @"operationParam1Hook":statuses[atomic_load(&param1Status)], @"operationParam1Encoding":@"@16@0:8",
        @"capturedOperations":@(atomic_load(&capturedOperations)), @"rejectedOperations":@(atomic_load(&rejectedOperations)),
        @"fetchCalls":@(atomic_load(&fetchCalls)), @"scopedLookups":@(atomic_load(&scopedLookups)),
        @"protectedMessages":@(atomic_load(&protectedMessages)), @"rejectedLookups":@(atomic_load(&rejectedLookups)),
        @"markerFailures":@(atomic_load(&markerFailures)), @"historyFreezes":@(atomic_load(&historyFreezes)),
        @"line14":L14Diagnostics(),
        @"displayReplacementReturns":@(atomic_load(&displayReturns)), @"inspectionErrors":@(atomic_load(&observationErrors)), @"markerCount":@(count),
        @"operationMapping":@"current parser: 64 sender / 65 others; param1 chat, param2 positive message ID, param3 exactly 1 silent",
        @"boundary":@"original fetch once; verified ordered server destroy-operation lookup for types 64/65 alone receives empty result before local cleanup/delete/tombstone",
        @"identity":@"native parser param1/param2 copied on its callback thread, consumed once at exact lookup; permanent result must match operation chat+ID and predicate ID; marker binds actual store/kind/chat/message",
        @"nativeABIPatched":@NO, @"deleteObjectGloballySuppressed":@NO, @"deviceRetentionVerified":@NO,
        @"limitations":@"server destroy route only; normal own text was verified separately on device; full-route parity is not inferred. Other routes, OpenChat and media bytes still need validation"};
}
