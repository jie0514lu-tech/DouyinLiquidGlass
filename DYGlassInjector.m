// DYGlassInjector.m - 玻璃注入实现（v0.5）

#import "DYGlassInjector.h"
#import "DYGlassView.h"
#import "DYPrefsSupport.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// ---- 关联对象键 ----
static const void *kGlassKey       = &kGlassKey;    // DYGlassView
static const void *kKindKey        = &kKindKey;     // NSNumber(命中类别)
static const void *kBgColorKey     = &kBgColorKey;  // 目标原始 backgroundColor
static const void *kHiddenViewsKey = &kHiddenViewsKey; // 被隐藏的背景子视图
static const void *kHiddenLayersKey= &kHiddenLayersKey;// 被隐藏的背景图层
static const void *kShadowKey      = &kShadowKey;   // 阴影视图（存在 target 上）
static const void *kTagKey         = &kTagKey;      // 类名标签（存在 target 上）
static const void *kShadowMarkerKey= &kShadowMarkerKey; // 内部视图标记（存在 shadow/tag 上）
static const void *kShadowTrackerKey = &kShadowTrackerKey; // 阴影生命周期追踪器
static const void *kTagTrackerKey    = &kTagTrackerKey;    // 标签生命周期追踪器
static const void *kFloatingBusyKey  = &kFloatingBusyKey;  // 悬浮重入防护标志

#pragma mark - 生命周期追踪器（防孤儿视图泄漏）
// shadow 挂在 target 的父视图、tag 挂在 window 上：target 被释放时它们仍被
// 外部 superview 强引用。绑定追踪器后，target 一死 → 关联对象释放 → 追踪器
// dealloc → 主动把外部视图从屏幕拔掉，杜绝刷视频导致的孤儿视图堆积。
@interface DYDeallocTracker : NSObject
@property (nonatomic, copy) void (^onDealloc)(void);
@end

@implementation DYDeallocTracker
- (void)dealloc {
    void (^block)(void) = self.onDealloc;
    if (block) block();
}
@end

// 弱表：记录所有已套玻璃的目标，便于整体重刷/移除
static NSMapTable<UIView *, DYGlassView *> *sGlassMap;

static NSMapTable<UIView *, DYGlassView *> *DYGlassMap(void) {
    if (!sGlassMap) sGlassMap = [NSMapTable weakToWeakObjectsMapTable];
    return sGlassMap;
}

static DYGlassView *DYGlassForTarget(UIView *target) {
    if (!target) return nil;
    return objc_getAssociatedObject(target, kGlassKey);
}

#pragma mark - 内部视图判定

BOOL DYIsInternalView(UIView *view) {
    if (!view) return NO;
    if ([view isKindOfClass:[DYGlassView class]]) return YES;
    if (objc_getAssociatedObject(view, kShadowMarkerKey)) return YES;
    return NO;
}

#pragma mark - 深层检测 / 背景判定

// 该视图内部是否存在可交互内容（按钮等）
static BOOL DYIsInteractiveDeep(UIView *v) {
    if (v.userInteractionEnabled) return YES;
    for (UIView *s in v.subviews) {
        if (DYIsInteractiveDeep(s)) return YES;
    }
    return NO;
}

// 判断 sub 是否是"铺满目标的纯背景子视图"：满足则隐藏，让玻璃透出来。
static BOOL DYLooksLikeBackgroundSubview(UIView *sub, UIView *target) {
    if (sub.hidden || sub.alpha < 0.8) return NO;

    CGRect sb = sub.frame;
    CGRect tb = target.bounds;
    BOOL fills = CGRectContainsRect(CGRectInset(tb, -1, -1), sb) &&
                 sb.size.width  >= tb.size.width  * 0.9 &&
                 sb.size.height >= tb.size.height * 0.9;
    if (!fills) return NO;

    NSString *cls = NSStringFromClass(sub.class);
    BOOL nameLikeBg = DYShouldHideSubviewClass(cls);
    BOOL plainBg    = !DYIsInteractiveDeep(sub) && sub.alpha >= 0.95;
    return nameLikeBg || plainBg;
}

