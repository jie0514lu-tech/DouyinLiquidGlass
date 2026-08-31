// DYGlassView - 玻璃视图（核心渲染层）
// 借鉴 LiquidAss 的 LGLiveBackdropView：
//   - layerClass = CABackdropLayer（系统实时背景捕获，App 内可用）
//   - 挂 CAFilter（默认 systemMaterialBlur，失败回退 gaussianBlur）
//   - 叠加对角线高光渐变（specular + overlay 高亮），做出液态玻璃的"光带"
// 注意：App 进程内无法注册自定义折射/色散滤镜（那是 backboardd 的能力），
//       因此本实现为"磨砂玻璃 + 高光"风格，而非逐像素折射。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYGlassView : UIView

/// 指定宿主来源（用于日志/调试），frame 为目标视图的 frame
- (instancetype)initWithFrame:(CGRect)frame source:(nullable NSString *)source;

/// 重新套用滤镜（设置变化 / 深浅色切换时调用）
- (void)applyFilter;

/// 更新高光渐变（圆角变化后调用）
- (void)updateSpecular;

/// 当前使用的 CAFilter 类型（只读，便于日志）
@property (nonatomic, copy, readonly) NSString *filterType;

@end

NS_ASSUME_NONNULL_END
