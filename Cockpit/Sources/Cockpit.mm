// Cockpit - CarPlay split view experiments
//
// Milestone 2: multi-app split screen on CarPlay display.
// Hosts two apps side by side: left 60% + right 40%.
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
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <dlfcn.h>

#if __has_include(<execinfo.h>)
#import <execinfo.h>
#define COCKPIT_HAVE_BACKTRACE 1
#else
#define COCKPIT_HAVE_BACKTRACE 0
#endif

#define COCKPIT_LOG     "/var/mobile/Library/Logs/Cockpit.log"
#define COCKPIT_OFF     "/var/mobile/Library/Preferences/lilliana.cockpit.off"
#define COCKPIT_PREFS   "/var/mobile/Library/Preferences/lilliana.cockpit.plist"
#define COCKPIT_HOSTING "/var/mobile/Library/Preferences/lilliana.cockpit.hosting"
#define COCKPIT_CRASHED "/var/mobile/Library/Preferences/lilliana.cockpit.crashed"
#define COCKPIT_NEWSCENE "/var/mobile/Library/Preferences/lilliana.cockpit.newscene"
#define COCKPIT_MODE    "/var/mobile/Library/Preferences/lilliana.cockpit.mode"
#define COCKPIT_HIDE    "/var/mobile/Library/Preferences/lilliana.cockpit.hide"
#define COCKPIT_CRASHCOUNT "/var/mobile/Library/Preferences/lilliana.cockpit.crashcount"

static NSString *const kPrefsHostApp  = @"HostBundleID";
static NSString *const kPrefsHostApp2 = @"HostBundleID2";
// static NSString *const kPrefsRatio = @"SplitRatio"; — unused in 0.0.20 (hardcoded kSplitRatio)
static NSString *const kPrefsEnabled  = @"Enabled";
static NSString *const kPrefsTestMain = @"TestOnMainScreen";

// Hardcoded for phase 1: left=didi 60%, right=amap 40%.
// Will be replaced by prefs-based config later.
static NSString *const kDefaultHost1 = @"com.xiaojukeji.didi";
static NSString *const kDefaultHost2 = @"com.autonavi.amap";
static CGFloat const kSplitRatio = 0.6;  // left pane gets 60% of usable area

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

#pragma mark - Crash capture

static void CockpitWriteRaw(const char *text)
{
    int fd = open(COCKPIT_LOG, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        write(fd, text, strlen(text));
        close(fd);
    }
}

static void CockpitSignalHandler(int signo)
{
    char header[96];
    snprintf(header, sizeof(header), "\n*** cockpit: signal %d ***\n", signo);
    CockpitWriteRaw(header);
    
    int crashFD = open(COCKPIT_CRASHED, O_WRONLY | O_CREAT, 0644);
    if (crashFD >= 0) {
        close(crashFD);
    }
    
#if COCKPIT_HAVE_BACKTRACE
    int fd = open(COCKPIT_LOG, O_WRONLY | O_APPEND);
    if (fd >= 0) {
        void *frames[64];
        int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }
#endif
    
    signal(signo, SIG_DFL);
    raise(signo);
}

