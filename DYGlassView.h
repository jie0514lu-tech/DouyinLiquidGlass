// DYGlassView - 玻璃视图（核心渲染层）
//
// v0.5 架构调整（针对真机反馈的 4 个核心问题中的"模糊降级"）：
//   底层改用 UIVisualEffectView（系统磨砂，App 进程内稳定可靠），
//   不再依赖 CABackdropLayer + CAFilter —— 那套在 SpringBoard 里表现好，
//   但在第三方 App 进程内会退化或失效。
//   自绘高光（对角线光带 + 顶部细亮边）保留，作为"液态"质感所在。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYGlassView : UIView

/// 指定宿主来源（用于日志/调试），frame 为目标视图的 frame
- (instancetype)initWithFrame:(CGRect)frame source:(nullable NSString *)source;

/// 更新高光渐变（圆角/尺寸变化后调用）
- (void)updateSpecular;

/// 当前磨砂方案（只读，便于日志）
@property (nonatomic, copy, readonly) NSString *filterType;

@end

NS_ASSUME_NONNULL_END
