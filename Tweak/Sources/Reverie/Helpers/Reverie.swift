import Darwin
import UIKit

/// IOKit power management, resolved at runtime.
///
/// Declaring these through `@_silgen_name` would work but makes the link step
/// depend on IOKit's stub exporting symbols that iOS does not advertise. Resolving
/// them dynamically keeps the dylib link-clean: if the symbols are missing the
/// device simply never suspends, instead of the tweak failing to load.
private typealias PowerCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void

private enum IOPM {
    typealias RegisterType = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>?, PowerCallback?, UnsafeMutablePointer<UInt32>?) -> UInt32
    typealias AllowType = @convention(c) (UInt32, Int) -> Int32
    typealias SleepType = @convention(c) (UInt32) -> Int32
    
    static let register: RegisterType? = symbol("IORegisterForSystemPower")
    static let allow: AllowType? = symbol("IOAllowPowerChange")
    static let sleep: SleepType? = symbol("IOPMSleepSystem")
    
    private static func symbol<T>(
        _ name: String
    ) -> T? {
        guard let handle: UnsafeMutableRawPointer = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sym: UnsafeMutableRawPointer = dlsym(handle, name)
        else {
            return nil
        }
        
        return unsafeBitCast(sym, to: T?.self)
    }
}

// IOKit power messages carry the 0xE0000000 flag. The previous implementation
// compared against bare 0x280/0x320, so neither case ever matched and every
// power event - including "the system just powered on" - fell through to
// IOPMSleepSystem(), i.e. the device was pushed straight back to sleep.
private let messageCanSystemSleep: UInt32  = 0xE0000270
private let messageSystemWillSleep: UInt32 = 0xE0000280
private let messageSystemHasPoweredOn: UInt32 = 0xE0000300

private func powerChangeCallback(
    refcon _: UnsafeMutableRawPointer?,
    service _: UInt32,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard Reverie.connect != 0 else {
        return
    }
    
    let id: Int = messageArgument.map { Int(bitPattern: $0) } ?? 0
    
    switch messageType {
        case messageCanSystemSleep, messageSystemWillSleep:
            // Never veto: Reverie asks for sleep itself, and delaying the
            // request would keep the radios alive for no reason.
            _ = IOPM.allow?(Reverie.connect, id)
        case messageSystemHasPoweredOn:
            // The system woke up (charger attach, button press, ...). Let the
            // coordinator decide whether we should stay awake.
            DispatchQueue.main.async {
                Power.shared.refresh()
                Coordinator.tick()
            }
        default:
            break
    }
}

struct Reverie {
    static var status: SleepStatus = .dreamless
    static var wakePress: Int = 0
    
    /// Automatic hibernation is skipped until this date, so a manual wake is
    /// not immediately undone by the "unplugged" rule.
    static var holdUntil: Date = .distantPast
    
    static var isSleeping: Bool {
        status == .autoSlept || status == .userSlept
    }
    
    fileprivate static var connect: UInt32 = 0
    
    private static var port: OpaquePointer?
    private static var object: UInt32 = 0
    private static var medCache: Bool = false
    private static var settleWorkItem: DispatchWorkItem?
    
    // MARK: - Lifecycle
    
    /// Registers the power notification client exactly once. Re-registering on
    /// every sleep cycle used to leak a notification port per cycle.
    static func bootstrap() {
        guard connect == 0, let register: IOPM.RegisterType = IOPM.register else {
            return
        }
        
        connect = register(nil, &port, powerChangeCallback, &object)
        Log.info("IORegisterForSystemPower connect = \(connect)")
    }
    
    // MARK: - Sleep
    
    static func sleep(
        reason: SleepStatus
    ) {
        guard !isSleeping else {
            return
        }
        
        // Refuse before touching any state: the device cannot survive the radios
        // going down mid-session, so a refused request must leave the state
        // machine alone. Marking it asleep here would stop every later attempt.
        guard Preferences.sleepWithCarPlay || !CarPlay.isActive else {
            Log.info("carplay is active, staying awake")
            return
        }
        
        guard connect != 0 else {
            Log.info("no power connection, cannot suspend")
            return
        }
        
        settleWorkItem?.cancel()
        status = reason
        
        Log.info("sleeping, reason = \(reason)")
        
        medCache = Media.isPlaying
        
        // Airplane mode is deliberately untouched: toggling it tears down
        // Wi-Fi and Bluetooth, which is what breaks wireless CarPlay on wake.
        if !LockScreen.isLocked {
            LockScreen.lock()
        }
        
        if medCache {
            Media.togglePlayPause()
        }
        
        Backlight.fadeOut()
        
        suspend()
    }
    
    /// Suspends the SoC after giving the lock/fade animation a moment to land.
    private static func suspend() {
        let work: DispatchWorkItem = .init {
            guard isSleeping else {
                return
            }
            
            Log.info("IOPMSleepSystem")
            _ = IOPM.sleep?(connect)
        }
        
        settleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    
    // MARK: - Wake
    
    static func wake(
        reason: SleepStatus
    ) {
        guard isSleeping else {
            return
        }
        
        settleWorkItem?.cancel()
        status = reason
        
        Log.info("waking, reason = \(reason)")
        
        if reason == .userWoken {
            holdUntil = .init(timeIntervalSinceNow: 90)
        } else {
            // Charger attach and the head unit powering up happen within a few
            // seconds of each other; keep the device awake long enough that a
            // brief power dip cannot bounce it straight back into hibernation.
            holdUntil = .init(timeIntervalSinceNow: 20)
        }
        
        if medCache {
            Media.togglePlayPause()
        }
        
        // Only a user initiated wake should light the screen; an automatic wake
        // on charger attach should leave the device in its normal standby state.
        if reason == .userWoken {
            Backlight.turnOn()
            LockScreen.unlock()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            if status == .autoWoken || status == .userWoken {
                status = .dreamless
            }
        }
    }
}
