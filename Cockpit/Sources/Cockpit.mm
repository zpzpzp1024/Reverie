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

#define COCKPIT_LOG     "/var/mobile/Library/Logs/Cockpit.log"
#define COCKPIT_OFF     "/var/mobile/Library/Preferences/lilliana.cockpit.off"
#define COCKPIT_PREFS   "/var/mobile/Library/Preferences/lilliana.cockpit.plist"
#define COCKPIT_HOSTING "/var/mobile/Library/Preferences/lilliana.cockpit.hosting"

static NSString *const kPrefsHostApp  = @"HostBundleID";
static NSString *const kPrefsRatio    = @"SplitRatio";
static NSString *const kPrefsEnabled  = @"Enabled";
static NSString *const kPrefsTestMain = @"TestOnMainScreen";

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

static NSString *HostBundleID(void)
{
    NSString *bundleID = PrefString(kPrefsHostApp);
    if (bundleID.length) {
        return bundleID;
    }
    
    NSString *text = [NSString stringWithContentsOfFile:@COCKPIT_HOST encoding:NSUTF8StringEncoding error:nil];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length ? text : nil;
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
    
    if (prefs) {
        CLog(@"prefs: %@", prefs);
    } else if ([manager fileExistsAtPath:path]) {
        CLog(@"prefs: file exists but is not a readable dictionary");
    }
    
    CLog(@"prefs: testMarker=%d hostFile=%d enabled=%d testMode=%d host=%@",
         FileExists(@COCKPIT_TEST),
         FileExists(@COCKPIT_HOST),
         PrefBool(kPrefsEnabled, YES),
         TestModeEnabled(),
         HostBundleID() ?: @"(none)");
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

static NSInteger IntReturn(id object, NSString *selector, NSInteger fallback)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) {
        return fallback;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel);
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
    if (!cls) {
        return;
    }
    
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
    CLog(@"api: %@ scene/identity (%lu): %@",
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
    LogClassSelector(request, @"requestForApplication:sceneIdentity:displayIdentity:", YES);
    LogClassSelector(controller, @"initWithIdentifier:andApplicationSceneEntity:", NO);
    LogClassSelector(controller, @"initWithApplicationSceneEntity:", NO);
    LogClassSelector(controller, @"_createSceneViewController", NO);
    LogClassSelector(controller, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", NO);
    LogClassSelector(controller, @"setIgnoresOcclusions:", NO);
    LogClassSelector(controller, @"_setCurrentMode:", NO);
    LogClassSelector(entity, @"initWithApplicationSceneHandle:", NO);
    LogClassSelector(appController, @"sharedInstance", YES);
    LogClassSelector(appController, @"applicationWithBundleIdentifier:", NO);
    
    id sceneManager = CallClass0(coordinator, @"mainDisplaySceneManager");
    CLog(@"api: mainDisplaySceneManager=%@", sceneManager ? NSStringFromClass([sceneManager class]) : @"nil");
    if (sceneManager) {
        id displayIdentity = Call0(sceneManager, @"displayIdentity");
        CLog(@"api: displayIdentity=%@", displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");
    }
    
    NSArray<NSString *> *keywords = @[@"scene", @"identity"];
    LogSelectors(manager, keywords);
    Class mainManager = NSClassFromString(@"SBMainDisplaySceneManager");
    if (mainManager && mainManager != manager) {
        LogSelectors(mainManager, keywords);
    }
    LogSelectors(NSClassFromString(@"SBApplication"), keywords);
}

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

static BOOL SetObjectIvar(id object, NSString *name, id value)
{
    Ivar ivar = object ? class_getInstanceVariable([object class], name.UTF8String) : NULL;
    if (!ivar) {
        return NO;
    }
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') {
        // Never poke a primitive ivar with an object pointer.
        return NO;
    }
    object_setIvar(object, ivar, value);
    return YES;
}

// Mirrors the sequence in carplay-cast: the transaction must be tracked in
// _activeTransitions and begun before _createSceneViewController, and the
// scene view wants displayMode 4 afterwards. Skipping these leaves the view
// controller in a half-committed state that SpringBoard eventually trips over.
static void ConfigureAppViewController(id viewController, id entity)
{
    SEL ignoresSel = NSSelectorFromString(@"setIgnoresOcclusions:");
    if ([viewController respondsToSelector:ignoresSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(viewController, ignoresSel, NO);
    }
    
    BOOL modeSet = NO;
    if ([viewController respondsToSelector:NSSelectorFromString(@"_setCurrentMode:")]) {
        CallInteger(viewController, @"_setCurrentMode:", 2);
        modeSet = YES;
    }
    if (!modeSet) {
        @try {
            [viewController setValue:@2 forKey:@"currentMode"];
            modeSet = YES;
        } @catch (NSException *exception) {
            CLog(@"host: currentMode via KVC failed: %@", exception.reason);
        }
    }
    if (!modeSet) {
        modeSet = SetObjectIvar(viewController, @"_currentMode", @2);
    }
    CLog(@"host: currentMode set=%d", modeSet);
    
    id activationSettings = Call0(viewController, @"_activationSettings");
    if (activationSettings) {
        Call0(activationSettings, @"clearActivationSettings");
        CLog(@"host: activation settings cleared");
    }
    
    SEL transactionSel = NSSelectorFromString(@"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:");
    if ([viewController respondsToSelector:transactionSel]) {
        id transaction = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(viewController, transactionSel, entity, YES);
        if (transaction) {
            id transitions = Call0(viewController, @"_activeTransitions");
            BOOL tracked = NO;
            if ([transitions respondsToSelector:@selector(addObject:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(transitions, @selector(addObject:), transaction);
                tracked = YES;
            }
            Call0(transaction, @"begin");
            CLog(@"host: transaction=%@ tracked=%d transitions=%@",
                 NSStringFromClass([transaction class]),
                 tracked,
                 transitions ? NSStringFromClass([transitions class]) : @"(nil)");
        } else {
            CLog(@"host: no scene update transaction");
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
    } else {
        CLog(@"host: no scene view for display mode");
    }
}

static void LogHostedState(id application, id handle, UIView *appView, UIView *sceneView)
{
    CLog(@"host: state processState=%ld running=%d",
         (long)IntReturn(application, @"processState", -1),
         BoolReturn(application, @"isRunning", NO));
    
    id scene = Call0(handle, @"sceneIfExists");
    CLog(@"host: state scene=%@ active=%d",
         scene ? NSStringFromClass([scene class]) : @"(nil)",
         BoolReturn(scene, @"isActive", NO));
    
    CLog(@"host: state view frame=%@ hidden=%d alpha=%.2f window=%@",
         NSStringFromCGRect(appView.frame),
         appView.hidden,
         appView.alpha,
         NSStringFromClass([appView.window class]));
    
    for (UIView *subview in appView.subviews) {
        CLog(@"host: state sub %@ frame=%@ hidden=%d alpha=%.2f",
             NSStringFromClass([subview class]),
             NSStringFromCGRect(subview.frame),
             subview.hidden,
             subview.alpha);
    }
    
    if (sceneView) {
        CLog(@"host: state sceneView frame=%@ transform=%@",
             NSStringFromCGRect([(UIView *)sceneView frame]),
             NSStringFromCGAffineTransform([(UIView *)sceneView transform]));
    }
}

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
    
    id sceneIdentity = nil;
    SEL identitySel = NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:");
    if ([sceneManager respondsToSelector:identitySel]) {
        sceneIdentity = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(sceneManager, identitySel, application, YES);
        CLog(@"host: identity via _sceneIdentityForApplication:createPrimaryIfRequired: = %@",
             sceneIdentity ? NSStringFromClass([sceneIdentity class]) : @"nil");
    }
    if (!sceneIdentity) {
        sceneIdentity = Call1(sceneManager, @"sceneIdentityForApplication:", application);
        if (sceneIdentity) {
            CLog(@"host: identity via sceneIdentityForApplication: = %@", NSStringFromClass([sceneIdentity class]));
        }
    }
    if (!sceneIdentity) {
        sceneIdentity = Call1(sceneManager, @"_sceneIdentityForApplication:", application);
        if (sceneIdentity) {
            CLog(@"host: identity via _sceneIdentityForApplication: = %@", NSStringFromClass([sceneIdentity class]));
        }
    }
    if (!sceneIdentity) {
        sceneIdentity = Call0(application, @"primarySceneIdentity");
        if (sceneIdentity) {
            CLog(@"host: identity via application.primarySceneIdentity = %@", NSStringFromClass([sceneIdentity class]));
        }
    }
    if (!sceneIdentity) {
        sceneIdentity = Call0(application, @"sceneIdentity");
        if (sceneIdentity) {
            CLog(@"host: identity via application.sceneIdentity = %@", NSStringFromClass([sceneIdentity class]));
        }
    }
    CLog(@"host: sceneIdentity=%@ class=%@",
         sceneIdentity ?: @"(nil)",
         sceneIdentity ? NSStringFromClass([sceneIdentity class]) : @"(nil)");
    
    id displayIdentity = Call0(sceneManager, @"displayIdentity");
    
    Class requestClass = NSClassFromString(@"SBApplicationSceneHandleRequest");
    id request = nil;
    @try {
        request = CallClass2(requestClass, @"defaultRequestForApplication:sceneIdentity:displayIdentity:", application, sceneIdentity, displayIdentity);
    } @catch (NSException *exception) {
        CLog(@"host: request threw %@: %@", exception.name, exception.reason);
    }
    if (!request) {
        CLog(@"host: no scene handle request");
        return nil;
    }
    CLog(@"host: request=%@", NSStringFromClass([request class]));
    
    id handle = Call1(sceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", request);
    if (!handle) {
        CLog(@"host: no scene handle");
        return nil;
    }
    CLog(@"host: handle=%@", NSStringFromClass([handle class]));
    
    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    id entity = Call1([entityClass alloc], @"initWithApplicationSceneHandle:", handle);
    if (!entity) {
        CLog(@"host: no scene entity");
        return nil;
    }
    
    Class vcClass = NSClassFromString(@"SBAppViewController");
    id viewController = Call2([vcClass alloc], @"initWithIdentifier:andApplicationSceneEntity:", bundleID, entity);
    if (!viewController) {
        viewController = Call1([vcClass alloc], @"initWithApplicationSceneEntity:", entity);
        if (viewController) {
            CLog(@"host: used initWithApplicationSceneEntity: fallback");
        }
    }
    if (!viewController) {
        CLog(@"host: no app view controller");
        return nil;
    }
    
    ConfigureAppViewController(viewController, entity);
    
    UIView *appView = Call0(viewController, @"view");
    if (!appView) {
        CLog(@"host: controller has no view");
        return nil;
    }
    
    CGSize phone = [UIScreen mainScreen].bounds.size;
    appView.backgroundColor = [UIColor clearColor];
    appView.autoresizingMask = UIViewAutoresizingNone;
    [container addSubview:appView];
    appView.frame = CGRectMake(0, 0, phone.width, phone.height);
    [appView layoutIfNeeded];
    CLog(@"host: view=%@ frame=%@ subviews=%lu",
         NSStringFromClass([appView class]),
         NSStringFromCGRect(appView.frame),
         (unsigned long)appView.subviews.count);
    
    // The scene lays out at phone size. Scale the content container down and
    // centre it in the pane instead of squeezing it into the pane's bounds,
    // otherwise the app re-lays out at half width and then gets shrunk again.
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
        CGFloat scaleX = container.bounds.size.width / MAX(phone.width, 1);
        CGFloat scaleY = container.bounds.size.height / MAX(phone.height, 1);
        CGFloat scale = MIN(scaleX, scaleY);
        contentView.transform = CGAffineTransformMakeScale(scale, scale);
        contentView.center = CGPointMake(container.bounds.size.width / 2.0,
                                         container.bounds.size.height / 2.0);
        CLog(@"host: scaled %.3f (x=%.3f y=%.3f) pane=%@ phone=%@",
             scale, scaleX, scaleY, NSStringFromCGSize(container.bounds.size), NSStringFromCGSize(phone));
        CLog(@"host: sceneView frame=%@ content frame=%@ center=%@",
             NSStringFromCGRect([(UIView *)sceneView frame]),
             NSStringFromCGRect(contentView.frame),
             NSStringFromCGPoint(contentView.center));
    } else {
        CLog(@"host: scene content view not reachable, showing unscaled");
    }
    
    CLog(@"host: %@ attached", bundleID);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        LogHostedState(application, handle, appView, sceneView);
    });
    
    return viewController;
}

#pragma mark - UI

static UIWindow *gWindow;
static UIWindow *gCloseWindow;
static UIView *gLeftPane;
static UIView *gDivider;
static UILabel *gLabel;
static UIButton *gCloseButton;
static id gHostController;
static BOOL gTestMode;
static BOOL gUserClosed;

@interface CockpitControl : NSObject
- (void)closeTapped;
@end

@implementation CockpitControl

- (void)closeTapped
{
    gUserClosed = YES;
    gWindow.hidden = YES;
    // The close button lives in its own window so a hosted app cannot cover it.
    gCloseWindow.hidden = YES;
    CLog(@"ui: overlay hidden by the user (respring to bring it back)");
}

@end

static CockpitControl *gControl;

static void Layout(void)
{
    if (!gWindow) {
        return;
    }
    
    CGRect bounds = gWindow.bounds;
    
    if (gTestMode) {
        // The window is already only the left half of the phone screen.
        gLeftPane.frame = bounds;
        gDivider.frame = CGRectMake(bounds.size.width - 2, 0, 2, bounds.size.height);
    } else {
        CGFloat ratio = PrefFloat(kPrefsRatio, 0.5);
        ratio = MAX(0.25, MIN(0.75, ratio));
        CGFloat split = floor(bounds.size.width * ratio);
        gLeftPane.frame = CGRectMake(0, 0, split, bounds.size.height);
        gDivider.frame = CGRectMake(split, 0, 2, bounds.size.height);
    }
    
    gLabel.frame = gLeftPane.bounds;
    
    if (gCloseWindow) {
        CGFloat paneWidth = gLeftPane.bounds.size.width;
        gCloseButton.frame = CGRectMake(0, 0, 48, 48);
        gCloseWindow.frame = CGRectMake(paneWidth - 60, 12, 48, 48);
        gCloseWindow.hidden = gUserClosed;
    }
}

static UIWindow *MakeTestWindow(void)
{
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat ratio = PrefFloat(kPrefsRatio, 0.5);
    ratio = MAX(0.25, MIN(0.75, ratio));
    CGRect frame = CGRectMake(0, 0, floor(screen.size.width * ratio), screen.size.height);
    
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
    
    CLog(@"test window: class=%@ frame=%@ screen=%@", NSStringFromClass([window class]), NSStringFromCGRect(frame), NSStringFromCGRect(screen));
    return window;
}

static void CreateInterface(BOOL testMode)
{
    UIWindow *window = testMode ? MakeTestWindow() : MakeCarWindow();
    if (!window) {
        return;
    }
    
    gTestMode = testMode;
    window.windowLevel = 9000000;
    window.backgroundColor = [UIColor clearColor];
    window.hidden = NO;
    
    UIView *left = [[UIView alloc] initWithFrame:CGRectZero];
    left.backgroundColor = [UIColor colorWithRed:0.05 green:0.20 blue:0.55 alpha:0.55];
    left.userInteractionEnabled = YES;
    left.clipsToBounds = YES;
    [window addSubview:left];
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = testMode ? @"Cockpit 探针\n手机屏测试" : @"Cockpit 探针\n左半屏";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [left addSubview:label];
    
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.backgroundColor = [UIColor whiteColor];
    [window addSubview:divider];
    
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    close.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    close.layer.cornerRadius = 24;
    if (!gControl) {
        gControl = [CockpitControl new];
    }
    [close addTarget:gControl action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    
    // A tiny separate window keeps the close button above any hosted app and
    // only steals touches inside its own 48x48 area.
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
        closeWindow.windowLevel = 10000000;
        closeWindow.backgroundColor = [UIColor clearColor];
        closeWindow.hidden = YES;
        [closeWindow addSubview:close];
    }
    
    gWindow = window;
    gCloseWindow = closeWindow;
    gLeftPane = left;
    gDivider = divider;
    gLabel = label;
    gCloseButton = close;
    
    Layout();
    
    CLog(@"ui: window=%@ bounds=%@ pane=%@",
         NSStringFromClass([window class]),
         NSStringFromCGRect(window.bounds),
         NSStringFromCGRect(left.frame));
    
    NSString *bundleID = HostBundleID();
    if (bundleID.length) {
        NSFileManager *manager = [NSFileManager defaultManager];
        if ([manager fileExistsAtPath:@COCKPIT_HOSTING]) {
            // A previous attempt never reached the 25 s all-clear, which means
            // SpringBoard died while hosting. Skip this launch so the phone
            // does not get stuck in a crash loop.
            CLog(@"host: previous attempt did not finish, skipping this launch");
            [manager removeItemAtPath:@COCKPIT_HOSTING error:nil];
        } else {
            [manager createFileAtPath:@COCKPIT_HOSTING contents:[NSData data] attributes:nil];
            CLog(@"ui: hosting %@ in %@ mode", bundleID, testMode ? @"test" : @"car");
            gHostController = HostApplication(bundleID, left);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [[NSFileManager defaultManager] removeItemAtPath:@COCKPIT_HOSTING error:nil];
                CLog(@"host: guard cleared after 25s");
            });
        }
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
        BOOL testMode = (!carConnected && TestModeEnabled());
        
        if (!carConnected && !testMode) {
            if (gWindow && !gWindow.hidden) {
                gWindow.hidden = YES;
                CLog(@"lifecycle: car display gone, window hidden");
            }
            return;
        }
        
        if (gWindow) {
            if (carConnected && gTestMode) {
                // CarPlay came up while we were testing on the phone screen.
                gWindow.hidden = YES;
                gWindow = nil;
                gCloseWindow.hidden = YES;
                gCloseWindow = nil;
                gLeftPane = nil;
                gDivider = nil;
                gLabel = nil;
                gCloseButton = nil;
                gHostController = nil;
                gTestMode = NO;
                gUserClosed = NO;
                CLog(@"lifecycle: car display found, rebuilding there");
            } else {
                if (gWindow.hidden && !gUserClosed) {
                    gWindow.hidden = NO;
                }
                return;
            }
        }
        
        if (gUserClosed) {
            return;
        }
        
        if (!PrefBool(kPrefsEnabled, YES)) {
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
        if (Disabled()) {
            return;
        }
        
        CLog(@"--- Cockpit 0.0.7 loaded ---");
        
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
