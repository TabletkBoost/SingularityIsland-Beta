#import "SingularityView.h"
#import <math.h>

#pragma mark - Helper: CAAnimation Delegate Block Wrapper

@interface SIAnimationBlockDelegate : NSObject <CAAnimationDelegate>
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL finished);
+ (instancetype)delegateWithCompletion:(nullable void (^)(BOOL finished))block;
@end

@implementation SIAnimationBlockDelegate

+ (instancetype)delegateWithCompletion:(nullable void (^)(BOOL finished))block {
    SIAnimationBlockDelegate *delegate = [[SIAnimationBlockDelegate alloc] init];
    delegate.completionBlock = block;
    return delegate;
}

- (void)animationDidStop:(CAAnimation *)anim finished:(BOOL)flag {
    if (self.completionBlock) {
        void (^block)(BOOL) = self.completionBlock;
        self.completionBlock = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            block(flag);
        });
    }
}

@end

#pragma mark - SingularityConfig

@implementation SingularityConfig

+ (instancetype)loadFromRootlessDisk {
    SingularityConfig *cfg = [[SingularityConfig alloc] init];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kSingularityPrefsPath];

    cfg.enabled = dict[@"enabled"] ? [dict[@"enabled"] boolValue] : YES;
    cfg.offsetX = dict[@"offsetX"] ? [dict[@"offsetX"] doubleValue] : 0.0;
    cfg.offsetY = dict[@"offsetY"] ? [dict[@"offsetY"] doubleValue] : 8.0;
    cfg.compactWidth = dict[@"compactWidth"] ? [dict[@"compactWidth"] doubleValue] : 126.0;
    cfg.compactHeight = dict[@"compactHeight"] ? [dict[@"compactHeight"] doubleValue] : 34.0;
    cfg.springStiffness = dict[@"springStiffness"] ? [dict[@"springStiffness"] doubleValue] : 380.0;
    cfg.persistentSilentSatellite = dict[@"persistentSilentSatellite"] ? [dict[@"persistentSilentSatellite"] boolValue] : YES;

    // Clamp values to safe geometric & physical ranges
    cfg.compactWidth = MAX(96.0, MIN(220.0, cfg.compactWidth));
    cfg.compactHeight = MAX(26.0, MIN(48.0, cfg.compactHeight));
    cfg.springStiffness = MAX(180.0, MIN(580.0, cfg.springStiffness));
    return cfg;
}

@end

#pragma mark - SingularityPassthroughWindow

@implementation SingularityPassthroughWindow

- (BOOL)_canShowWhileLocked {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.interactivePillView && !self.interactivePillView.hidden && self.interactivePillView.alpha > 0.01) {
        CGPoint pillPt = [self convertPoint:point toView:self.interactivePillView];
        if (CGRectContainsPoint(CGRectInset(self.interactivePillView.bounds, -6.0, -6.0), pillPt)) {
            UIView *hit = [self.interactivePillView hitTest:pillPt withEvent:event];
            return hit ?: self.interactivePillView;
        }
    }
    if (self.interactiveSatelliteView && !self.interactiveSatelliteView.hidden && self.interactiveSatelliteView.alpha > 0.01) {
        CGPoint satPt = [self convertPoint:point toView:self.interactiveSatelliteView];
        if (CGRectContainsPoint(CGRectInset(self.interactiveSatelliteView.bounds, -4.0, -4.0), satPt)) {
            return self.interactiveSatelliteView;
        }
    }
    // Pass all other touches directly through to SpringBoard / active app
    return nil;
}

@end

#pragma mark - SingularityView Private Interface

@interface SingularityView ()

@property (nonatomic, strong, readwrite) SingularityConfig *config;
@property (nonatomic, assign, readwrite) SingularityDisplayState currentState;

// Core Pill Geometry Layers (GPU-composited, zero UIVisualEffectView)
@property (nonatomic, strong) UIView *pillContainerView;
@property (nonatomic, strong) CAShapeLayer *pillShapeLayer;
@property (nonatomic, strong) CAShapeLayer *pillRimLayer;
@property (nonatomic, strong) UIView *contentContainerView;
@property (nonatomic, strong) CAShapeLayer *contentMaskLayer;

// Secondary Singularity Satellite Pill
@property (nonatomic, strong) UIView *satelliteContainerView;
@property (nonatomic, strong) CAShapeLayer *satelliteBgLayer;
@property (nonatomic, strong) CALayer *satelliteIndicatorDotLayer;
@property (nonatomic, assign) BOOL satelliteVisible;
@property (nonatomic, assign) BOOL isScreenRecording;
@property (nonatomic, assign) BOOL isMicrophoneActive;
@property (nonatomic, assign) BOOL isSilentActive;

// Transient State Tracking
@property (nonatomic, strong, nullable) NSTimer *autoCollapseTimer;
@property (nonatomic, assign) NSUInteger animationGeneration;

// Cached Now Playing Metadata
@property (nonatomic, copy, nullable) NSString *mediaTitle;
@property (nonatomic, copy, nullable) NSString *mediaArtist;
@property (nonatomic, strong, nullable) UIImage *mediaArtwork;
@property (nonatomic, assign) BOOL mediaIsPlaying;

// Active Content Subviews (managed inside contentContainerView)
@property (nonatomic, strong) NSMutableArray<UIView *> *activeContentViews;

// Current Pill Size
@property (nonatomic, assign) CGSize currentPillSize;
@property (nonatomic, assign) CGFloat currentCornerRadius;

@end

@implementation SingularityView

#pragma mark - Lifecycle & Setup

- (instancetype)initWithFrame:(CGRect)frame config:(SingularityConfig *)config {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        _config = config ?: [SingularityConfig loadFromRootlessDisk];
        _currentState = SingularityDisplayStateIdle;
        _activeContentViews = [NSMutableArray array];
        _currentPillSize = CGSizeMake(_config.compactWidth, _config.compactHeight);
        _currentCornerRadius = _config.compactHeight * 0.5;

        [self setupPillLayers];
        [self setupSatelliteLayers];
        [self setupGestures];
        [self layoutPillImmediately];
        self.hidden = !_config.enabled;
    }
    return self;
}

- (UIView *)pillHitTargetView {
    return self.pillContainerView;
}

- (UIView *)satelliteHitTargetView {
    return self.satelliteContainerView;
}

