#import "StartupProfiler.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>

// Startup profiler: records one armed launch from the RUIN constructor to the
// first UIApplicationDidBecomeActive, then writes a JSON log asynchronously.
// Events live in a fixed static buffer; nothing is written to disk and no
// Objective-C objects are allocated on the recording path, so the overhead per
// span is a clock read plus a short unfair-lock critical section. When the
// profiler is not armed, every entry point returns after one atomic load.

NSString *const RUINStartupProfileRecordNextLaunchDefaultsKey = @"RUINStartupProfileRecordNextLaunch";

static NSString *const RUINStartupProfileLastStatusKey = @"RUINStartupProfileLastStatus";
static NSString *const RUINStartupProfileLastEventCountKey = @"RUINStartupProfileLastEventCount";
static NSString *const RUINStartupProfileLastDroppedCountKey = @"RUINStartupProfileLastDroppedCount";
static NSString *const RUINStartupProfileLastTotalMsKey = @"RUINStartupProfileLastTotalMs";
static NSString *const RUINStartupProfileLastRecordedAtKey = @"RUINStartupProfileLastRecordedAt";

enum {
    RUINProfileEventCapacity = 2048,
    RUINProfileMaxDepth = 32,
};
static const NSTimeInterval RUINProfileWatchdogSeconds = 30.0;

extern NSString *const RUINVersion;

typedef struct {
    const char *name;
    uint64_t startNs;
    uint64_t endNs;
    uint64_t threadId;
    uint32_t depth;
    uint32_t status;
    uint32_t kind; // 0 = span, 1 = instant
    uint32_t sequence;
} RUINProfileEventRecord;

static RUINProfileEventRecord sEvents[RUINProfileEventCapacity];
static uint32_t sEventCount;
static uint32_t sDroppedCount;
static uint32_t sSequence;
static os_unfair_lock sEventsLock = OS_UNFAIR_LOCK_INIT;

static atomic_bool sLaunchBegun;
static atomic_bool sRecording;
static atomic_bool sFinalized;
static uint64_t sT0Ns;
static uint64_t sActiveNs;
static mach_timebase_info_data_t sTimebase;
static id sBackgroundObserver;

static __thread uint32_t sSpanStack[RUINProfileMaxDepth];
static __thread uint32_t sSpanDepth;

static uint64_t RUINProfileNowNs(void) {
    uint64_t ticks = mach_absolute_time();
    return ticks * sTimebase.numer / sTimebase.denom;
}

static NSString *RUINProfileStatusString(uint32_t status) {
    switch (status) {
        case RUINProfileStatusFailed: return @"failed";
        case RUINProfileStatusSkipped: return @"skipped";
        default: return @"ok";
    }
}

static NSString *RUINStartupProfileDirectory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return caches.length ? [caches stringByAppendingPathComponent:@"RUIN"] : nil;
}

static NSString *RUINStartupProfileLogPath(void) {
    NSString *directory = RUINStartupProfileDirectory();
    return directory ? [directory stringByAppendingPathComponent:@"startup-profile.json"] : nil;
}

void RUINProfileSpanBegin(const char *name) {
    if (!atomic_load_explicit(&sRecording, memory_order_relaxed)) return;
    uint64_t startNs = RUINProfileNowNs();
    uint64_t threadId = pthread_mach_thread_np(pthread_self());
    uint32_t depth = sSpanDepth;
    uint32_t index = UINT32_MAX;
    os_unfair_lock_lock(&sEventsLock);
    if (sEventCount < RUINProfileEventCapacity) {
        index = sEventCount++;
        RUINProfileEventRecord *event = &sEvents[index];
        event->name = name;
        event->startNs = startNs;
        event->endNs = 0;
        event->threadId = threadId;
        event->depth = depth;
        event->status = RUINProfileStatusOK;
        event->kind = 0;
        event->sequence = sSequence++;
    } else {
        sDroppedCount++;
    }
    os_unfair_lock_unlock(&sEventsLock);
    if (sSpanDepth < RUINProfileMaxDepth) sSpanStack[sSpanDepth] = index;
    sSpanDepth++;
}

void RUINProfileSpanEnd(RUINProfileStatus status) {
    if (!atomic_load_explicit(&sRecording, memory_order_relaxed)) return;
    if (!sSpanDepth) return;
    sSpanDepth--;
    if (sSpanDepth >= RUINProfileMaxDepth) return;
    uint32_t index = sSpanStack[sSpanDepth];
    if (index == UINT32_MAX) return;
    uint64_t endNs = RUINProfileNowNs();
    os_unfair_lock_lock(&sEventsLock);
    if (index < sEventCount && !sEvents[index].endNs) {
        sEvents[index].endNs = endNs;
        sEvents[index].status = (uint32_t)status;
    }
    os_unfair_lock_unlock(&sEventsLock);
}

