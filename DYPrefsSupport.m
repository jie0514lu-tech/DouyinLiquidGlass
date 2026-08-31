// DYPrefsSupport.m

#import "DYPrefsSupport.h"
#import <objc/runtime.h>

// rootless 越狱（Dopamine/palera1n）路径映射
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#ifndef jbroot
#define jbroot(path) (path)
#endif
#endif

static NSString *const kPrefsDomain = @"com.dy.liquidglass";
static CFStringRef const kReloadNote = CFSTR("com.dy.liquidglass/Reload");

static NSDictionary<NSString *, id> *sCache;
static NSMutableArray<void (^)(void)> *sHandlers;
static BOOL sSetup;

static NSString *DYPrefsPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/com.dy.liquidglass.plist");
}

static NSDictionary<NSString *, id> *DYPrefs(void) {
    if (!sCache) {
        sCache = [NSDictionary dictionaryWithContentsOfFile:DYPrefsPath()] ?: @{};
    }
    return sCache;
}

static id DYValue(NSString *key) {
    return DYPrefs()[key];
}

static BOOL DYBool(NSString *key, BOOL fallback) {
    id v = DYValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return fallback;
}

static CGFloat DYFloat(NSString *key, CGFloat fallback) {
    id v = DYValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return (CGFloat)[v doubleValue];
    return fallback;
}

static NSArray<NSString *> *DYStrings(NSString *key) {
    id v = DYValue(key);
    if ([v isKindOfClass:[NSArray class]]) return v;
    return @[];
}

#pragma mark - 对外接口

BOOL DYGlobalEnabled(void) {
    return DYBool(@"Enabled", YES);
}

NSString *DYFilterType(void) {
    id v = DYValue(@"FilterType");
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    return @"systemMaterialBlur";
}

CGFloat DYBlurRadius(void) {
    return DYFloat(@"Blur", 0.0);
}

CGFloat DYCaptureScale(void) {
    CGFloat q = DYFloat(@"Quality", 1.0);
    return q > 0.0 ? q : 1.0;
}

CGFloat DYGlossIntensity(void) {
    return DYFloat(@"Gloss", 0.7);
}

CGFloat DYCornerRadius(void) {
    return DYFloat(@"CornerRadius", -1.0); // <0 跟随目标
}

BOOL DYHeuristicsEnabled(void) {
    return DYBool(@"Heuristics", YES);
}

BOOL DYIsExactTarget(NSString *className) {
    if (!className.length) return NO;
    return [DYStrings(@"TargetClasses") containsObject:className];
}

BOOL DYMatchesTargetSubstring(NSString *className) {
    if (!className.length) return NO;
    for (NSString *sub in DYStrings(@"TargetSubstrings")) {
        if (sub.length && [className containsString:sub]) return YES;
    }
    return NO;
}

BOOL DYIsExcluded(NSString *className) {
    if (!className.length) return NO;
    for (NSString *sub in DYStrings(@"ExcludedClasses")) {
        if (sub.length && [className containsString:sub]) return YES;
    }
    return NO;
}

BOOL DYShouldHideSubviewClass(NSString *className) {
    if (!className.length) return NO;
    for (NSString *sub in DYStrings(@"HideSubviewsContaining")) {
        if (sub.length && [className containsString:sub]) return YES;
    }
    return NO;
}

BOOL DYHeuristicBottomBar(UIView *view) {
    if (!view.window) return NO;
    CGRect f = view.bounds;
    if (f.size.width < 200.0 || f.size.width < f.size.height * 2.0) return NO;
    CGRect wf = [view convertRect:view.bounds toView:view.window];
    CGFloat winH = view.window.bounds.size.height;
    // 贴底
    return fabs(CGRectGetMaxY(wf) - winH) < 60.0;
}

void DYObserveReload(void (^handler)(void)) {
    if (!handler) return;
    if (!sHandlers) sHandlers = [NSMutableArray array];
    [sHandlers addObject:[handler copy]];

    if (sSetup) return;
    sSetup = YES;

    static void (*cb)(CFNotificationCenterRef, void *, CFStringRef,
                      const void *, CFDictionaryRef) = NULL;
    if (!cb) {
        cb = ^(CFNotificationCenterRef c, void *o, CFStringRef n,
               const void *obj, CFDictionaryRef info) {
            (void)c; (void)o; (void)n; (void)obj; (void)info;
            dispatch_async(dispatch_get_main_queue(), ^{
                DYInvalidateCaches();
                for (void (^h)(void) in [sHandlers copy]) h();
            });
        };
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, cb, kReloadNote, NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}

void DYInvalidateCaches(void) {
    sCache = nil;
}