- (void)setupPillLayers {
    self.pillContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.config.compactWidth, self.config.compactHeight)];
    self.pillContainerView.backgroundColor = [UIColor clearColor];
    self.pillContainerView.userInteractionEnabled = YES;
    [self addSubview:self.pillContainerView];

    // Main OLED-black pill shape (GPU-composited path)
    self.pillShapeLayer = [CAShapeLayer layer];
    self.pillShapeLayer.fillColor = [UIColor blackColor].CGColor;
    self.pillShapeLayer.shadowColor = [UIColor blackColor].CGColor;
    self.pillShapeLayer.shadowOpacity = 0.42f;
    self.pillShapeLayer.shadowRadius = 10.0f;
    self.pillShapeLayer.shadowOffset = CGSizeMake(0.0, 4.0);
    [self.pillContainerView.layer addSublayer:self.pillShapeLayer];

    // Subtle specular rim for depth & charging pulse feedback
    self.pillRimLayer = [CAShapeLayer layer];
    self.pillRimLayer.fillColor = [UIColor clearColor].CGColor;
    self.pillRimLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.13].CGColor;
    self.pillRimLayer.lineWidth = 0.75;
    [self.pillContainerView.layer addSublayer:self.pillRimLayer];

    // Content container masked by CAShapeLayer to clip erupting/collapsing elements cleanly at the event horizon
    self.contentContainerView = [[UIView alloc] initWithFrame:self.pillContainerView.bounds];
    self.contentContainerView.backgroundColor = [UIColor clearColor];
    self.contentContainerView.userInteractionEnabled = YES;
    self.contentMaskLayer = [CAShapeLayer layer];
    self.contentMaskLayer.fillColor = [UIColor blackColor].CGColor;
    self.contentContainerView.layer.mask = self.contentMaskLayer;
    [self.pillContainerView addSubview:self.contentContainerView];
}

- (void)setupSatelliteLayers {
    CGFloat d = self.config.compactHeight;
    self.satelliteContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    self.satelliteContainerView.backgroundColor = [UIColor clearColor];
    self.satelliteContainerView.hidden = YES;
    self.satelliteContainerView.alpha = 0.0;
    [self addSubview:self.satelliteContainerView];

    self.satelliteBgLayer = [CAShapeLayer layer];
    self.satelliteBgLayer.fillColor = [UIColor blackColor].CGColor;
    self.satelliteBgLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.13].CGColor;
    self.satelliteBgLayer.lineWidth = 0.75;
    [self.satelliteContainerView.layer addSublayer:self.satelliteBgLayer];

    self.satelliteIndicatorDotLayer = [CALayer layer];
    self.satelliteIndicatorDotLayer.backgroundColor = [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:1.0].CGColor;
    self.satelliteIndicatorDotLayer.bounds = CGRectMake(0, 0, 10.0, 10.0);
    self.satelliteIndicatorDotLayer.cornerRadius = 5.0;
    self.satelliteIndicatorDotLayer.shadowOpacity = 0.75f;
    self.satelliteIndicatorDotLayer.shadowRadius = 4.0f;
    self.satelliteIndicatorDotLayer.shadowOffset = CGSizeZero;
    [self.satelliteContainerView.layer addSublayer:self.satelliteIndicatorDotLayer];
}

- (void)setupGestures {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillTap:)];
    [self.pillContainerView addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillLongPress:)];
    longPress.minimumPressDuration = 0.35;
    [self.pillContainerView addGestureRecognizer:longPress];
}

#pragma mark - Configuration & Geometry Helpers

- (CGPoint)pillAnchorCenterForSize:(CGSize)size {
    CGFloat screenWidth = CGRectGetWidth(self.bounds);
    CGFloat centerX = (screenWidth * 0.5) + self.config.offsetX;
    CGFloat topY = self.config.offsetY;
    return CGPointMake(centerX, topY + (size.height * 0.5));
}

- (CGFloat)effectiveStiffness {
    return self.config.springStiffness;
}

- (CGFloat)effectiveDampingForMass:(CGFloat)mass stiffness:(CGFloat)stiffness dampingRatio:(CGFloat)zeta {
    // Physical critical damping formula: c = 2 * zeta * sqrt(k * m)
    return 2.0 * zeta * sqrt(stiffness * mass);
}

- (CFTimeInterval)gravitationalPullDuration {
    // Higher stiffness => faster gravitational pull (clamped 0.24s–0.44s)
    CGFloat normalized = (self.config.springStiffness - 180.0) / 400.0; // 0..1
    return 0.42 - (normalized * 0.16);
}

- (void)layoutPillImmediately {
    CGSize sz = self.currentPillSize;
    CGPoint center = [self pillAnchorCenterForSize:sz];
    CGRect bounds = CGRectMake(0, 0, sz.width, sz.height);
    CGPathRef pillPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:self.currentCornerRadius].CGPath;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.pillContainerView.bounds = bounds;
    self.pillContainerView.center = center;
    self.contentContainerView.frame = bounds;

    self.pillShapeLayer.frame = bounds;
    self.pillShapeLayer.path = pillPath;
    self.pillShapeLayer.shadowPath = pillPath;

    self.pillRimLayer.frame = bounds;
    self.pillRimLayer.path = pillPath;

    self.contentMaskLayer.frame = bounds;
    self.contentMaskLayer.path = pillPath;
    [CATransaction commit];

    [self updateSatelliteGeometryAnimated:NO];
}

- (void)applyConfig:(SingularityConfig *)config animated:(BOOL)animated {
    self.config = config;
    self.hidden = !config.enabled;

    if (self.currentState == SingularityDisplayStateIdle) {
        self.currentPillSize = CGSizeMake(config.compactWidth, config.compactHeight);
        self.currentCornerRadius = config.compactHeight * 0.5;
    } else if (self.currentState == SingularityDisplayStateMediaCompact) {
        self.currentPillSize = CGSizeMake(MAX(config.compactWidth + 58.0, 186.0), config.compactHeight);
        self.currentCornerRadius = config.compactHeight * 0.5;
    }

    if (animated) {
        [self animatePillToSize:self.currentPillSize cornerRadius:self.currentCornerRadius];
    } else {
        [self layoutPillImmediately];
    }

    [self refreshSatelliteState];
}

#pragma mark - Black Hole Singularity CoreAnimation Math

/**
 * Constructs a 3D spaghettification transform matrix:
 *   T = P * R(theta) * S(sParallel, sPerp, 1) * R(-theta)
 * stretching the layer along the exact gravitational vector toward the singularity
 * while compressing it perpendicular to the radial axis.
 */
static CATransform3D SISpaghettificationTransform(CGFloat angleRad, CGFloat scaleParallel, CGFloat scalePerpendicular) {
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / 600.0; // Subtle perspective lensing
    t = CATransform3DRotate(t, angleRad, 0.0, 0.0, 1.0);
    t = CATransform3DScale(t, scaleParallel, scalePerpendicular, 1.0);
    t = CATransform3DRotate(t, -angleRad, 0.0, 0.0, 1.0);
    return t;
}

