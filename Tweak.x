#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>
#import "SingularityView.h"

#pragma mark - Private SpringBoard & MediaRemote Declarations

@interface SBApplication : NSObject
- (NSString *)displayName;
- (NSString *)bundleIdentifier;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bundleID;
@end

@interface SBIcon : NSObject
- (UIImage *)getIconImage:(int)format;
@end

@interface SBIconModel : NSObject
- (SBIcon *)applicationIconForBundleIdentifier:(NSString *)bundleID;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBIconModel *)model;
@end

@interface NCNotificationContent : NSObject
@property (nonatomic, copy, readonly) NSString *header;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *subtitle;
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, strong, readonly) UIImage *icon;
@end

@interface NCNotificationRequest : NSObject
@property (nonatomic, copy, readonly) NSString *sectionIdentifier;
@property (nonatomic, strong, readonly) NCNotificationContent *content;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (BOOL)togglePlayPauseForEventSource:(long long)source;
- (BOOL)changeTrack:(int)direction eventSource:(long long)source;
@end

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isOnAC;
- (int)batteryCapacityAsPercentage;
@end

@interface SBRingerControl : NSObject
- (BOOL)isRingerMuted;
@end

@interface SBRingerHUDViewController : UIViewController
@end

// MediaRemote C API declarations (linked via PrivateFramework MediaRemote)
extern void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^completion)(CFDictionaryRef information));
extern CFStringRef kMRMediaRemoteNowPlayingInfoTitle;
extern CFStringRef kMRMediaRemoteNowPlayingInfoArtist;
extern CFStringRef kMRMediaRemoteNowPlayingInfoArtworkData;
extern CFStringRef kMRMediaRemoteNowPlayingInfoPlaybackRate;

#pragma mark - Global Singularity Overlay Controller

@interface SingularityOverlayManager : NSObject <SingularityMediaActionDelegate>
@property (nonatomic, strong) SingularityPassthroughWindow *overlayWindow;
@property (nonatomic, strong) SingularityView *singularityView;
@property (nonatomic, strong) SingularityConfig *config;
@property (nonatomic, assign) BOOL testSilentToggleState;
@property (nonatomic, assign) BOOL lastKnownChargingState;
@property (nonatomic, assign) BOOL lastRingerMutedState;
@property (nonatomic, assign) CFAbsoluteTime lastRingerEventTimestamp;
+ (instancetype)sharedManager;
- (void)setupOverlayWindow;
- (void)reloadPreferences;
- (void)handleRingerStateChanged:(BOOL)isMuted force:(BOOL)force;
- (void)refreshNowPlayingMetadata;
- (void)refreshCaptureAndAudioIndicators;
@end

@implementation SingularityOverlayManager

+ (instancetype)sharedManager {
    static SingularityOverlayManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SingularityOverlayManager alloc] init];
    });
    return instance;
}

- (void)setupOverlayWindow {
    if (self.overlayWindow) return;

    self.config = [SingularityConfig loadFromRootlessDisk];

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }

    if (activeScene) {
        self.overlayWindow = [[SingularityPassthroughWindow alloc] initWithWindowScene:activeScene];
        self.overlayWindow.frame = screenBounds;
    } else {
        self.overlayWindow = [[SingularityPassthroughWindow alloc] initWithFrame:screenBounds];
    }

    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 1.0;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.userInteractionEnabled = YES;

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.rootViewController = rootVC;

    self.singularityView = [[SingularityView alloc] initWithFrame:screenBounds config:self.config];
    self.singularityView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.singularityView.mediaDelegate = self;
    [rootVC.view addSubview:self.singularityView];

    self.overlayWindow.interactivePillView = self.singularityView.pillHitTargetView;
    self.overlayWindow.interactiveSatelliteView = self.singularityView.satelliteHitTargetView;
    self.overlayWindow.hidden = NO;

    // Sync initial silent state for persistent satellite dot
    int token = 0;
    uint64_t state = 1;
    if (notify_register_check("com.apple.springboard.ringerstate", &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
        BOOL muted = (state == 0);
        self.lastRingerMutedState = muted;
        [self.singularityView setSilentStateForSatellite:muted];
    }

    // Observe Screen Recording (UIScreen.isCaptured) & Audio Route Changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshCaptureAndAudioIndicators)
                                                 name:UIScreenCapturedDidChangeNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshCaptureAndAudioIndicators)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];

    [self refreshCaptureAndAudioIndicators];
    [self refreshNowPlayingMetadata];
}

