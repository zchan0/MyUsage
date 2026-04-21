import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.myusage"

    static let antigravity = Logger(subsystem: subsystem, category: "Antigravity")
    static let claude = Logger(subsystem: subsystem, category: "Claude")
    static let general = Logger(subsystem: subsystem, category: "General")
}

/// Temporary debug logger that uses NSLog for visibility in bare binaries.
enum DebugLog {
    static func info(_ message: String) {
        #if DEBUG
        NSLog("[MyUsage] %@", message)
        #endif
    }
}