- (void)absorbLayer:(CALayer *)layer
  towardSingularity:(CGPoint)singularityPoint
              delay:(CFTimeInterval)delay
           duration:(CFTimeInterval)duration
         completion:(nullable void (^)(void))completion {

    CGPoint startPos = layer.position;
    CGFloat dx = singularityPoint.x - startPos.x;
    CGFloat dy = singularityPoint.y - startPos.y;
    CGFloat distance = hypot(dx, dy);
    CGFloat radialAngle = (distance > 0.5) ? atan2(dy, dx) : 0.0;

    // 1. Gravitational Acceleration Position Keyframe (slow start -> violent event-horizon pull)
    CGPoint midPos = CGPointMake(startPos.x + dx * 0.28, startPos.y + dy * 0.28);
    CAKeyframeAnimation *posAnim = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    posAnim.values = @[
        [NSValue valueWithCGPoint:startPos],
        [NSValue valueWithCGPoint:midPos],
        [NSValue valueWithCGPoint:singularityPoint]
    ];
    posAnim.keyTimes = @[@0.0, @0.42, @1.0];
    posAnim.timingFunctions = @[
        [CAMediaTimingFunction functionWithControlPoints:0.45f :0.0f :0.85f :0.20f],
        [CAMediaTimingFunction functionWithControlPoints:0.70f :0.0f :0.95f :0.35f]
    ];

    // 2. Spaghettification & Event Horizon Compression (non-uniform CATransform3D -> 0.01 collapse)
    CATransform3D t0 = CATransform3DIdentity;
    CATransform3D t1 = SISpaghettificationTransform(radialAngle, 1.26, 0.78);
    CATransform3D t2 = SISpaghettificationTransform(radialAngle, 1.54, 0.40);
    CATransform3D t3 = CATransform3DMakeScale(0.01, 0.01, 1.0);

    CAKeyframeAnimation *transformAnim = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    transformAnim.values = @[
        [NSValue valueWithCATransform3D:t0],
        [NSValue valueWithCATransform3D:t1],
        [NSValue valueWithCATransform3D:t2],
        [NSValue valueWithCATransform3D:t3]
    ];
    transformAnim.keyTimes = @[@0.0, @0.34, @0.72, @1.0];
    transformAnim.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn],
        [CAMediaTimingFunction functionWithControlPoints:0.60f :0.0f :0.90f :0.30f],
        [CAMediaTimingFunction functionWithControlPoints:0.75f :0.0f :1.0f :0.45f]
    ];

    // 3. Event Horizon Opacity Drop (stays crisp until crossing the border, then vanishes)
    CAKeyframeAnimation *opacityAnim = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    opacityAnim.values = @[@(layer.opacity), @(layer.opacity * 0.92f), @0.0f];
    opacityAnim.keyTimes = @[@0.0, @0.68, @1.0];

    // 4. Composite CAAnimationGroup
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[posAnim, transformAnim, opacityAnim];
    group.duration = duration;
    group.beginTime = CACurrentMediaTime() + delay;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;
    if (completion) {
        group.delegate = [SIAnimationBlockDelegate delegateWithCompletion:^(BOOL finished) {
            completion();
        }];
    }

    [layer addAnimation:group forKey:@"singularityAbsorption"];
}

- (void)ejectLayer:(CALayer *)layer
   fromSingularity:(CGPoint)singularityPoint
        toPosition:(CGPoint)targetPosition
      axisStretchX:(CGFloat)stretchX
      axisStretchY:(CGFloat)stretchY
             delay:(CFTimeInterval)delay {

    CGFloat stiffness = [self effectiveStiffness];
    CGFloat mass = 0.85;
    CGFloat damping = [self effectiveDampingForMass:mass stiffness:stiffness dampingRatio:0.72];

    // Ensure final model state is set cleanly before attaching animation
    layer.position = targetPosition;
    layer.transform = CATransform3DIdentity;
    layer.opacity = 1.0f;

    // 1. Spring Ejection along Position Vector
    CASpringAnimation *posSpring = [CASpringAnimation animationWithKeyPath:@"position"];
    posSpring.fromValue = [NSValue valueWithCGPoint:singularityPoint];
    posSpring.toValue = [NSValue valueWithCGPoint:targetPosition];
    posSpring.mass = mass;
    posSpring.stiffness = stiffness;
    posSpring.damping = damping;
    posSpring.initialVelocity = 4.2;
    posSpring.duration = posSpring.settlingDuration;

    // 2. Hyper-Compressed -> Axis-Stretched Eruption -> Organic Overshoot -> Rest
    CATransform3D tStart = CATransform3DMakeScale(0.01, 0.01, 1.0);
    CATransform3D tErupt = CATransform3DMakeScale(stretchX, stretchY, 1.0);
    tErupt.m34 = -1.0 / 600.0;
    CATransform3D tOvershoot = CATransform3DMakeScale(1.045, 1.035, 1.0);
    CATransform3D tEnd = CATransform3DIdentity;

    CAKeyframeAnimation *transformAnim = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    transformAnim.values = @[
        [NSValue valueWithCATransform3D:tStart],
        [NSValue valueWithCATransform3D:tErupt],
        [NSValue valueWithCATransform3D:tOvershoot],
        [NSValue valueWithCATransform3D:tEnd]
    ];
    transformAnim.keyTimes = @[@0.0, @0.32, @0.68, @1.0];
    transformAnim.timingFunctions = @[
        [CAMediaTimingFunction functionWithControlPoints:0.12f :0.85f :0.28f :1.0f],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]
    ];
    transformAnim.duration = MIN(0.46, posSpring.settlingDuration * 0.85);

    // 3. Fast Opacity Reveal
    CABasicAnimation *opacityAnim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacityAnim.fromValue = @0.0f;
    opacityAnim.toValue = @1.0f;
    opacityAnim.duration = 0.16;
    opacityAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[posSpring, transformAnim, opacityAnim];
    group.duration = MAX(posSpring.settlingDuration, transformAnim.duration);
    group.beginTime = CACurrentMediaTime() + delay;
    group.fillMode = kCAFillModeBackwards;
    group.removedOnCompletion = YES;

    [layer addAnimation:group forKey:@"singularityEjection"];
}

- (void)triggerMassAbsorptionRecoil {
    // High-stiffness mass-absorption recoil: pill briefly expands ~4% and snaps back
    // Spec: mass 0.8, stiffness 380, damping 22
    CASpringAnimation *recoil = [CASpringAnimation animationWithKeyPath:@"transform"];
    recoil.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.042, 1.048, 1.0)];
    recoil.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    recoil.mass = 0.8;
    recoil.stiffness = 380.0;
    recoil.damping = 22.0;
    recoil.initialVelocity = 6.0;
    recoil.duration = recoil.settlingDuration;
    recoil.removedOnCompletion = YES;

    [self.pillContainerView.layer removeAnimationForKey:@"massAbsorptionRecoil"];
    [self.pillContainerView.layer addAnimation:recoil forKey:@"massAbsorptionRecoil"];
}

#pragma mark - GPU-Composited Pill Morphing

