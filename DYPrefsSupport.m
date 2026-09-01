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

#pragma mark - 对外接口

BOOL DYGlobalEnabled(void) {
    return DYBool(@"Enabled", YES);
}

BOOL DYDebugEnabled(void) {
    // 0.5.6 起彻底写死为 NO（无视本地残留旧 plist）。
    // 之前真机上红框一直出现，就是因为诊断时手动把 plist 的 Debug 改过 YES，
    // 残留配置压过了代码默认值。诊断开关不再读配置。
    return NO;
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
    // 0.5.6 起彻底关闭几何盲猜（无视本地残留旧 plist）：
    // 底部/顶部/右侧启发式全部不跑，杜绝 AWEFeedViewCell 整屏误套。
    // 命中只走精确类名白名单 + 带护栏的子串白名单。
    return NO;
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
    // 0.5.6 起彻底写死为 NO（无视本地残留旧 plist），不再显示红色类名标签。
    return NO;
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
            // 注意：不再加入猜测的右侧容器类名（AWEFeedInteractView 等）——
            // 实测会匹配到大容器、玻璃盖住头像/点赞/评论/分享图标。
            // 右侧按钮改由 SideHeuristic 精确几何判定（且必须含图标）。
        ];
    }
    NSArray *custom = DYStrings(@"TargetClasses");
    if (custom.count) return custom; // 自定义优先
    return sDefaultTargetClasses;
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
    NSArray *custom = DYStrings(@"TargetSubstrings");
    if (custom.count) return custom; // 自定义优先
    return sDefaultSubstrings;
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
    NSArray *custom = DYStrings(@"ExcludedClasses");
    if (custom.count) return custom; // 自定义优先
    return sDefaultExcluded;
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

// 右侧悬浮按钮：30~110pt 方形、靠右边缘(<70pt)、垂直中段
BOOL DYHeuristicSideButton(UIView *view) {
    // 0.5.3 保留（默认 YES）：点赞/评论/收藏/分享的类名尚未抓到，
    // 这是目前唯一能覆盖它们的路径。判定精确（右缘小方块+垂直中段），
    // 误伤面小。抓到真实类名后可把 SideHeuristic 改 NO 走白名单。
    if (!DYBool(@"SideHeuristic", YES)) return NO;
    if (!view.window) return NO;
    CGRect f = view.bounds;
    if (f.size.width < 30.0 || f.size.width > 110.0) return NO;
    if (f.size.height < 30.0 || f.size.height > 110.0) return NO;
    CGRect wf = [view convertRect:view.bounds toView:view.window];
    CGFloat winW = view.window.bounds.size.width;
    CGFloat winH = view.window.bounds.size.height;
    if (CGRectGetMaxX(wf) < winW - 70.0) return NO;   // 靠右边缘
    CGFloat midY = CGRectGetMidY(wf);
    if (midY < 200.0 || midY > winH - 200.0) return NO; // 垂直中段
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
