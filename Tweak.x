// DouyinLiquidGlass - 抖音 App 内液态玻璃插件（主入口）
// 思路来源：winaviation-tweaks/liquidass（借鉴其"玻璃宿主路由 + 自绘高光"思路）
//
// v0.5 架构（针对真机反馈重构）：
//  1) 悬浮重构：底栏缩成"悬浮药丸"（左右留白、抬高、圆角、独立阴影）
//  2) 放弃全局 layoutSubviews Hook → 只对已套玻璃的类做定向 Hook（性能更优）
//  3) 磨砂底改用 UIVisualEffectView（App 进程内稳定），自绘高光保留
//  4) 深度清理黑色背景层 + 玻璃层级正确（背景之上、内容之下）
//  5) 类名调试标签：被套玻璃的视图屏幕显示类名（截图即得真实类名）
//
// 不依赖 CydiaSubstrate / ElleKit 的 %hook，纯 runtime swizzle →
// 同一 dylib：Sileo(Dopamine) 与 TrollFools(巨魔) 两条路都能加载。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DYGlassView.h"
#import "DYGlassInjector.h"
#import "DYPrefsSupport.h"

#pragma mark - 命中判定（返回命中类别）

// 0=未命中  1=类名  2=底栏启发式  3=顶部导航启发式  4=右侧按钮启发式
static NSInteger DYHitKind(UIView *v) {
    if (!v || !v.window) return 0;
    if (!DYGlobalEnabled()) return 0;

    // 关键防线：绝不能给玻璃层/阴影/标签自己再套玻璃（否则递归崩溃）
    if (DYIsInternalView(v)) return 0;

    NSString *cls = NSStringFromClass(v.class);
    if (!cls.length) return 0;

    NSInteger decision = DYClassDecision(cls);
    if (decision == 1) {
        if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(类名): %@", cls);
        return 1;   // 类名命中（白名单/子串）
    }
    if (decision == -1) return 0;   // 被排除，连启发式也不看

    // 类名未命中 → 几何启发式（底部栏 / 顶部导航 / 右侧悬浮按钮）
    if (DYHeuristicsEnabled()) {
        if (DYHeuristicBottomBar(v)) {
            if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(底栏启发式): %@", cls);
            return 2;
        }
        if (DYHeuristicTopBar(v)) {
            if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(顶部导航启发式): %@", cls);
            return 3;
        }
        if (DYHeuristicSideButton(v)) {
            if (DYDebugEnabled()) NSLog(@"[DouyinLiquidGlass] 命中(右侧按钮启发式): %@", cls);
            return 4;
        }
    }
    return 0;
}

#pragma mark - 轻量全局入口（只 Hook didMoveToWindow，每视图一次，成本极低）

@interface UIView (DouyinLiquidGlass)
- (void)dy_didMoveToWindow;
@end

@implementation UIView (DouyinLiquidGlass)

- (void)dy_didMoveToWindow {
    // 交换后 dy_didMoveToWindow 已指向原始 didMoveToWindow，直接调用即执行原逻辑
    [self dy_didMoveToWindow];
    if (!self.window) return;
    @try {
        NSInteger kind = DYHitKind(self);
        if (kind > 0) DYApplyGlassToView(self, kind);
    } @catch (__unused NSException *e) {
        // 任何异常都吞掉：插件可以无效果，但绝不能让抖音闪退
    }
}

@end

#pragma mark - 初始化（dylib 被加载进抖音进程时自动执行）

__attribute__((constructor))
static void DYInitialize(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class uiview = [UIView class];
        Method m1 = class_getInstanceMethod(uiview, @selector(didMoveToWindow));
        Method m2 = class_getInstanceMethod(uiview, @selector(dy_didMoveToWindow));
        BOOL ok = (m1 && m2);
        if (ok) method_exchangeImplementations(m1, m2);

        // 设置/plist 改动（com.dy.liquidglass/Reload）后整体重刷
        DYObserveReload(^{
            DYRemoveAllGlass();
            DYInvalidateCaches();
        });

        if (DYDebugEnabled()) {
            NSLog(@"[DouyinLiquidGlass] 插件已加载 v0.5: didMoveToWindow=%@, 磨砂=UIVisualEffectView",
                  ok ? @"OK" : @"FAIL");
        }
    });
}