void RUINProfileInstant(const char *name, RUINProfileStatus status) {
    if (!atomic_load_explicit(&sRecording, memory_order_relaxed)) return;
    uint64_t nowNs = RUINProfileNowNs();
    uint64_t threadId = pthread_mach_thread_np(pthread_self());
    os_unfair_lock_lock(&sEventsLock);
    if (sEventCount < RUINProfileEventCapacity) {
        RUINProfileEventRecord *event = &sEvents[sEventCount++];
        event->name = name;
        event->startNs = nowNs;
        event->endNs = nowNs;
        event->threadId = threadId;
        event->depth = sSpanDepth;
        event->status = (uint32_t)status;
        event->kind = 1;
        event->sequence = sSequence++;
    } else {
        sDroppedCount++;
    }
    os_unfair_lock_unlock(&sEventsLock);
}

static void RUINStartupProfileFinalize(NSString *status) {
    if (!atomic_load_explicit(&sRecording, memory_order_relaxed)) return;
    if (atomic_exchange_explicit(&sFinalized, true, memory_order_acq_rel)) return;
    uint64_t endNs = RUINProfileNowNs();
    atomic_store_explicit(&sRecording, false, memory_order_relaxed);
    if (sBackgroundObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:sBackgroundObserver];
        sBackgroundObserver = nil;
    }

    os_unfair_lock_lock(&sEventsLock);
    uint32_t count = sEventCount;
    uint32_t dropped = sDroppedCount;
    RUINProfileEventRecord *snapshot = malloc(sizeof(RUINProfileEventRecord) * (count ?: 1));
    if (snapshot) memcpy(snapshot, sEvents, sizeof(RUINProfileEventRecord) * count);
    os_unfair_lock_unlock(&sEventsLock);
    if (!snapshot) return;

    // Chronological order by start time; sequence breaks ties deterministically.
    qsort_b(snapshot, count, sizeof(RUINProfileEventRecord), ^int(const void *a, const void *b) {
        const RUINProfileEventRecord *left = a, *right = b;
        if (left->startNs != right->startNs) return left->startNs < right->startNs ? -1 : 1;
        return left->sequence < right->sequence ? -1 : (left->sequence > right->sequence);
    });

    NSMutableArray *events = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        const RUINProfileEventRecord *event = &snapshot[i];
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"name"] = event->name ? [NSString stringWithUTF8String:event->name] : @"unknown";
        row[@"type"] = event->kind ? @"instant" : @"span";
        row[@"startMs"] = @((double)(event->startNs - sT0Ns) / 1.0e6);
        if (event->endNs) {
            row[@"endMs"] = @((double)(event->endNs - sT0Ns) / 1.0e6);
            row[@"durationMs"] = @((double)(event->endNs - event->startNs) / 1.0e6);
            row[@"status"] = RUINProfileStatusString(event->status);
        } else {
            // Span still open when recording ended: measurement is incomplete.
            row[@"endMs"] = NSNull.null;
            row[@"durationMs"] = NSNull.null;
            row[@"status"] = @"incomplete";
        }
        row[@"threadId"] = @(event->threadId);
        row[@"depth"] = @(event->depth);
        [events addObject:row];
    }
    free(snapshot);

    double totalMs = (double)((sActiveNs ?: endNs) - sT0Ns) / 1.0e6;
    NSDate *recordedAt = NSDate.date;
    NSDictionary *document = @{
        @"format": @"ruin.startup-profile",
        @"version": @1,
        @"ruinVersion": RUINVersion ?: @"unknown",
        @"recordedAt": [[NSISO8601DateFormatter new] stringFromDate:recordedAt] ?: @"",
        @"status": status,
        @"completionCriterion": @"first UIApplicationDidBecomeActive after RUIN constructor entry",
        @"clock": @"mach_absolute_time (monotonic)",
        @"t0": @"RUINConstructor entry; process start and dyld time are not included",
        @"totalStartupMs": @(totalMs),
        @"eventCount": @(count),
        @"droppedEventCount": @(dropped),
        @"truncated": @(dropped > 0),
        @"notes": @[
            @"Events from dylib constructors that run before the RUIN constructor are not captured.",
            @"Events include the install wave that runs inside the first DidBecomeActive handler.",
            @"No account identifiers, message content or credentials are recorded."
        ],
        @"events": events
    };

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:status forKey:RUINStartupProfileLastStatusKey];
    [defaults setInteger:count forKey:RUINStartupProfileLastEventCountKey];
    [defaults setInteger:dropped forKey:RUINStartupProfileLastDroppedCountKey];
    [defaults setDouble:totalMs forKey:RUINStartupProfileLastTotalMsKey];
    [defaults setObject:recordedAt forKey:RUINStartupProfileLastRecordedAtKey];

    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.tqmane.ruin.startup-profile", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        NSString *directory = RUINStartupProfileDirectory();
        if (!directory) return;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:NULL]) return;
        NSData *data = [NSJSONSerialization dataWithJSONObject:document
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        if (data) [data writeToFile:RUINStartupProfileLogPath() options:NSDataWritingAtomic error:NULL];
    });
}

