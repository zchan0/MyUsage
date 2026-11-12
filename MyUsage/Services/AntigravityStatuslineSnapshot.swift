import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Allowlisted Antigravity CLI (`agy`) statusLine payload persisted locally.
/// Receipt time is local, not a server sample time.
struct AntigravityStatuslineSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let receivedAt: Double
    let sessionID: String
    let cliVersion: String?
    let planTier: String?
    let email: String?
    let quotas: [QuotaBucket]

    init(
        schemaVersion: Int = 1,
        receivedAt: Double,
        sessionID: String,
        cliVersion: String? = nil,
        planTier: String? = nil,
        email: String? = nil,
        quotas: [QuotaBucket] = []
    ) {
        self.schemaVersion = schemaVersion
        self.receivedAt = receivedAt
        self.sessionID = sessionID
        self.cliVersion = cliVersion
        self.planTier = planTier
        self.email = email
        self.quotas = quotas
    }

    struct QuotaBucket: Codable, Sendable, Equatable {
        let bucketID: String
        let displayName: String?
        let groupName: String?
        let window: String?
        let remainingFraction: Double
        let resetsAt: Double?

        init(
            bucketID: String,
            displayName: String? = nil,
            groupName: String? = nil,
            window: String? = nil,
            remainingFraction: Double,
            resetsAt: Double? = nil
        ) {
            self.bucketID = bucketID
            self.displayName = displayName
            self.groupName = groupName
            self.window = window
            self.remainingFraction = remainingFraction
            self.resetsAt = resetsAt
        }

        var isValid: Bool {
            !bucketID.isEmpty && bucketID.utf8.count <= 128
                && (displayName.map { !$0.isEmpty && $0.utf8.count <= 160 } ?? true)
                && (groupName.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true)
                && (window.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
                && remainingFraction.isFinite && (0...1).contains(remainingFraction)
                && (resetsAt.map { $0.isFinite && $0 > 0 && $0 <= 253_402_300_799 } ?? true)
        }
    }

    var isValid: Bool {
        schemaVersion == 1
            && receivedAt.isFinite && receivedAt > 0 && receivedAt <= 253_402_300_799
            && !sessionID.isEmpty && sessionID.utf8.count <= 256
            && (cliVersion.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true)
            && (planTier.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true)
            && (email.map { !$0.isEmpty && $0.utf8.count <= 254 } ?? true)
            && quotas.count <= 32
            && quotas.allSatisfy(\.isValid)
    }

    static func capture(_ data: Data, receivedAt: Date) throws -> Self {
        guard data.count <= 1_048_576,
              let input = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityStatuslineError.invalidSnapshot
        }

        let rawSession = trimmedString(input["conversation_id"]) ?? trimmedString(input["session_id"])
        let cliVersion = boundedString(trimmedString(input["version"]), maxBytes: 128)
        let account = (input["account"] as? [String: Any]) ?? (input["user"] as? [String: Any])
        let planTier = boundedString(
            trimmedString(input["plan_tier"])
                ?? trimmedString(input["planTier"])
                ?? trimmedString(account?["plan_tier"])
                ?? trimmedString(account?["planTier"]),
            maxBytes: 128
        )
        let email = sanitizeEmail(
            trimmedString(input["email"])
                ?? trimmedString(account?["email"])
                ?? trimmedString(account?["account_email"])
                ?? trimmedString(account?["accountEmail"])
        )
        let rawQuota: Any? = (input["quota"] as? [String: Any])
            ?? (input["quotas"] as? [String: Any])
            ?? (input["quota"] as? [Any])
            ?? (input["quotas"] as? [Any])
        let hasQuotaObject = rawQuota != nil

        // Require at least one recognized Antigravity statusLine field so arbitrary JSON is rejected.
        guard rawSession != nil || cliVersion != nil || hasQuotaObject else {
            throw AntigravityStatuslineError.invalidSnapshot
        }

        let sessionID = rawSession ?? "default"
        let quotas = parseQuotas(from: rawQuota, receivedAt: receivedAt)

        let value = Self(
            schemaVersion: 1,
            receivedAt: receivedAt.timeIntervalSince1970,
            sessionID: sessionID,
            cliVersion: cliVersion,
            planTier: planTier,
            email: email,
            quotas: quotas
        )
        guard value.isValid else { throw AntigravityStatuslineError.invalidSnapshot }
        return value
    }

    // MARK: - Parsing helpers

    private static func parseQuotas(from rawQuota: Any?, receivedAt: Date) -> [QuotaBucket] {
        if let list = rawQuota as? [Any] {
            return parseBucketList(list, groupName: nil, receivedAt: receivedAt)
        }
        guard let dict = rawQuota as? [String: Any] else { return [] }

        var buckets: [QuotaBucket] = []

        // Support optional envelope `{ "groups": [...] }` or `{ "buckets": { ... } / [...] }` as well as
        // the official flat dictionary `{ "<bucket-id>": { "remaining_fraction": ... } }`.
        if let groups = (dict["groups"] ?? dict["quota_groups"] ?? dict["quotaGroups"]) as? [Any] {
            for rawGroup in groups {
                guard let group = rawGroup as? [String: Any] else { continue }
                let groupName = boundedString(
                    trimmedString(group["display_name"])
                        ?? trimmedString(group["displayName"])
                        ?? trimmedString(group["name"]),
                    maxBytes: 128
                )
                if let list = (group["buckets"] ?? group["quota_buckets"] ?? group["quotaBuckets"]) as? [Any] {
                    for bucket in parseBucketList(list, groupName: groupName, receivedAt: receivedAt) {
                        buckets.append(bucket)
                        if buckets.count == 32 { return buckets }
                    }
                }
            }
        } else if let list = (dict["buckets"] ?? dict["quota_buckets"] ?? dict["quotaBuckets"]) as? [Any] {
            return parseBucketList(list, groupName: nil, receivedAt: receivedAt)
        } else if let nested = dict["buckets"] as? [String: Any] {
            for key in nested.keys.sorted() {
                guard let fields = nested[key] as? [String: Any],
                      let bucket = parseBucket(id: key, groupName: nil, fields: fields, receivedAt: receivedAt) else {
                    continue
                }
                buckets.append(bucket)
                if buckets.count == 32 { break }
            }
        } else {
            for key in dict.keys.sorted() {
                guard let fields = dict[key] as? [String: Any],
                      let bucket = parseBucket(id: key, groupName: nil, fields: fields, receivedAt: receivedAt) else {
                    continue
                }
                buckets.append(bucket)
                if buckets.count == 32 { break }
            }
        }

        return buckets
    }

    private static func parseBucketList(
        _ list: [Any],
        groupName: String?,
        receivedAt: Date
    ) -> [QuotaBucket] {
        var buckets: [QuotaBucket] = []
        for item in list {
            guard let fields = item as? [String: Any],
                  let bucket = parseBucket(
                      id: trimmedString(fields["bucket_id"])
                          ?? trimmedString(fields["bucketId"])
                          ?? trimmedString(fields["id"]),
                      groupName: groupName,
                      fields: fields,
                      receivedAt: receivedAt
                  ) else { continue }
            buckets.append(bucket)
            if buckets.count == 32 { break }
        }
        return buckets
    }

    private static func parseBucket(
        id: String?,
        groupName: String?,
        fields: [String: Any],
        receivedAt: Date
    ) -> QuotaBucket? {
        guard let bucketID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !bucketID.isEmpty else {
            return nil
        }
        if let disabled = boolValue(fields["disabled"]), disabled {
            return nil
        }

        let remainingFraction: Double
        if let value = doubleValue(fields["remaining_fraction"] ?? fields["remainingFraction"] ?? fields["remaining"]) {
            guard (0...1).contains(value) else { return nil }
            remainingFraction = value
        } else if let used = doubleValue(fields["used_fraction"] ?? fields["usedFraction"]) {
            guard (0...1).contains(used) else { return nil }
            remainingFraction = 1 - used
        } else if let pct = doubleValue(fields["remaining_percentage"] ?? fields["remainingPercentage"]) {
            guard (0...100).contains(pct) else { return nil }
            remainingFraction = pct / 100
        } else if let pct = doubleValue(fields["used_percentage"] ?? fields["usedPercentage"]) {
            guard (0...100).contains(pct) else { return nil }
            remainingFraction = 1 - pct / 100
        } else {
            return nil
        }

        let resetsAt = parseResetTimestamp(fields: fields, receivedAt: receivedAt)
        let displayName = boundedString(
            trimmedString(fields["display_name"])
                ?? trimmedString(fields["displayName"])
                ?? trimmedString(fields["label"]),
            maxBytes: 160
        )
        let resolvedGroup = groupName ?? boundedString(
            trimmedString(fields["group_name"]) ?? trimmedString(fields["groupName"]),
            maxBytes: 128
        )
        let window = boundedString(
            trimmedString(fields["window"])
                ?? trimmedString(fields["window_label"])
                ?? trimmedString(fields["windowLabel"])
                ?? trimmedString(fields["cadence"]),
            maxBytes: 64
        )

        let bucket = QuotaBucket(
            bucketID: bucketID,
            displayName: displayName,
            groupName: resolvedGroup,
            window: window,
            remainingFraction: remainingFraction,
            resetsAt: resetsAt
        )
        return bucket.isValid ? bucket : nil
    }

    private static func parseResetTimestamp(fields: [String: Any], receivedAt: Date) -> Double? {
        for key in ["reset_time", "resetTime", "resets_at", "resetsAt"] {
            guard let raw = fields[key], !(raw is NSNull) else { continue }
            if let num = doubleValue(raw) {
                let seconds = num > 10_000_000_000 ? num / 1_000 : num
                if seconds > 0 && seconds <= 253_402_300_799 { return seconds }
            } else if let str = trimmedString(raw) {
                let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(str))
                    ?? (try? Date.ISO8601FormatStyle().parse(str))
                if let ts = date?.timeIntervalSince1970, ts > 0 && ts <= 253_402_300_799 {
                    return ts
                }
            }
        }
        if let seconds = doubleValue(fields["reset_in_seconds"] ?? fields["resetInSeconds"]), seconds > 0 {
            let ts = receivedAt.timeIntervalSince1970 + seconds
            if ts > 0 && ts <= 253_402_300_799 { return ts }
        }
        return nil
    }

    private static func trimmedString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boundedString(_ raw: String?, maxBytes: Int) -> String? {
        guard let raw, raw.utf8.count <= maxBytes else { return nil }
        return raw
    }

    private static func sanitizeEmail(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 254, raw.contains("@"),
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return raw
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }
        let val = num.doubleValue
        return val.isFinite ? val : nil
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        guard let num = raw as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() else { return nil }
        return num.boolValue
    }
}

