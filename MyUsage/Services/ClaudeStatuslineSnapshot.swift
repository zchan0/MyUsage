import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Only this allowlisted payload is persisted. Receipt time is local, not a server sample time.
struct ClaudeStatuslineSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let receivedAt: Double
    let sessionID: String
    let claudeCodeVersion: String
    let rateLimits: RateLimits
    let resetCredits: [ResetCreditGrant]?

    init(
        schemaVersion: Int,
        receivedAt: Double,
        sessionID: String,
        claudeCodeVersion: String,
        rateLimits: RateLimits,
        resetCredits: [ResetCreditGrant]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.receivedAt = receivedAt
        self.sessionID = sessionID
        self.claudeCodeVersion = claudeCodeVersion
        self.rateLimits = rateLimits
        self.resetCredits = resetCredits
    }

    struct RateLimits: Codable, Sendable, Equatable {
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour", sevenDay = "seven_day"
        }
    }

    struct Window: Codable, Sendable, Equatable {
        let usedPercentage: Double
        let resetsAt: Double
        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage", resetsAt = "resets_at"
        }
        var isValid: Bool {
            usedPercentage.isFinite && (0...100).contains(usedPercentage)
                && resetsAt.isFinite && resetsAt > 0 && resetsAt <= 253_402_300_799
        }
    }

    struct ResetCreditGrant: Codable, Sendable, Equatable {
        let id: String
        let label: String?
        let resetsLeft: Int
        let endsAt: Double?
        let usableNow: Bool?

        var isValid: Bool {
            !id.isEmpty && id.utf8.count <= 128
                && (label.map { $0.utf8.count <= 160 } ?? true)
                && resetsLeft >= 0 && resetsLeft <= 100
                && (endsAt.map { $0.isFinite && $0 > 0 && $0 <= 253_402_300_799 } ?? true)
        }
    }

    var isValid: Bool {
        schemaVersion == 1 && receivedAt.isFinite && receivedAt > 0 && receivedAt <= 253_402_300_799
            && !sessionID.isEmpty && sessionID.utf8.count <= 256
            && !claudeCodeVersion.isEmpty && claudeCodeVersion.utf8.count <= 128
            && (rateLimits.fiveHour?.isValid ?? true) && (rateLimits.sevenDay?.isValid ?? true)
            && (resetCredits?.count ?? 0) <= 32 && (resetCredits?.allSatisfy(\.isValid) ?? true)
    }

    static func capture(_ data: Data, receivedAt: Date) throws -> Self {
        guard data.count <= 1_048_576,
              let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = input["session_id"] as? String,
              let version = input["version"] as? String else { throw ClaudeStatuslineError.invalidSnapshot }
        let limits = input["rate_limits"] as? [String: Any] ?? [:]
        func window(_ name: String) -> Window? {
            guard let raw = limits[name] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let value = try? JSONDecoder().decode(Window.self, from: data), value.isValid else { return nil }
            return value
        }
        let cedarEmber = input["cedar_ember"] as? [String: Any]
        let grants = cedarEmber?["grants"] as? [Any]
            ?? limits["reset_credits"] as? [Any]
            ?? input["reset_credits"] as? [Any]
            ?? []
        var resetCredits: [ResetCreditGrant] = []
        for raw in grants {
            guard let fields = raw as? [String: Any], let grant = parseGrant(fields) else { continue }
            resetCredits.append(grant)
            if resetCredits.count == 32 { break }
        }
        let value = Self(schemaVersion: 1, receivedAt: receivedAt.timeIntervalSince1970,
                         sessionID: session, claudeCodeVersion: version,
                         rateLimits: .init(fiveHour: window("five_hour"), sevenDay: window("seven_day")),
                         resetCredits: resetCredits.isEmpty ? nil : resetCredits)
        guard value.isValid else { throw ClaudeStatuslineError.invalidSnapshot }
        return value
    }

    private static func parseGrant(_ fields: [String: Any]) -> ResetCreditGrant? {
        func field(_ keys: String...) -> Any? {
            for key in keys {
                if let value = fields[key], !(value is NSNull) { return value }
            }
            return nil
        }

        guard let id = fields["id"] as? String,
              let rawCount = field("resets_left", "resetsLeft", "remaining") as? NSNumber,
              CFGetTypeID(rawCount) != CFBooleanGetTypeID(),
              let resetsLeft = rawCount as? Int else { return nil }
        let label = (fields["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = label.flatMap { $0.isEmpty ? nil : $0 }

        var endsAt: Double?
        if let expiry = field("ends_at", "endsAt", "expires_at", "expiresAt") {
            guard let timestamp = parseGrantExpiry(expiry) else { return nil }
            endsAt = timestamp
        }

        var usableNow: Bool?
        if let usable = field("usable_now", "usableNow") {
            guard let flag = usable as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            usableNow = flag.boolValue
        }

        let grant = ResetCreditGrant(id: id, label: normalizedLabel, resetsLeft: resetsLeft, endsAt: endsAt, usableNow: usableNow)
        return grant.isValid ? grant : nil
    }

    private static func parseGrantExpiry(_ raw: Any) -> Double? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let seconds = number.doubleValue
            return seconds > 10_000_000_000 ? seconds / 1_000 : seconds
        }
        guard let string = raw as? String else { return nil }
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
        return date?.timeIntervalSince1970
    }
}

