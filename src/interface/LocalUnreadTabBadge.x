%config(generator=internal);

#import "LocalUnreadTabBadge.h"
#import "LocalUnreadBadges.h"
#import "TargetMetadata.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>

@interface RUINLocalTabBadgeState : NSObject
@property(nonatomic, weak) UITabBarController *owner;
@property(nonatomic, copy) NSString *nativeValue;
@end
@implementation RUINLocalTabBadgeState @end

static char StateKey, BoundItemKey;
static Class rootClass, chatClass, chatAltClass;
static NSHashTable<UITabBarController *> *roots;
static NSUInteger correction, correctionWrites, rawChanges, bindings;
static BOOL installed;
static UITabBarItem *applyingItem;

static BOOL SameValue(NSString *left, NSString *right) {
    return left == right || [left isEqualToString:right];
}

static BOOL ClassBelongs(Class cls) {
    return RUINClassBelongsToBundleExecutable(cls);
}

static NSString *ProjectedValue(NSString *native, NSUInteger count) {
    if (!count || !native.length || native.length > 20) return native;
    NSUInteger value = 0;
    for (NSUInteger i = 0; i < native.length; i++) {
        unichar c = [native characterAtIndex:i];
        if (c < '0' || c > '9' || value > (NSUIntegerMax - (c - '0')) / 10) return native;
        value = value * 10 + c - '0';
    }
    return value > count ? [NSString stringWithFormat:@"%lu", (unsigned long)(value - count)] : nil;
}

static UITabBarItem *TalkItem(UITabBarController *root) {
    UITabBarItem *found = nil;
    for (UIViewController *entry in root.viewControllers) {
        UIViewController *content = entry;
        NSUInteger depth = 0;
        while ([content isKindOfClass:UINavigationController.class] && depth++ < 8)
            content = ((UINavigationController *)content).viewControllers.firstObject;
        if (!chatClass || (![content isKindOfClass:chatClass] && !(chatAltClass && [content isKindOfClass:chatAltClass]))) continue;
        UITabBarItem *item = entry.tabBarItem;
        if (!item || (found && found != item)) return nil; // Ambiguous native structure: preserve it.
        found = item;
    }
    return found;
}

// ---- LINE 14.6.3: the Talk badge is drawn by LINE.SkinnedTabBarItem and set
// through the category setter -[UITabBarItem setSkinnedBadgeValue:]; the
// system badgeValue stays nil. The last native value is recorded from launch.
@interface UITabBarItem (RUINLINE14Skinned)
- (void)setSkinnedBadgeValue:(id)value; // LINE 14.6.3 category, checked at runtime before use
@end
static char SkinnedNativeKey;
static BOOL skinnedHooked;
static NSUInteger skinnedNativeSets, skinnedWrites;
static NSString *skinnedValueClass;
static id ProjectedSkinned(id native, NSUInteger count) {
    if ([native isKindOfClass:NSNumber.class]) {
        long long value = [native longLongValue];
        if (!count || value <= 0) return native;
        return value > (long long)count ? @(value - (long long)count) : @0;
    }
    if (native == nil || [native isKindOfClass:NSString.class]) return ProjectedValue(native, count);
    return native;
}
static void WriteSkinned(UITabBarItem *item, NSUInteger count) {
    if (!skinnedHooked || !item) return;
    id stored = objc_getAssociatedObject(item, &SkinnedNativeKey);
    if (!stored) return; // Native value not observed yet: never invent one.
    id native = stored == NSNull.null ? nil : stored;
    UITabBarItem *previous = applyingItem;
    applyingItem = item;
    @try { [item setSkinnedBadgeValue:ProjectedSkinned(native, count)]; skinnedWrites++; }
    @finally { applyingItem = previous; }
}
static void WriteValue(UITabBarItem *item, NSString *value) {
    if (SameValue(item.badgeValue, value)) return;
    UITabBarItem *previous = applyingItem;
    applyingItem = item;
    @try { item.badgeValue = value; correctionWrites++; }
    @finally { applyingItem = previous; }
}

