import UIKit

/// Decides when the device hibernates. Charging is the only automatic wake
/// source and unplugging is the only automatic sleep source, which replaces the
/// old "battery level equals X" rules that could be skipped by the battery
/// notification granularity.
struct Coordinator {
    private static var idleTicks: Int = 0
    
    /// Polls are 3s apart, so this is roughly 9s of "unplugged and idle". The
    /// car cuts power and CarPlay at the same time, so this grace period only
    /// needs to cover the head unit finishing its shutdown.
    private static let ticksBeforeSleep: Int = 3
    
    static func start() {
        Reverie.bootstrap()
        
        Power.shared.onChargingChanged = { _ in
            tick()
        }
        
        Power.shared.onTick = {
            tick()
        }
        
        Power.shared.start()
        
        Log.info(
            "coordinator started: wakeOnCharge = \(Preferences.wakeOnCharge), "
            + "sleepOnUnplug = \(Preferences.sleepOnUnplug), "
            + "sleepOnlyWhenLocked = \(Preferences.sleepOnlyWhenLocked), "
            + "sleepWithCarPlay = \(Preferences.sleepWithCarPlay)"
        )
    }
    
    static func tick() {
        guard Preferences.isEnabled else {
            return
        }
        
        if Power.shared.isCharging {
            idleTicks = 0
            
            guard Reverie.isSleeping, Preferences.wakeOnCharge else {
                return
            }
            
            Reverie.wake(reason: .autoWoken)
            return
        }
        
        guard Preferences.sleepOnUnplug, !Reverie.isSleeping else {
            idleTicks = 0
            return
        }
        
        guard canHibernate else {
            idleTicks = 0
            return
        }
        
        idleTicks += 1
        
        guard idleTicks >= ticksBeforeSleep else {
            return
        }
        
        idleTicks = 0
        Reverie.sleep(reason: .autoSlept)
    }
    
    private static var canHibernate: Bool {
        guard Date() >= Reverie.holdUntil else {
            return false
        }
        
        if Preferences.sleepOnlyWhenLocked, !LockScreen.isLocked {
            return false
        }
        
        if !Preferences.sleepWithCarPlay, CarPlay.isActive {
            return false
        }
        
        return true
    }
}