- (void)animatePillToSize:(CGSize)targetSize cornerRadius:(CGFloat)targetRadius {
    CGSize oldSize = self.currentPillSize;
    CGFloat oldRadius = self.currentCornerRadius;
    self.currentPillSize = targetSize;
    self.currentCornerRadius = targetRadius;

    CGPoint oldCenter = self.pillContainerView.center;
    CGPoint newCenter = [self pillAnchorCenterForSize:targetSize];

    CGRect oldBounds = CGRectMake(0, 0, oldSize.width, oldSize.height);
    CGRect newBounds = CGRectMake(0, 0, targetSize.width, targetSize.height);

    CGPathRef oldPath = [UIBezierPath bezierPathWithRoundedRect:oldBounds cornerRadius:oldRadius].CGPath;
    CGPathRef newPath = [UIBezierPath bezierPathWithRoundedRect:newBounds cornerRadius:targetRadius].CGPath;

    CGFloat stiffness = [self effectiveStiffness];
    CGFloat mass = 0.85;
    CGFloat damping = [self effectiveDampingForMass:mass stiffness:stiffness dampingRatio:0.78];

    // Commit final model values without implicit animations
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.pillContainerView.bounds = newBounds;
    self.pillContainerView.center = newCenter;
    self.contentContainerView.frame = newBounds;

    self.pillShapeLayer.frame = newBounds;
    self.pillShapeLayer.path = newPath;
    self.pillShapeLayer.shadowPath = newPath;

    self.pillRimLayer.frame = newBounds;
    self.pillRimLayer.path = newPath;

    self.contentMaskLayer.frame = newBounds;
    self.contentMaskLayer.path = newPath;
    [CATransaction commit];

    // Animate container bounds & center with matched CASpringAnimation
    CASpringAnimation *boundsSpring = [CASpringAnimation animationWithKeyPath:@"bounds"];
    boundsSpring.fromValue = [NSValue valueWithCGRect:oldBounds];
    boundsSpring.toValue = [NSValue valueWithCGRect:newBounds];
    boundsSpring.mass = mass;
    boundsSpring.stiffness = stiffness;
    boundsSpring.damping = damping;
    boundsSpring.duration = boundsSpring.settlingDuration;

    CASpringAnimation *posSpring = [CASpringAnimation animationWithKeyPath:@"position"];
    posSpring.fromValue = [NSValue valueWithCGPoint:oldCenter];
    posSpring.toValue = [NSValue valueWithCGPoint:newCenter];
    posSpring.mass = mass;
    posSpring.stiffness = stiffness;
    posSpring.damping = damping;
    posSpring.duration = posSpring.settlingDuration;

    [self.pillContainerView.layer addAnimation:boundsSpring forKey:@"pillBoundsSpring"];
    [self.pillContainerView.layer addAnimation:posSpring forKey:@"pillPositionSpring"];

    // Animate CAShapeLayer paths (pill fill, rim, shadowPath, and content clip mask)
    NSArray<CAShapeLayer *> *shapeLayers = @[self.pillShapeLayer, self.pillRimLayer, self.contentMaskLayer];
    for (CAShapeLayer *shape in shapeLayers) {
        CASpringAnimation *pathSpring = [CASpringAnimation animationWithKeyPath:@"path"];
        pathSpring.fromValue = (__bridge id)oldPath;
        pathSpring.toValue = (__bridge id)newPath;
        pathSpring.mass = mass;
        pathSpring.stiffness = stiffness;
        pathSpring.damping = damping;
        pathSpring.duration = pathSpring.settlingDuration;
        [shape addAnimation:pathSpring forKey:@"pillPathSpring"];

        if (shape == self.pillShapeLayer) {
            CASpringAnimation *shadowSpring = [CASpringAnimation animationWithKeyPath:@"shadowPath"];
            shadowSpring.fromValue = (__bridge id)oldPath;
            shadowSpring.toValue = (__bridge id)newPath;
            shadowSpring.mass = mass;
            shadowSpring.stiffness = stiffness;
            shadowSpring.damping = damping;
            shadowSpring.duration = shadowSpring.settlingDuration;
            [shape addAnimation:shadowSpring forKey:@"pillShadowSpring"];
        }
    }

    [self updateSatelliteGeometryAnimated:YES];
}

#pragma mark - Detached Color Indicator Dot (Secondary Singularity Satellite)

- (void)setScreenRecordingActive:(BOOL)active {
    if (self.isScreenRecording == active) return;
    self.isScreenRecording = active;
    [self refreshSatelliteState];
}

- (void)setMicrophoneActive:(BOOL)active {
    if (self.isMicrophoneActive == active) return;
    self.isMicrophoneActive = active;
    [self refreshSatelliteState];
}

- (void)setSilentStateForSatellite:(BOOL)isMuted {
    if (self.isSilentActive == isMuted) return;
    self.isSilentActive = isMuted;
    [self refreshSatelliteState];
}

- (SingularitySatelliteReason)activeSatelliteReason {
    if (self.isScreenRecording) return SingularitySatelliteReasonScreenRecording;
    if (self.isMicrophoneActive) return SingularitySatelliteReasonMicrophone;
    if (self.isSilentActive && self.config.persistentSilentSatellite) return SingularitySatelliteReasonSilent;
    return SingularitySatelliteReasonNone;
}

- (UIColor *)colorForSatelliteReason:(SingularitySatelliteReason)reason {
    switch (reason) {
        case SingularitySatelliteReasonScreenRecording:
        case SingularitySatelliteReasonSilent:
            return [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:1.0]; // #FF3B30
        case SingularitySatelliteReasonMicrophone:
            return [UIColor colorWithRed:1.0 green:0.584 blue:0.0 alpha:1.0]; // #FF9500
        default:
            return [UIColor clearColor];
    }
}

- (CGPoint)targetSatelliteCenter {
    CGFloat d = self.config.compactHeight;
    CGFloat pillRightEdge = self.pillContainerView.center.x + (self.currentPillSize.width * 0.5);
    CGFloat centerY = self.config.offsetY + (d * 0.5);
    // Exact 6pt gap to the right of the main pill
    return CGPointMake(pillRightEdge + 6.0 + (d * 0.5), centerY);
}

- (void)updateSatelliteGeometryAnimated:(BOOL)animated {
    CGFloat d = self.config.compactHeight;
    CGRect bounds = CGRectMake(0, 0, d, d);
    CGPathRef circlePath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:d * 0.5].CGPath;
    CGPoint targetCenter = [self targetSatelliteCenter];

    // Hide satellite visually if the main pill is wide-expanded (notification / expanded media)
    BOOL wideExpanded = (self.currentState == SingularityDisplayStateNotification ||
                         self.currentState == SingularityDisplayStateMediaExpanded);

    if (wideExpanded && self.satelliteVisible) {
        self.satelliteContainerView.alpha = 0.0;
        return;
    } else if (!wideExpanded && self.satelliteVisible) {
        self.satelliteContainerView.alpha = 1.0;
    }

    if (!animated) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.satelliteContainerView.bounds = bounds;
        self.satelliteContainerView.center = targetCenter;
        self.satelliteBgLayer.frame = bounds;
        self.satelliteBgLayer.path = circlePath;
        self.satelliteIndicatorDotLayer.position = CGPointMake(d * 0.5, d * 0.5);
        [CATransaction commit];
    } else if (self.satelliteVisible) {
        CGPoint oldCenter = self.satelliteContainerView.center;
        self.satelliteContainerView.bounds = bounds;
        self.satelliteContainerView.center = targetCenter;
        self.satelliteBgLayer.frame = bounds;
        self.satelliteBgLayer.path = circlePath;
        self.satelliteIndicatorDotLayer.position = CGPointMake(d * 0.5, d * 0.5);

        CASpringAnimation *moveSpring = [CASpringAnimation animationWithKeyPath:@"position"];
        moveSpring.fromValue = [NSValue valueWithCGPoint:oldCenter];
        moveSpring.toValue = [NSValue valueWithCGPoint:targetCenter];
        moveSpring.mass = 0.85;
        moveSpring.stiffness = [self effectiveStiffness];
        moveSpring.damping = [self effectiveDampingForMass:0.85 stiffness:moveSpring.stiffness dampingRatio:0.78];
        moveSpring.duration = moveSpring.settlingDuration;
        [self.satelliteContainerView.layer addAnimation:moveSpring forKey:@"satelliteTrackPill"];
    }
}