static void RefreshRoot(UITabBarController *root) {
    if (!NSThread.isMainThread || ![root isKindOfClass:rootClass]) return;
    [roots addObject:root];
    UITabBarItem *old = objc_getAssociatedObject(root, &BoundItemKey);
    UITabBarItem *item = TalkItem(root);
    if (old != item) {
        RUINLocalTabBadgeState *oldState = objc_getAssociatedObject(old, &StateKey);
        if (oldState.owner == root) {
            WriteValue(old, oldState.nativeValue);
            objc_setAssociatedObject(old, &StateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(root, &BoundItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!item) return;
    RUINLocalTabBadgeState *state = objc_getAssociatedObject(item, &StateKey);
    if (state && !state.owner) {
        WriteValue(item, state.nativeValue);
        objc_setAssociatedObject(item, &StateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        state = nil;
    }
    BOOL newlyBound = !state;
    if (!state) {
        state = [RUINLocalTabBadgeState new];
        state.owner = root;
        state.nativeValue = item.badgeValue;
        objc_setAssociatedObject(item, &StateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        bindings++;
    }
    if (state.owner != root) return;
    WriteValue(item, ProjectedValue(state.nativeValue, correction));
    WriteSkinned(item, correction);
    if (newlyBound) RUINRefreshLocalUnreadBadgeTotals();
}

%group RUINLocalUnreadTabBadgeHooks
%hook UITabBarItem
- (void)setBadgeValue:(NSString *)value {
    RUINLocalTabBadgeState *state = objc_getAssociatedObject(self, &StateKey);
    if (applyingItem == self || !NSThread.isMainThread || !state) { %orig(value); return; }
    UITabBarController *owner = state.owner;
    if (!owner || TalkItem(owner) != self) {
        objc_setAssociatedObject(self, &StateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(value);
        return;
    }
    BOOL changed = !SameValue(state.nativeValue, value);
    state.nativeValue = value;
    %orig(ProjectedValue(value, correction));
    if (changed) { rawChanges++; RUINRefreshLocalUnreadBadgeTotals(); }
}
%end

%hook UIViewController
- (void)setTabBarItem:(UITabBarItem *)item {
    %orig(item);
    UITabBarController *root = self.tabBarController;
    if ([root isKindOfClass:rootClass]) RefreshRoot(root);
}
%end

%hook RUINUnreadNativeRoot
- (void)setViewControllers:(NSArray *)controllers { %orig(controllers); RefreshRoot(self); }
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated { %orig(controllers, animated); RefreshRoot(self); }
- (void)viewDidLoad { %orig; RefreshRoot(self); }
- (void)viewDidAppear:(BOOL)animated { %orig(animated); RefreshRoot(self); }
%end
%end

%group RUINLocalUnreadSkinnedBadge
%hook UITabBarItem
- (void)setSkinnedBadgeValue:(id)value {
    if (applyingItem == self) { %orig(value); return; }
    objc_setAssociatedObject(self, &SkinnedNativeKey, value ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    skinnedNativeSets++;
    skinnedValueClass = value ? NSStringFromClass([value class]) : @"nil";
    RUINLocalTabBadgeState *state = NSThread.isMainThread ? objc_getAssociatedObject(self, &StateKey) : nil;
    UITabBarController *owner = state.owner;
    if (!owner || TalkItem(owner) != self) { %orig(value); return; }
    %orig(ProjectedSkinned(value, correction));
    rawChanges++;
    RUINRefreshLocalUnreadBadgeTotals();
}
%end
%end

__attribute__((constructor)) static void RUINInstallSkinnedBadgeEarly(void) {
    Method method = class_getInstanceMethod(UITabBarItem.class, @selector(setSkinnedBadgeValue:));
    if (!method || strcmp(method_getTypeEncoding(method), "v24@0:8@16") || !method_getImplementation(method)) return;
    %init(RUINLocalUnreadSkinnedBadge);
    skinnedHooked = YES;
}

// iOS 18 UITab API only; absent on iOS 15 (LINE 14.6.3 port).
%group RUINLocalUnreadTabBadgeTabs
%hook RUINUnreadNativeTabsRoot
- (void)setTabs:(NSArray *)tabs { %orig(tabs); RefreshRoot(self); }
- (void)setTabs:(NSArray *)tabs animated:(BOOL)animated { %orig(tabs, animated); RefreshRoot(self); }
%end
%end

// Discover already-built roots once at installation. Badge setters never scan
// windows, reflect Swift fields, or access a native unread model.
static void DiscoverRoots(UIViewController *controller, NSHashTable *seen) {
    if (!controller || [seen containsObject:controller]) return;
    [seen addObject:controller];
    if ([controller isKindOfClass:rootClass]) RefreshRoot((id)controller);
    for (UIViewController *child in controller.childViewControllers) DiscoverRoots(child, seen);
    DiscoverRoots(controller.presentedViewController, seen);
}

void RUINInstallLocalUnreadTabBadge(void) {
    if (!NSThread.isMainThread || installed || !RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary)) return;
    Class root = NSClassFromString(@"_TtC22LineSharedUIComponents20RootTabBarController");
    if (!root) root = NSClassFromString(@"_TtC20LineUtilUIComponents20RootTabBarController"); // LINE 14.6.3
    Class chat = NSClassFromString(@"_TtC13LineChatTabUI25ChatTabPageViewController");
    if (!chat) chat = NSClassFromString(@"_TtC13LineChatTabUI21ChatTabViewController"); // LINE 14.6.3
    if (![root isSubclassOfClass:UITabBarController.class] || ![chat isSubclassOfClass:UIViewController.class] ||
        !ClassBelongs(root) || !ClassBelongs(chat)) return;
    const SEL selectors[] = {@selector(setViewControllers:), @selector(setViewControllers:animated:),
        @selector(viewDidLoad), @selector(viewDidAppear:)};
    const char *types[] = {"v24@0:8@16", "v28@0:8@16B24", "v16@0:8", "v20@0:8B16"};
    const SEL tabSelectors[] = {@selector(setTabs:), @selector(setTabs:animated:)};
    const char *tabTypes[] = {"v24@0:8@16", "v28@0:8@16B24"};
    BOOL hasTabs = YES;
    for (NSUInteger i = 0; i < 2; i++) {
        Method method = class_getInstanceMethod(root, tabSelectors[i]);
        if (!method || strcmp(method_getTypeEncoding(method), tabTypes[i]) || !method_getImplementation(method)) hasTabs = NO;
    }
    Method badge = class_getInstanceMethod(UITabBarItem.class, @selector(setBadgeValue:));
    if (!badge || strcmp(method_getTypeEncoding(badge), "v24@0:8@16") || !method_getImplementation(badge)) return;
    Method item = class_getInstanceMethod(UIViewController.class, @selector(setTabBarItem:));
    if (!item || strcmp(method_getTypeEncoding(item), "v24@0:8@16") || !method_getImplementation(item)) return;
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        Method method = class_getInstanceMethod(root, selectors[i]);
        if (!method || strcmp(method_getTypeEncoding(method), types[i]) || !method_getImplementation(method)) return;
    }
    rootClass = root; chatClass = chat;
    chatAltClass = NSClassFromString(@"_TtC13LineChatTabUI21ChatTabViewController"); // LINE 14.6.3 Talk tab root
    roots = [NSHashTable weakObjectsHashTable];
    %init(RUINLocalUnreadTabBadgeHooks, RUINUnreadNativeRoot = root);
    if (hasTabs) { %init(RUINLocalUnreadTabBadgeTabs, RUINUnreadNativeTabsRoot = root); }
    installed = YES;
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) DiscoverRoots(window.rootViewController, seen);
    }
}

void RUINSetLocalUnreadTabBadgeCorrection(NSUInteger count) {
    if (!NSThread.isMainThread) return;
    correction = count;
    RUINInstallLocalUnreadTabBadge();
    for (UITabBarController *root in roots.allObjects) RefreshRoot(root);
}

static NSArray *TabShapes(void) {
    NSMutableArray *out = [NSMutableArray array];
    UITabBarController *root = roots.allObjects.firstObject;
    for (UIViewController *entry in root.viewControllers) {
        UIViewController *content = entry;
        NSUInteger depth = 0;
        while ([content isKindOfClass:UINavigationController.class] && depth++ < 8)
            content = ((UINavigationController *)content).viewControllers.firstObject;
        id skinned = objc_getAssociatedObject(entry.tabBarItem, &SkinnedNativeKey);
        [out addObject:@{@"content":content ? NSStringFromClass(content.class) : @"", @"badge":entry.tabBarItem.badgeValue ?: @"",
            @"skinnedNative":skinned ? [skinned description] : @"-"}];
    }
    return out;
}
NSDictionary *RUINLocalUnreadTabBadgeDiagnostics(void) {
    return @{@"installed":@(installed), @"correction":@(correction), @"bindings":@(bindings),
        @"rawChanges":@(rawChanges), @"displayWrites":@(correctionWrites),
        @"rootClass":rootClass ? NSStringFromClass(rootClass) : @"", @"chatClass":chatClass ? NSStringFromClass(chatClass) : @"",
        @"liveRoots":@(roots.allObjects.count), @"tabs":TabShapes(),
        @"skinnedHooked":@(skinnedHooked), @"skinnedNativeSets":@(skinnedNativeSets), @"skinnedWrites":@(skinnedWrites),
        @"skinnedValueClass":skinnedValueClass ?: @""};
}
