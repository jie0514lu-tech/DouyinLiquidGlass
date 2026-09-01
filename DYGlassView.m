// DYGlassView.m - 玻璃视图实现（v0.5）
//
// 三层结构（从下到上）：
//   0) UIVisualEffectView —— 稳定磨砂底（App 内可靠，不依赖私有 CAFilter）
//   1) 淡白底（alpha 0.10）—— 玻璃面板感 + 内容可读
//   2) 自绘高光（对角线光带 + 顶部细亮边）—— 液态玻璃的"光感"
// 圆角/裁剪由宿主设置：self.layer.masksToBounds=YES + cornerRadius。

#import "DYGlassView.h"
#import "DYPrefsSupport.h"
#import <QuartzCore/QuartzCore.h>

// 头文件里 filterType 是 readonly，类扩展里改成 readwrite 以便实现内部赋值
@interface DYGlassView ()
@property (nonatomic, copy, readwrite) NSString *filterType;
@end

@implementation DYGlassView {
    UIVisualEffectView *_fxView;       // 磨砂底
    UIView             *_tintView;     // 淡白底
    UIView             *_highlightView;// 高光容器
    CAGradientLayer    *_specular;     // 对角线光带
    CAGradientLayer    *_specularBoost;// 加强光带（overlay 混合）
    CALayer            *_edgeLayer;    // 顶部细亮边
}

- (instancetype)initWithFrame:(CGRect)frame source:(NSString *)source {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    (void)source;

    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.layer.masksToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = 12.0; // 注入时按需覆盖

    // 0) 稳定磨砂底：UIVisualEffectView（SystemThinMaterialDark 默认，可在 plist 调 BlurStyle）
    _fxView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:DYBlurStyle()]];
    _fxView.frame = self.bounds;
    _fxView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _fxView.userInteractionEnabled = NO;
    // iOS14 上 UIVisualEffectView 的 backing 层可能不完全跟随宿主 cornerRadius 裁切，
    // 显式给它加 masksToBounds + 同步圆角，保证毛玻璃绝不会溢出药丸圆角
    _fxView.layer.masksToBounds = YES;
    _fxView.layer.cornerRadius = self.layer.cornerRadius;
    [self addSubview:_fxView];

    // 1) 淡白底
    _tintView = [[UIView alloc] initWithFrame:self.bounds];
    _tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [self addSubview:_tintView];

    // 2) 高光层容器（位于磨砂之上）
    _highlightView = [[UIView alloc] initWithFrame:self.bounds];
    _highlightView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _highlightView.userInteractionEnabled = NO;
    _highlightView.backgroundColor = [UIColor clearColor];
    [self addSubview:_highlightView];

    self.filterType = [NSString stringWithFormat:@"UIVisualEffectView(%ld)", (long)DYBlurStyle()];
    [self updateSpecular];
    return self;
}

- (void)updateSpecular {
    CGRect b = self.bounds;
    if (CGRectIsEmpty(b)) return;

    CGFloat gloss = DYGlossIntensity();
    if (gloss <= 0.001) {
        _specular.hidden = YES;
        _specularBoost.hidden = YES;
        _edgeLayer.hidden = YES;
        return;
    }

    if (!_specular) {
        // 对角线光带：左上 → 右下的亮条，模拟光线在玻璃上扫过
        _specular = [CAGradientLayer layer];
        _specular.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:gloss].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:gloss * 0.55].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        ];
        _specular.locations = @[@0.0, @0.10, @0.18, @0.40];
        _specular.startPoint = CGPointMake(0.0, 0.0);
        _specular.endPoint   = CGPointMake(1.0, 1.0);
        [_highlightView.layer addSublayer:_specular];

        // 加强光带（普通 alpha 混合即可，稳妥不引入滤镜名风险）
        _specularBoost = [CAGradientLayer layer];
        _specularBoost.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:MIN(1.0, gloss * 1.1)].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        ];
        _specularBoost.locations = @[@0.0, @0.14, @0.24];
        _specularBoost.startPoint = _specular.startPoint;
        _specularBoost.endPoint   = _specular.endPoint;
        [_highlightView.layer addSublayer:_specularBoost];

        // 顶部细亮边（玻璃边缘反光）
        _edgeLayer = [CALayer layer];
        _edgeLayer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.32].CGColor;
        [_highlightView.layer addSublayer:_edgeLayer];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specular.hidden = NO;
    _specularBoost.hidden = NO;
    _edgeLayer.hidden = NO;
    _specular.frame = b;
    _specularBoost.frame = b;
    _edgeLayer.frame = CGRectMake(0.0, 0.0, b.size.width, 1.2);
    // 宿主圆角变化时同步给磨砂底，保证裁切一致（见 init 注释）
    _fxView.layer.cornerRadius = self.layer.cornerRadius;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateSpecular];
}

@end
