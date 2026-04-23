import Foundation

/// Disk cache for Claude's monthly USD estimate. Avoids re-parsing
/// `~/.claude/projects/**/*.jsonl` on every refresh tick when no new
/// session files have been written — see `specs/11-claude-data-sources.md`.
///
/// Gated by (calendar month, max source file mtime). Once a new message is
/// appended to any tracked JSONL, the filesystem bumps the file's mtime,
/// our stat pass picks it up, and the cache is invalidated into a full
/// rescan. Month rollover is handled by the month check.
enum ClaudeCostCache {

    // MARK: - Schema

    /// Bump when `Payload` changes shape. Older caches are silently discarded.
    static let currentVersion = 1

    struct Payload: Codable, Sendable, Equatable {
        let v: Int
        /// Calendar month key, `"YYYY-MM"` from the writer's locale calendar.
        let month: String
        /// Final USD total (preComputedCost + token-priced cost).
        let totalUSD: Double
        /// Server-provided `costUSD` sum, kept for diagnostics / UI reuse.
        let preComputedCost: Double
        /// Per-model token counts for rows that did NOT carry `costUSD`.
        /// Stored so future per-model UI can reuse the breakdown without
        /// another full scan.
        let tokensByModel: [String: CachedTokenCounts]
        /// Latest `contentModificationDate` across all JSONL files scanned.
        /// Next stat pass uses this as the cache-invalidation key.
        let maxSourceMtime: Date
        let computedAt: Date
    }

    /// Codable mirror of `TokenUsage` kept local to the cache so schema
    /// changes to `TokenUsage` don't silently break cache decode — bump
    /// `currentVersion` instead.
    struct CachedTokenCounts: Codable, Sendable, Equatable {
        let input: Int
        let output: Int
        let cacheWrite: Int
        let cacheRead: Int
        let cachedInput: Int
    }

    // MARK: - Paths

    static let defaultFileURL: URL = defaultDirectory
        .appendingPathComponent("claude-cost.json")

    static let defaultDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MyUsage", isDirectory: true)
    }()

    // MARK: - Read / Write

    /// Never throws; returns `nil` on missing file, invalid JSON, or schema
    /// version mismatch.
    static func read(from url: URL = defaultFileURL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        guard payload.v == currentVersion else { return nil }
        return payload
    }

    /// Atomic write with directory creation. Throws on filesystem errors;
    /// callers should log and continue — cost cache is reconstructible.
    static func write(_ payload: Payload, to url: URL = defaultFileURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    /// `"YYYY-MM"` in the provided calendar (local time). Month boundaries
    /// follow the user's locale on purpose: the "monthly cost" label on the
    /// card should flip at the user's local midnight on the 1st.
    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

extension ClaudeCostCache.CachedTokenCounts {
    init(_ usage: TokenUsage) {
        self.input = usage.input
        self.output = usage.output
        self.cacheWrite = usage.cacheWrite
        self.cacheRead = usage.cacheRead
        self.cachedInput = usage.cachedInput
    }
}
