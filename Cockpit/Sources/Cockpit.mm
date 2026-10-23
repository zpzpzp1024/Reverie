// Cockpit - CarPlay split view experiments
//
// Milestone 1: prove that SpringBoard can put a window on the CarPlay display
// and that an arbitrary app's scene can be hosted inside it.
//
// The hosting pattern follows carplay-cast (Apache-2.0):
//   AVExternalDevice.currentCarPlayExternalDevice
//     -> CADisplay -> FBSDisplayConfiguration -> UIRootSceneWindow
//   SBApplicationSceneHandleRequest -> SBApplicationSceneEntity
//     -> SBAppViewController -> view
//
// Everything runs after SpringBoard is up, is wrapped in @try/@catch, and can be
// disabled by creating /var/mobile/Library/Preferences/lilliana.cockpit.off.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <stdio.h>

#define COCKPIT_LOG   "/var/mobile/Library/Logs/Cockpit.log"
#define COCKPIT_OFF   "/var/mobile/Library/Preferences/lilliana.cockpit.off"
#define COCKPIT_PREFS "/var/mobile/Library/Preferences/lilliana.cockpit.plist"

static NSString *const kPrefsHostApp = @"HostBundleID";
static NSString *const kPrefsRatio   = @"SplitRatio";
static NSString *const kPrefsEnabled = @"Enabled";

#pragma mark - Logging

static void CLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[Cockpit] %@", message);
    
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:[NSDate date]], message];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *path = @COCKPIT_LOG;
    
    if ([[manager attributesOfItemAtPath:path error:nil] fileSize] > 256 * 1024) {
        [manager removeItemAtPath:path error:nil];
    }
    if (![manager fileExistsAtPath:path]) {
        [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createFileAtPath:path contents:nil attributes:nil];
    }
    
    FILE *file = fopen(COCKPIT_LOG, "a");
    if (file) {
        fputs(line.UTF8String, file);
        fclose(file);
    }
}

#pragma mark - Preferences

static id Pref(NSString *key)
{
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@COCKPIT_PREFS];
    return prefs[key];
}

static BOOL PrefBool(NSString *key, BOOL fallback)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSString *PrefString(NSString *key)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static CGFloat PrefFloat(NSString *key, CGFloat fallback)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

#pragma mark - Runtime helpers

static id Call0(id object, NSString *selector)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static id Call1(id object, NSString *selector, id argument)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(object, sel, argument);
}

static id Call2(id object, NSString *selector, id a, id b)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL, id, id))objc_msgSend)(object, sel, a, b);
}

static id CallClass0(Class cls, NSString *selector)
{
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

static id CallClass2(Class cls, NSString *selector, id a, id b, id c)
{
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)cls, sel, a, b, c);
}

