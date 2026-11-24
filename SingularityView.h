#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// Strict Rootless (/var/jb) Preferences & Darwin Notification Constants
static NSString * const kSingularityPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.yourname.singularityisland.plist";
static NSString * const kSingularityPrefsChangedNotification = @"com.yourname.singularityisland/prefsChanged";
static NSString * const kSingularityTestNotificationEvent = @"com.yourname.singularityisland/testNotification";
static NSString * const kSingularityTestSilentEvent = @"com.yourname.singularityisland/testSilent";

typedef NS_ENUM(NSInteger, SingularityDisplayState) {
    SingularityDisplayStateIdle = 0,
    SingularityDisplayStateMediaCompact,
    SingularityDisplayStateMediaExpanded,
    SingularityDisplayStateSilentAlert,
    SingularityDisplayStateChargingAlert,
    SingularityDisplayStateNotification
};

typedef NS_ENUM(NSInteger, SingularitySatelliteReason) {
    SingularitySatelliteReasonNone = 0,
    SingularitySatelliteReasonSilent,
    SingularitySatelliteReasonMicrophone,
    SingularitySatelliteReasonScreenRecording
};

@interface SingularityConfig : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) CGFloat offsetX;
@property (nonatomic, assign) CGFloat offsetY;
@property (nonatomic, assign) CGFloat compactWidth;
@property (nonatomic, assign) CGFloat compactHeight;
@property (nonatomic, assign) CGFloat springStiffness;
@property (nonatomic, assign) BOOL persistentSilentSatellite;

+ (instancetype)loadFromRootlessDisk;
@end

@interface SingularityPassthroughWindow : UIWindow
@property (nonatomic, weak, nullable) UIView *interactivePillView;
@property (nonatomic, weak, nullable) UIView *interactiveSatelliteView;
@end

@protocol SingularityMediaActionDelegate <NSObject>
- (void)singularityDidRequestTogglePlayPause;
- (void)singularityDidRequestNextTrack;
- (void)singularityDidRequestPreviousTrack;
@end

@interface SingularityView : UIView

@property (nonatomic, strong, readonly) SingularityConfig *config;
@property (nonatomic, assign, readonly) SingularityDisplayState currentState;
@property (nonatomic, weak, nullable) id<SingularityMediaActionDelegate> mediaDelegate;
@property (nonatomic, strong, readonly) UIView *pillHitTargetView;
@property (nonatomic, strong, readonly) UIView *satelliteHitTargetView;

- (instancetype)initWithFrame:(CGRect)frame config:(SingularityConfig *)config;
- (void)applyConfig:(SingularityConfig *)config animated:(BOOL)animated;

// System Event Triggers
- (void)showSilentMode:(BOOL)isMuted;
- (void)showChargingWithBatteryLevel:(NSInteger)percent;
- (void)showNotificationWithTitle:(NSString *)title
                          message:(NSString *)message
                          appName:(nullable NSString *)appName
                             icon:(nullable UIImage *)icon;
- (void)updateNowPlayingTitle:(nullable NSString *)title
                       artist:(nullable NSString *)artist
                      artwork:(nullable UIImage *)artwork
                    isPlaying:(BOOL)isPlaying;

// Satellite Status Dot Control
- (void)setScreenRecordingActive:(BOOL)active;
- (void)setMicrophoneActive:(BOOL)active;
- (void)setSilentStateForSatellite:(BOOL)isMuted;

// Explicit CoreAnimation Singularity Primitives
- (void)absorbLayer:(CALayer *)layer
  towardSingularity:(CGPoint)singularityPoint
              delay:(CFTimeInterval)delay
           duration:(CFTimeInterval)duration
         completion:(nullable void (^)(void))completion;

- (void)ejectLayer:(CALayer *)layer
   fromSingularity:(CGPoint)singularityPoint
        toPosition:(CGPoint)targetPosition
      axisStretchX:(CGFloat)stretchX
      axisStretchY:(CGFloat)stretchY
             delay:(CFTimeInterval)delay;

- (void)triggerMassAbsorptionRecoil;

@end

NS_ASSUME_NONNULL_END
