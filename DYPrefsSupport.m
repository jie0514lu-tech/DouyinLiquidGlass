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

static CFStringRef const kReloadNote = CFSTR("com.dy.liquidglass/Reload");

static NSDictionary<NSString *, id> *sCache;
static NSMutableArray<void (^)(void)> *sHandlers;
static BOOL sSetup;

// 类名命中缓存：避免抖音里上千个视图、每次布局都重复做字符串匹配
static NSMutableSet<NSString *> *sClassHitCache;       // 类名命中
static NSMutableSet<NSString *> *sClassMissCache;      // 类名未命中
static NSMutableSet<NSString *> *sClassExcludedCache;  // 类名被排除

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

// ===== v0.5.8 自愈迁移 =====
// 旧版本调试过程中，plist 被手动改过 Debug/ShowClassTag/Heuristics/TargetClasses 等，
// 残留值导致：红框常驻 / 标签乱显示 / 全屏误套 / 白名单被覆盖而"全无玻璃"。
// 插件首次加载时调用一次：清掉这些危险残留键 + 确保总开关为开。
// 白名单已改为并集（内置永远生效），此迁移是"双保险"彻底清场。
void DYResetStalePrefs(void) {
    @try {
        NSString *path = DYPrefsPath();
        NSMutableDictionary *d =
            [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
        BOOL changed = NO;

        NSArray<NSString *> *staleKeys = @[
            @"Debug",            // 旧诊断红框开关（已废弃，改用 DiagnosticMode）
            @"ShowClassTag",     // 旧类名标签开关（已废弃，改用 DiagnosticMode）
            @"Heuristics",       // 旧几何盲猜总开关（已写死关闭）
            @"TargetClasses",    // 旧白名单覆盖（会挤掉内置核心目标，已改并集）
            @"TargetSubstrings", // 旧子串覆盖（同上）
            @"ExcludedClasses",  // 旧排除覆盖（同上）
            @"BottomHeuristic", @"TopHeuristic", @"SideHeuristic", // 旧启发式（已写死关闭）
        ];
        for (NSString *k in staleKeys) {
            if (d[k]) {
                [d removeObjectForKey:k];
                changed = YES;
            }
        }
        // 总开关必须为开——残留 Enabled=NO 会把整个插件关掉（表现就是"全无玻璃"）
        NSNumber *en = d[@"Enabled"];
        if (![en isKindOfClass:[NSNumber class]] || ![en boolValue]) {
            d[@"Enabled"] = @YES;
            changed = YES;
        }
        if (changed) {
            [d writeToFile:path atomically:YES];
            sCache = nil; // 让缓存重新读取
        }
    } @catch (__unused NSException *e) {
        // 自愈失败不影响主流程（并集白名单本身已免疫）
    }
}

#pragma mark - 对外接口

BOOL DYGlobalEnabled(void) {
    return DYBool(@"Enabled", YES);
}

BOOL DYDebugEnabled(void) {
    // v0.5.6 起不再读旧的 Debug 键（曾被残留值污染成 YES 导致红框常驻）。
    // v0.5.8 改用全新键 DiagnosticMode（历史上从未设置过，无残留污染风险）：
    //   需要抓真实类名/看命中时，在 plist 里把 DiagnosticMode 设为 YES 即可。
    return DYBool(@"DiagnosticMode", NO);
}

NSInteger DYClassDecision(NSString *className) {
    if (!className.length) return 0;
    if ([sClassHitCache containsObject:className]) return 1;
    if ([sClassExcludedCache containsObject:className]) return -1;
    if ([sClassMissCache containsObject:className]) return 0;

    if (DYIsExcluded(className)) {
        if (!sClassExcludedCache) sClassExcludedCache = [NSMutableSet set];
        [sClassExcludedCache addObject:className];
        return -1;
    }
    if (DYIsExactTarget(className) || DYMatchesTargetSubstring(className)) {
        if (!sClassHitCache) sClassHitCache = [NSMutableSet set];
        [sClassHitCache addObject:className];
        return 1;
    }
    if (!sClassMissCache) sClassMissCache = [NSMutableSet set];
    [sClassMissCache addObject:className];
    return 0;
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
    // v0.5.9：重新启用几何启发式（仅右侧按钮 SideHeuristic 默认 YES，底部/顶部默认 NO）。
    // 右侧点赞/评论/收藏/分享类名抓不准（40.x 一直在变），几何识别右缘小方块是
    // 唯一稳妥路径；配合 DYGlassInjector 的"含图标+小尺寸"护栏，不会误盖大容器。
    return YES;
}

BOOL DYFloatingEnabled(void) {
    return DYBool(@"Floating", YES);
}

CGFloat DYFloatingMargin(void) {
    return DYFloat(@"FloatMargin", 16.0);
}

CGFloat DYFloatingWidth(void) {
    // 0.5.5：悬浮药丸的固定宽度（默认 300pt，居中），避免"全屏宽药丸"盖住底部进度条。
    // 传 -1 时回退为"全屏宽 - 2×Margin"的旧行为。
    return DYFloat(@"FloatWidth", 300.0);
}

CGFloat DYFloatingLift(void) {
    return DYFloat(@"FloatLift", 24.0);
}

CGFloat DYFloatingCornerRadius(void) {
    return DYFloat(@"FloatCornerRadius", -1.0); // <0 药丸（高度一半）
}

BOOL DYShowClassTag(void) {
    // v0.5.8：同 DYDebugEnabled，走全新键 DiagnosticMode（默认关，无残留污染）。
    return DYBool(@"DiagnosticMode", NO);
}

UIBlurEffectStyle DYBlurStyle(void) {
    // 默认 59 = UIBlurEffectStyleSystemThinMaterialDark（暗色薄磨砂，视频背景上最像液态玻璃）
    return (UIBlurEffectStyle)DYFloat(@"BlurStyle", 59.0);
}

// ===== 精准白名单（0.5.3）=====
// 类名来自抖音 40.1.0 真机调试截图（类名标签）核实，不再靠宽泛子串瞎猜。
// 用 plist 的 TargetClasses 可覆盖（填了自定义就以自定义为准）。

static NSArray<NSString *> *sDefaultTargetClasses;

static NSArray<NSString *> *DYTargetClasses(void) {
    if (!sDefaultTargetClasses) {
        sDefaultTargetClasses = @[
            @"AWEFeedTopBarContainer", // 顶部导航容器（直播/团购/热点…）已核实
            @"AWENormalModeTabBar",    // 底部 tab 栏容器（会被悬浮成药丸）已核实
        ];
    }
    // v0.5.8：并集。内置白名单永远生效，plist 自定义只能"追加"不能"覆盖"。
    // 修复：旧版残留的 TargetClasses 会整体替换默认名单，把 AWENormalModeTabBar 等
    // 核心目标挤掉 → 底部/顶部全无玻璃。现在即使 plist 有脏值也不影响核心命中。
    NSArray *custom = DYStrings(@"TargetClasses");
    if (!custom.count) return sDefaultTargetClasses;
    NSMutableArray *all = [sDefaultTargetClasses mutableCopy];
    for (NSString *c in custom) {
        if (c.length && ![all containsObject:c]) [all addObject:c];
    }
    return all;
}

BOOL DYIsExactTarget(NSString *className) {
    if (!className.length) return NO;
    return [DYTargetClasses() containsObject:className];
}

// 子串白名单：0.5.6 默认加入"右侧四大金刚+头像"的猜测类名。
// 注意：这些类名是猜测（截图里右侧从未被标过类名），必须配合 DYGlassInjector
// 里的"非精确命中必须是小尺寸且含图标/文字"护栏，防止误套大容器盖住按钮。
// 若真机无效，说明类名不对，需用诊断手段抓真实类名。
static NSArray<NSString *> *sDefaultSubstrings;

static NSArray<NSString *> *DYTargetSubstrings(void) {
    if (!sDefaultSubstrings) {
        sDefaultSubstrings = @[
            @"AWEFeedLikeButton",       // 右侧：点赞（猜测）
            @"AWEFeedCommentButton",    // 右侧：评论（猜测）
            @"AWEFeedShareButton",      // 右侧：分享（猜测）
            @"AWEFeedCollectionButton", // 右侧：收藏（猜测）
            @"AWEFeedAvatarView",       // 右侧：头像（猜测）
        ];
    }
    // v0.5.8：并集，同 DYTargetClasses（内置猜测永远生效，自定义只追加）
    NSArray *custom = DYStrings(@"TargetSubstrings");
    if (!custom.count) return sDefaultSubstrings;
    NSMutableArray *all = [sDefaultSubstrings mutableCopy];
    for (NSString *c in custom) {
        if (c.length && ![all containsObject:c]) [all addObject:c];
    }
    return all;
}

BOOL DYMatchesTargetSubstring(NSString *className) {
    if (!className.length) return NO;
    for (NSString *sub in DYTargetSubstrings()) {
        if (sub.length && [className containsString:sub]) return YES;
    }
    return NO;
}

// ===== 排除名单（0.5.3）=====
// 真机调试中发现会被启发式/宽匹配误套的类，一律排除。
static NSArray<NSString *> *sDefaultExcluded;

static NSArray<NSString *> *DYExcludedSubstrings(void) {
    if (!sDefaultExcluded) {
        sDefaultExcluded = @[
            @"AWEFeedViewCell", // 整个视频背景单元（曾被误套整屏玻璃）
            @"AWEGradientView", // 视频底部文字渐变（不是 tab 栏）
        ];
    }
    // v0.5.8：并集，同 DYTargetClasses（内置排除永远生效，自定义只追加）
    NSArray *custom = DYStrings(@"ExcludedClasses");
    if (!custom.count) return sDefaultExcluded;
    NSMutableArray *all = [sDefaultExcluded mutableCopy];
    for (NSString *c in custom) {
        if (c.length && ![all containsObject:c]) [all addObject:c];
    }
    return all;
}

BOOL DYIsExcluded(NSString *className) {
    if (!className.length) return NO;
    for (NSString *sub in DYExcludedSubstrings()) {
        if (sub.length && [className containsString:sub]) return YES;
    }
    return NO;
}

BOOL DYShouldHideSubviewClass(NSString *className) {
    if (!className.length) return NO;
    // 默认背景类名子串（无需配置即可识别）；可用 plist 的 HideSubviewsContaining 覆盖
    static NSArray<NSString *> *sDefaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDefaults = @[
            @"Background", @"BarBackground", @"BG", @"Bg",
            @"BackView", @"BottomBg", @"BarBg", @"Wrapper",
        ];
    });
    NSArray *custom = DYStrings(@"HideSubviewsContaining");
    if (custom.count) {
        for (NSString *sub in custom) {
            if (sub.length && [className containsString:sub]) return YES;
        }
        return NO;
    }
    for (NSString *sub in sDefaults) {
        if (sub.length && [className containsString:sub]) return YES;
    }
    return NO;
}

