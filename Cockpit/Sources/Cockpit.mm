// Cockpit - CarPlay split view experiments
//
// 0.0.23: scene-state liveness (isRunning is dead weight on this device),
// auto-recovery via nudge-then-rehost health check, toggle button at the
// whole-screen top-left with 40% opaque background.
// 0.0.22: restore Mode 2 hosting (only mechanism that pulls the app process
// up), contain the foreground-consistency crash (mode 0 before hide/teardown,
// NSException assertion filter), fix the toggle button (it lives inside the
// main window now — a second UIWindow on the car display never received taps).
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
#define COCKPIT_CRASHCOUNT "/var/mobile/Library/Preferences/lilliana.cockpit.crashcount"

static NSString *const kPrefsHostApp  = @"HostBundleID";
static NSString *const kPrefsHostApp2 = @"HostBundleID2";
static NSString *const kPrefsEnabled  = @"Enabled";
static NSString *const kPrefsTestMain = @"TestOnMainScreen";

static NSString *const kDefaultHost1 = @"com.xiaojukeji.didi";
static NSString *const kDefaultHost2 = @"com.autonavi.amap";
static CGFloat const kSplitRatio = 0.6;

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

static int gCrashCount = 0;

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
    
    gCrashCount++;
    NSString *countStr = [NSString stringWithFormat:@"%d", gCrashCount];
    [countStr writeToFile:@COCKPIT_CRASHCOUNT atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CLog(@"*** cockpit: crash count now %d", gCrashCount);
}

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
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static id Call1(id object, NSString *selector, id argument)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(object, sel, argument);
}

static id Call2(id object, NSString *selector, id a, id b)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(object, sel, a, b);
}

static id CallClass0(Class cls, NSString *selector)
{
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

static id CallClass2(Class cls, NSString *selector, id a, id b, id c)
{
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)cls, sel, a, b, c);
}

static BOOL BoolReturn(id object, NSString *selector, BOOL fallback)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

static void CallInteger(id object, NSString *selector, NSInteger value)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return;
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

@interface HostSlot : NSObject
@property (copy) NSString *bundleID;
@property (strong) UIView *container;
@property id viewController;
@property id application;
@property id handle;
@property double birth;          // CFAbsoluteTime when hosted
@property double lastRehost;     // rate-limits re-host/reactivation attempts
@property int rehostCount;       // total re-hosts, for logs
@property int failedNudges;      // consecutive reactivations that didn't stick
@end

@implementation HostSlot
@end

static HostSlot *gSlots[2];
static BOOL gUserClosed = NO;

static BOOL SetCurrentMode(id viewController, NSInteger mode)
{
    if (!viewController) return NO;
    @try {
        if ([viewController respondsToSelector:NSSelectorFromString(@"_setCurrentMode:")]) {
            CallInteger(viewController, @"_setCurrentMode:", mode);
            return YES;
        }
        [viewController setValue:@(mode) forKey:@"currentMode"];
        return YES;
    } @catch (NSException *exception) {
        CLog(@"mode: set to %ld failed: %@", (long)mode, exception.reason);
    }
    return NO;
}

static void SlotSetMode(int index, NSInteger mode)
{
    HostSlot *slot = gSlots[index];
    if (!slot || !slot.viewController) return;
    @try {
        SetCurrentMode(slot.viewController, mode);
    } @catch (NSException *exception) {
        CLog(@"mode[%d]: threw %@", index, exception.reason);
    }
}

#pragma mark - Scene foreground assertion filter

// Hosting an app scene from our own window makes SpringBoard raise
// NSInternalInconsistencyException ("Something changed the scene's ...
// foreground status out from underneath us") whenever another party
// (CarBridge, the phone UI, or the launch path itself) flips the scene's
// foreground flag while our SBAppViewController still holds Live mode.
// The exception aborts SpringBoard — the 0.0.20 crash loop in Cockpit-3.log.
// Swallow exactly that assertion while we are hosting, and resync our
// controller's mode to 0 so it matches the scene's real state. Everything
// else still propagates.
static IMP gOriginalInstanceRaise;
static IMP gOriginalClassRaise;

