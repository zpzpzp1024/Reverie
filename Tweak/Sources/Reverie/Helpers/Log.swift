import os.log

enum Log {
    private static let log: OSLog = .init(
        subsystem: "lilliana.reverie",
        category: "hibernation"
    )
    
    static func info(
        _ message: String
    ) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