- (void)refreshSatelliteState {
    SingularitySatelliteReason reason = [self activeSatelliteReason];
    BOOL shouldShow = (reason != SingularitySatelliteReasonNone) && self.config.enabled;

    if (shouldShow) {
        UIColor *dotColor = [self colorForSatelliteReason:reason];
        self.satelliteIndicatorDotLayer.backgroundColor = dotColor.CGColor;
        self.satelliteIndicatorDotLayer.shadowColor = dotColor.CGColor;

        if (!self.satelliteVisible) {
            self.satelliteVisible = YES;
            [self animateSatelliteBudOff];
        } else {
            [self updateSatelliteGeometryAnimated:YES];
        }
    } else if (self.satelliteVisible) {
        self.satelliteVisible = NO;
        [self animateSatelliteAbsorbBack];
    }
}

- (void)animateSatelliteBudOff {
    CGFloat d = self.config.compactHeight;
    CGRect bounds = CGRectMake(0, 0, d, d);
    CGPathRef circlePath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:d * 0.5].CGPath;

    CGPoint targetCenter = [self targetSatelliteCenter];
    CGFloat pillRightEdge = self.pillContainerView.center.x + (self.currentPillSize.width * 0.5);
    CGPoint originInsidePill = CGPointMake(pillRightEdge - (d * 0.35), targetCenter.y);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.satelliteContainerView.hidden = NO;
    self.satelliteContainerView.alpha = 1.0;
    self.satelliteContainerView.bounds = bounds;
    self.satelliteContainerView.center = targetCenter;
    self.satelliteContainerView.layer.transform = CATransform3DIdentity;
    self.satelliteBgLayer.frame = bounds;
    self.satelliteBgLayer.path = circlePath;
    self.satelliteIndicatorDotLayer.position = CGPointMake(d * 0.5, d * 0.5);
    [CATransaction commit];

    // 1. Spring detachment from right edge of main pill
    CASpringAnimation *posSpring = [CASpringAnimation animationWithKeyPath:@"position"];
    posSpring.fromValue = [NSValue valueWithCGPoint:originInsidePill];
    posSpring.toValue = [NSValue valueWithCGPoint:targetCenter];
    posSpring.mass = 0.9;
    posSpring.stiffness = 320.0;
    posSpring.damping = 20.0;
    posSpring.initialVelocity = 5.5;
    posSpring.duration = posSpring.settlingDuration;

    // 2. Liquid surface-tension stretch (budding off horizontally, pinching vertically, snapping circular)
    CAKeyframeAnimation *stretchAnim = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    stretchAnim.values = @[
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.35, 0.55, 1.0)],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.34, 0.72, 1.0)],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.92, 1.08, 1.0)],
        [NSValue valueWithCATransform3D:CATransform3DIdentity]
    ];
    stretchAnim.keyTimes = @[@0.0, @0.30, @0.65, @1.0];
    stretchAnim.duration = 0.44;
    stretchAnim.timingFunctions = @[
        [CAMediaTimingFunction functionWithControlPoints:0.20f :0.85f :0.30f :1.0f],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]
    ];

    [self.satelliteContainerView.layer removeAllAnimations];
    [self.satelliteContainerView.layer addAnimation:posSpring forKey:@"satelliteBudPosition"];
    [self.satelliteContainerView.layer addAnimation:stretchAnim forKey:@"satelliteBudStretch"];

    // Subtle pulsing glow on the color indicator dot
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.55;
    pulse.duration = 1.25;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.satelliteIndicatorDotLayer addAnimation:pulse forKey:@"satelliteDotPulse"];
}

- (void)animateSatelliteAbsorbBack {
    [self.satelliteIndicatorDotLayer removeAnimationForKey:@"satelliteDotPulse"];
    CGPoint pillCenter = self.pillContainerView.center;
    CFTimeInterval dur = [self gravitationalPullDuration] * 0.9;

    __weak typeof(self) weakSelf = self;
    [self absorbLayer:self.satelliteContainerView.layer
    towardSingularity:pillCenter
                delay:0.0
             duration:dur
           completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.satelliteVisible) {
            strongSelf.satelliteContainerView.hidden = YES;
            [strongSelf.satelliteContainerView.layer removeAllAnimations];
            [strongSelf triggerMassAbsorptionRecoil];
        }
    }];
}

#pragma mark - Content Lifecycle (Absorption -> Removal)

- (void)invalidateAutoCollapseTimer {
    if (self.autoCollapseTimer) {
        [self.autoCollapseTimer invalidate];
        self.autoCollapseTimer = nil;
    }
}

- (void)absorbCurrentContentAndRun:(nullable void (^)(void))afterAbsorption {
    if (self.activeContentViews.count == 0) {
        if (afterAbsorption) afterAbsorption();
        return;
    }

    NSArray<UIView *> *viewsToAbsorb = [self.activeContentViews copy];
    [self.activeContentViews removeAllObjects];

    CGPoint singularity = CGPointMake(self.currentPillSize.width * 0.5, self.currentPillSize.height * 0.5);
    CFTimeInterval pullDuration = [self gravitationalPullDuration];

    __block NSInteger remaining = (NSInteger)viewsToAbsorb.count;
    for (NSUInteger idx = 0; idx < viewsToAbsorb.count; idx++) {
        UIView *subview = viewsToAbsorb[idx];
        subview.userInteractionEnabled = NO;
        CFTimeInterval stagger = idx * 0.025;

        [self absorbLayer:subview.layer
        towardSingularity:singularity
                    delay:stagger
                 duration:pullDuration
               completion:^{
            [subview removeFromSuperview];
            remaining--;
            if (remaining == 0) {
                if (afterAbsorption) {
                    afterAbsorption();
                }
            }
        }];
    }
}

- (void)collapseToRestingState {
    [self invalidateAutoCollapseTimer];
    NSUInteger gen = ++self.animationGeneration;

    __weak typeof(self) weakSelf = self;
    [self absorbCurrentContentAndRun:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.animationGeneration != gen) return;

        if (strongSelf.mediaTitle.length > 0 && strongSelf.mediaIsPlaying) {
            [strongSelf transitionToMediaCompact];
        } else {
            strongSelf.currentState = SingularityDisplayStateIdle;
            [strongSelf animatePillToSize:CGSizeMake(strongSelf.config.compactWidth, strongSelf.config.compactHeight)
                             cornerRadius:strongSelf.config.compactHeight * 0.5];
            [strongSelf triggerMassAbsorptionRecoil];
        }
    }];
}

#pragma mark - 1. Silent Mode / Ringer Switch Animation (iPhone 14 Pro – 17 Pro Max Style)