static BOOL BoolReturn(id object, NSString *selector, BOOL fallback)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) {
        return fallback;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

#pragma mark - CarPlay display

static id CarDisplay(void)
{
    Class deviceClass = NSClassFromString(@"AVExternalDevice");
    id device = CallClass0(deviceClass, @"currentCarPlayExternalDevice");
    if (!device) {
        return nil;
    }
    
    NSArray *screenIDs = Call0(device, @"screenIDs");
    NSString *uniqueID = [screenIDs isKindOfClass:[NSArray class]] && screenIDs.count ? screenIDs[0] : nil;
    if (![uniqueID isKindOfClass:[NSString class]]) {
        return nil;
    }
    
    Class displayClass = NSClassFromString(@"CADisplay");
    NSArray *displays = CallClass0(displayClass, @"displays");
    for (id display in displays) {
        NSString *candidate = Call0(display, @"uniqueId");
        if ([candidate isEqualToString:uniqueID]) {
            return display;
        }
    }
    
    return nil;
}

static UIWindow *MakeCarWindow(void)
{
    id display = CarDisplay();
    if (!display) {
        CLog(@"make window: no CarPlay CADisplay");
        return nil;
    }
    
    Class configClass = NSClassFromString(@"FBSDisplayConfiguration");
    SEL initSel = NSSelectorFromString(@"initWithCADisplay:isMainDisplay:");
    if (!configClass || ![configClass instancesRespondToSelector:initSel]) {
        CLog(@"make window: FBSDisplayConfiguration missing");
        return nil;
    }
    
    id config = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([configClass alloc], initSel, display, NO);
    
    Class windowClass = NSClassFromString(@"UIRootSceneWindow");
    SEL windowSel = NSSelectorFromString(@"initWithDisplayConfiguration:");
    if (!windowClass || ![windowClass instancesRespondToSelector:windowSel]) {
        CLog(@"make window: UIRootSceneWindow missing");
        return nil;
    }
    
    id window = ((id (*)(id, SEL, id))objc_msgSend)([windowClass alloc], windowSel, config);
    if (![window isKindOfClass:[UIWindow class]]) {
        CLog(@"make window: unexpected class %@", NSStringFromClass([window class]));
        return nil;
    }
    
    CLog(@"make window: created %@ frame=%@", NSStringFromClass([window class]), NSStringFromCGRect([(UIWindow *)window frame]));
    return window;
}

#pragma mark - Probe

static void DumpProbe(void)
{
    CLog(@"--- probe: screens (%lu) ---", (unsigned long)[UIScreen screens].count);
    for (UIScreen *screen in [UIScreen screens]) {
        CLog(@"screen %@ bounds=%@ scale=%.2f car=%d carplay=%d",
             NSStringFromClass([screen class]),
             NSStringFromCGRect(screen.bounds),
             screen.scale,
             BoolReturn(screen, @"_isCarScreen", NO),
             BoolReturn(screen, @"_isCarPlayScreen", NO));
        
        id display = Call0(screen, @"display");
        if (display) {
            CLog(@"  display=%@ uniqueId=%@", NSStringFromClass([display class]), Call0(display, @"uniqueId"));
        }
    }
    
    CLog(@"--- probe: UIScreen scenes ---");
    for (UIScreen *screen in [UIScreen screens]) {
        id scene = Call0(screen, @"_scene");
        if (scene) {
            CLog(@"  screenScene %@ role=%@", NSStringFromClass([scene class]), Call0(scene, @"role"));
        }
    }
    
    CLog(@"--- probe: app scenes ---");
    id app = [UIApplication sharedApplication];
    NSSet *scenes = Call0(app, @"connectedScenes");
    if ([scenes isKindOfClass:[NSSet class]]) {
        for (UIScene *scene in scenes) {
            CLog(@"  scene %@ state=%ld", NSStringFromClass([scene class]), (long)scene.activationState);
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                    CLog(@"    window %@ frame=%@ level=%.0f hidden=%d root=%@",
                         NSStringFromClass([window class]),
                         NSStringFromCGRect(window.frame),
                         window.windowLevel,
                         window.hidden,
                         NSStringFromClass([[window rootViewController] class]));
                }
            }
        }
    } else {
        CLog(@"  connectedScenes unavailable (%@)", NSStringFromClass([scenes class]));
    }
}

#pragma mark - Hosting

