// DouyinLiquidGlass - 抖音 App 内液态玻璃插件（主入口）
// 思路来源：winaviation-tweaks/liquidass（借鉴其"玻璃宿主路由"机制：
//   把宿主控件替换成 CABackdropLayer 玻璃层 + 高光 + 圆角）
//
// 架构说明（0.2.0 重要升级）：
//   本版本不依赖 CydiaSubstrate / ElleKit 的 %hook，改用 Objective-C runtime
//   直接 swizzle UIView。因此同一份 dylib 两种装法都能跑：
//     - 作为 deb 装进 Dopamine（Sileo），由 ElleKit 注入抖音进程；
//     - 用 TrollStore / TrollFools 直接注入抖音 IPA（无需越狱运行时）。
//   两条路都不引入 substrate 依赖 → 降低崩溃面、加载更快。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DYGlassView.h"
#import "DYGlassInjector.h"
#import "DYPrefsSupport.h"

#pragma mark - 命中判定（速度优先：类名缓存 + 几何启发式）

static BOOL DYShouldHandleView(UIView *v) {
    if (!v || !v.window) return NO;
    if (!DYGlobalEnabled()) return NO;

    // 关键防线：绝不能给玻璃层自己再套玻璃（否则无限递归崩溃）
    if ([v isKindOfClass:[DYGlassView class]]) return NO;

    NSString *cls = NSStringFromClass(v.class);
    if (!cls.length) return NO;

    NSInteger decision = DYClassDecision(cls);
    if (decision == 1) {
        if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(类名): %@", cls);
        return YES;   // 类名命中（白名单/子串）
    }
    if (decision == -1) return NO;   // 被排除，连启发式也不看

    // 类名未命中 → 几何启发式（底部栏 / 顶部导航 / 右侧悬浮按钮）
    if (DYHeuristicsEnabled()) {
        if (DYHeuristicBottomBar(v)) {
            if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(底栏启发式): %@", cls);
            return YES;
        }
        if (DYHeuristicTopBar(v)) {
            if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(顶部导航启发式): %@", cls);
            return YES;
        }
        if (DYHeuristicSideButton(v)) {
            if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(右侧按钮启发式): %@", cls);
            return YES;
        }
    }

    return NO;
}

#pragma mark - 运行时 Swizzle（不依赖 substrate）

@interface UIView (DouyinLiquidGlass)
- (void)dy_didMoveToWindow;
- (void)dy_layoutSubviews;
@end

@implementation UIView (DouyinLiquidGlass)

- (void)dy_didMoveToWindow {
    // 交换后 dy_didMoveToWindow 已指向原始 didMoveToWindow，直接调用即执行原逻辑
    [self dy_didMoveToWindow];
    if (!self.window) return;
    @try {
        if (DYShouldHandleView(self)) {
            DYApplyGlassToView(self);
        }
    } @catch (__unused NSException *e) {
        // 任何异常都吞掉：插件可以无效果，但绝不能让抖音闪退
    }
}

- (void)dy_layoutSubviews {
    [self dy_layoutSubviews];
    if (!self.window) return;
    @try {
        if (DYShouldHandleView(self)) {
            DYSyncGlassGeometry(self);
        }
    } @catch (__unused NSException *e) {
        // 同上：静默失败，不影响原布局
    }
}

@end

#pragma mark - 初始化（dylib 被加载进抖音进程时自动执行）

__attribute__((constructor))
static void DYInitialize(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class uiview = [UIView class];

        // 交换 didMoveToWindow / layoutSubviews（幂等，只换一次）
        Method m1 = class_getInstanceMethod(uiview, @selector(didMoveToWindow));
        Method m2 = class_getInstanceMethod(uiview, @selector(dy_didMoveToWindow));
        if (m1 && m2) method_exchangeImplementations(m1, m2);

        Method m3 = class_getInstanceMethod(uiview, @selector(layoutSubviews));
        Method m4 = class_getInstanceMethod(uiview, @selector(dy_layoutSubviews));
        if (m3 && m4) method_exchangeImplementations(m3, m4);

        // 设置/plist 改动（com.dy.liquidglass/Reload）后整体重刷
        DYObserveReload(^{
            DYRemoveAllGlass();
            DYInvalidateCaches();
        });

        if (DYDebugEnabled()) {
            BOOL swz = (m1 && m2 && m3 && m4);
            NSLog(@"[DouyinLiquidGlass] 插件已加载: UIView swizzle=%@, CABackdropLayer=%@",
                  swz ? @"OK" : @"FAIL",
                  NSClassFromString(@"CABackdropLayer") ? @"可用" : @"不可用");
        }
    });
}