- (void)showSilentMode:(BOOL)isMuted {
    if (!self.config.enabled) return;

    [self setSilentStateForSatellite:isMuted];
    [self invalidateAutoCollapseTimer];
    NSUInteger gen = ++self.animationGeneration;

    __weak typeof(self) weakSelf = self;
    [self absorbCurrentContentAndRun:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.animationGeneration != gen) return;

        strongSelf.currentState = SingularityDisplayStateSilentAlert;
        CGSize targetSize = CGSizeMake(216.0, 38.0);
        [strongSelf animatePillToSize:targetSize cornerRadius:19.0];

        CGPoint singularity = CGPointMake(targetSize.width * 0.5, targetSize.height * 0.5);

        // Left: Vibrant Red Bell (#FF3B30) when muted, Crisp White/Silver Bell (#F2F2F7) when Ring
        UIColor *accentColor = isMuted
            ? [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:1.0]
            : [UIColor colorWithRed:0.949 green:0.949 blue:0.969 alpha:1.0];

        UIView *bellBadge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26.0, 26.0)];
        bellBadge.backgroundColor = isMuted
            ? [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:0.22]
            : [UIColor colorWithWhite:1.0 alpha:0.14];
        bellBadge.layer.cornerRadius = 13.0;

        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
        UIImage *bellImg = [UIImage systemImageNamed:(isMuted ? @"bell.slash.fill" : @"bell.fill") withConfiguration:symCfg];
        UIImageView *bellView = [[UIImageView alloc] initWithImage:bellImg];
        bellView.tintColor = accentColor;
        bellView.contentMode = UIViewContentModeScaleAspectFit;
        bellView.frame = CGRectMake(5.0, 5.0, 16.0, 16.0);
        [bellBadge addSubview:bellView];

        // Right: "Silent" or "Ring" label
        UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 88.0, 24.0)];
        statusLabel.text = isMuted ? @"Silent" : @"Ring";
        statusLabel.textColor = accentColor;
        statusLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        statusLabel.textAlignment = NSTextAlignmentRight;

        [strongSelf.contentContainerView addSubview:bellBadge];
        [strongSelf.contentContainerView addSubview:statusLabel];
        [strongSelf.activeContentViews addObjectsFromArray:@[bellBadge, statusLabel]];

        CGPoint bellTarget = CGPointMake(24.0, targetSize.height * 0.5);
        CGPoint labelTarget = CGPointMake(targetSize.width - 58.0, targetSize.height * 0.5);

        // Singularity Ejection (horizontal axis stretch)
        [strongSelf ejectLayer:bellBadge.layer
               fromSingularity:singularity
                    toPosition:bellTarget
                  axisStretchX:1.25
                  axisStretchY:0.78
                         delay:0.01];

        [strongSelf ejectLayer:statusLabel.layer
               fromSingularity:singularity
                    toPosition:labelTarget
                  axisStretchX:1.22
                  axisStretchY:0.82
                         delay:0.04];

        // Pendulum Shake CAKeyframeAnimation on the Bell Icon when Silent ON
        if (isMuted) {
            CAKeyframeAnimation *pendulum = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
            pendulum.values = @[@0.0, @(-0.28), @(0.25), @(-0.18), @(0.12), @(-0.05), @0.0];
            pendulum.keyTimes = @[@0.0, @0.16, @0.34, @0.52, @0.70, @0.86, @1.0];
            pendulum.duration = 0.52;
            pendulum.beginTime = CACurrentMediaTime() + 0.14;
            pendulum.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [bellView.layer addAnimation:pendulum forKey:@"silentBellPendulum"];
        }

        // Auto-suck back into center singularity after 1.5s
        strongSelf.autoCollapseTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                                        target:strongSelf
                                                                      selector:@selector(collapseToRestingState)
                                                                      userInfo:nil
                                                                       repeats:NO];
    }];
}

#pragma mark - 2. Charging State Animation (Green Singularity Pulse)

- (void)showChargingWithBatteryLevel:(NSInteger)percent {
    if (!self.config.enabled) return;

    [self invalidateAutoCollapseTimer];
    NSUInteger gen = ++self.animationGeneration;

    __weak typeof(self) weakSelf = self;
    [self absorbCurrentContentAndRun:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.animationGeneration != gen) return;

        strongSelf.currentState = SingularityDisplayStateChargingAlert;
        CGSize targetSize = CGSizeMake(236.0, 38.0);
        [strongSelf animatePillToSize:targetSize cornerRadius:19.0];

        CGPoint singularity = CGPointMake(targetSize.width * 0.5, targetSize.height * 0.5);
        UIColor *chargeGreen = [UIColor colorWithRed:0.188 green:0.820 blue:0.345 alpha:1.0]; // #30D158

        // Green singularity rim pulse
        CAKeyframeAnimation *rimColorAnim = [CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
        rimColorAnim.values = @[
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.13].CGColor,
            (__bridge id)[chargeGreen colorWithAlphaComponent:0.95].CGColor,
            (__bridge id)[chargeGreen colorWithAlphaComponent:0.45].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.13].CGColor
        ];
        rimColorAnim.keyTimes = @[@0.0, @0.22, @0.65, @1.0];
        rimColorAnim.duration = 1.6;
        [strongSelf.pillRimLayer addAnimation:rimColorAnim forKey:@"chargingRimPulse"];

        CAKeyframeAnimation *rimWidthAnim = [CAKeyframeAnimation animationWithKeyPath:@"lineWidth"];
        rimWidthAnim.values = @[@0.75, @2.2, @1.2, @0.75];
        rimWidthAnim.keyTimes = @[@0.0, @0.22, @0.65, @1.0];
        rimWidthAnim.duration = 1.6;
        [strongSelf.pillRimLayer addAnimation:rimWidthAnim forKey:@"chargingRimWidth"];

        UILabel *chargingLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 84.0, 22.0)];
        chargingLabel.text = @"Charging";
        chargingLabel.textColor = [UIColor whiteColor];
        chargingLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];

        UIView *rightGroup = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 74.0, 22.0)];
        UILabel *pctLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 48.0, 22.0)];
        pctLabel.text = [NSString stringWithFormat:@"%ld%%", (long)MAX(0, MIN(100, percent))];
        pctLabel.textColor = chargeGreen;
        pctLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.5 weight:UIFontWeightBold];
        pctLabel.textAlignment = NSTextAlignmentRight;
        [rightGroup addSubview:pctLabel];

        UIImageSymbolConfiguration *boltCfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightBold];
        UIImageView *boltIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.fill" withConfiguration:boltCfg]];
        boltIcon.tintColor = chargeGreen;
        boltIcon.contentMode = UIViewContentModeScaleAspectFit;
        boltIcon.frame = CGRectMake(52.0, 3.0, 16.0, 16.0);
        [rightGroup addSubview:boltIcon];

        [strongSelf.contentContainerView addSubview:chargingLabel];
        [strongSelf.contentContainerView addSubview:rightGroup];
        [strongSelf.activeContentViews addObjectsFromArray:@[chargingLabel, rightGroup]];

        [strongSelf ejectLayer:chargingLabel.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(56.0, targetSize.height * 0.5)
                  axisStretchX:1.24
                  axisStretchY:0.80
                         delay:0.01];

        [strongSelf ejectLayer:rightGroup.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(targetSize.width - 48.0, targetSize.height * 0.5)
                  axisStretchX:1.24
                  axisStretchY:0.80
                         delay:0.04];

        strongSelf.autoCollapseTimer = [NSTimer scheduledTimerWithTimeInterval:2.2
                                                                        target:strongSelf
                                                                      selector:@selector(collapseToRestingState)
                                                                      userInfo:nil
                                                                       repeats:NO];
    }];
}

#pragma mark - 3. Notification Banner Card

