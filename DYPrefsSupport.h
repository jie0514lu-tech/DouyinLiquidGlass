// DYPrefsSupport - 偏好读取 / 命中判定 / 设置热更新
// 配置域：com.dy.liquidglass（Root.plist 里同样指向这个域，改动实时生效）

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局开关（默认开）
BOOL DYGlobalEnabled(void);

/// 当前应该用的滤镜类型（默认 systemMaterialBlur）
NSString *DYFilterType(void);

/// 高斯模糊半径（0 表示交给系统材质）
CGFloat DYBlurRadius(void);

/// 背景捕获 scale（质量）
CGFloat DYCaptureScale(void);

/// 高光强度 0~1
CGFloat DYGlossIntensity(void);

/// 圆角半径，<0 表示跟随目标视图
CGFloat DYCornerRadius(void);

/// 是否启用底部横条启发式
BOOL DYHeuristicsEnabled(void);

/// 精确类名白名单命中
BOOL DYIsExactTarget(NSString *className);

/// 子串白名单命中
BOOL DYMatchesTargetSubstring(NSString *className);

/// 排除名单命中
BOOL DYIsExcluded(NSString *className);

/// 子视图类名是否应被当作背景隐藏
BOOL DYShouldHideSubviewClass(NSString *className);

/// 底部横条启发式：宽 > 2*高、贴窗口底部、宽 > 200pt
BOOL DYHeuristicBottomBar(UIView *view);

/// 设置变化回调（Darwin 通知 com.dy.liquidglass/Reload）
void DYObserveReload(void (^handler)(void));

/// 清空缓存（重刷时调用）
void DYInvalidateCaches(void);

NS_ASSUME_NONNULL_END