- (void)reloadPreferences {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.config = [SingularityConfig loadFromRootlessDisk];
        [self.singularityView applyConfig:self.config animated:YES];
    });
}

- (void)handleRingerStateChanged:(BOOL)isMuted force:(BOOL)force {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.config.enabled) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        // Debounce duplicate firing when both SBRingerControl and Darwin ringerstate trigger together
        if (!force && self.lastRingerMutedState == isMuted && (now - self.lastRingerEventTimestamp) < 0.25) {
            return;
        }
        self.lastRingerMutedState = isMuted;
        self.lastRingerEventTimestamp = now;
        [self.singularityView showSilentMode:isMuted];
    });
}

- (void)refreshCaptureAndAudioIndicators {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL captured = [UIScreen mainScreen].isCaptured;
        [self.singularityView setScreenRecordingActive:captured];

        AVAudioSession *session = [AVAudioSession sharedInstance];
        BOOL micInUse = (session.currentRoute.inputs.count > 0 &&
                         ([session.category isEqualToString:AVAudioSessionCategoryRecord] ||
                          [session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]));
        [self.singularityView setMicrophoneActive:micInUse];
    });
}

- (void)refreshNowPlayingMetadata {
    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef infoRef) {
        NSDictionary *info = (__bridge NSDictionary *)infoRef;
        if (!info || info.count == 0) {
            [self.singularityView updateNowPlayingTitle:nil artist:nil artwork:nil isPlaying:NO];
            return;
        }

        NSString *title = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoTitle];
        NSString *artist = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoArtist];
        NSData *artworkData = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoArtworkData];
        NSNumber *rateNum = info[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoPlaybackRate];

        UIImage *artwork = artworkData ? [UIImage imageWithData:artworkData] : nil;
        BOOL isPlaying = (rateNum != nil) ? ([rateNum doubleValue] > 0.01) : [[%c(SBMediaController) sharedInstance] isPlaying];

        [self.singularityView updateNowPlayingTitle:title artist:artist artwork:artwork isPlaying:isPlaying];
    });
}

#pragma mark - SingularityMediaActionDelegate

- (void)singularityDidRequestTogglePlayPause {
    SBMediaController *mc = [%c(SBMediaController) sharedInstance];
    if ([mc respondsToSelector:@selector(togglePlayPauseForEventSource:)]) {
        [mc togglePlayPauseForEventSource:0];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshNowPlayingMetadata];
    });
}

- (void)singularityDidRequestNextTrack {
    SBMediaController *mc = [%c(SBMediaController) sharedInstance];
    if ([mc respondsToSelector:@selector(changeTrack:eventSource:)]) {
        [mc changeTrack:1 eventSource:0];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshNowPlayingMetadata];
    });
}

- (void)singularityDidRequestPreviousTrack {
    SBMediaController *mc = [%c(SBMediaController) sharedInstance];
    if ([mc respondsToSelector:@selector(changeTrack:eventSource:)]) {
        [mc changeTrack:-1 eventSource:0];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshNowPlayingMetadata];
    });
}

@end

#pragma mark - Darwin Notification Callbacks

static void SIPrefsChangedCallback(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    [[SingularityOverlayManager sharedManager] reloadPreferences];
}

static void SITestNotificationCallback(CFNotificationCenterRef center,
                                       void *observer,
                                       CFStringRef name,
                                       const void *object,
                                       CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SingularityOverlayManager *mgr = [SingularityOverlayManager sharedManager];
        [mgr.singularityView showNotificationWithTitle:@"SingularityIsland"
                                               message:@"Event horizon physics active — gravitational spaghettification & spring recoil preview."
                                               appName:@"SingularityIsland"
                                                  icon:nil];
    });
}

static void SITestSilentCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SingularityOverlayManager *mgr = [SingularityOverlayManager sharedManager];
        mgr.testSilentToggleState = !mgr.testSilentToggleState;
        [mgr handleRingerStateChanged:mgr.testSilentToggleState force:YES];
    });
}

static void SIRingerStateDarwinCallback(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    int token = 0;
    uint64_t state = 1;
    if (notify_register_check("com.apple.springboard.ringerstate", &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
    }
    BOOL isMuted = (state == 0);
    [[SingularityOverlayManager sharedManager] handleRingerStateChanged:isMuted force:NO];
}

#pragma mark - SpringBoard Lifecycle Hook

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SingularityOverlayManager sharedManager] setupOverlayWindow];
    });
}

%end

#pragma mark - Silent Mode / Ringer Switch & Stock HUD Suppression

%hook SBRingerControl