enum ClaudeStatuslineError: LocalizedError {
    case invalidSnapshot, unsafePath, settingsChanged, unsupportedStatusline, io
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "Claude statusline snapshot is invalid or unsupported."
        case .unsafePath: "Claude statusline storage must be owned by this user with private permissions."
        case .settingsChanged: "Statusline changed outside MyUsage. Your settings were preserved. Restore the MyUsage command before disabling, or remove its wrapper manually."
        case .unsupportedStatusline: "Existing statusLine is not a supported command. Your settings were preserved."
        case .io: "Could not access Claude statusline files."
        }
    }
}

/// Private files, same-directory atomic replacement, and cross-process serialization.
enum ClaudePrivateFiles {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw ClaudeStatuslineError.unsafePath }
        guard chmod(url.path, 0o700) == 0 else { throw ClaudeStatuslineError.io }
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    static func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ClaudeStatuslineError.io }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 65_536 else {
            throw ClaudeStatuslineError.unsafePath
        }
        return try handle.readToEnd() ?? Data()
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ClaudeStatuslineError.io }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw ClaudeStatuslineError.io }
    }

    static func locked<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ClaudeStatuslineError.io }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ClaudeStatuslineError.unsafePath }
        guard flock(fd, LOCK_EX) == 0 else { throw ClaudeStatuslineError.io }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

struct ClaudeStatuslineStore: Sendable {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyUsage/ClaudeStatusline", isDirectory: true)
    let directory: URL
    var snapshotsDirectory: URL { directory.appendingPathComponent("snapshots", isDirectory: true) }

    func write(_ data: Data, now: Date = .now) throws {
        let snapshot = try ClaudeStatuslineSnapshot.capture(data, receivedAt: now)
        try ClaudePrivateFiles.directory(directory)
        try ClaudePrivateFiles.directory(snapshotsDirectory)
        let key = SHA256.hash(data: Data(snapshot.sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = snapshotsDirectory.appendingPathComponent("\(key).json")
        try ClaudePrivateFiles.locked(at: snapshotsDirectory.appendingPathComponent("\(key).lock")) {
            // A delayed writer must not replace a newer receipt for the same session.
            if let old = try? JSONDecoder().decode(ClaudeStatuslineSnapshot.self, from: ClaudePrivateFiles.read(file)),
               old.isValid, old.receivedAt > snapshot.receivedAt { return }
            try ClaudePrivateFiles.atomicWrite(JSONEncoder().encode(snapshot), to: file)
        }
    }

    struct ReadResult {
        let latest: ClaudeStatuslineSnapshot?
        let hasInvalidFiles: Bool
    }

    func read() throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: snapshotsDirectory.path) else {
            return .init(latest: nil, hasInvalidFiles: false)
        }
        // Do not follow a redirected snapshot directory, even on the read path.
        for url in [directory, snapshotsDirectory] {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ClaudeStatuslineError.unsafePath }
        }
        var latest: ClaudeStatuslineSnapshot?
        var invalid = false
        for file in try FileManager.default.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            guard let data = try? ClaudePrivateFiles.read(file),
                  let value = try? JSONDecoder().decode(ClaudeStatuslineSnapshot.self, from: data), value.isValid else {
                invalid = true
                continue
            }
            // Pick one complete receipt; never sum sessions or stitch their windows together.
            if latest == nil || value.receivedAt > latest!.receivedAt
                || (value.receivedAt == latest!.receivedAt && value.sessionID > latest!.sessionID) { latest = value }
        }
        return .init(latest: latest, hasInvalidFiles: invalid)
    }
}