static void CockpitResyncAfterSwallow(NSString *reason)
{
    for (int index = 0; index < 2; index++) {
        HostSlot *slot = gSlots[index];
        if (!slot || !slot.viewController) continue;
        if (![reason containsString:slot.bundleID]) continue;
        CLog(@"assert: resyncing mode[%d] %@ to 0", index, slot.bundleID);
        dispatch_async(dispatch_get_main_queue(), ^{
            SlotSetMode(index, 0);
        });
        return;
    }
    // Reason did not name one of our scenes, but we are hosting — stand all
    // slots down anyway so the controllers cannot be the stale side.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int index = 0; index < 2; index++) {
            if (gSlots[index] && gSlots[index].viewController) SlotSetMode(index, 0);
        }
    });
}

static BOOL CockpitShouldSwallow(NSString *name, NSString *reason)
{
    if (!name || ![name isEqualToString:@"NSInternalInconsistencyException"]) return NO;
    if (![reason containsString:@"foreground status out from underneath us"]) return NO;
    return (gSlots[0] != nil || gSlots[1] != nil);
}

static void CockpitRaiseInstance(id self, SEL _cmd)
{
    BOOL swallow = NO;
    @try {
        swallow = CockpitShouldSwallow([self name], [self reason]);
    } @catch (__unused NSException *ignored) { }
    if (swallow) {
        CLog(@"assert: swallowed scene foreground assertion (instance raise)");
        CockpitResyncAfterSwallow([self reason] ?: @"");
        return;
    }
    ((void (*)(id, SEL))gOriginalInstanceRaise)(self, _cmd);
}

static void CockpitRaiseClass(id self, SEL _cmd, NSString *name, NSString *format, va_list args)
{
    BOOL swallow = NO;
    if (format) {
        // Format a COPY of the varargs — va_list must reach the original
        // raise untouched when we pass the exception through.
        va_list copy;
        va_copy(copy, args);
        NSString *reason = nil;
        @try { reason = [[NSString alloc] initWithFormat:format arguments:copy]; } @catch (...) {}
        va_end(copy);
        swallow = CockpitShouldSwallow(name, reason);
        if (swallow) {
            CLog(@"assert: swallowed scene foreground assertion (class raise)");
            CockpitResyncAfterSwallow(reason ?: @"");
            return;
        }
    } else {
        swallow = CockpitShouldSwallow(name, nil);
        if (swallow) {
            CLog(@"assert: swallowed scene foreground assertion (class raise, no format)");
            return;
        }
    }
    ((void (*)(id, SEL, NSString *, NSString *, va_list))gOriginalClassRaise)(self, _cmd, name, format, args);
}

static void InstallExceptionFilter(void)
{
    Method instanceMethod = class_getInstanceMethod([NSException class], @selector(raise));
    if (instanceMethod) {
        gOriginalInstanceRaise = method_setImplementation(instanceMethod, (IMP)CockpitRaiseInstance);
    }
    Method classMethod = class_getClassMethod([NSException class], @selector(raise:format:arguments:));
    if (classMethod) {
        gOriginalClassRaise = method_setImplementation(classMethod, (IMP)CockpitRaiseClass);
    }
    CLog(@"filter: NSException raise hooks installed instance=%d class=%d",
         gOriginalInstanceRaise != NULL, gOriginalClassRaise != NULL);
}

#pragma mark - Hosting sequence

