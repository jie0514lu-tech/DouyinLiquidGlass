// DouyinLiquidGlass - 抖音 App 内液态玻璃插件（主入口）
// 思路来源：winaviation-tweaks/liquidass（借鉴其"玻璃宿主路由"机制：
//   把"系统材质视图"替换成 CABackdropLayer 玻璃层 + 高光 + 圆角）
// 本插件是独立工程，与 DYKiller 无源码关系、互不冲突，可共存。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DYGlassView.h"
#import "DYGlassInjector.h"
#import "DYPrefsSupport.h"

#pragma mark - 命中判定（速度优先：先看类名，再决定要不要做完整注入）

static BOOL DYShouldHandleView(UIView *v) {
    if (!v || !v.window) return NO;
    if (!DYGlobalEnabled()) return NO;

    NSString *cls = NSStringFromClass(v.class);
    if (!cls.length) return NO;

    // 1. 排除名单（子串匹配）
    if (DYIsExcluded(cls)) return NO;

    // 2. 精确类名白名单（来自 class-dump 后填入的 TargetClasses）
    if (DYIsExactTarget(cls)) return YES;

    // 3. 子串白名单（如 "TabBar" / "BottomBar" / "SearchBar" 等）
    if (DYMatchesTargetSubstring(cls)) return YES;

    // 4. 启发式：底部大尺寸横条（常见 tab 栏/底部栏形态）
    if (DYHeuristicsEnabled() && DYHeuristicBottomBar(v)) return YES;

    return NO;
}

#pragma mark - Hooks（借用 LiquidAss 的生命周期钩子思路）

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (DYShouldHandleView(self)) {
        DYApplyGlassToView(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!self.window) return;
    if (DYShouldHandleView(self)) {
        DYSyncGlassGeometry(self);
    }
}

%end

#pragma mark - 构造

%ctor {
    // 设置面板改动（com.dy.liquidglass/Reload）后整体重刷
    DYObserveReload(^{
        DYRemoveAllGlass();
        DYInvalidateCaches();
    });
}