- (void)showNotificationWithTitle:(NSString *)title
                          message:(NSString *)message
                          appName:(nullable NSString *)appName
                             icon:(nullable UIImage *)icon {
    if (!self.config.enabled) return;

    [self invalidateAutoCollapseTimer];
    NSUInteger gen = ++self.animationGeneration;

    __weak typeof(self) weakSelf = self;
    [self absorbCurrentContentAndRun:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.animationGeneration != gen) return;

        strongSelf.currentState = SingularityDisplayStateNotification;
        CGFloat maxW = MIN(CGRectGetWidth(strongSelf.bounds) - 24.0, 356.0);
        CGSize targetSize = CGSizeMake(maxW, 78.0);
        [strongSelf animatePillToSize:targetSize cornerRadius:32.0];

        CGPoint singularity = CGPointMake(targetSize.width * 0.5, targetSize.height * 0.5);

        // App icon container
        UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 42.0, 42.0)];
        iconView.layer.cornerRadius = 11.0;
        iconView.layer.masksToBounds = YES;
        iconView.contentMode = UIViewContentModeScaleAspectFill;
        if (icon) {
            iconView.image = icon;
        } else {
            iconView.backgroundColor = [UIColor colorWithRed:0.16 green:0.48 blue:1.0 alpha:1.0];
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightSemibold];
            iconView.image = [UIImage systemImageNamed:@"bell.badge.fill" withConfiguration:cfg];
            iconView.tintColor = [UIColor whiteColor];
            iconView.contentMode = UIViewContentModeCenter;
        }

        CGFloat textWidth = targetSize.width - 84.0;
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, textWidth, 20.0)];
        titleLabel.text = title.length > 0 ? title : (appName ?: @"Notification");
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, textWidth, 32.0)];
        bodyLabel.text = message ?: @"";
        bodyLabel.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
        bodyLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        bodyLabel.numberOfLines = 2;
        bodyLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        [strongSelf.contentContainerView addSubview:iconView];
        [strongSelf.contentContainerView addSubview:titleLabel];
        [strongSelf.contentContainerView addSubview:bodyLabel];
        [strongSelf.activeContentViews addObjectsFromArray:@[iconView, titleLabel, bodyLabel]];

        [strongSelf ejectLayer:iconView.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(38.0, targetSize.height * 0.5)
                  axisStretchX:1.18
                  axisStretchY:0.84
                         delay:0.0];

        [strongSelf ejectLayer:titleLabel.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(68.0 + textWidth * 0.5, 25.0)
                  axisStretchX:1.22
                  axisStretchY:0.82
                         delay:0.03];

        [strongSelf ejectLayer:bodyLabel.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(68.0 + textWidth * 0.5, 51.0)
                  axisStretchX:1.16
                  axisStretchY:0.86
                         delay:0.055];

        strongSelf.autoCollapseTimer = [NSTimer scheduledTimerWithTimeInterval:4.2
                                                                        target:strongSelf
                                                                      selector:@selector(collapseToRestingState)
                                                                      userInfo:nil
                                                                       repeats:NO];
    }];
}

#pragma mark - 4. Now Playing Media (Compact Waveform + Expanded Controls)

- (UIView *)buildWaveformViewWithBarCount:(NSInteger)count size:(CGSize)size animated:(BOOL)playing {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    CGFloat barWidth = 2.5;
    CGFloat spacing = (size.width - (barWidth * count)) / MAX(1, count - 1);
    NSArray<NSNumber *> *durations = @[@0.52, @0.38, @0.64, @0.44, @0.58];
    NSArray<NSNumber *> *minScales = @[@0.22, @0.35, @0.18, @0.30, @0.25];
    UIColor *barColor = [UIColor colorWithRed:0.46 green:0.78 blue:1.0 alpha:1.0];

    for (NSInteger i = 0; i < count; i++) {
        CALayer *bar = [CALayer layer];
        bar.backgroundColor = barColor.CGColor;
        bar.cornerRadius = barWidth * 0.5;
        CGFloat x = i * (barWidth + spacing);
        bar.frame = CGRectMake(x, 0, barWidth, size.height);
        [container.layer addSublayer:bar];

        if (playing) {
            CAKeyframeAnimation *osc = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
            CGFloat minS = [minScales[i % minScales.count] doubleValue];
            osc.values = @[@(minS), @1.0, @(minS + 0.25), @0.85, @(minS)];
            osc.duration = [durations[i % durations.count] doubleValue];
            osc.repeatCount = HUGE_VALF;
            osc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [bar addAnimation:osc forKey:@"waveformOsc"];
        } else {
            bar.transform = CATransform3DMakeScale(1.0, 0.25, 1.0);
        }
    }
    return container;
}

- (void)updateNowPlayingTitle:(nullable NSString *)title
                       artist:(nullable NSString *)artist
                      artwork:(nullable UIImage *)artwork
                    isPlaying:(BOOL)isPlaying {
    self.mediaTitle = title;
    self.mediaArtist = artist;
    self.mediaArtwork = artwork;
    self.mediaIsPlaying = isPlaying;

    if (!self.config.enabled) return;

    // Do not interrupt high-priority transient alerts
    if (self.currentState == SingularityDisplayStateSilentAlert ||
        self.currentState == SingularityDisplayStateChargingAlert ||
        self.currentState == SingularityDisplayStateNotification) {
        return;
    }

    if (title.length == 0 && !isPlaying) {
        if (self.currentState == SingularityDisplayStateMediaCompact ||
            self.currentState == SingularityDisplayStateMediaExpanded) {
            [self collapseToRestingState];
        }
        return;
    }

    if (self.currentState == SingularityDisplayStateMediaExpanded) {
        [self transitionToMediaExpanded];
    } else if (isPlaying) {
        [self transitionToMediaCompact];
    }
}

- (void)transitionToMediaCompact {
    [self invalidateAutoCollapseTimer];
    NSUInteger gen = ++self.animationGeneration;

    __weak typeof(self) weakSelf = self;
    [self absorbCurrentContentAndRun:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.animationGeneration != gen) return;

        strongSelf.currentState = SingularityDisplayStateMediaCompact;
        CGFloat w = MAX(strongSelf.config.compactWidth + 58.0, 186.0);
        CGFloat h = strongSelf.config.compactHeight;
        CGSize targetSize = CGSizeMake(w, h);
        [strongSelf animatePillToSize:targetSize cornerRadius:h * 0.5];

        CGPoint singularity = CGPointMake(w * 0.5, h * 0.5);
        CGFloat artSize = h - 10.0;

        UIImageView *artView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, artSize, artSize)];
        artView.layer.cornerRadius = 6.0;
        artView.layer.masksToBounds = YES;
        artView.contentMode = UIViewContentModeScaleAspectFill;
        if (strongSelf.mediaArtwork) {
            artView.image = strongSelf.mediaArtwork;
        } else {
            artView.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
            artView.image = [UIImage systemImageNamed:@"music.note"];
            artView.tintColor = [UIColor whiteColor];
            artView.contentMode = UIViewContentModeCenter;
        }

        UIView *waveform = [strongSelf buildWaveformViewWithBarCount:4 size:CGSizeMake(20.0, 14.0) animated:strongSelf.mediaIsPlaying];

        [strongSelf.contentContainerView addSubview:artView];
        [strongSelf.contentContainerView addSubview:waveform];
        [strongSelf.activeContentViews addObjectsFromArray:@[artView, waveform]];

        [strongSelf ejectLayer:artView.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(12.0 + artSize * 0.5, h * 0.5)
                  axisStretchX:1.20
                  axisStretchY:0.84
                         delay:0.0];

        [strongSelf ejectLayer:waveform.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(w - 22.0, h * 0.5)
                  axisStretchX:1.20
                  axisStretchY:0.84
                         delay:0.03];
    }];
}

