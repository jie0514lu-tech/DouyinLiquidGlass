// DYGlassView.m - 玻璃视图实现

#import "DYGlassView.h"
#import "DYPrefsSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

// 私有类/方法运行时解析（App 内同样可用，无需私有 SDK 头）
static Class DYCABackdropLayerClass(void) {
    return NSClassFromString(@"CABackdropLayer");
}

// 用运行时方式调用 CAFilter filterWithType:
static id DYCAFilterWithType(NSString *type) {
    Class cls = NSClassFromString(@"CAFilter");
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"filterWithType:");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(Class, SEL, id))objc_msgSend)(cls, sel, type);
}

@interface DYGlassView ()
@property (nonatomic, copy, readwrite) NSString *filterType;
@end

@implementation DYGlassView {
    NSString          *_groupName;
    CAGradientLayer   *_specular;
    CAGradientLayer   *_specularBoost;
    CALayer           *_specularMask;
    BOOL               _backdropConfigured;
    BOOL               _filterAttached;
}

+ (Class)layerClass {
    return DYCABackdropLayerClass() ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame source:(NSString *)source {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    static uint32_t sCounter = 0;
    _groupName = [NSString stringWithFormat:@"dy.liquidglass.%u",
                  (unsigned)++sCounter];

    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    self.opaque                 = NO;
    self.layer.masksToBounds    = YES;
    self.layer.cornerCurve      = kCACornerCurveContinuous;

    [self applyFilter];
    [self updateSpecular];
    return self;
}

- (void)applyFilter {
    CALayer *layer = self.layer;
    Class backdropCls = DYCABackdropLayerClass();
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;

    @try {
        if (!_backdropConfigured) {
            // 让渲染服务在 App 窗口内捕获"玻璃后面"的内容
            [layer setValue:@NO  forKey:@"layerUsesCoreImageFilters"];
            [layer setValue:@YES forKey:@"windowServerAware"];
            [layer setValue:_groupName forKey:@"groupName"];
            [layer setValue:@"dy.liquidglass" forKey:@"groupNamespace"];
            [layer setValue:@YES forKey:@"ignoresScreenClip"];
            CGFloat scale = DYCaptureScale();
            if (scale > 0.0) [layer setValue:@(scale) forKey:@"scale"];
            _backdropConfigured = YES;
        }

        // 滤镜类型选择：优先系统材质模糊（App 内已注册），失败回退高斯模糊
        NSString *type = DYFilterType();
        if (!type.length) type = @"systemMaterialBlur";

        NSArray *existing = layer.filters;
        if (_filterAttached && existing.count == 1) {
            NSString *cur = nil;
            @try { cur = [existing.firstObject valueForKey:@"type"]; } @catch (...) {}
            if ([cur isEqualToString:type]) return; // 已套用同款，跳过
        }

        id glassFilter = DYCAFilterWithType(type);
        if (!glassFilter && ![type isEqualToString:@"gaussianBlur"]) {
            // 回退：系统材质类型在新系统/旧系统可能不可用
            type = @"gaussianBlur";
            glassFilter = DYCAFilterWithType(type);
        }
        if (!glassFilter) return;

        CGFloat blur = DYBlurRadius();
        if ([type isEqualToString:@"gaussianBlur"] && blur > 0.0) {
            @try {
                [glassFilter setValue:@(blur) forKey:@"inputRadius"];
                [glassFilter setValue:@YES forKey:@"inputNormalizeEdges"];
            } @catch (__unused NSException *e) {}
        }

        layer.filters = @[glassFilter];
        self.filterType = [type copy];
        _filterAttached = YES;
    } @catch (NSException *e) {
        // 静默失败，保持系统原样
    }
}

- (void)updateSpecular {
    if (CGRectIsEmpty(self.bounds)) return;
    CGFloat gloss = DYGlossIntensity();
    if (gloss <= 0.001) {
        _specular.hidden = YES;
        _specularBoost.hidden = YES;
        return;
    }

    if (!_specular) {
        _specular = [CAGradientLayer layer];
        _specular.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:gloss].CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:gloss].CGColor,
        ];
        _specular.locations = @[@0.0, @0.5, @1.0];
        _specularMask = [CALayer layer];
        _specularMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularMask.borderColor     = UIColor.blackColor.CGColor;
        _specular.mask = _specularMask;
        [self.layer addSublayer:_specular];

        _specularBoost = [CAGradientLayer layer];
        _specularBoost.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:MIN(1.0, gloss * 1.2)].CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:MIN(1.0, gloss * 1.2)].CGColor,
        ];
        _specularBoost.locations = @[@0.0, @0.5, @1.0];
        _specularBoost.compositingFilter = @"overlayBlendMode";
        _specularBoostMask = [CALayer layer];
        _specularBoostMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularBoostMask.borderColor     = UIColor.blackColor.CGColor;
        _specularBoost.mask = _specularBoostMask;
        [self.layer addSublayer:_specularBoost];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specular.hidden = NO;
    _specularBoost.hidden = NO;
    for (CALayer *g in @[_specular, _specularBoost]) g.frame = self.bounds;
    for (CALayer *m in @[_specularMask, _specularBoostMask]) {
        m.frame = self.bounds;
        m.cornerRadius = self.layer.cornerRadius;
        m.cornerCurve  = self.layer.cornerCurve;
        m.borderWidth  = 0.75;
    }
    // 对角线高光方向（左上 → 右下）
    _specular.startPoint = CGPointMake(0.0, 0.0);
    _specular.endPoint   = CGPointMake(1.0, 1.0);
    _specularBoost.startPoint = _specular.startPoint;
    _specularBoost.endPoint   = _specular.endPoint;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyFilter];
    [self updateSpecular];
}

@end