static void CockpitExceptionHandler(NSException *exception)
{
    CLog(@"*** cockpit: uncaught %@: %@", exception.name, exception.reason);
    for (NSString *line in exception.callStackSymbols) {
        CLog(@"cockpit stack: %@", line);
    }
    [[NSFileManager defaultManager] createFileAtPath:@COCKPIT_CRASHED contents:[NSData data] attributes:nil];
    
    // Increment crash count for loop protection.
    gCrashCount++;
    NSString *countStr = [NSString stringWithFormat:@"%d", gCrashCount];
    [countStr writeToFile:@COCKPIT_CRASHCOUNT atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CLog(@"*** cockpit: crash count now %d", gCrashCount);

static void InstallCrashHandlers(void)
{
    NSSetUncaughtExceptionHandler(&CockpitExceptionHandler);
    signal(SIGABRT, CockpitSignalHandler);
    signal(SIGSEGV, CockpitSignalHandler);
    signal(SIGBUS, CockpitSignalHandler);
    signal(SIGILL, CockpitSignalHandler);
    signal(SIGFPE, CockpitSignalHandler);
    signal(SIGTRAP, CockpitSignalHandler);
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

// static CGFloat PrefFloat(NSString *key, CGFloat fallback) — unused in 0.0.20 (hardcoded ratio)

// Marker files are easier to create from Filza than editing a plist.
#define COCKPIT_TEST "/var/mobile/Library/Preferences/lilliana.cockpit.test"
#define COCKPIT_HOST "/var/mobile/Library/Preferences/lilliana.cockpit.host"

static BOOL FileExists(NSString *path)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static BOOL TestModeEnabled(void)
{
    if (PrefBool(kPrefsTestMain, NO)) {
        return YES;
    }
    return FileExists(@COCKPIT_TEST);
}

static NSString *HostBundleID1(void)
{
    NSString *bundleID = PrefString(kPrefsHostApp);
    if (bundleID.length) return bundleID;
    
    NSString *text = [NSString stringWithContentsOfFile:@COCKPIT_HOST encoding:NSUTF8StringEncoding error:nil];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length) return text;
    
    return kDefaultHost1;
}

static NSString *HostBundleID2(void)
{
    NSString *bundleID = PrefString(kPrefsHostApp2);
    if (bundleID.length) return bundleID;
    return kDefaultHost2;
}

static void LogPrefsState(void)
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *path = @COCKPIT_PREFS;
    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    
    CLog(@"prefs: path=%@ exists=%d size=%llu parsed=%d keys=%lu",
         path,
         [manager fileExistsAtPath:path],
         [attributes fileSize],
         prefs != nil,
         (unsigned long)prefs.count);
    
    CLog(@"prefs: testMarker=%d hostFile=%d enabled=%d testMode=%d host1=%@ host2=%@",
         FileExists(@COCKPIT_TEST),
         FileExists(@COCKPIT_HOST),
         PrefBool(kPrefsEnabled, YES),
         TestModeEnabled(),
         HostBundleID1(),
         HostBundleID2());
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

static void CallInteger(id object, NSString *selector, NSInteger value)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) {
        return;
    }
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, sel, value);
}

#pragma mark - CarPlay display

static void LogClassSelector(Class cls, NSString *selector, BOOL classMethod)
{
    SEL sel = NSSelectorFromString(selector);
    BOOL found = classMethod ? [cls respondsToSelector:sel] : [cls instancesRespondToSelector:sel];
    CLog(@"api: %@ %c%@ = %d", NSStringFromClass(cls), classMethod ? '+' : '-', selector, found);
}

static void LogSelectors(Class cls, NSArray<NSString *> *keywords)
{
    if (!cls) return;
    
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        NSString *lowercase = name.lowercaseString;
        for (NSString *keyword in keywords) {
            if ([lowercase containsString:keyword]) {
                [matches addObject:name];
                break;
            }
        }
    }
    free(methods);
    
    [matches sortUsingSelector:@selector(compare:)];
    CLog(@"api: %@ methods (%lu): %@",
         NSStringFromClass(cls),
         (unsigned long)matches.count,
         [matches componentsJoinedByString:@" | "]);
}

