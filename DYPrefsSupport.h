// DYPrefsSupport - 偏好读取 / 命中判定 / 设置热更新
// 配置域：com.dy.liquidglass（Root.plist 里同样指向这个域，改动实时生效）

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局开关（默认开）
BOOL DYGlobalEnabled(void);

/// 调试日志开关（默认开，便于首测定位命中情况）
BOOL DYDebugEnabled(void);

/// 类名判定（带缓存）：
///   1  = 命中（套玻璃）
///   -1 = 被排除（直接跳过，连启发式也不看）
///   0  = 类名未命中（可继续交给几何启发式）
NSInteger DYClassDecision(NSString *className);

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

/// 悬浮药丸开关（底栏缩边 + 抬高 + 圆角 + 阴影）
BOOL DYFloatingEnabled(void);

/// 悬浮左右留白（pt）
CGFloat DYFloatingMargin(void);

/// 悬浮距底抬高（pt）
CGFloat DYFloatingLift(void);

/// 悬浮圆角（pt），<0 表示高度一半（药丸）
CGFloat DYFloatingCornerRadius(void);

/// 是否在屏幕上叠加类名调试标签（截图即得真实类名）
BOOL DYShowClassTag(void);

/// 磨砂样式（UIBlurEffectStyle，默认 59 = SystemThinMaterialDark）
UIBlurEffectStyle DYBlurStyle(void);

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

/// 顶部导航栏启发式：宽 >=250、高 20~100、位于窗口顶部区域
BOOL DYHeuristicTopBar(UIView *view);

/// 右侧悬浮按钮启发式：30~110pt 方形、靠右边缘、垂直中段
BOOL DYHeuristicSideButton(UIView *view);

/// 设置变化回调（Darwin 通知 com.dy.liquidglass/Reload）
void DYObserveReload(void (^handler)(void));

/// 清空缓存（重刷时调用）
void DYInvalidateCaches(void);

NS_ASSUME_NONNULL_END