static id HostApplication(NSString *bundleID, UIView *container)
{
    if (bundleID.length == 0) {
        return nil;
    }
    
    Class appControllerClass = NSClassFromString(@"SBApplicationController");
    id appController = CallClass0(appControllerClass, @"sharedInstance");
    id application = Call1(appController, @"applicationWithBundleIdentifier:", bundleID);
    if (!application) {
        CLog(@"host: %@ is not installed", bundleID);
        return nil;
    }
    CLog(@"host: application=%@", NSStringFromClass([application class]));
    
    id sceneManager = CallClass0(NSClassFromString(@"SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    if (!sceneManager) {
        CLog(@"host: no main display scene manager");
        return nil;
    }
    
    SEL identitySel = NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:");
    id sceneIdentity = nil;
    if ([sceneManager respondsToSelector:identitySel]) {
        sceneIdentity = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(sceneManager, identitySel, application, YES);
    }
    if (!sceneIdentity) {
        CLog(@"host: no scene identity");
        return nil;
    }
    
    id displayIdentity = Call0(sceneManager, @"displayIdentity");
    
    Class requestClass = NSClassFromString(@"SBApplicationSceneHandleRequest");
    id request = CallClass2(requestClass, @"defaultRequestForApplication:sceneIdentity:displayIdentity:", application, sceneIdentity, displayIdentity);
    if (!request) {
        CLog(@"host: no scene handle request");
        return nil;
    }
    
    id handle = Call1(sceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", request);
    if (!handle) {
        CLog(@"host: no scene handle");
        return nil;
    }
    
    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    id entity = Call1([entityClass alloc], @"initWithApplicationSceneHandle:", handle);
    if (!entity) {
        CLog(@"host: no scene entity");
        return nil;
    }
    
    Class vcClass = NSClassFromString(@"SBAppViewController");
    id viewController = Call2([vcClass alloc], @"initWithIdentifier:andApplicationSceneEntity:", bundleID, entity);
    if (!viewController) {
        CLog(@"host: no app view controller");
        return nil;
    }
    
    @try {
        [viewController setValue:@2 forKey:@"currentMode"];
    } @catch (NSException *exception) {
        CLog(@"host: _currentMode failed: %@", exception.reason);
    }
    
    SEL transactionSel = NSSelectorFromString(@"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:");
    if ([viewController respondsToSelector:transactionSel]) {
        id transaction = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(viewController, transactionSel, entity, YES);
        Call0(transaction, @"begin");
    }
    
    Call0(viewController, @"_createSceneViewController");
    
    UIView *appView = Call0(viewController, @"view");
    if (!appView) {
        CLog(@"host: controller has no view");
        return nil;
    }
    
    appView.frame = container.bounds;
    appView.backgroundColor = [UIColor clearColor];
    [container addSubview:appView];
    
    // The hosted scene renders at phone size; scale it into the pane the same
    // way CarBridge does.
    id deviceController = nil;
    @try {
        deviceController = [viewController valueForKey:@"_deviceAppViewController"];
    } @catch (NSException *exception) {
        CLog(@"host: no device controller: %@", exception.reason);
    }
    
    id sceneView = nil;
    @try {
        sceneView = [deviceController valueForKey:@"_sceneView"];
    } @catch (NSException *exception) {
        CLog(@"host: no scene view: %@", exception.reason);
    }
    
    UIView *contentView = nil;
    @try {
        contentView = [sceneView valueForKey:@"_sceneContentContainerView"];
    } @catch (NSException *exception) {
        CLog(@"host: no content view: %@", exception.reason);
    }
    
    if (contentView) {
        CGSize phone = [UIScreen mainScreen].bounds.size;
        CGFloat scaleX = container.bounds.size.width / MAX(phone.width, 1);
        CGFloat scaleY = container.bounds.size.height / MAX(phone.height, 1);
        contentView.transform = CGAffineTransformMakeScale(scaleX, scaleY);
        CLog(@"host: scaled %.3f/%.3f pane=%@ phone=%@",
             scaleX, scaleY, NSStringFromCGSize(container.bounds.size), NSStringFromCGSize(phone));
    } else {
        CLog(@"host: scene content view not reachable, showing unscaled");
    }
    
    CLog(@"host: %@ attached", bundleID);
    return viewController;
}

#pragma mark - UI

static UIWindow *gWindow;
static UIView *gLeftPane;
static UIView *gDivider;
static UILabel *gLabel;
static id gHostController;

static void Layout(void)
{
    if (!gWindow) {
        return;
    }
    
    CGRect bounds = gWindow.bounds;
    CGFloat ratio = PrefFloat(kPrefsRatio, 0.5);
    ratio = MAX(0.25, MIN(0.75, ratio));
    CGFloat split = floor(bounds.size.width * ratio);
    
    gLeftPane.frame = CGRectMake(0, 0, split, bounds.size.height);
    gLabel.frame = gLeftPane.bounds;
    gDivider.frame = CGRectMake(split, 0, 2, bounds.size.height);
}

static void CreateInterface(void)
{
    UIWindow *window = MakeCarWindow();
    if (!window) {
        return;
    }
    
    window.windowLevel = 9000000;
    window.backgroundColor = [UIColor clearColor];
    window.hidden = NO;
    
    UIView *left = [[UIView alloc] initWithFrame:CGRectZero];
    left.backgroundColor = [UIColor colorWithRed:0.05 green:0.20 blue:0.55 alpha:0.55];
    left.userInteractionEnabled = YES;
    [window addSubview:left];
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"Cockpit 探针\n左半屏";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [left addSubview:label];
    
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.backgroundColor = [UIColor whiteColor];
    [window addSubview:divider];
    
    gWindow = window;
    gLeftPane = left;
    gDivider = divider;
    gLabel = label;
    
    Layout();
    
    CLog(@"ui: window=%@ bounds=%@ pane=%d",
         NSStringFromClass([window class]),
         NSStringFromCGRect(window.bounds),
         BoolReturn(window, @"isHidden", YES) ? 0 : 1);
    
    NSString *bundleID = PrefString(kPrefsHostApp);
    if (bundleID.length) {
        CLog(@"ui: hosting %@", bundleID);
        gHostController = HostApplication(bundleID, left);
    } else {
        CLog(@"ui: no HostBundleID set, probe only");
    }
}

#pragma mark - Lifecycle

static BOOL Disabled(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@COCKPIT_OFF];
}

static void Tick(void)
{
    @try {
        BOOL carConnected = (CarDisplay() != nil);
        
        if (!carConnected) {
            if (gWindow && !gWindow.hidden) {
                gWindow.hidden = YES;
                CLog(@"lifecycle: CarPlay gone, window hidden");
            }
            return;
        }
        
        if (gWindow) {
            if (gWindow.hidden) {
                gWindow.hidden = NO;
                CLog(@"lifecycle: CarPlay back, window shown");
            }
            return;
        }
        
        if (!PrefBool(kPrefsEnabled, YES)) {
            return;
        }
        
        CreateInterface();
    } @catch (NSException *exception) {
        CLog(@"tick: exception %@: %@", exception.name, exception.reason);
    }
}

__attribute__((constructor))
static void CockpitInit(void)
{
    @autoreleasepool {
        if (Disabled()) {
            return;
        }
        
        CLog(@"--- Cockpit 0.0.1 loaded ---");
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            DumpProbe();
            Tick();
            
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
                Tick();
            }];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