void RUINStartupProfileBeginLaunch(void) {
    if (atomic_exchange_explicit(&sLaunchBegun, true, memory_order_acq_rel)) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:RUINStartupProfileRecordNextLaunchDefaultsKey]) return;
    // Consume the flag first so exactly one launch is recorded.
    [defaults removeObjectForKey:RUINStartupProfileRecordNextLaunchDefaultsKey];
    mach_timebase_info(&sTimebase);
    if (!sTimebase.denom) { sTimebase.numer = 1; sTimebase.denom = 1; }
    sT0Ns = RUINProfileNowNs();
    atomic_store_explicit(&sRecording, true, memory_order_relaxed);
    RUINProfileSpanBegin("ruin.constructor");
    sBackgroundObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
        usingBlock:^(NSNotification *notification) {
            (void)notification;
            RUINStartupProfileFinalize(@"incomplete");
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RUINProfileWatchdogSeconds * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            RUINStartupProfileFinalize(@"timeout");
        });
}

void RUINStartupProfileFinishConstructor(void) {
    RUINProfileSpanEnd(RUINProfileStatusOK);
}

void RUINStartupProfileMarkActive(void) {
    if (!atomic_load_explicit(&sRecording, memory_order_relaxed)) return;
    if (sActiveNs) return;
    sActiveNs = RUINProfileNowNs();
    RUINProfileInstant("app.did_become_active", RUINProfileStatusOK);
}

void RUINStartupProfileFinishActivation(void) {
    if (!sActiveNs) return;
    RUINStartupProfileFinalize(@"complete");
}

NSDictionary<NSString *, id> *RUINStartupProfileSummary(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *status = [defaults stringForKey:RUINStartupProfileLastStatusKey];
    NSDate *recordedAt = [defaults objectForKey:RUINStartupProfileLastRecordedAtKey];
    return @{
        @"armed": @([defaults boolForKey:RUINStartupProfileRecordNextLaunchDefaultsKey]),
        @"hasLog": @([NSFileManager.defaultManager fileExistsAtPath:RUINStartupProfileLogPath() ?: @""]),
        @"status": status ?: @"none",
        @"eventCount": @([defaults integerForKey:RUINStartupProfileLastEventCountKey]),
        @"droppedEventCount": @([defaults integerForKey:RUINStartupProfileLastDroppedCountKey]),
        @"totalMs": @([defaults doubleForKey:RUINStartupProfileLastTotalMsKey]),
        @"recordedAt": [recordedAt isKindOfClass:NSDate.class] ? recordedAt : NSNull.null
    };
}

NSURL *RUINStartupProfileSavedLogURL(void) {
    NSString *path = RUINStartupProfileLogPath();
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path];
}

NSDictionary<NSString *, id> *RUINStartupProfileLoadSavedLog(void) {
    NSString *path = RUINStartupProfileLogPath();
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

BOOL RUINStartupProfileDeleteSavedLog(void) {
    NSString *path = RUINStartupProfileLogPath();
    BOOL removed = !path || ![NSFileManager.defaultManager fileExistsAtPath:path] ||
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:RUINStartupProfileLastStatusKey];
    [defaults removeObjectForKey:RUINStartupProfileLastEventCountKey];
    [defaults removeObjectForKey:RUINStartupProfileLastDroppedCountKey];
    [defaults removeObjectForKey:RUINStartupProfileLastTotalMsKey];
    [defaults removeObjectForKey:RUINStartupProfileLastRecordedAtKey];
    return removed;
}