enum AntigravityStatuslineError: LocalizedError {
    case invalidSnapshot, unsafePath, settingsChanged, unsupportedStatusline, io

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            "Antigravity statusline snapshot is invalid or unsupported."
        case .unsafePath:
            "Antigravity statusline storage must be owned by this user with private permissions."
        case .settingsChanged:
            "Antigravity CLI statusLine changed outside MyUsage. Your settings were preserved. Restore the MyUsage command before disabling, or remove its wrapper manually."
        case .unsupportedStatusline:
            "Existing Antigravity CLI statusLine is not a supported command. Your settings were preserved."
        case .io:
            "Could not access Antigravity statusline files."
        }
    }

    static func mappingPrivateFileError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ClaudeStatuslineError {
            switch error {
            case .unsafePath: throw AntigravityStatuslineError.unsafePath
            case .io: throw AntigravityStatuslineError.io
            case .invalidSnapshot: throw AntigravityStatuslineError.invalidSnapshot
            case .settingsChanged: throw AntigravityStatuslineError.settingsChanged
            case .unsupportedStatusline: throw AntigravityStatuslineError.unsupportedStatusline
            }
        }
    }
}

struct AntigravityStatuslineStore: Sendable {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyUsage/AntigravityStatusline", isDirectory: true)

    let directory: URL
    var snapshotsDirectory: URL { directory.appendingPathComponent("snapshots", isDirectory: true) }