// 判断渐变层是否为"深色且不透明"（只看首末两色，防误伤半透明装饰渐变）
static BOOL DYLayerIsDark(CAGradientLayer *g) {
    NSArray *colors = g.colors;
    if (colors.count < 2) return NO;
    NSInteger idxs[2] = {0, (NSInteger)colors.count - 1};
    for (int k = 0; k < 2; k++) {
        CGColorRef c = (__bridge CGColorRef)colors[idxs[k]];
        if (!c) return NO;
        const CGFloat *comps = CGColorGetComponents(c);
        size_t n = CGColorGetNumberOfComponents(c);
        CGFloat r = 0, gg = 0, b = 0, a = 0;
        if (n >= 4) { r = comps[0]; gg = comps[1]; b = comps[2]; a = comps[3]; }
        else if (n == 2) { r = gg = b = comps[0]; a = comps[1]; }
        else return NO;
        if (a < 0.5) return NO;                       // 半透明不算"黑底"
        if ((0.299 * r + 0.587 * gg + 0.114 * b) > 0.45) return NO; // 偏亮不算
    }
    return YES;
}

// 深度清理背景：目标自身背景色 + 铺满的深色/纯色/背景图层 + 背景型子视图
static void DYDeepCleanBackground(UIView *target, DYGlassView *glass) {
    // 1) 目标自身背景色（记住以便移除时还原）
    UIColor *bg = target.backgroundColor;
    if (bg && CGColorGetAlpha(bg.CGColor) > 0.01) {
        objc_setAssociatedObject(target, kBgColorKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        target.backgroundColor = [UIColor clearColor];
    }

    // 2) 铺满的深色渐变 / 纯色底 / 背景图图层
    NSMutableArray *hiddenLayers = [NSMutableArray array];
    for (CALayer *sl in [target.layer.sublayers copy]) {
        if (sl.hidden || sl == glass.layer) continue;
        CGRect slf = sl.frame;
        if (slf.size.width  < target.bounds.size.width  * 0.9 ||
            slf.size.height < target.bounds.size.height * 0.9) continue;
        BOOL shouldHide = NO;
        if ([sl isKindOfClass:[CAGradientLayer class]]) {
            shouldHide = DYLayerIsDark((CAGradientLayer *)sl);
        } else {
            if (sl.contents != nil) shouldHide = YES;   // 背景图
            else if (sl.backgroundColor && CGColorGetAlpha(sl.backgroundColor) > 0.9)
                shouldHide = YES;                       // 不透明纯色底
        }
        if (shouldHide) {
            sl.hidden = YES;
            [hiddenLayers addObject:sl];
        }
    }
    if (hiddenLayers.count)
        objc_setAssociatedObject(target, kHiddenLayersKey, hiddenLayers,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 3) 铺满且无交互的背景型子视图
    NSMutableArray *hiddenViews = [NSMutableArray array];
    for (UIView *sub in [target.subviews copy]) {
        if (sub == glass) continue;
        if (DYLooksLikeBackgroundSubview(sub, target)) {
            sub.hidden = YES;
            [hiddenViews addObject:sub];
        }
    }
    if (hiddenViews.count)
        objc_setAssociatedObject(target, kHiddenViewsKey, hiddenViews,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 悬浮药丸重构

static BOOL DYShouldFloatTarget(UIView *target, NSInteger kind) {
    if (kind == 2) return YES; // 底栏启发式：直接悬浮
    if (kind == 1) {           // 类名命中：名字像底栏才悬浮
        NSString *cls = NSStringFromClass(target.class);
        for (NSString *s in @[@"TabBar", @"BottomBar", @"BottomNav",
                              @"MainTabBar", @"ToolBar"]) {
            if (cls.length && [cls containsString:s]) return YES;
        }
    }
    return NO;
}

// 悬浮药丸：左右留白 + 抬高 + 药丸圆角；阴影用独立视图承载（masksToBounds 会吃掉阴影）
static void DYApplyFloating(UIView *target, DYGlassView *glass) {
    if (!target.window || !target.superview) return;

    // 重入防护：同一次逻辑内若再次进入（如 setNeedsLayout 偶发同步触发布局），直接返回，
    // 彻底杜绝"悬浮→setNeedsLayout→Hook→再悬浮"的 CPU 100% 死循环风险。
    if (objc_getAssociatedObject(target, kFloatingBusyKey)) return;
    objc_setAssociatedObject(target, kFloatingBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        CGRect winF = [target convertRect:target.bounds toView:target.window];
        CGFloat winW = target.window.bounds.size.width;
        CGFloat winH = target.window.bounds.size.height;

        CGFloat margin = DYFloatingMargin();   // 左右留白
        CGFloat lift   = DYFloatingLift();     // 距底抬高
        CGFloat newW   = winW - margin * 2.0;
        if (newW < 80.0) return;
        CGFloat newH = winF.size.height;
        CGFloat newX = margin;
        CGFloat newY = winH - lift - newH;
        CGRect newWin = CGRectMake(newX, newY, newW, newH);
        CGRect newLocal = [target.superview convertRect:newWin fromView:target.window];

        // 容差判断替代严格相等：多次坐标转换产生的极小浮点抖动不会引发反复 setNeedsLayout
        CGRect oldF = target.frame;
        if (fabs(oldF.origin.x - newLocal.origin.x) > 0.5 ||
            fabs(oldF.origin.y - newLocal.origin.y) > 0.5 ||
            fabs(oldF.size.width  - newLocal.size.width)  > 0.5 ||
            fabs(oldF.size.height - newLocal.size.height) > 0.5) {
            target.frame = newLocal;
            [target setNeedsLayout];
        }

        CGFloat radius = DYFloatingCornerRadius();
        if (radius < 0.0) radius = newH * 0.5; // 药丸：高度一半
        target.layer.cornerRadius = radius;
        target.layer.cornerCurve  = kCACornerCurveContinuous;
        target.layer.masksToBounds = YES;      // 裁内容/玻璃到药丸内
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];

        // 独立阴影层（先打内部标记，再插入——否则插入瞬间 didMoveToWindow 会把阴影误判成底栏再套玻璃）
        UIView *shadow = objc_getAssociatedObject(target, kShadowKey);
        if (!shadow) {
            shadow = [[UIView alloc] init];
            shadow.userInteractionEnabled = NO;
            shadow.backgroundColor = [UIColor clearColor];
            objc_setAssociatedObject(shadow, kShadowMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [target.superview insertSubview:shadow belowSubview:target];
            objc_setAssociatedObject(target, kShadowKey, shadow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // 生命周期追踪：target 被销毁时自动拔掉阴影，防孤儿视图泄漏
            __weak UIView *weakShadow = shadow;
            DYDeallocTracker *tracker = [[DYDeallocTracker alloc] init];
            tracker.onDealloc = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakShadow removeFromSuperview];
                });
            };
            objc_setAssociatedObject(target, kShadowTrackerKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        shadow.frame = newLocal;
        shadow.layer.shadowColor   = [UIColor blackColor].CGColor;
        shadow.layer.shadowOpacity = 0.28;
        shadow.layer.shadowRadius  = 12.0;
        shadow.layer.shadowOffset  = CGSizeMake(0, 6);
        shadow.layer.shadowPath    = [UIBezierPath bezierPathWithRoundedRect:shadow.bounds
                                                                cornerRadius:radius].CGPath;
    } @finally {
        objc_setAssociatedObject(target, kFloatingBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - 类名调试标签

static void DYAddClassTag(UIView *target) {
    if (!DYShowClassTag()) return;
    if (objc_getAssociatedObject(target, kTagKey)) return;
    UIWindow *win = target.window;
    if (!win) return;
    CGRect tf = [target convertRect:target.bounds toView:win];
    UILabel *tag = [[UILabel alloc] initWithFrame:
                    CGRectMake(tf.origin.x, tf.origin.y, MIN(tf.size.width, 200), 16)];
    tag.text = NSStringFromClass(target.class);
    tag.font = [UIFont systemFontOfSize:9];
    tag.textColor = [UIColor whiteColor];
    tag.backgroundColor = [UIColor colorWithRed:0.82 green:0.12 blue:0.14 alpha:0.9];
    tag.layer.cornerRadius = 4;
    tag.layer.masksToBounds = YES;
    tag.textAlignment = NSTextAlignmentCenter;
    objc_setAssociatedObject(tag, kShadowMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // 先标记
    [win addSubview:tag];
    objc_setAssociatedObject(target, kTagKey, tag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 生命周期追踪：target 被销毁时自动拔掉标签，防孤儿视图泄漏（标签挂在 window 上）
    __weak UIView *weakTag = tag;
    DYDeallocTracker *tracker = [[DYDeallocTracker alloc] init];
    tracker.onDealloc = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakTag removeFromSuperview];
        });
    };
    objc_setAssociatedObject(target, kTagTrackerKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 定向布局 Hook（替代全局 layoutSubviews）

static NSMutableDictionary<NSString *, NSValue *> *gLayoutHooks;

// 安全名单：这些通用类绝不被定向 Hook（避免影响海量普通视图）
static BOOL DYClassSafeToTrack(Class cls) {
    NSString *n = NSStringFromClass(cls);
    static NSSet<NSString *> *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [NSSet setWithArray:@[
            @"UIView", @"UIControl", @"UIButton", @"UIImageView",
            @"UILabel", @"UIScrollView", @"UITableViewCell", @"UICollectionViewCell",
        ]];
    });
    return !([bad containsObject:n] || [n hasPrefix:@"_UI"]);
}

static void DYLayoutHook(id self, SEL _cmd) {
    NSString *key = NSStringFromClass(object_getClass(self));
    IMP orig = [[gLayoutHooks objectForKey:key] pointerValue];
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    @try {
        if (DYGlassForTarget(self)) DYResyncTarget(self);
    } @catch (__unused NSException *e) {
        // 布局回调里绝不能抛异常影响原布局
    }
}

void DYTrackLayoutForClass(Class cls) {
    if (!cls || !DYClassSafeToTrack(cls)) return;
    NSString *key = NSStringFromClass(cls);
    if (key.length == 0 || [gLayoutHooks objectForKey:key]) return;

    SEL sel = @selector(layoutSubviews);
    Method own = class_getInstanceMethod(cls, sel);
    Method sup = class_getInstanceMethod(class_getSuperclass(cls), sel);
    IMP orig = NULL;

    if (own && own != sup) {
        // 该类自己实现了 layoutSubviews → 替换其 IMP，保留原始
        orig = method_getImplementation(own);
        method_setImplementation(own, (IMP)DYLayoutHook);
    } else {
        // 该类没实现 → 添加一个重写，并把父类实现作为原始调用
        orig = sup ? method_getImplementation(sup)
                   : class_getMethodImplementation(class_getSuperclass(cls), sel);
        class_addMethod(cls, sel, (IMP)DYLayoutHook, "v@:");
    }

    if (!gLayoutHooks) gLayoutHooks = [NSMutableDictionary dictionary];
    gLayoutHooks[key] = [NSValue valueWithPointer:orig];
}

#pragma mark - 几何同步 / 重刷

void DYResyncTarget(UIView *target) {
    if (!target) return;
    DYGlassView *glass = DYGlassForTarget(target);
    if (!glass) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    NSNumber *kindNum = objc_getAssociatedObject(target, kKindKey);
    NSInteger kind = kindNum ? kindNum.integerValue : 0;
    if (DYFloatingEnabled() && DYShouldFloatTarget(target, kind)) {
        DYApplyFloating(target, glass);
    }

    DYSyncGlassGeometry(target);
    [CATransaction commit];
}

void DYSyncGlassGeometry(UIView *target) {
    if (!target) return;
    DYGlassView *glass = DYGlassForTarget(target);
    if (!glass) return;

    CGRect b = target.bounds;
    if (!CGRectEqualToRect(glass.frame, b)) {
        glass.frame = b;
    }

    CGFloat radius = DYCornerRadius();
    if (radius < 0.0) radius = target.layer.cornerRadius;
    if (radius <= 0.0) radius = 12.0;
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
    }
    [glass updateSpecular];

    // 刷新类名标签位置
    UIView *tag = objc_getAssociatedObject(target, kTagKey);
    if (tag && target.window) {
        CGRect tf = [target convertRect:target.bounds toView:target.window];
        tag.frame = CGRectMake(tf.origin.x, tf.origin.y, MIN(tf.size.width, 200), 16);
    }
}

#pragma mark - 注入

static void DYInstallGlass(UIView *target, NSInteger kind) {
    if (DYGlassForTarget(target)) return;

    DYGlassView *glass = [[DYGlassView alloc] initWithFrame:target.bounds
                                                     source:NSStringFromClass(target.class)];
    [target insertSubview:glass atIndex:0];
    objc_setAssociatedObject(target, kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(target, kKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [DYGlassMap() setObject:glass forKey:target];

    // 深度清理背景（深色渐变/纯色底/背景图）→ 玻璃不被黑底盖住
    DYDeepCleanBackground(target, glass);

    // 悬浮药丸重构（底栏类）
    if (DYFloatingEnabled() && DYShouldFloatTarget(target, kind)) {
        DYApplyFloating(target, glass);
    }

    // 定向布局 Hook：只跟踪这一个类，替代全局 layoutSubviews
    DYTrackLayoutForClass(target.class);

    DYSyncGlassGeometry(target);

    // 延迟补刷：目标 frame 可能在 didMoveToWindow 之后才被设置
    __weak UIView *weakTarget = target;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakTarget) DYResyncTarget(weakTarget);
    });

    if (DYDebugEnabled()) {
        NSLog(@"[DouyinLiquidGlass] 套玻璃: %@ kind=%ld filter=%@",
              NSStringFromClass(target.class), (long)kind, glass.filterType);
        glass.layer.borderColor = [UIColor redColor].CGColor;
        glass.layer.borderWidth = 1.5;
    }

    DYAddClassTag(target);
}

void DYApplyGlassToView(UIView *target, NSInteger kind) {
    if (!target) return;
    DYInstallGlass(target, kind);
    DYSyncGlassGeometry(target);
}

void DYRemoveAllGlass(void) {
    NSMapTable *map = DYGlassMap();
    for (UIView *target in [map.keyEnumerator allObjects]) {
        DYGlassView *glass = [map objectForKey:target];
        if (glass) [glass removeFromSuperview];
        objc_setAssociatedObject(target, kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(target, kKindKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIColor *bg = objc_getAssociatedObject(target, kBgColorKey);
        if (bg) {
            target.backgroundColor = bg;
            objc_setAssociatedObject(target, kBgColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSArray *hidden = objc_getAssociatedObject(target, kHiddenViewsKey);
        for (UIView *sub in hidden) sub.hidden = NO;
        objc_setAssociatedObject(target, kHiddenViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSArray *hiddenLayers = objc_getAssociatedObject(target, kHiddenLayersKey);
        for (CALayer *sl in hiddenLayers) sl.hidden = NO;
        objc_setAssociatedObject(target, kHiddenLayersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *shadow = objc_getAssociatedObject(target, kShadowKey);
        [shadow removeFromSuperview];
        objc_setAssociatedObject(target, kShadowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(target, kShadowTrackerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *tag = objc_getAssociatedObject(target, kTagKey);
        [tag removeFromSuperview];
        objc_setAssociatedObject(target, kTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(target, kTagTrackerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        objc_setAssociatedObject(target, kFloatingBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [map removeAllObjects];
}