static void LogHostingAPI(void)
{
    Class coordinator = NSClassFromString(@"SBSceneManagerCoordinator");
    Class manager = NSClassFromString(@"SBSceneManager");
    Class request = NSClassFromString(@"SBApplicationSceneHandleRequest");
    Class controller = NSClassFromString(@"SBAppViewController");
    Class entity = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    Class appController = NSClassFromString(@"SBApplicationController");
    
    CLog(@"api: classes coordinator=%d manager=%d request=%d appVC=%d entity=%d appController=%d",
         coordinator != nil, manager != nil, request != nil,
         controller != nil, entity != nil, appController != nil);
    
    LogClassSelector(coordinator, @"mainDisplaySceneManager", YES);
    LogClassSelector(manager, @"displayIdentity", NO);
    LogClassSelector(manager, @"_sceneIdentityForApplication:createPrimaryIfRequired:", NO);
    LogClassSelector(manager, @"fetchOrCreateApplicationSceneHandleForRequest:", NO);
    LogClassSelector(request, @"defaultRequestForApplication:sceneIdentity:displayIdentity:", YES);
    LogClassSelector(controller, @"initWithIdentifier:andApplicationSceneEntity:", NO);
    LogClassSelector(controller, @"_createSceneViewController", NO);
    LogClassSelector(controller, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", NO);
    LogClassSelector(controller, @"setIgnoresOcclusions:", NO);
    LogClassSelector(controller, @"_setCurrentMode:", NO);
    LogClassSelector(controller, @"_invalidate", NO);
    LogClassSelector(controller, @"_invalidateForReason:", NO);
    LogClassSelector(controller, @"invalidate", NO);
    LogClassSelector(controller, @"_tearDown", NO);
    LogClassSelector(entity, @"initWithApplicationSceneHandle:", NO);
    LogClassSelector(appController, @"sharedInstance", YES);
    LogClassSelector(appController, @"applicationWithBundleIdentifier:", NO);
    
    id sceneManager = CallClass0(coordinator, @"mainDisplaySceneManager");
    CLog(@"api: mainDisplaySceneManager=%@", sceneManager ? NSStringFromClass([sceneManager class]) : @"nil");
    if (sceneManager) {
        id displayIdentity = Call0(sceneManager, @"displayIdentity");
        CLog(@"api: displayIdentity=%@", displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");
    }
    
    LogSelectors(manager, @[@"scene", @"identity"]);
    Class mainManager = NSClassFromString(@"SBMainDisplaySceneManager");
    if (mainManager && mainManager != manager) {
        LogSelectors(mainManager, @[@"scene", @"identity"]);
    }
    LogSelectors(controller, @[@"invalid", @"tear", @"dealloc", @"destroy", @"cleanup"]);
    LogSelectors(NSClassFromString(@"SBApplication"), @[@"scene", @"identity"]);
}

static id CarDisplay(void)
{
    Class deviceClass = NSClassFromString(@"AVExternalDevice");
    id device = CallClass0(deviceClass, @"currentCarPlayExternalDevice");
    if (!device) return nil;
    
    NSArray *screenIDs = Call0(device, @"screenIDs");
    NSString *uniqueID = [screenIDs isKindOfClass:[NSArray class]] && screenIDs.count ? screenIDs[0] : nil;
    if (![uniqueID isKindOfClass:[NSString class]]) return nil;
    
    Class displayClass = NSClassFromString(@"CADisplay");
    NSArray *displays = CallClass0(displayClass, @"displays");
    for (id display in displays) {
        NSString *candidate = Call0(display, @"uniqueId");
        if ([candidate isEqualToString:uniqueID]) return display;
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
    }
    
    CLog(@"--- probe: app scenes ---");
    id app = [UIApplication sharedApplication];
    NSSet *scenes = Call0(app, @"connectedScenes");
    if ([scenes isKindOfClass:[NSSet class]]) {
        for (UIScene *scene in scenes) {
            CLog(@"  scene %@ state=%ld", NSStringFromClass([scene class]), (long)scene.activationState);
        }
    }
}

#pragma mark - Host slot

// Each hosted app is tracked in a HostSlot.
@interface HostSlot : NSObject
@property (copy) NSString *bundleID;
@property (strong) UIView *container;   // blue pane that holds the app view
@property (strong) UILabel *label;
@property id viewController;            // SBAppViewController
@property id application;               // SBApplication
@property id handle;                    // SBDeviceApplicationSceneHandle
@end

@implementation HostSlot
@end

static HostSlot *gSlots[2];
static BOOL gUserClosed = NO;
static BOOL gHidden = NO;  // hidden via lilliana.cockpit.hide marker
static int gCrashCount = 0;

// SetCurrentMode and ApplyModeWhenReady removed in 0.0.21 — we no longer
// set Mode 2 on the SBAppViewController, which was the root cause of the
// "foreground status changed out from underneath us" crash.

static void ConfigureAppViewController(id viewController, id entity, id application)
{
    SEL ignoresSel = NSSelectorFromString(@"setIgnoresOcclusions:");
    if ([viewController respondsToSelector:ignoresSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(viewController, ignoresSel, YES);
    }
    
    // Do NOT set Mode 2 here. Setting Mode 2 (Live/foreground) causes
    // NSInternalInconsistencyException when another app is launched on the
    // phone — SpringBoard changes the scene's foreground status to NO, but
    // the SBAppViewController still thinks it's Live. CarBridge also
    // manipulates scene state, compounding the conflict.
    // Instead, rely on setIgnoresOcclusions:YES + the scene update
    // transaction with deliveringActions:YES to bring the app up, and let
    // SpringBoard manage the foreground/background lifecycle naturally.
    // The displayMode 4 (LiveContent) on the scene view is what makes the
    // app's content visible even without explicit Mode 2.
    CLog(@"host: skipping Mode 2 (let SpringBoard manage foreground)");
    
    id activationSettings = Call0(viewController, @"_activationSettings");
    if (activationSettings) {
        Call0(activationSettings, @"clearActivationSettings");
    }
    
    SEL transactionSel = NSSelectorFromString(@"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:");
    if ([viewController respondsToSelector:transactionSel]) {
        id transaction = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(viewController, transactionSel, entity, YES);
        if (transaction) {
            id transitions = Call0(viewController, @"_activeTransitions");
            if ([transitions respondsToSelector:@selector(addObject:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(transitions, @selector(addObject:), transaction);
            }
            Call0(transaction, @"begin");
            CLog(@"host: transaction begun tracked=%d", transitions != nil);
        }
    }
    
    Call0(viewController, @"_createSceneViewController");
    
    id sceneView = Call0(viewController, @"appView");
    if (sceneView) {
        SEL displaySel = NSSelectorFromString(@"setDisplayMode:animationFactory:completion:");
        id factory = CallClass0(NSClassFromString(@"SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
        if ([sceneView respondsToSelector:displaySel]) {
            ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(sceneView, displaySel, (NSInteger)4, factory, nil);
            CLog(@"host: displayMode 4 applied");
        }
    }
}

static void ScaleAppViewIntoContainer(UIView *appView, UIView *container)
{
    CGSize phone = [UIScreen mainScreen].bounds.size;
    appView.backgroundColor = [UIColor clearColor];
    appView.autoresizingMask = UIViewAutoresizingNone;
    [container addSubview:appView];
    appView.frame = CGRectMake(0, 0, phone.width, phone.height);
    [appView layoutIfNeeded];
    
    // Scale the scene content to fit the container.
    id deviceController = nil;
    @try { deviceController = [appView.nextResponder valueForKey:@"_deviceAppViewController"]; } @catch (...) {}
    // Try via the view controller if nextResponder didn't work
    if (!deviceController) {
        // Walk up to find the view controller, then access _deviceAppViewController
        id responder = appView.nextResponder;
        while (responder && ![responder isKindOfClass:[UIViewController class]]) {
            responder = Call0(responder, @"nextResponder");
        }
        if (responder) {
            @try { deviceController = [responder valueForKey:@"_deviceAppViewController"]; } @catch (...) {}
        }
    }
    
    id sceneView = nil;
    @try { sceneView = [deviceController valueForKey:@"_sceneView"]; } @catch (...) {}
    
    UIView *contentView = nil;
    @try { contentView = [sceneView valueForKey:@"_sceneContentContainerView"]; } @catch (...) {}
    
    if (contentView) {
        CGFloat scaleX = container.bounds.size.width / MAX(phone.width, 1);
        CGFloat scaleY = container.bounds.size.height / MAX(phone.height, 1);
        CGFloat scale = MIN(scaleX, scaleY);
        contentView.transform = CGAffineTransformMakeScale(scale, scale);
        contentView.center = CGPointMake(container.bounds.size.width / 2.0,
                                         container.bounds.size.height / 2.0);
        CLog(@"host: scaled %.3f pane=%@ phone=%@",
             scale, NSStringFromCGSize(container.bounds.size), NSStringFromCGSize(phone));
    } else {
        CLog(@"host: content view not reachable, showing unscaled");
    }
}

static HostSlot *HostApplication(NSString *bundleID, UIView *container)
{
    if (bundleID.length == 0) return nil;
    
    HostSlot *slot = [HostSlot new];
    slot.bundleID = bundleID;
    slot.container = container;
    
    Class appControllerClass = NSClassFromString(@"SBApplicationController");
    id appController = CallClass0(appControllerClass, @"sharedInstance");
    id application = Call1(appController, @"applicationWithBundleIdentifier:", bundleID);
    if (!application) {
        CLog(@"host: %@ is not installed", bundleID);
        return nil;
    }
    slot.application = application;
    CLog(@"host: %@ application=%@", bundleID, NSStringFromClass([application class]));
    
    BOOL alreadyRunning = BoolReturn(application, @"isRunning", NO);
    CLog(@"host: %@ running=%d", bundleID, alreadyRunning);
    
    id sceneManager = CallClass0(NSClassFromString(@"SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    if (!sceneManager) {
        CLog(@"host: no main display scene manager");
        return nil;
    }
    
    id sceneIdentity = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@COCKPIT_NEWSCENE]) {
        sceneIdentity = Call1(sceneManager, @"newSceneIdentityForApplication:", application);
        CLog(@"host: %@ newSceneIdentity=%@", bundleID, sceneIdentity ?: @"(nil)");
    }
    
    SEL identitySel = NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:");
    if ([sceneManager respondsToSelector:identitySel]) {
        sceneIdentity = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(sceneManager, identitySel, application, YES);
    }
    if (!sceneIdentity) sceneIdentity = Call1(sceneManager, @"sceneIdentityForApplication:", application);
    if (!sceneIdentity) sceneIdentity = Call1(sceneManager, @"_sceneIdentityForApplication:", application);
    if (!sceneIdentity) sceneIdentity = Call0(application, @"primarySceneIdentity");
    if (!sceneIdentity) sceneIdentity = Call0(application, @"sceneIdentity");
    CLog(@"host: %@ sceneIdentity=%@", bundleID, sceneIdentity ?: @"(nil)");
    
    id displayIdentity = Call0(sceneManager, @"displayIdentity");
    
    Class requestClass = NSClassFromString(@"SBApplicationSceneHandleRequest");
    id request = nil;
    @try {
        request = CallClass2(requestClass, @"defaultRequestForApplication:sceneIdentity:displayIdentity:", application, sceneIdentity, displayIdentity);
    } @catch (NSException *exception) {
        CLog(@"host: %@ request threw %@", bundleID, exception.reason);
    }
    if (!request) {
        CLog(@"host: %@ no scene handle request", bundleID);
        return nil;
    }
    
    id handle = Call1(sceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", request);
    if (!handle) {
        CLog(@"host: %@ no scene handle", bundleID);
        return nil;
    }
    slot.handle = handle;
    CLog(@"host: %@ handle=%@", bundleID, NSStringFromClass([handle class]));
    
    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    id entity = Call1([entityClass alloc], @"initWithApplicationSceneHandle:", handle);
    if (!entity) {
        CLog(@"host: %@ no scene entity", bundleID);
        return nil;
    }
    
    Class vcClass = NSClassFromString(@"SBAppViewController");
    id viewController = Call2([vcClass alloc], @"initWithIdentifier:andApplicationSceneEntity:", bundleID, entity);
    if (!viewController) {
        viewController = Call1([vcClass alloc], @"initWithApplicationSceneEntity:", entity);
    }
    if (!viewController) {
        CLog(@"host: %@ no app view controller", bundleID);
        return nil;
    }
    slot.viewController = viewController;
    
    ConfigureAppViewController(viewController, entity, application);
    
    // No mode polling — we don't set Mode 2 anymore, so there's nothing
    // to re-apply or downgrade. The scene transaction handles app launch.
    
    UIView *appView = Call0(viewController, @"view");
    if (!appView) {
        CLog(@"host: %@ controller has no view", bundleID);
        return nil;
    }
    
    ScaleAppViewIntoContainer(appView, container);
    
    CLog(@"host: %@ attached", bundleID);
    
    // Log state after a delay.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CLog(@"host: %@ state running=%d", bundleID, BoolReturn(application, @"isRunning", NO));
        id scene = Call0(handle, @"sceneIfExists");
        CLog(@"host: %@ scene=%@ active=%d",
             bundleID,
             scene ? NSStringFromClass([scene class]) : @"(nil)",
             BoolReturn(scene, @"isActive", NO));
    });
    
    return slot;
}

static void TeardownSlot(HostSlot *slot)
{
    if (!slot || !slot.viewController) return;
    
    // No mode reset — we never set Mode 2, so no need to revert.
    // Just invalidate the view controller.
    NSArray<NSString *> *invalSels = @[
        @"invalidate",
        @"_invalidate",
        @"_invalidateForReason:",
        @"_tearDown",
    ];
    for (NSString *selName in invalSels) {
        SEL sel = NSSelectorFromString(selName);
        if (![slot.viewController respondsToSelector:sel]) continue;
        @try {
            if ([selName containsString:@":"]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(slot.viewController, sel, 0);
            } else {
                ((void (*)(id, SEL))objc_msgSend)(slot.viewController, sel);
            }
            CLog(@"teardown[%@]: called %@", slot.bundleID, selName);
            break;
        } @catch (NSException *e) {
            CLog(@"teardown[%@]: %@ threw %@", slot.bundleID, selName, e.reason);
        }
    }
    
    slot.viewController = nil;
    slot.application = nil;
    slot.handle = nil;
}

static void TeardownAllHosts(void)
{
    for (int i = 0; i < 2; i++) {
        if (gSlots[i]) {
            TeardownSlot(gSlots[i]);
            gSlots[i] = nil;
        }
    }
    gUserClosed = NO;
}

#pragma mark - UI

static UIWindow *gWindow;
static UIWindow *gCloseWindow;
static UIView *gPanes[2];
static UIView *gDivider;
static BOOL gTestMode;

@interface CockpitControl : NSObject
- (void)closeTapped;
@end

@implementation CockpitControl

- (void)closeTapped
{
    gUserClosed = YES;
    
    // Just hide the window — no mode changes. Since we never set Mode 2,
    // there's no need to revert to Mode 0. Hiding the window is enough
    // to make the overlay disappear without triggering scene state assertions.
    gWindow.hidden = YES;
    gCloseWindow.hidden = YES;
    CLog(@"ui: overlay hidden by user");
}

@end

static CockpitControl *gControl;

static void Layout(void)
{
    if (!gWindow) return;
    
    CGRect bounds = gWindow.bounds;
    
    if (gTestMode) {
        // Test mode: single pane fills the window.
        if (gPanes[0]) gPanes[0].frame = bounds;
        gDivider.frame = CGRectMake(bounds.size.width - 2, 0, 2, bounds.size.height);
    } else {
        // CarPlay: left margin for sidebar, then 60/40 split.
        CGFloat sideMargin = floor(bounds.size.width / 13.0);
        CGFloat usable = bounds.size.width - sideMargin;
        CGFloat leftWidth = floor(usable * kSplitRatio);
        
        if (gPanes[0]) {
            gPanes[0].frame = CGRectMake(sideMargin, 0, leftWidth, bounds.size.height);
        }
        if (gPanes[1]) {
            gPanes[1].frame = CGRectMake(sideMargin + leftWidth, 0,
                                         usable - leftWidth, bounds.size.height);
        }
        gDivider.frame = CGRectMake(sideMargin + leftWidth, 0, 2, bounds.size.height);
    }
    
    // Position close button at top-right of left pane.
    if (gCloseWindow && gPanes[0]) {
        CGFloat paneWidth = gPanes[0].bounds.size.width;
        CGFloat paneX = gPanes[0].frame.origin.x;
        gCloseWindow.frame = CGRectMake(paneX + paneWidth - 60, 12, 48, 48);
        gCloseWindow.hidden = gUserClosed;
    }
}

static UIWindow *MakeTestWindow(void)
{
    CGRect screen = [UIScreen mainScreen].bounds;
    CGRect frame = CGRectMake(0, 0, floor(screen.size.width * 0.5), screen.size.height);
    
    UIWindow *window = nil;
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            break;
        }
    }
    if (!window) {
        window = [[UIWindow alloc] initWithFrame:frame];
    }
    window.frame = frame;
    
    CLog(@"test window: class=%@ frame=%@", NSStringFromClass([window class]), NSStringFromCGRect(frame));
    return window;
}

static UIView *MakePane(NSString *title, UIColor *bgColor)
{
    UIView *pane = [[UIView alloc] initWithFrame:CGRectZero];
    pane.backgroundColor = bgColor;
    pane.userInteractionEnabled = YES;
    pane.clipsToBounds = YES;
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [pane addSubview:label];
    
    return pane;
}

static void CreateInterface(BOOL testMode)
{
    UIWindow *window = testMode ? MakeTestWindow() : MakeCarWindow();
    if (!window) return;
    
    gTestMode = testMode;
    window.windowLevel = 9000000;
    window.backgroundColor = [UIColor clearColor];
    window.hidden = NO;
    
    // Create two panes with blue translucent background.
    UIColor *paneColor = [UIColor colorWithRed:0.05 green:0.20 blue:0.55 alpha:0.55];
    gPanes[0] = MakePane(@"Cockpit 探针\n左屏", paneColor);
    gPanes[1] = MakePane(@"Cockpit 探针\n右屏", paneColor);
    [window addSubview:gPanes[0]];
    [window addSubview:gPanes[1]];
    
    gDivider = [[UIView alloc] initWithFrame:CGRectZero];
    gDivider.backgroundColor = [UIColor whiteColor];
    [window addSubview:gDivider];
    
    // Close button in separate window.
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    close.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    close.layer.cornerRadius = 24;
    if (!gControl) gControl = [CockpitControl new];
    [close addTarget:gControl action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    
    UIWindow *closeWindow = nil;
    if (testMode) {
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                closeWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                break;
            }
        }
        if (!closeWindow) {
            closeWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        }
    } else {
        // On CarPlay, create close window on the same window scene as the main window.
        id windowScene = Call0(window, @"windowScene");
        if (windowScene) {
            closeWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        }
        if (!closeWindow) {
            closeWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        }
    }
    closeWindow.windowLevel = 10000000;
    closeWindow.backgroundColor = [UIColor clearColor];
    closeWindow.hidden = YES;
    [closeWindow addSubview:close];
    
    gWindow = window;
    gCloseWindow = closeWindow;
    
    Layout();
    
    CLog(@"ui: window=%@ bounds=%@ pane0=%@ pane1=%@",
         NSStringFromClass([window class]),
         NSStringFromCGRect(window.bounds),
         NSStringFromCGRect(gPanes[0].frame),
         NSStringFromCGRect(gPanes[1].frame));
    
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:@COCKPIT_HOSTING]) {
        [manager removeItemAtPath:@COCKPIT_HOSTING error:nil];
    }
    
    BOOL hadCrash = [manager fileExistsAtPath:@COCKPIT_CRASHED];
    if (hadCrash) {
        CLog(@"host: crash marker from last session found, proceeding anyway");
        [manager removeItemAtPath:@COCKPIT_CRASHED error:nil];
    }
    
    if (testMode) {
        // Test mode: only host one app in the single pane.
        NSString *bundleID = HostBundleID1();
        CLog(@"ui: hosting %@ in test mode", bundleID);
        gSlots[0] = HostApplication(bundleID, gPanes[0]);
    } else {
        // CarPlay mode: host two apps.
        NSString *bid1 = HostBundleID1();
        NSString *bid2 = HostBundleID2();
        CLog(@"ui: hosting %@ + %@ in car mode", bid1, bid2);
        gSlots[0] = HostApplication(bid1, gPanes[0]);
        gSlots[1] = HostApplication(bid2, gPanes[1]);
    }
}

