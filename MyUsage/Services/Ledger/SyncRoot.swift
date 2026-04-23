import Foundation

/// Where the ledger writes its per-device JSONL files. Abstracted so tests
/// can point at a `tmp/` directory without needing a real iCloud account.
///
/// Contract:
/// - `rootURL` is the folder that contains `devices/<uuid>/…`.
/// - `isAvailable` is `false` when the user has iCloud Drive disabled — the
///   writer falls back to local-only mode and skips JSONL export.
protocol SyncRoot: Sendable {
    /// `devices/` directory. Parent is created if missing.
    var rootURL: URL? { get }
    /// Whether sync should run at all right now.
    var isAvailable: Bool { get }
}

/// Production root: `~/Library/Mobile Documents/com~apple~CloudDocs/MyUsage/devices/`.
///
/// The public `com~apple~CloudDocs` path deliberately avoids any iCloud
/// entitlement so ad-hoc signed builds can use it.
struct UbiquitySyncRoot: SyncRoot {

    var rootURL: URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("MyUsage/devices", isDirectory: true)
    }

    var isAvailable: Bool { rootURL != nil }
}

/// Test-only root pointing at an explicit local folder.
struct LocalSyncRoot: SyncRoot {
    let rootURL: URL?
    let isAvailable: Bool

    init(url: URL) {
        self.rootURL = url
        self.isAvailable = true
    }
}

/// Fixed filenames inside `devices/<uuid>/`.
enum SyncLayout {
    static let ledgerFilename = "ledger.jsonl"
    static let manifestFilename = "manifest.json"

    /// `devices/<uuid>/`.
    static func deviceFolder(in root: URL, deviceID: String) -> URL {
        root.appendingPathComponent(deviceID, isDirectory: true)
    }

    static func ledgerFile(in root: URL, deviceID: String) -> URL {
        deviceFolder(in: root, deviceID: deviceID).appendingPathComponent(ledgerFilename)
    }

    static func manifestFile(in root: URL, deviceID: String) -> URL {
        deviceFolder(in: root, deviceID: deviceID).appendingPathComponent(manifestFilename)
    }
}
