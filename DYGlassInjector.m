// DYGlassInjector.m - 玻璃注入实现

#import "DYGlassInjector.h"
#import "DYGlassView.h"
#import "DYPrefsSupport.h"
#import <objc/runtime.h>

static const void *kGlassKey       = &kGlassKey;   // DYGlassView
static const void *kBgColorKey     = &kBgColorKey; // 目标原始 backgroundColor
static const void *kHiddenViewsKey = &kHiddenViewsKey; // 被隐藏的背景子视图

// 弱表：记录所有已套玻璃的目标，便于整体重刷/移除
static NSMapTable<UIView *, DYGlassView *> *sGlassMap;

static NSMapTable<UIView *, DYGlassView *> *DYGlassMap(void) {
    if (!sGlassMap) sGlassMap = [NSMapTable weakToWeakObjectsMapTable];
    return sGlassMap;
}

// 保守隐藏"看起来像背景"的子视图：类名含指定子串，且铺满目标 bounds，
// 且不在最上层（避免误伤前景图标/文字）。
static BOOL DYLooksLikeBackgroundSubview(UIView *sub, UIView *target) {
    if (!sub.hidden && sub.alpha > 0.1 && !sub.userInteractionEnabled) {
        CGRect sb = sub.frame;
        CGRect tb = target.bounds;
        // 铺满目标且尺寸足够大
        if (CGRectContainsRect(CGRectInset(tb, -1, -1), sb) &&
            sb.size.width >= tb.size.width * 0.9 &&
            sb.size.height >= tb.size.height * 0.9) {
            if (DYShouldHideSubviewClass(NSStringFromClass(sub.class))) return YES;
        }
    }
    return NO;
}

#pragma mark - 内部

static DYGlassView *DYGlassForTarget(UIView *target) {
    return objc_getAssociatedObject(target, kGlassKey);
}

static void DYInstallGlass(UIView *target) {
    if (DYGlassForTarget(target)) return;

    DYGlassView *glass = [[DYGlassView alloc] initWithFrame:target.bounds
                                                     source:NSStringFromClass(target.class)];
    [target insertSubview:glass atIndex:0];
    objc_setAssociatedObject(target, kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [DYGlassMap() setObject:glass forKey:target];

    // 抹掉目标自身背景色（记住以便移除时还原）
    UIColor *bg = target.backgroundColor;
    if (bg && CGColorGetAlpha(bg.CGColor) > 0.01) {
        objc_setAssociatedObject(target, kBgColorKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        target.backgroundColor = [UIColor clearColor];
    }

    // 保守隐藏背景型子视图
    NSMutableArray *hidden = [NSMutableArray array];
    for (UIView *sub in target.subviews) {
        if (sub == glass) continue;
        if (DYLooksLikeBackgroundSubview(sub, target)) {
            sub.hidden = YES;
            [hidden addObject:sub];
        }
    }
    if (hidden.count) {
        objc_setAssociatedObject(target, kHiddenViewsKey, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [DYSyncGlassGeometry(target)];
}

#pragma mark - 公开接口

void DYApplyGlassToView(UIView *target) {
    if (!target) return;
    DYInstallGlass(target);
    DYSyncGlassGeometry(target);
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
    if (radius < 0.0) radius = target.layer.cornerRadius; // <0 表示跟随目标
    if (radius <= 0.0) radius = 12.0;
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
    }
}

void DYRemoveAllGlass(void) {
    NSMapTable *map = DYGlassMap();
    for (UIView *target in [map.keyEnumerator allObjects]) {
        DYGlassView *glass = [map objectForKey:target];
        if (glass) [glass removeFromSuperview];
        objc_setAssociatedObject(target, kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIColor *bg = objc_getAssociatedObject(target, kBgColorKey);
        if (bg) {
            target.backgroundColor = bg;
            objc_setAssociatedObject(target, kBgColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSArray *hidden = objc_getAssociatedObject(target, kHiddenViewsKey);
        for (UIView *sub in hidden) sub.hidden = NO;
        objc_setAssociatedObject(target, kHiddenViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [map removeAllObjects];
}