#pragma mark - Lifecycle

static BOOL Disabled(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@COCKPIT_OFF];
}

static BOOL CarScreenConnected(void)
{
    for (UIScreen *screen in [UIScreen screens]) {
        if (BoolReturn(screen, @"_isCarScreen", NO) || BoolReturn(screen, @"_isCarPlayScreen", NO)) {
            return YES;
        }
        if (![[UIScreen mainScreen] isEqual:screen] && screen.bounds.size.width != [UIScreen mainScreen].bounds.size.width) {
            return YES;
        }
    }
    return NO;
}

static void Tick(void)
{
    @try {
        BOOL carConnected = CarScreenConnected();
        BOOL testMode = (!carConnected && TestModeEnabled());
        
        // Check hide marker for temporary hide/restore without CarPlay disconnect.
        BOOL hideMarker = FileExists(@COCKPIT_HIDE);
        if (hideMarker && !gHidden) {
            gHidden = YES;
            if (gWindow && !gWindow.hidden) {
                gWindow.hidden = YES;
                gCloseWindow.hidden = YES;
                CLog(@"lifecycle: hidden via marker file");
            }
        } else if (!hideMarker && gHidden) {
            gHidden = NO;
            gUserClosed = NO;  // also clear user-closed so it can reshow
            if (gWindow && gWindow.hidden) {
                gWindow.hidden = NO;
                gCloseWindow.hidden = NO;
                CLog(@"lifecycle: restored via marker file removal");
            }
        }
        
        if (gHidden) return;
        
        if (!carConnected && !testMode) {
            if (gWindow && !gWindow.hidden) {
                TeardownAllHosts();
                gWindow.hidden = YES;
                CLog(@"lifecycle: car display gone, window hidden");
            }
            return;
        }
        
        if (gWindow) {
            if (carConnected && gTestMode) {
                TeardownAllHosts();
                gWindow.hidden = YES;
                gWindow = nil;
                gCloseWindow.hidden = YES;
                gCloseWindow = nil;
                gPanes[0] = nil;
                gPanes[1] = nil;
                gDivider = nil;
                gTestMode = NO;
                CLog(@"lifecycle: car display found, rebuilding there");
            } else {
                if (gWindow.hidden && !gUserClosed) {
                    gWindow.hidden = NO;
                }
                return;
            }
        }
        
        if (gUserClosed) return;
        if (!PrefBool(kPrefsEnabled, YES)) return;
        
        // Crash loop protection: if we crashed 3+ times in a row,
        // stop trying to create the interface.
        if (gCrashCount >= 3) {
            CLog(@"lifecycle: crash loop detected (%d), skipping create", gCrashCount);
            return;
        }
        
        CreateInterface(testMode);
    } @catch (NSException *exception) {
        CLog(@"tick: exception %@: %@", exception.name, exception.reason);
    }
}

__attribute__((constructor))
static void CockpitInit(void)
{
    @autoreleasepool {
        if (Disabled()) return;
        
        CLog(@"--- Cockpit 0.0.21 loaded ---");
        InstallCrashHandlers();
        
        // Read crash count from last session.
        NSString *crashCountText = [NSString stringWithContentsOfFile:@COCKPIT_CRASHCOUNT encoding:NSUTF8StringEncoding error:nil];
        gCrashCount = [crashCountText.intValue] ?: 0;
        if (gCrashCount > 0) {
            CLog(@"init: crash count from last session = %d", gCrashCount);
            if (gCrashCount >= 3) {
                // Reset crash count — we'll try again this session.
                gCrashCount = 0;
                [[NSFileManager defaultManager] removeItemAtPath:@COCKPIT_CRASHCOUNT error:nil];
                CLog(@"init: crash count reset, will try again");
            }
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            LogPrefsState();
            LogHostingAPI();
            DumpProbe();
            Tick();
            
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
                Tick();
            }];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}