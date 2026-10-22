import Foundation
import os.log

/// Unified log plus a plain-text mirror in `/var/mobile/Library/Logs/Reverie.log`.
///
/// The unified log needs a Mac (Console), libimobiledevice or a working `log`
/// binary on device, and its info-level entries are hidden unless you pass
/// `--info`. The file is there so the tweak can be checked from Filza on a phone
/// that was just unplugged from the car, where no cable or terminal is around.
enum Log {
    private static let subsystem: String = "lilliana.reverie"
    private static let log: OSLog = .init(subsystem: subsystem, category: "hibernation")
    private static let path: String = "/var/mobile/Library/Logs/Reverie.log"
    private static let limit: UInt64 = 256 * 1024
    private static let queue: DispatchQueue = .init(label: "\(subsystem).log")
    
    private static let formatter: DateFormatter = {
        let formatter: DateFormatter = .init()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = .init(identifier: "en_US_POSIX")
        return formatter
    }()
    
    static func info(
        _ message: String
    ) {
        os_log("%{public}@", log: log, type: .info, message)
        
        let stamp: String = formatter.string(from: .init())
        
        queue.async {
            append("\(stamp) \(message)\n")
        }
    }
    
    private static func append(
        _ line: String
    ) {
        let manager: FileManager = .default
        
        if let attributes = try? manager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? UInt64,
           size > limit {
            try? manager.removeItem(atPath: path)
        }
        
        if !manager.fileExists(atPath: path) {
            try? manager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            manager.createFile(atPath: path, contents: nil)
        }
        
        guard let handle: FileHandle = .init(forWritingAtPath: path) else {
            return
        }
        
        defer {
            try? handle.close()
        }
        
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