    func write(_ data: Data, now: Date = .now) throws {
        let snapshot = try AntigravityStatuslineSnapshot.capture(data, receivedAt: now)
        try AntigravityStatuslineError.mappingPrivateFileError {
            try ClaudePrivateFiles.directory(directory)
            try ClaudePrivateFiles.directory(snapshotsDirectory)
            let key = SHA256.hash(data: Data(snapshot.sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = snapshotsDirectory.appendingPathComponent("\(key).json")
            try ClaudePrivateFiles.locked(at: snapshotsDirectory.appendingPathComponent("\(key).lock")) {
                if let old = try? JSONDecoder().decode(AntigravityStatuslineSnapshot.self, from: ClaudePrivateFiles.read(file)),
                   old.isValid, old.receivedAt > snapshot.receivedAt {
                    return
                }
                try ClaudePrivateFiles.atomicWrite(JSONEncoder().encode(snapshot), to: file)
            }
        }
    }

    struct ReadResult: Sendable {
        let latest: AntigravityStatuslineSnapshot?
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
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw AntigravityStatuslineError.unsafePath
            }
        }
        var latest: AntigravityStatuslineSnapshot?
        var invalid = false
        for file in try FileManager.default.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            guard let data = try? ClaudePrivateFiles.read(file),
                  let value = try? JSONDecoder().decode(AntigravityStatuslineSnapshot.self, from: data),
                  value.isValid else {
                invalid = true
                continue
            }
            // Pick one complete receipt; never sum sessions or stitch their buckets together.
            if latest == nil
                || value.receivedAt > latest!.receivedAt
                || (value.receivedAt == latest!.receivedAt && value.sessionID > latest!.sessionID) {
                latest = value
            }
        }
        return .init(latest: latest, hasInvalidFiles: invalid)
    }
}
