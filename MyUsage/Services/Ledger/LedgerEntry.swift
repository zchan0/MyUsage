import Foundation

/// One row in the usage ledger. v1 rows are **daily aggregates** per
/// (device, provider, account, day) — `sourceHash` is just the day string
/// so re-scanning the same log is idempotent via the PRIMARY KEY. Finer
/// granularity (per-session, per-message) can be added later without a
/// schema migration by evolving how `sourceHash` is computed.
///
/// Wire format (JSONL, camelCase) and SQLite column names (snake_case) are
/// kept in sync by the `Codable` keys below.
struct LedgerEntry: Sendable, Equatable, Codable {

    /// Schema version for the JSONL line itself. Bump if the struct shape
    /// changes; readers silently drop unknown versions.
    static let wireVersion = 1

    /// Author device UUID. Constant per (install, Mac).
    let deviceId: String

    /// Account identifier. v1 always `"default"`; spec 13 fills in real
    /// values for users with multiple Claude / Codex accounts.
    let accountId: String

    /// Provider kind — the enum's raw value (`"claude"` / `"codex"`).
    /// Stored as a string so the column survives enum additions.
    let provider: String

    /// UTC calendar day in `YYYY-MM-DD` format. Using UTC keeps the month
    /// boundary deterministic across time zones.
    let day: String

    /// Authoritative cost (USD) for this (device, provider, account, day).
    /// Frozen at write time — later `pricing.json` edits do not retroactively
    /// rewrite past rows (see "Non-goals" in spec 12).
    let costUSD: Double

    /// Dedup key for this row. v1: equals `day`. Future (per-message)
    /// granularity can put a real hash here without touching the schema.
    let sourceHash: String

    /// Unix seconds when this row was written locally. Used as the tiebreaker
    /// during peer imports and conflict-copy merges.
    let recordedAt: Int64

    /// JSONL wire version. Always `wireVersion` on write; tolerated as a
    /// mismatch signal on read.
    let v: Int

    init(
        deviceId: String,
        accountId: String = "default",
        provider: ProviderKind,
        day: String,
        costUSD: Double,
        sourceHash: String? = nil,
        recordedAt: Date = .now,
        v: Int = LedgerEntry.wireVersion
    ) {
        self.deviceId = deviceId
        self.accountId = accountId
        self.provider = provider.rawValue
        self.day = day
        self.costUSD = costUSD
        self.sourceHash = sourceHash ?? day
        self.recordedAt = Int64(recordedAt.timeIntervalSince1970)
        self.v = v
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case v
        case deviceId
        case accountId
        case provider
        case day
        case costUSD
        case sourceHash
        case recordedAt
    }
}

/// Canonical UTC calendar used for day bucketing. Kept as a single source of
/// truth so writer + reader + tests agree on month / day rollover.
enum LedgerCalendar {

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? c.timeZone
        return c
    }()

    /// `YYYY-MM-DD` in UTC.
    static func dayKey(for date: Date) -> String {
        let comps = utc.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0
        )
    }

    /// `YYYY-MM` in UTC.
    static func monthKey(for date: Date) -> String {
        let comps = utc.dateComponents([.year, .month], from: date)
        return String(
            format: "%04d-%02d",
            comps.year ?? 0,
            comps.month ?? 0
        )
    }

    /// Extract the `YYYY-MM` prefix of a `YYYY-MM-DD` day string.
    static func monthPrefix(of day: String) -> String {
        String(day.prefix(7))
    }

    /// First instant of the calendar month containing `date`, in UTC.
    static func startOfMonthUTC(for date: Date) -> Date {
        let comps = utc.dateComponents([.year, .month], from: date)
        return utc.date(from: comps) ?? date
    }
}
