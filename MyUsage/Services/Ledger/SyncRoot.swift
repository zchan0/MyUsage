import Foundation

/// Where the ledger reads and writes its per-device JSONL files. `rootURL`
/// is the user-selected base folder; the on-disk layout is
/// `<root>/devices/<uuid>/{ledger.jsonl,manifest.json}`.
protocol SyncRoot: Sendable {
    /// User-selected base folder (for example `~/Sync/MyUsage`).
    var rootURL: URL? { get }
    /// Whether sync should run at all right now.
    var isAvailable: Bool { get }
}

/// Snapshot of the current sync-folder selection. Used by Settings UI so it
/// can show a stable path even if the bookmark no longer resolves.
enum SyncFolderState: Equatable, Sendable {
    case idle
    case available
    case readOnly
    case unavailable
    case notFound
}

struct SyncFolderSnapshot: Equatable, Sendable {
    let baseURL: URL?
    let pathHint: String?
    let state: SyncFolderState
    let suggestedBaseURL: URL

    var isConfigured: Bool { state != .idle }
    var isAvailable: Bool {
        switch state {
        case .available, .readOnly:
            return true
        case .idle, .unavailable, .notFound:
            return false
        }
    }
    var canWrite: Bool { state == .available }
}

/// Production root backed by a security-scoped bookmark in `UserDefaults`.
/// The folder can live anywhere: iCloud Drive, Syncthing, Dropbox, NAS, etc.
final class SyncFolderRoot: SyncRoot, @unchecked Sendable {
    static let bookmarkKey = "MyUsage.syncFolderBookmark"
    static let pathHintKey = "MyUsage.syncFolderPathHint"
    static let pollIntervalKey = "MyUsage.syncPollInterval"
    static let defaultPollInterval: TimeInterval = 30

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let isICloudDriveAvailable: @Sendable () -> Bool

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isICloudDriveAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.ubiquityIdentityToken != nil
        }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.isICloudDriveAvailable = isICloudDriveAvailable
    }

    var rootURL: URL? { resolvedBaseURL() }

    var isAvailable: Bool { snapshot().isAvailable }

    func snapshot() -> SyncFolderSnapshot {
        let baseURL = resolvedBaseURL()
        let pathHint = baseURL?.path ?? defaults.string(forKey: Self.pathHintKey)
        let state: SyncFolderState

        if let baseURL {
            state = accessState(baseURL: baseURL)
        } else if let pathHint, !pathHint.isEmpty {
            state = fileManager.fileExists(atPath: pathHint) ? .notFound : .unavailable
        } else {
            state = .idle
        }

        return SyncFolderSnapshot(
            baseURL: baseURL,
            pathHint: pathHint,
            state: state,
            suggestedBaseURL: suggestedBaseURL()
        )
    }

    func currentOrSuggestedBaseURL() -> URL {
        if let baseURL = resolvedBaseURL() {
            return baseURL
        }
        if let pathHint = defaults.string(forKey: Self.pathHintKey), !pathHint.isEmpty {
            return URL(fileURLWithPath: pathHint, isDirectory: true)
        }
        return suggestedBaseURL()
    }

    func setBaseURL(_ selectedURL: URL) throws {
        let baseURL = Self.normalizeSelectedBaseURL(selectedURL)
        let bookmark = try baseURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(baseURL.path, forKey: Self.pathHintKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathHintKey)
    }

    func migrateLegacyIfNeeded() {
        guard defaults.data(forKey: Self.bookmarkKey) == nil else { return }
        guard let legacy = legacyICloudBaseURLIfPopulated() else { return }
        try? setBaseURL(legacy)
    }

    func pollInterval() -> TimeInterval {
        let raw = defaults.object(forKey: Self.pollIntervalKey) as? Int
            ?? Int(Self.defaultPollInterval)
        if raw == 0 { return 0 }
        return TimeInterval(max(5, raw))
    }

    static func normalizeSelectedBaseURL(_ url: URL) -> URL {
        if url.lastPathComponent == SyncLayout.devicesFolderName {
            return url.deletingLastPathComponent()
        }
        return url
    }

    static func legacyICloudBaseURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("MyUsage", isDirectory: true)
    }

    private func suggestedBaseURL() -> URL {
        if isICloudDriveAvailable() {
            return Self.legacyICloudBaseURL(homeDirectory: homeDirectory)
        }
        return homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MyUsage", isDirectory: true)
    }

    private func legacyICloudBaseURLIfPopulated() -> URL? {
        let legacyBase = Self.legacyICloudBaseURL(homeDirectory: homeDirectory)
        let devicesFolder = SyncLayout.devicesFolder(in: legacyBase)
        guard fileManager.fileExists(atPath: devicesFolder.path) else { return nil }
        guard let children = try? fileManager.contentsOfDirectory(
            at: devicesFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), !children.isEmpty else {
            return nil
        }
        return legacyBase
    }

    private func resolvedBaseURL() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        let normalized = Self.normalizeSelectedBaseURL(resolved)
        if isStale {
            try? setBaseURL(normalized)
        }
        return normalized
    }

    private func accessState(baseURL: URL) -> SyncFolderState {
        withSecurityScope(baseURL) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .unavailable
            }

            guard (try? fileManager.contentsOfDirectory(atPath: baseURL.path)) != nil else {
                return .unavailable
            }

            let devicesFolder = SyncLayout.devicesFolder(in: baseURL)
            let writeTarget: URL
            if fileManager.fileExists(atPath: devicesFolder.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                writeTarget = devicesFolder
            } else {
                writeTarget = baseURL
            }

            return fileManager.isWritableFile(atPath: writeTarget.path)
                ? .available
                : .readOnly
        } ?? .unavailable
    }

    private func withSecurityScope<T>(_ url: URL, _ body: () -> T) -> T? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return body()
    }
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

/// Fixed filenames inside `<root>/devices/<uuid>/`.
enum SyncLayout {
    static let devicesFolderName = "devices"
    static let ledgerFilename = "ledger.jsonl"
    static let manifestFilename = "manifest.json"

    static func devicesFolder(in root: URL) -> URL {
        root.appendingPathComponent(devicesFolderName, isDirectory: true)
    }

    /// `<root>/devices/<uuid>/`.
    static func deviceFolder(in root: URL, deviceID: String) -> URL {
        devicesFolder(in: root).appendingPathComponent(deviceID, isDirectory: true)
    }

    static func ledgerFile(in root: URL, deviceID: String) -> URL {
        deviceFolder(in: root, deviceID: deviceID).appendingPathComponent(ledgerFilename)
    }

    static func manifestFile(in root: URL, deviceID: String) -> URL {
        deviceFolder(in: root, deviceID: deviceID).appendingPathComponent(manifestFilename)
    }
}