BOOL DYHeuristicBottomBar(UIView *view) {
    // 0.5.3 默认关闭：宽泛贴底判定会误伤 AWEFeedViewCell（整屏 cell）与
    // AWEGradientView（视频底部渐变）。底部 tab 栏走精准类名白名单。
    if (!DYBool(@"BottomHeuristic", NO)) return NO;
    if (!view.window) return NO;
    CGRect f = view.bounds;
    // 宽条：宽>=200、宽>=2×高、高>=20（高度下限排除进度条/分隔线等细条）
    if (f.size.width < 200.0 || f.size.width < f.size.height * 2.0 ||
        f.size.height < 20.0) return NO;
    CGRect wf = [view convertRect:view.bounds toView:view.window];
    CGFloat winH = view.window.bounds.size.height;
    // 贴底或悬浮底栏：距窗口底部 <180pt（覆盖普通 tab 栏与悬浮 dock）
    return fabs(CGRectGetMaxY(wf) - winH) < 180.0;
}

// 顶部导航栏：宽 >=250、高 20~100、高不超过宽的一半、位于窗口顶部区域
BOOL DYHeuristicTopBar(UIView *view) {
    // 0.5.3 默认关闭：AWEFeedViewCell 在 cell 创建早期 frame 是顶部细条时
    // 会命中此判定，把整个视频背景套上玻璃。顶部导航走精准类名白名单。
    if (!DYBool(@"TopHeuristic", NO)) return NO;
    if (!view.window) return NO;
    CGRect f = view.bounds;
    if (f.size.width < 250.0 || f.size.height < 20.0 || f.size.height > 100.0) return NO;
    if (f.size.height > f.size.width * 0.5) return NO;
    CGRect wf = [view convertRect:view.bounds toView:view.window];
    CGFloat minY = CGRectGetMinY(wf);
    if (minY < -10.0 || minY > 220.0) return NO;
    return YES;
}