- (void)setRingerMuted:(BOOL)muted {
    %orig;
    [[SingularityOverlayManager sharedManager] handleRingerStateChanged:muted force:NO];
}

- (void)activateRingerHUDForVolumeChangeWithInitialVolume:(float)volume {
    if ([SingularityOverlayManager sharedManager].config.enabled) {
        return; // Suppress stock HUD
    }
    %orig;
}

%end

%hook SBRingerHUDViewController

- (void)viewWillAppear:(BOOL)animated {
    if ([SingularityOverlayManager sharedManager].config.enabled) {
        self.view.hidden = YES;
        self.view.alpha = 0.0;
        return;
    }
    %orig;
}

- (BOOL)definesPresentationContext {
    if ([SingularityOverlayManager sharedManager].config.enabled) {
        return NO;
    }
    return %orig;
}

%end

#pragma mark - Notification Banner Interception & Suppression

static UIImage *SIResolveAppIcon(NSString *bundleID, UIImage *fallbackIcon) {
    if (fallbackIcon) return fallbackIcon;
    if (bundleID.length == 0) return nil;
    SBIconController *iconCtrl = [%c(SBIconController) sharedInstance];
    SBIconModel *model = [iconCtrl respondsToSelector:@selector(model)] ? [iconCtrl model] : nil;
    SBIcon *icon = [model respondsToSelector:@selector(applicationIconForBundleIdentifier:)]
        ? [model applicationIconForBundleIdentifier:bundleID] : nil;
    if (icon && [icon respondsToSelector:@selector(getIconImage:)]) {
        return [icon getIconImage:2];
    }
    return nil;
}

%hook NCNotificationDispatcher

- (void)postNotificationWithRequest:(NCNotificationRequest *)request {
    SingularityOverlayManager *mgr = [SingularityOverlayManager sharedManager];
    if (mgr.config.enabled && request && request.content) {
        NSString *title = request.content.title.length > 0 ? request.content.title : request.content.header;
        NSString *message = request.content.message ?: request.content.subtitle;
        NSString *bundleID = request.sectionIdentifier;
        UIImage *icon = SIResolveAppIcon(bundleID, request.content.icon);

        dispatch_async(dispatch_get_main_queue(), ^{
            [mgr.singularityView showNotificationWithTitle:title
                                                   message:message
                                                   appName:request.content.header
                                                      icon:icon];
        });
    }
    %orig;
}

%end

%hook SBBannerManager

- (BOOL)postPresentable:(id)presentable withOptions:(unsigned long long)options userInfo:(id)userInfo error:(NSError **)error {
    if ([SingularityOverlayManager sharedManager].config.enabled) {
        return YES;
    }
    return %orig;
}

%end

#pragma mark - Now Playing Media Hook

%hook SBMediaController

- (void)_nowPlayingInfoChanged {
    %orig;
    [[SingularityOverlayManager sharedManager] refreshNowPlayingMetadata];
}

- (void)_mediaRemoteNowPlayingApplicationIsPlayingDidChange:(id)notification {
    %orig;
    [[SingularityOverlayManager sharedManager] refreshNowPlayingMetadata];
}

%end

#pragma mark - Charging State Hook

%hook SBUIController

- (void)ACPowerChanged {
    %orig;
    SingularityOverlayManager *mgr = [SingularityOverlayManager sharedManager];
    if (!mgr.config.enabled) return;

    BOOL onAC = [self isOnAC];
    if (onAC && !mgr.lastKnownChargingState) {
        NSInteger percent = (NSInteger)[self batteryCapacityAsPercentage];
        dispatch_async(dispatch_get_main_queue(), ^{
            [mgr.singularityView showChargingWithBatteryLevel:percent];
        });
    }
    mgr.lastKnownChargingState = onAC;
}

%end

#pragma mark - Constructor (Register Darwin Listeners)

%ctor {
    @autoreleasepool {
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();

        CFNotificationCenterAddObserver(darwin,
                                        NULL,
                                        SIPrefsChangedCallback,
                                        (__bridge CFStringRef)kSingularityPrefsChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(darwin,
                                        NULL,
                                        SITestNotificationCallback,
                                        (__bridge CFStringRef)kSingularityTestNotificationEvent,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(darwin,
                                        NULL,
                                        SITestSilentCallback,
                                        (__bridge CFStringRef)kSingularityTestSilentEvent,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(darwin,
                                        NULL,
                                        SIRingerStateDarwinCallback,
                                        CFSTR("com.apple.springboard.ringerstate"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
