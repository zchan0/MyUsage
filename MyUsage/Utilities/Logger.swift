import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.myusage"

    static let antigravity = Logger(subsystem: subsystem, category: "Antigravity")
    static let claude = Logger(subsystem: subsystem, category: "Claude")
    static let codex = Logger(subsystem: subsystem, category: "Codex")
    static let general = Logger(subsystem: subsystem, category: "General")
}

/// Temporary debug logger that uses NSLog for visibility in bare binaries.
/// Set MYUSAGE_DEBUG_LOG=<path> to also append breadcrumbs to a file —
/// NSLog/os_log delivery is unreliable for unbundled binaries with
/// redirected stderr, which makes automated repro runs blind without this.
enum DebugLog {
    static func info(_ message: String) {
        #if DEBUG
        NSLog("[MyUsage] %@", message)
        guard let path = ProcessInfo.processInfo.environment["MYUSAGE_DEBUG_LOG"] else { return }
        let line = "\(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
        #endif
    }
}