// 右侧悬浮按钮：30~80pt 小方块、靠右边缘(≤80pt)、垂直中段。
// v0.5.9 收紧到 30~80（此前 30~110 偶发命中右缘大容器，玻璃盖住整列图标）。
BOOL DYHeuristicSideButton(UIView *view) {
    if (!DYBool(@"SideHeuristic", YES)) return NO;
    if (!view.window) return NO;
    CGRect f = view.bounds;
    if (f.size.width < 30.0 || f.size.width > 80.0) return NO;
    if (f.size.height < 30.0 || f.size.height > 80.0) return NO;
    CGRect wf = [view convertRect:view.bounds toView:view.window];
    CGFloat winW = view.window.bounds.size.width;
    CGFloat winH = view.window.bounds.size.height;
    if (CGRectGetMaxX(wf) < winW - 80.0) return NO;   // 靠右边缘
    CGFloat midY = CGRectGetMidY(wf);
    if (midY < 200.0 || midY > winH - 150.0) return NO; // 垂直中段
    return YES;
}

// Darwin 通知回调必须是静态 C 函数（block 不能隐式转换成函数指针，clang 会报错）
static void DYReloadNotify(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        DYInvalidateCaches();
        for (void (^h)(void) in [sHandlers copy]) h();
    });
}

void DYObserveReload(void (^handler)(void)) {
    if (!handler) return;
    if (!sHandlers) sHandlers = [NSMutableArray array];
    [sHandlers addObject:[handler copy]];

    if (sSetup) return;
    sSetup = YES;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, &DYReloadNotify, kReloadNote, NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}

void DYInvalidateCaches(void) {
    sCache = nil;
    [sClassHitCache removeAllObjects];
    [sClassMissCache removeAllObjects];
    [sClassExcludedCache removeAllObjects];
}
