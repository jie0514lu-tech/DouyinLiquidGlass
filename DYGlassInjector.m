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

    // 向上防套娃（关键）：玻璃视图内部的任何子视图（_fxView/_tintView/高光层等）
    // 的 frame 往往等于目标（如底栏）尺寸，若只判"自身"会漏判，导致无限套玻璃→栈溢出。
    UIView *superview = view.superview;
    while (superview) {
        if ([superview isKindOfClass:[DYGlassView class]]) return YES;
        superview = superview.superview;
    }

    // 向下防套娃：系统磨砂/特效组件及其私有类一律不处理（防 UIVisualEffectView 内部懒加载视图）
    NSString *cls = NSStringFromClass(view.class);
    if ([cls hasPrefix:@"UIVisualEffect"] || [cls hasPrefix:@"_UIVisualEffect"]) return YES;

    return NO;
}

#pragma mark - 深层检测 / 背景判定

// 前置声明：DYDeepCleanBackground（较早）会调用 DYHasImageOrLabelDeep（较晚定义）。
// static 函数没有头文件声明，必须先在这里声明，否则 clang 报 implicit declaration 编译错误。
static BOOL DYHasImageOrLabelDeep(UIView *v);

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

// 深度清理背景（0.5.6 保守版）：
//  - 目标自身背景色清掉；
//  - 图层层：只隐藏"铺满的深色渐变/不透明纯色底/背景图"；
//  - 子视图层：只隐藏"铺满、且类名像背景/含 Blur、且内部无任何图标/文字"的视图。
//  ★ 任何含 UIImageView/UILabel 的子视图一律不隐藏（头像、点赞图标、标签绝不误伤）。
static void DYDeepCleanBackground(UIView *target, DYGlassView *glass) {
    // 1) 目标自身背景色（记住以便移除时还原）
    UIColor *bg = target.backgroundColor;
    if (bg && CGColorGetAlpha(bg.CGColor) > 0.01) {
        objc_setAssociatedObject(target, kBgColorKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        target.backgroundColor = [UIColor clearColor];
    }

    // 2) 图层层：铺满的深色渐变 / 纯色底 / 背景图
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

    // 3) 子视图层：铺满 + 类名像背景/含Blur + 无图标文字 → 隐藏
    NSMutableArray *hiddenViews = [NSMutableArray array];
    for (UIView *sub in [target.subviews copy]) {
        if (sub == glass) continue;
        // ★ 免死金牌：含图标/文字的视图绝不隐藏（头像、点赞图标、tab 图标与文字）
        if (DYHasImageOrLabelDeep(sub)) continue;

        CGRect sb = sub.frame;
        BOOL fills = sb.size.width  >= target.bounds.size.width  * 0.9 &&
                     sb.size.height >= target.bounds.size.height * 0.9;
        if (!fills) continue;

        NSString *cls = NSStringFromClass(sub.class);
        BOOL bgLike = DYShouldHideSubviewClass(cls) || [cls containsString:@"Blur"];
        if (!bgLike) continue;
        sub.hidden = YES;
        [hiddenViews addObject:sub];
    }
    if (hiddenViews.count)
        objc_setAssociatedObject(target, kHiddenViewsKey, hiddenViews,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 悬浮药丸重构

// 深查某视图内部是否含图标/文字（UIImageView 或 UILabel）。
// 用于右侧按钮：只给"真实按钮"（含图标）套玻璃，透明手势层/装饰容器不套，
// 避免玻璃盖住头像、点赞、评论、分享图标。
static BOOL DYHasImageOrLabelDeep(UIView *v) {
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        if (iv.image) return YES;
    }
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length) return YES;
    }
    for (UIView *s in v.subviews) {
        if (DYHasImageOrLabelDeep(s)) return YES;
    }
    return NO;
}

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