- (void)transitionToMediaExpanded {
    [self invalidateAutoCollapseTimer];
    NSUInteger gen = ++self.animationGeneration;

    __weak typeof(self) weakSelf = self;
    [self absorbCurrentContentAndRun:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.animationGeneration != gen) return;

        strongSelf.currentState = SingularityDisplayStateMediaExpanded;
        CGFloat maxW = MIN(CGRectGetWidth(strongSelf.bounds) - 24.0, 356.0);
        CGSize targetSize = CGSizeMake(maxW, 152.0);
        [strongSelf animatePillToSize:targetSize cornerRadius:38.0];

        CGPoint singularity = CGPointMake(targetSize.width * 0.5, targetSize.height * 0.5);

        // Top Row: Album Art + Track Info + Waveform
        UIImageView *artView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 56.0, 56.0)];
        artView.layer.cornerRadius = 14.0;
        artView.layer.masksToBounds = YES;
        artView.contentMode = UIViewContentModeScaleAspectFill;
        if (strongSelf.mediaArtwork) {
            artView.image = strongSelf.mediaArtwork;
        } else {
            artView.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
            artView.image = [UIImage systemImageNamed:@"music.note"];
            artView.tintColor = [UIColor whiteColor];
            artView.contentMode = UIViewContentModeCenter;
        }

        CGFloat textW = targetSize.width - 134.0;
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, textW, 22.0)];
        titleLabel.text = strongSelf.mediaTitle.length > 0 ? strongSelf.mediaTitle : @"Not Playing";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];

        UILabel *artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, textW, 18.0)];
        artistLabel.text = strongSelf.mediaArtist.length > 0 ? strongSelf.mediaArtist : @"Music";
        artistLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
        artistLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];

        UIView *waveform = [strongSelf buildWaveformViewWithBarCount:5 size:CGSizeMake(26.0, 18.0) animated:strongSelf.mediaIsPlaying];

        // Bottom Row: Playback Controls
        UIView *controlsBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200.0, 44.0)];
        UIImageSymbolConfiguration *btnCfg = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
        UIImageSymbolConfiguration *playCfg = [UIImageSymbolConfiguration configurationWithPointSize:26.0 weight:UIImageSymbolWeightBold];

        UIButton *prevBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        prevBtn.frame = CGRectMake(12.0, 2.0, 44.0, 40.0);
        [prevBtn setImage:[UIImage systemImageNamed:@"backward.fill" withConfiguration:btnCfg] forState:UIControlStateNormal];
        prevBtn.tintColor = [UIColor whiteColor];
        [prevBtn addTarget:strongSelf action:@selector(handlePreviousTap) forControlEvents:UIControlEventTouchUpInside];

        UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        playBtn.frame = CGRectMake(78.0, 0.0, 44.0, 44.0);
        NSString *playSym = strongSelf.mediaIsPlaying ? @"pause.fill" : @"play.fill";
        [playBtn setImage:[UIImage systemImageNamed:playSym withConfiguration:playCfg] forState:UIControlStateNormal];
        playBtn.tintColor = [UIColor whiteColor];
        [playBtn addTarget:strongSelf action:@selector(handlePlayPauseTap) forControlEvents:UIControlEventTouchUpInside];

        UIButton *nextBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        nextBtn.frame = CGRectMake(144.0, 2.0, 44.0, 40.0);
        [nextBtn setImage:[UIImage systemImageNamed:@"forward.fill" withConfiguration:btnCfg] forState:UIControlStateNormal];
        nextBtn.tintColor = [UIColor whiteColor];
        [nextBtn addTarget:strongSelf action:@selector(handleNextTap) forControlEvents:UIControlEventTouchUpInside];

        [controlsBar addSubview:prevBtn];
        [controlsBar addSubview:playBtn];
        [controlsBar addSubview:nextBtn];

        NSArray<UIView *> *newViews = @[artView, titleLabel, artistLabel, waveform, controlsBar];
        for (UIView *v in newViews) {
            [strongSelf.contentContainerView addSubview:v];
        }
        [strongSelf.activeContentViews addObjectsFromArray:newViews];

        // Staggered Singularity Ejection
        [strongSelf ejectLayer:artView.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(48.0, 48.0)
                  axisStretchX:1.14
                  axisStretchY:1.18
                         delay:0.0];

        [strongSelf ejectLayer:titleLabel.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(88.0 + textW * 0.5, 38.0)
                  axisStretchX:1.20
                  axisStretchY:0.86
                         delay:0.025];

        [strongSelf ejectLayer:artistLabel.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(88.0 + textW * 0.5, 59.0)
                  axisStretchX:1.16
                  axisStretchY:0.88
                         delay:0.045];

        [strongSelf ejectLayer:waveform.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(targetSize.width - 30.0, 48.0)
                  axisStretchX:1.18
                  axisStretchY:0.84
                         delay:0.05];

        [strongSelf ejectLayer:controlsBar.layer
               fromSingularity:singularity
                    toPosition:CGPointMake(targetSize.width * 0.5, 114.0)
                  axisStretchX:0.88
                  axisStretchY:1.22
                         delay:0.07];
    }];
}

#pragma mark - Interaction Handlers

- (void)handlePillTap:(UITapGestureRecognizer *)gesture {
    if (self.currentState == SingularityDisplayStateMediaCompact) {
        [self transitionToMediaExpanded];
    } else if (self.currentState == SingularityDisplayStateMediaExpanded) {
        CGPoint loc = [gesture locationInView:self.pillContainerView];
        // Tapping the top half collapses back to compact media pill
        if (loc.y < 82.0) {
            [self transitionToMediaCompact];
        }
    } else if (self.currentState == SingularityDisplayStateNotification) {
        [self collapseToRestingState];
    }
}

- (void)handlePillLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (self.currentState == SingularityDisplayStateMediaCompact ||
        (self.currentState == SingularityDisplayStateIdle && self.mediaTitle.length > 0)) {
        [self transitionToMediaExpanded];
    }
}

- (void)handlePreviousTap {
    if ([self.mediaDelegate respondsToSelector:@selector(singularityDidRequestPreviousTrack)]) {
        [self.mediaDelegate singularityDidRequestPreviousTrack];
    }
}

- (void)handlePlayPauseTap {
    if ([self.mediaDelegate respondsToSelector:@selector(singularityDidRequestTogglePlayPause)]) {
        [self.mediaDelegate singularityDidRequestTogglePlayPause];
    }
}

- (void)handleNextTap {
    if ([self.mediaDelegate respondsToSelector:@selector(singularityDidRequestNextTrack)]) {
        [self.mediaDelegate singularityDidRequestNextTrack];
    }
}

@end
