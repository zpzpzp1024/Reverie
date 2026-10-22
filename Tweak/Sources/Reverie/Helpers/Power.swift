import UIKit

/// Tracks charger attach/detach. Battery state notifications are not guaranteed
/// to be delivered while the device is suspended, so we also poll as a safety net.
final class Power {
    static let shared: Power = .init()
    
    private(set) var isCharging: Bool = false
    
    var onChargingChanged: ((Bool) -> Void)?
    var onTick: (() -> Void)?
    
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    
    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        isCharging = Power.readCharging()
        
        observers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        
        let timer: Timer = .init(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self: Power = self else {
                return
            }
            
            self.refresh()
            self.onTick?()
        }
        
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        
        Log.info("power monitor started, charging = \(isCharging)")
    }
    
    func refresh() {
        let charging: Bool = Power.readCharging()
        
        guard charging != isCharging else {
            return
        }
        
        isCharging = charging
        Log.info("charger state changed, charging = \(charging)")
        onChargingChanged?(charging)
    }
    
    private static func readCharging() -> Bool {
        let state: UIDevice.BatteryState = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
}