// 悬浮药丸（0.5.6 新方案）：★绝不修改原生容器 frame★。
// 抖音的 AutoLayout/切 tab 动画会和我们改 frame 冲突（标签不跟随、切换消失、顶到进度条）。
// 现在：容器保持原生位置尺寸，我们把玻璃画成"胶囊"垫在容器内部（水平内缩 margin），
// 原生 tab 项还在原生位置 → 天然都在胶囊内（标签跟随）；容器不动 → 不碰进度条、不触发布局冲突。
// 阴影作为玻璃的兄弟层插在容器内部（随容器一起生灭，无孤儿泄漏问题）。
static void DYApplyFloating(UIView *target, DYGlassView *glass) {
    if (!target.window || !target.superview) return;

    // 重入防护：同一次逻辑内若再次进入直接返回，杜绝"悬浮→setNeedsLayout→Hook→再悬浮"死循环
    if (objc_getAssociatedObject(target, kFloatingBusyKey)) return;
    objc_setAssociatedObject(target, kFloatingBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        CGRect b = target.bounds;
        CGFloat margin = DYFloatingMargin();
        CGFloat pillW = b.size.width - margin * 2.0;
        if (pillW < 80.0) return;
        CGFloat pillH = b.size.height - 8.0;   // 上下各留 4pt，看起来像悬浮胶囊
        if (pillH < 16.0) pillH = b.size.height;
        CGFloat pillX = margin;
        CGFloat pillY = (b.size.height - pillH) * 0.5; // 垂直居中
        CGRect pillFrame = CGRectMake(pillX, pillY, pillW, pillH);
        CGFloat radius = DYFloatingCornerRadius();
        if (radius < 0.0) radius = pillH * 0.5;  // 药丸：高度一半

        // 容器不裁内容（否则阴影出不去）；玻璃自身有 masksToBounds=YES 负责裁模糊
        target.layer.masksToBounds = NO;

        glass.frame = pillFrame;
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];

        // 阴影层：插在容器内部、玻璃之下（兄弟层，随容器生灭）
        UIView *shadow = objc_getAssociatedObject(target, kShadowKey);
        if (!shadow) {
            shadow = [[UIView alloc] init];
            shadow.userInteractionEnabled = NO;
            shadow.backgroundColor = [UIColor clearColor];
            objc_setAssociatedObject(shadow, kShadowMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(target, kShadowKey, shadow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // 原生重排可能把阴影摘掉/顶上去：自愈到"玻璃下方"
        if (shadow.superview != target) {
            [target insertSubview:shadow belowSubview:glass];
        } else if ([target.subviews indexOfObject:shadow] >
                   [target.subviews indexOfObject:glass]) {
            [shadow removeFromSuperview];
            [target insertSubview:shadow belowSubview:glass];
        }
        shadow.frame = pillFrame;
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

// 非悬浮目标（右侧按钮 / 顶部导航等）：玻璃铺满目标，方形自动转圆形胶囊
static void DYApplyRoundedGlass(UIView *target, DYGlassView *glass) {
    CGRect b = target.bounds;
    glass.frame = b;

    CGFloat w = b.size.width, h = b.size.height;
    CGFloat radius = DYCornerRadius();
    if (radius < 0.0) {
        radius = target.layer.cornerRadius;
        if (radius <= 0.0 && w > 0 && fabs(w - h) < 2.0) {
            radius = w * 0.5;              // 方形 → 正圆
        }
    }
    if (radius <= 0.0) radius = 12.0;
    CGFloat maxR = MIN(w, h) * 0.5;        // 圆角不超过短边一半
    if (radius > maxR) radius = maxR;
    glass.layer.cornerRadius = radius;
    [glass updateSpecular];
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

    // 切 tab 时原生可能重排/移除子视图：玻璃被摘掉就重新钉回 index 0（背景之上、内容之下）
    if (glass.superview != target) {
        [target insertSubview:glass atIndex:0];
    } else if (target.subviews.firstObject != glass) {
        [glass removeFromSuperview];
        [target insertSubview:glass atIndex:0];
    }
    // 阴影必须保持"玻璃下方"（DYApplyFloating 里也有自愈，这里双保险）
    UIView *shadow = objc_getAssociatedObject(target, kShadowKey);
    if (shadow && shadow.superview == target) {
        NSUInteger gi = [target.subviews indexOfObject:glass];
        NSUInteger si = [target.subviews indexOfObject:shadow];
        if (si != NSNotFound && gi != NSNotFound && si > gi) {
            [shadow removeFromSuperview];
            [target insertSubview:shadow belowSubview:glass];
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    DYSyncGlassGeometry(target);
    [CATransaction commit];
}

void DYSyncGlassGeometry(UIView *target) {
    if (!target) return;
    DYGlassView *glass = DYGlassForTarget(target);
    if (!glass) return;

    NSNumber *kindNum = objc_getAssociatedObject(target, kKindKey);
    NSInteger kind = kindNum ? kindNum.integerValue : 0;
    if (DYFloatingEnabled() && DYShouldFloatTarget(target, kind)) {
        // 底部 tab 栏：悬浮胶囊（不改容器 frame）
        DYApplyFloating(target, glass);
    } else {
        // 顶部导航 / 右侧按钮：铺满 + 方形自动转圆
        DYApplyRoundedGlass(target, glass);
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

    // 深度清理背景（深色渐变/纯色底/背景图/Blur 子视图）→ 玻璃不被黑底盖住；含图标文字的一律不隐藏
    DYDeepCleanBackground(target, glass);

    // 定向布局 Hook：只跟踪这一个类，替代全局 layoutSubviews
    DYTrackLayoutForClass(target.class);

    // 应用几何（悬浮胶囊 / 圆角玻璃，按类别自动选择）
    DYSyncGlassGeometry(target);

    // 延迟补刷：目标 frame 可能在 didMoveToWindow 之后才被设置
    __weak UIView *weakTarget = target;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakTarget) DYResyncTarget(weakTarget);
    });

    if (DYDebugEnabled()) {
        NSLog(@"[DouyinLiquidGlass] 套玻璃: %@ kind=%ld", NSStringFromClass(target.class), (long)kind);
    }

    DYAddClassTag(target);
}

void DYApplyGlassToView(UIView *target, NSInteger kind) {
    if (!target) return;
    // 右侧按钮（kind==4 几何判定，已随启发式关闭不会触发，保留兜底）：只给含图标/文字的套玻璃
    if (kind == 4 && !DYHasImageOrLabelDeep(target)) return;

    NSString *cls = NSStringFromClass(target.class);
    if (!DYIsExactTarget(cls)) {
        // 非精确命中（子串白名单的"右侧按钮"猜测类名，未核实）：
        //  ① 必须是小尺寸（真实按钮，≤160pt），大容器直接拒绝——防玻璃盖住头像/点赞/评论/分享；
        //  ② 必须含图标/文字。
        if (target.bounds.size.width  > 160.0 ||
            target.bounds.size.height > 160.0) return;
        if (!DYHasImageOrLabelDeep(target)) return;
    }
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
