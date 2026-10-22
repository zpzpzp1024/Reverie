import UIKit

/// Runtime bridge to the SpringBoard private classes Reverie needs.
///
/// The private header dump shipped in `$THEOS/vendor/include/SpringBoard` is
/// years out of date (for example it does not declare `turnOnScreenFully` at
/// all), and the `ReverieImports` module the old code imported does not exist
/// in this repository. Going through the ObjC runtime keeps the build free of
/// any header dump and tolerates selector/signature drift between iOS versions:
/// every call becomes a no-op when the class or method is missing.
enum SpringBoard {
    static func classObject(
        _ name: String
    ) -> AnyClass? {
        NSClassFromString(name)
    }
    
    /// Sends `+sharedInstance` and returns the +0 reference.
    static func sharedInstance(
        _ name: String
    ) -> AnyObject? {
        guard let cls: AnyClass = classObject(name),
              let fn: (@convention(c) (AnyObject, Selector) -> AnyObject?) = classImplementation("sharedInstance", on: cls)
        else {
            return nil
        }
        
        return fn(cls, sel_registerName("sharedInstance"))
    }
    
    static func classImplementation<T>(
        _ selector: String,
        on cls: AnyClass
    ) -> T? {
        guard let method: Method = class_getClassMethod(cls, sel_registerName(selector)) else {
            return nil
        }
        
        return unsafeBitCast(method_getImplementation(method), to: T?.self)
    }
    
    static func implementation<T>(
        _ selector: String,
        on object: AnyObject
    ) -> T? {
        guard let cls: AnyClass = object_getClass(object),
              let method: Method = class_getInstanceMethod(cls, sel_registerName(selector))
        else {
            return nil
        }
        
        return unsafeBitCast(method_getImplementation(method), to: T?.self)
    }
}

enum LockScreen {
    private static var manager: AnyObject? {
        SpringBoard.sharedInstance("SBLockScreenManager")
    }
    
    static var isLocked: Bool {
        guard let manager: AnyObject = manager,
              let fn: (@convention(c) (AnyObject, Selector) -> Bool) = SpringBoard.implementation("isUILocked", on: manager)
        else {
            return true
        }
        
        return fn(manager, sel_registerName("isUILocked"))
    }
    
    static func lock() {
        perform("lockUIFromSource:withOptions:")
    }
    
    static func unlock() {
        perform("unlockUIFromSource:withOptions:")
    }
    
    private static func perform(
        _ selector: String
    ) {
        guard let manager: AnyObject = manager,
              let fn: (@convention(c) (AnyObject, Selector, UInt, NSDictionary?) -> Void) = SpringBoard.implementation(selector, on: manager)
        else {
            return
        }
        
        fn(manager, sel_registerName(selector), 2, nil)
    }
}

enum Backlight {
    private static var controller: AnyObject? {
        SpringBoard.sharedInstance("SBBacklightController")
    }
    
    static func fadeOut() {
        perform("_startFadeOutAnimationFromLockSource:", UInt64(0))
    }
    
    static func turnOn() {
        perform("turnOnScreenFullyWithBacklightSource:", UInt64(0))
    }
    
    private static func perform(
        _ selector: String,
        _ source: UInt64
    ) {
        guard let controller: AnyObject = controller,
              let fn: (@convention(c) (AnyObject, Selector, UInt64) -> Void) = SpringBoard.implementation(selector, on: controller)
        else {
            return
        }
        
        fn(controller, sel_registerName(selector), source)
    }
}

enum Media {
    private static var controller: AnyObject? {
        SpringBoard.sharedInstance("SBMediaController")
    }
    
    static var isPlaying: Bool {
        guard let controller: AnyObject = controller,
              let fn: (@convention(c) (AnyObject, Selector) -> Bool) = SpringBoard.implementation("isPlaying", on: controller)
        else {
            return false
        }
        
        return fn(controller, sel_registerName("isPlaying"))
    }
    
    static func togglePlayPause() {
        guard let controller: AnyObject = controller,
              let fn: (@convention(c) (AnyObject, Selector, Int64) -> Void) = SpringBoard.implementation("togglePlayPauseForEventSource:", on: controller)
        else {
            return
        }
        
        fn(controller, sel_registerName("togglePlayPauseForEventSource:"), 0)
    }
}
