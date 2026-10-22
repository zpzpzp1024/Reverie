private let prefs: JinxPreferences = .init(for: "lilliana.reverie")

struct Preferences {
    static let isEnabled: Bool              = prefs.get(for: "isEnabled",             default: true)
    static let wakeOnCharge: Bool           = prefs.get(for: "wakeOnCharge",          default: true)
    static let sleepOnUnplug: Bool          = prefs.get(for: "sleepOnUnplug",         default: true)
    static let sleepOnlyWhenLocked: Bool    = prefs.get(for: "sleepOnlyWhenLocked",   default: true)
    static let sleepWithCarPlay: Bool       = prefs.get(for: "sleepWithCarPlay",      default: false)
}
