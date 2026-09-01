// DYGlassInjector - 玻璃注入 / 几何同步 / 悬浮重构 / 移除
//
// v0.5（针对真机反馈重构）：
//   - 深度清理背景：隐藏铺满的深色渐变/纯色底/背景图，玻璃才不会被黑底盖住
//   - 悬浮药丸重构：底栏缩进留白 + 抬高 + 药丸圆角 + 独立阴影层
//   - 定向布局 Hook：只对已套玻璃的类做 layoutSubviews Hook，替代全局 Hook
//   - 类名调试标签：屏幕上直接显示被套玻璃视图的类名（截图即得，无需 Lookin）

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 给目标视图套上玻璃（幂等：已套过则只同步几何）。
/// kind：1=类名命中  2=底栏启发式  3=顶部导航启发式  4=右侧按钮启发式
void DYApplyGlassToView(UIView *target, NSInteger kind);

/// 同步玻璃层几何（目标 frame/圆角变化时调用）
void DYSyncGlassGeometry(UIView *target);

/// 重新应用悬浮/几何（定向 layoutSubviews Hook 里调用）
void DYResyncTarget(UIView *target);

/// 移除所有已注入的玻璃（设置改动时整体重刷用）
void DYRemoveAllGlass(void);

/// 定向 Hook 该类的 layoutSubviews（替代全局布局 Hook，性能更优）
void DYTrackLayoutForClass(Class cls);

/// 是否是我们内部创建的视图（玻璃/阴影/标签）——命中判定必须跳过
BOOL DYIsInternalView(UIView *view);

NS_ASSUME_NONNULL_END
