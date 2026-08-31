// DYGlassInjector - 玻璃注入/几何同步/移除
// 借鉴 LiquidAss 的 LGInjectGlassIntoMaterialGroupType 思路：
//   在目标视图内部"最底层"插入玻璃层，并把目标自身背景抹掉，
//   让玻璃的实时模糊透出背后的内容，同时保留目标的文字/图标。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 给目标视图套上玻璃（幂等：已套过则只同步几何）
void DYApplyGlassToView(UIView *target);

/// 同步玻璃层几何（目标 frame/圆角变化时调用）
void DYSyncGlassGeometry(UIView *target);

/// 移除所有已注入的玻璃（设置改动时整体重刷用）
void DYRemoveAllGlass(void);

NS_ASSUME_NONNULL_END
