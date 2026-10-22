import UIKit

/// Best-effort CarPlay session detection.
///
/// Wireless CarPlay needs Bluetooth (pairing) and Wi-Fi (transport), both of
/// which are torn down by a real hibernation, so sleeping while a session is
/// live always costs the session. A CarPlay session shows up in SpringBoard as
/// an external UIScreen, which is what we look at here: it needs no private
/// headers and no framework that may not be loaded in-process.
///
/// In the intended setup the car cuts power and the CarPlay session at the same
/// time, so this mostly acts as a guard against hibernating in the middle of a
/// drive when the charger drops out for a moment.
enum CarPlay {
    private static let cacheLifetime: TimeInterval = 2.0
    private static var cached: Bool = false
    private static var cachedAt: Date = .distantPast
    
    static var isActive: Bool {
        if Date().timeIntervalSince(cachedAt) < cacheLifetime {
            return cached
        }
        
        let active: Bool = UIScreen.screens.count > 1
        cached = active
        cachedAt = .init()
        
        return active
    }
}
