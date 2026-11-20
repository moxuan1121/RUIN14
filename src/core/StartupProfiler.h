#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RUINProfileStatus) {
    RUINProfileStatusOK = 0,
    RUINProfileStatusFailed = 1,
    RUINProfileStatusSkipped = 2,
};

/// One-shot arming flag: when YES at dylib load, the next launch is recorded
/// once and the flag is consumed. Written from the RUIN settings screen.
extern NSString *const RUINStartupProfileRecordNextLaunchDefaultsKey;

// Lifecycle, driven from Tweak.x. All functions are safe no-ops when the
// profiler was not armed for this launch.
void RUINStartupProfileBeginLaunch(void);
void RUINStartupProfileFinishConstructor(void);
void RUINStartupProfileMarkActive(void);
void RUINStartupProfileFinishActivation(void);

// Settings support.
NSDictionary<NSString *, id> *RUINStartupProfileSummary(void);
NSURL *_Nullable RUINStartupProfileSavedLogURL(void);
NSDictionary<NSString *, id> *_Nullable RUINStartupProfileLoadSavedLog(void);
BOOL RUINStartupProfileDeleteSavedLog(void);

// Span primitives. Names must be string literals (they are stored as pointers).
void RUINProfileSpanBegin(const char *name);
void RUINProfileSpanEnd(RUINProfileStatus status);
void RUINProfileInstant(const char *name, RUINProfileStatus status);

NS_ASSUME_NONNULL_END

// Instrumentation macros. Under any host-check build they compile to nothing
// (except that RUIN_PROFILE_CALL still evaluates its expression exactly once),
// so host fixtures that compile production sources never see profiler symbols.
// RUIN_BUILD_VERSION is defined by the Makefile for every dylib object and by
// nothing else, so it also gates whole-file fixtures that define no host macro
// of their own (Siri, LocalFontUI): outside the shipped dylib the macros are
// always no-ops.
#if defined(RUIN_HOST_CHECK) || defined(RUIN_KEYCHAIN_HOST_CHECK) || \
    defined(RUIN_SIDELOAD_HOST_CHECK) || defined(RUIN_MESSAGE_HISTORY_HOST_CHECK) || \
    defined(RUIN_UNSEND_OPERATION_HOST_CHECK) || !defined(RUIN_BUILD_VERSION)
#define RUIN_PROFILE_BEGIN(name) do {} while (0)
#define RUIN_PROFILE_END(status) do {} while (0)
#define RUIN_PROFILE_INSTANT(name, status) do {} while (0)
#define RUIN_PROFILE_CALL(name, expr) do { expr; } while (0)
#else
#define RUIN_PROFILE_BEGIN(name) RUINProfileSpanBegin(name)
#define RUIN_PROFILE_END(status) RUINProfileSpanEnd(status)
#define RUIN_PROFILE_INSTANT(name, status) RUINProfileInstant(name, status)
#define RUIN_PROFILE_CALL(name, expr) do { \
    RUINProfileSpanBegin(name); \
    expr; \
    RUINProfileSpanEnd(RUINProfileStatusOK); \
} while (0)
#endif
