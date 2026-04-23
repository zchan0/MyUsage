import Foundation

/// `manifest.json` lives alongside each device's `ledger.jsonl` and lets
/// peers read a quick summary of that device's contributions without
/// parsing the full JSONL. This is a UX cache — the SQLite merge is still
/// authoritative.
struct LedgerManifest: Codable, Sendable, Equatable {

    static let currentVersion = 1

    let v: Int
    let deviceId: String
    let deviceName: String
    /// Unix seconds when this manifest was last written.
    let updatedAt: Int64
    /// Total rows ever written by this device (approximate; reset on
    /// "Reset ledger").
    let rowCount: Int
    /// Unix seconds of the most recent ledger entry.
    let lastEntryAt: Int64
    /// `provider` → `monthKey` → total cost. Only current-month rollups are
    /// kept populated; older months are truncated to save space.
    let monthlyTotals: [String: [String: Double]]

    init(
        deviceId: String,
        deviceName: String,
        updatedAt: Date,
        rowCount: Int,
        lastEntryAt: Date?,
        monthlyTotals: [String: [String: Double]],
        v: Int = LedgerManifest.currentVersion
    ) {
        self.v = v
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.updatedAt = Int64(updatedAt.timeIntervalSince1970)
        self.rowCount = rowCount
        self.lastEntryAt = Int64((lastEntryAt ?? .distantPast).timeIntervalSince1970)
        self.monthlyTotals = monthlyTotals
    }
}

enum LedgerManifestCodec {

    /// Read + validate the manifest at `url`. Returns `nil` on any failure
    /// (missing file, bad JSON, schema mismatch) — callers treat "no
    /// manifest" and "unreadable manifest" identically.
    static func read(from url: URL) -> LedgerManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let manifest = try? decoder.decode(LedgerManifest.self, from: data) else {
            return nil
        }
        guard manifest.v == LedgerManifest.currentVersion else { return nil }
        return manifest
    }

    /// Atomic write. Caller is responsible for directory creation.
    static func write(_ manifest: LedgerManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()
}