static void ApplyDisplayMode4(id viewController)
{
    if (!viewController) return;
    id sceneView = Call0(viewController, @"appView");
    if (!sceneView) return;
    SEL displaySel = NSSelectorFromString(@"setDisplayMode:animationFactory:completion:");
    if (![sceneView respondsToSelector:displaySel]) return;
    id factory = CallClass0(NSClassFromString(@"SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(sceneView, displaySel, (NSInteger)4, factory, nil);
}

// 0.0.22: Mode 2 (Live/foreground) is the only mechanism on this device that
// makes the scene transaction pull the app process up — 0.0.21 skipped it and
// the scenes never activated (log: scene=(nil) active=0, nothing displayed).
// The crash Mode 2 used to cause is handled by:
//   1. hide/teardown switch the controller back to mode 0 first,
//   2. the NSException filter below swallows the consistency assertion.
// Mode 2 is NEVER auto-reverted while hosting: 0.0.23 dropped the isRunning
// based revert (isRunning stays 0 on this device even while content renders,
// and the revert killed working displays ~8s in). Recovery is the health
// check's job: nudge, then re-host.
static void ConfigureAppViewController(id viewController, id entity, id application)
{
    (void)application;
    
    SEL ignoresSel = NSSelectorFromString(@"setIgnoresOcclusions:");
    if ([viewController respondsToSelector:ignoresSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(viewController, ignoresSel, YES);
    }
    
    SetCurrentMode(viewController, 2);
    CLog(@"host: currentMode set to 2 (foreground)");
    
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
    
    ApplyDisplayMode4(viewController);
    CLog(@"host: displayMode 4 applied");
}

static void ScaleAppViewIntoContainer(UIView *appView, UIView *container)
{
    CGSize phone = [UIScreen mainScreen].bounds.size;
    appView.backgroundColor = [UIColor clearColor];
    appView.autoresizingMask = UIViewAutoresizingNone;
    [container addSubview:appView];
    appView.frame = CGRectMake(0, 0, phone.width, phone.height);
    [appView layoutIfNeeded];
    
    id deviceController = nil;
    @try { deviceController = [appView.nextResponder valueForKey:@"_deviceAppViewController"]; } @catch (...) {}
    if (!deviceController) {
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

// 0.0.23: the liveness signal is the SCENE, not SBApplication.isRunning. On
// this device isRunning stays 0 forever even while the scene renders live
// content, and the 0.0.22 revert-to-0 keyed on it killed a working display
// ~8s in (log: scene=FBScene active=1 running=0, then "reverted to 0").
// Mode 2 is therefore never reverted here. Once the scene is confirmed
// active the poll stops; if the scene later dies, HealthCheckSlots re-hosts.
static void ApplyModeWhenReady(int index, int attempt);

static void ApplyModeWhenReady(int index, int attempt)
{
    HostSlot *slot = gSlots[index];
    if (!slot || !slot.viewController) return;
    if (gUserClosed) return;
    
    char tag = index == 0 ? 'L' : 'R';
    id scene = slot.handle ? Call0(slot.handle, @"sceneIfExists") : nil;
    BOOL active = BoolReturn(scene, @"isActive", NO);
    CLog(@"mode[%c]: poll attempt=%d scene=%@ active=%d",
         tag, attempt, scene ? @"FBScene" : @"(nil)", active);
    
    if (scene && active) {
        SetCurrentMode(slot.viewController, 2);
        CLog(@"mode[%c]: scene active, live confirmed", tag);
        return;
    }
    
    if (attempt < 15) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ApplyModeWhenReady(index, attempt + 1);
        });
    } else {
        CLog(@"mode[%c]: scene never came up after 30s, handing over to health check", tag);
    }
}

static HostSlot *HostApplication(NSString *bundleID, UIView *container, int slotIndex)
{
    if (bundleID.length == 0) return nil;
    
    HostSlot *slot = [HostSlot new];
    slot.bundleID = bundleID;
    slot.container = container;
    slot.birth = CFAbsoluteTimeGetCurrent();
    
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
    if (FileExists(@COCKPIT_NEWSCENE)) {
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
    
    UIView *appView = Call0(viewController, @"view");
    if (!appView) {
        CLog(@"host: %@ controller has no view", bundleID);
        return nil;
    }
    
    ScaleAppViewIntoContainer(appView, container);
    
    CLog(@"host: %@ attached", bundleID);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ApplyModeWhenReady(slotIndex, 1);
    });
    
    return slot;
}

static void TeardownSlot(HostSlot *slot)
{
    if (!slot || !slot.viewController) return;
    
    // Back to background mode BEFORE invalidating: a controller holding Live
    // while its scene tears down trips the foreground-consistency assertion.
    @try {
        SetCurrentMode(slot.viewController, 0);
        CLog(@"teardown[%@]: mode back to 0", slot.bundleID);
    } @catch (NSException *exception) {
        CLog(@"teardown[%@]: mode 0 threw %@", slot.bundleID, exception.reason);
    }
    
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
static UIView *gPanes[2];
static UIView *gDivider;
static BOOL gTestMode;
static UIButton *gToggleButton;

static void RestoreSlot(int index)
{
    HostSlot *slot = gSlots[index];
    if (!slot) return;
    
    id scene = slot.handle ? Call0(slot.handle, @"sceneIfExists") : nil;
    BOOL active = BoolReturn(scene, @"isActive", NO);
    CLog(@"restore[%d]: %@ scene=%@ active=%d",
         index, slot.bundleID,
         scene ? NSStringFromClass([scene class]) : @"(nil)", active);
    
    if (scene && slot.viewController) {
        SlotSetMode(index, 2);
        ApplyDisplayMode4(slot.viewController);
        return;
    }
    
    // Scene was destroyed while hidden — re-host from scratch. No retry cap:
    // this only runs on an explicit user tap, and lastRehost still rate-limits
    // it against the health check's attempts.
    slot.rehostCount++;
    slot.lastRehost = CFAbsoluteTimeGetCurrent();
    CLog(@"restore[%d]: scene gone, re-hosting (#%d)", index, slot.rehostCount);
    TeardownSlot(slot);
    gSlots[index] = HostApplication(slot.bundleID, slot.container, index);
}

@interface CockpitControl : NSObject
- (void)toggleTapped;
@end

@implementation CockpitControl

- (void)toggleTapped
{
    if (!gUserClosed) {
        // Hide the panes but keep the window and button alive so the user can
        // tap again to restore. Stand the controllers down from Live first —
        // a controller holding Live while its scene gets occluded is the
        // classic foreground-consistency crash trigger (0.0.19 knew this).
        gUserClosed = YES;
        for (int index = 0; index < 2; index++) {
            if (gPanes[index]) gPanes[index].hidden = YES;
        }
        if (gDivider) gDivider.hidden = YES;
        [gToggleButton setTitle:@"⟳" forState:UIControlStateNormal];
        for (int index = 0; index < 2; index++) {
            SlotSetMode(index, 0);
        }
        CLog(@"ui: overlay hidden by user (hosting kept alive)");
    } else {
        gUserClosed = NO;
        for (int index = 0; index < 2; index++) {
            if (gPanes[index]) gPanes[index].hidden = NO;
        }
        if (gDivider) gDivider.hidden = NO;
        [gToggleButton setTitle:@"✕" forState:UIControlStateNormal];
        for (int index = 0; index < 2; index++) {
            RestoreSlot(index);
        }
        CLog(@"ui: overlay restored by user");
    }
}

@end

static CockpitControl *gControl;

static void Layout(void)
{
    if (!gWindow) return;
    
    CGRect bounds = gWindow.bounds;
    
    if (gTestMode) {
        if (gPanes[0]) gPanes[0].frame = bounds;
        gDivider.frame = CGRectMake(bounds.size.width - 2, 0, 2, bounds.size.height);
    } else {
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
    
    // Toggle button sits at the very top-left corner of the WHOLE car display
    // (window coordinates), not the left pane, so it never covers hosted
    // content. It lives INSIDE gWindow: a second UIWindow on the car display
    // never received taps (0.0.20/0.0.21 logs show zero toggleTapped calls).
    if (gToggleButton) {
        gToggleButton.frame = CGRectMake(8, 8, 48, 48);
        [gWindow bringSubviewToFront:gToggleButton];
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
    
    // Toggle button — always visible, lets user hide/show the panes.
    // It is a subview of the same window as the panes so it shares the
    // display and the touch pipeline that already works; the button also
    // survives "close" (only the panes hide), so there is always a way
    // back in. 40% opaque background per user request (very subtle).
    if (!gControl) gControl = [CockpitControl new];
    UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [toggle setTitle:@"✕" forState:UIControlStateNormal];
    [toggle setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    toggle.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    toggle.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    toggle.layer.cornerRadius = 24;
    toggle.layer.zPosition = 9999;
    [toggle addTarget:gControl action:@selector(toggleTapped) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:toggle];
    
    gWindow = window;
    gToggleButton = toggle;
    
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
        NSString *bundleID = HostBundleID1();
        CLog(@"ui: hosting %@ in test mode", bundleID);
        gSlots[0] = HostApplication(bundleID, gPanes[0], 0);
    } else {
        NSString *bid1 = HostBundleID1();
        NSString *bid2 = HostBundleID2();
        CLog(@"ui: hosting %@ + %@ in car mode", bid1, bid2);
        gSlots[0] = HostApplication(bid1, gPanes[0], 0);
        gSlots[1] = HostApplication(bid2, gPanes[1], 1);
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

// Auto-recovery (user choice, 0.0.23): when a hosted app's scene dies
// (system reclaim, crash, force-kill on the phone), re-host it so the pane
// fills again. The scene object itself is the liveness signal — isRunning is
// useless on this device. A scene that exists but went inactive first gets a
// cheap "nudge" (mode 2 + displayMode 4); two nudges that don't stick
// escalate to a full re-host. Everything is rate-limited by a 15s per-slot
// cooldown; the birth grace window lets a fresh host come up undisturbed.
static void HealthCheckSlots(void)
{
    double now = CFAbsoluteTimeGetCurrent();
    for (int index = 0; index < 2; index++) {
        HostSlot *slot = gSlots[index];
        if (!slot || !slot.viewController) continue;
        if (now - slot.birth < 20) continue;
        if (now - slot.lastRehost < 15) continue;
        
        id scene = slot.handle ? Call0(slot.handle, @"sceneIfExists") : nil;
        BOOL active = BoolReturn(scene, @"isActive", NO);
        
        if (scene && active) {
            slot.failedNudges = 0;
            continue;
        }
        
        slot.lastRehost = now;
        
        if (scene && slot.failedNudges < 2) {
            slot.failedNudges++;
            CLog(@"health[%d]: scene inactive, nudging back to live (nudge %d)", index, slot.failedNudges);
            SlotSetMode(index, 2);
            ApplyDisplayMode4(slot.viewController);
            continue;
        }
        
        slot.rehostCount++;
        slot.failedNudges = 0;
        CLog(@"health[%d]: scene gone or unresponsive, re-hosting (#%d)", index, slot.rehostCount);
        TeardownSlot(slot);
        gSlots[index] = HostApplication(slot.bundleID, slot.container, index);
    }
}

static void Tick(void)
{
    @try {
        BOOL carConnected = CarScreenConnected();
        BOOL testMode = (!carConnected && TestModeEnabled());
        
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
                gPanes[0] = nil;
                gPanes[1] = nil;
                gDivider = nil;
                gToggleButton = nil;
                gTestMode = NO;
                CLog(@"lifecycle: car display found, rebuilding there");
            } else {
                if (gWindow.hidden && !gUserClosed) {
                    gWindow.hidden = NO;
                }
                if (!gUserClosed) {
                    HealthCheckSlots();
                }
                return;
            }
        }
        
        if (gUserClosed) return;
        if (!PrefBool(kPrefsEnabled, YES)) return;
        
        // Crash loop protection.
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
        
        CLog(@"--- Cockpit 0.0.23 loaded ---");
        InstallExceptionFilter();
        InstallCrashHandlers();
        
        // Read crash count from last session.
        NSString *crashCountText = [NSString stringWithContentsOfFile:@COCKPIT_CRASHCOUNT encoding:NSUTF8StringEncoding error:nil];
        gCrashCount = crashCountText ? [crashCountText intValue] : 0;
        if (gCrashCount > 0) {
            CLog(@"init: crash count from last session = %d", gCrashCount);
            if (gCrashCount >= 3) {
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
