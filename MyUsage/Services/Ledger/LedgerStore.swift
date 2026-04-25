import Foundation
import SQLite3

// SQLITE_TRANSIENT — required by sqlite3_bind_text to copy the string.
private let SQLITE_TRANSIENT_DEST = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

/// SQLite-backed storage for the multi-device ledger. One instance per
/// on-disk database; use `:memory:` for tests.
///
/// Thread-safety: wrapped by `LedgerWriter` (an actor), so all access
/// already serializes. `LedgerStore` itself is non-actor to keep callers
/// simple.
final class LedgerStore: @unchecked Sendable {

    /// Schema version stored in `schema_meta`. Bump on `CREATE TABLE` changes.
    static let schemaVersion = 1

    private let path: String
    private var db: OpaquePointer?

    /// Sentinel path that opens a per-connection in-memory SQLite database
    /// (matching SQLite's C-API convention). Use in tests.
    static let inMemoryPath = ":memory:"

    /// Errors the store can produce. Kept LocalizedError for log-friendly
    /// messages without pulling in a full error-type hierarchy.
    enum StoreError: Error, LocalizedError {
        case open(code: Int32, message: String)
        case prepare(sql: String, code: Int32, message: String)
        case step(sql: String, code: Int32, message: String)
        case schemaTooNew(found: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case .open(let code, let message):
                return "Ledger open failed (\(code)): \(message)"
            case .prepare(let sql, let code, let message):
                return "Ledger prepare failed (\(code)): \(message) — SQL: \(sql)"
            case .step(let sql, let code, let message):
                return "Ledger step failed (\(code)): \(message) — SQL: \(sql)"
            case .schemaTooNew(let found, let supported):
                return "Ledger schema v\(found) is newer than this build (v\(supported))"
            }
        }
    }

    // MARK: - Init / teardown

    /// Open (or create) a file-backed database at `url`. Parent directory
    /// is created on demand.
    convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    /// Open (or create) a database at `path`. Pass `LedgerStore.inMemoryPath`
    /// (`":memory:"`) for an isolated in-memory DB — useful for tests.
    init(path: String) throws {
        self.path = path

        if path != Self.inMemoryPath {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        }

        let openResult = sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw StoreError.open(code: openResult, message: message)
        }

        // WAL is only supported on file-backed databases; in-memory stays
        // on the default rollback journal.
        if path != Self.inMemoryPath {
            try exec("PRAGMA journal_mode=WAL;")
        }
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")

        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Migration

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                version INTEGER NOT NULL
            );
        """)

        let current = try selectInt("SELECT version FROM schema_meta LIMIT 1;")
        if let current {
            if current > Self.schemaVersion {
                throw StoreError.schemaTooNew(
                    found: current,
                    supported: Self.schemaVersion
                )
            }
        } else {
            try exec(
                "INSERT INTO schema_meta (version) VALUES (\(Self.schemaVersion));"
            )
        }

        try exec("""
            CREATE TABLE IF NOT EXISTS ledger_entries (
                device_id    TEXT    NOT NULL,
                account_id   TEXT    NOT NULL,
                provider     TEXT    NOT NULL,
                day          TEXT    NOT NULL,
                cost_usd     REAL    NOT NULL,
                source_hash  TEXT    NOT NULL,
                schema_ver   INTEGER NOT NULL DEFAULT 1,
                recorded_at  INTEGER NOT NULL,
                PRIMARY KEY (device_id, account_id, provider, source_hash)
            );
        """)

        try exec("""
            CREATE INDEX IF NOT EXISTS idx_ledger_month
              ON ledger_entries (provider, day);
        """)

        try exec("""
            CREATE INDEX IF NOT EXISTS idx_ledger_device
              ON ledger_entries (device_id, provider);
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS peer_state (
                device_id   TEXT PRIMARY KEY,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                updated_at  INTEGER NOT NULL
            );
        """)
    }

    // MARK: - Upsert

    /// Insert a batch of entries with "latest recordedAt wins" semantics.
    /// Returns the rows that were actually written (new or replaced) so the
    /// writer can decide which ones to append to JSONL.
    @discardableResult
    func upsert(_ entries: [LedgerEntry]) throws -> [LedgerEntry] {
        guard !entries.isEmpty else { return [] }

        let sql = """
            INSERT INTO ledger_entries
                (device_id, account_id, provider, day, cost_usd,
                 source_hash, schema_ver, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(device_id, account_id, provider, source_hash)
            DO UPDATE SET
                cost_usd    = excluded.cost_usd,
                day         = excluded.day,
                recorded_at = excluded.recorded_at
            WHERE excluded.recorded_at >= ledger_entries.recorded_at
               AND excluded.cost_usd   <> ledger_entries.cost_usd;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        try exec("BEGIN IMMEDIATE;")
        var applied: [LedgerEntry] = []
        applied.reserveCapacity(entries.count)

        for entry in entries {
            let before = sqlite3_total_changes(db)

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, entry.deviceId, -1, SQLITE_TRANSIENT_DEST)
            sqlite3_bind_text(stmt, 2, entry.accountId, -1, SQLITE_TRANSIENT_DEST)
            sqlite3_bind_text(stmt, 3, entry.provider, -1, SQLITE_TRANSIENT_DEST)
            sqlite3_bind_text(stmt, 4, entry.day, -1, SQLITE_TRANSIENT_DEST)
            sqlite3_bind_double(stmt, 5, entry.costUSD)
            sqlite3_bind_text(stmt, 6, entry.sourceHash, -1, SQLITE_TRANSIENT_DEST)
            sqlite3_bind_int(stmt, 7, Int32(Self.schemaVersion))
            sqlite3_bind_int64(stmt, 8, entry.recordedAt)

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                try? exec("ROLLBACK;")
                throw StoreError.step(
                    sql: sql,
                    code: rc,
                    message: String(cString: sqlite3_errmsg(db))
                )
            }

            if sqlite3_total_changes(db) > before {
                applied.append(entry)
            }
        }

        try exec("COMMIT;")
        return applied
    }

    // MARK: - Queries

    /// Sum of `cost_usd` for the given provider within the given
    /// `YYYY-MM` month across *all* devices.
    func monthlyTotal(provider: ProviderKind, monthKey: String) throws -> Double {
        let sql = """
            SELECT COALESCE(SUM(cost_usd), 0)
            FROM ledger_entries
            WHERE provider = ?1 AND substr(day, 1, 7) = ?2;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, SQLITE_TRANSIENT_DEST)
        sqlite3_bind_text(stmt, 2, monthKey, -1, SQLITE_TRANSIENT_DEST)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    /// Per-device subtotal for a given (provider, month). Used by the
    /// provider-card popover.
    struct DeviceTotal: Sendable, Equatable {
        let deviceId: String
        let costUSD: Double
    }

    func monthlyTotalsByDevice(
        provider: ProviderKind,
        monthKey: String
    ) throws -> [DeviceTotal] {
        let sql = """
            SELECT device_id, SUM(cost_usd)
            FROM ledger_entries
            WHERE provider = ?1 AND substr(day, 1, 7) = ?2
            GROUP BY device_id
            ORDER BY SUM(cost_usd) DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, SQLITE_TRANSIENT_DEST)
        sqlite3_bind_text(stmt, 2, monthKey, -1, SQLITE_TRANSIENT_DEST)

        var result: [DeviceTotal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            let cost = sqlite3_column_double(stmt, 1)
            result.append(DeviceTotal(
                deviceId: String(cString: idCStr),
                costUSD: cost
            ))
        }
        return result
    }

    /// Per-provider monthly total for a single device's own rows. Feeds
    /// the `monthlyTotals` section of `manifest.json`.
    func monthlyTotalsForManifest(
        deviceID: String,
        monthKey: String
    ) throws -> [String: [String: Double]] {
        let sql = """
            SELECT provider, substr(day, 1, 7) AS m, SUM(cost_usd)
            FROM ledger_entries
            WHERE device_id = ?1 AND substr(day, 1, 7) = ?2
            GROUP BY provider, m;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceID, -1, SQLITE_TRANSIENT_DEST)
        sqlite3_bind_text(stmt, 2, monthKey, -1, SQLITE_TRANSIENT_DEST)

        var out: [String: [String: Double]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pCStr = sqlite3_column_text(stmt, 0),
                  let mCStr = sqlite3_column_text(stmt, 1) else { continue }
            let provider = String(cString: pCStr)
            let m = String(cString: mCStr)
            let cost = sqlite3_column_double(stmt, 2)
            out[provider, default: [:]][m] = cost
        }
        return out
    }

    /// Row count + latest `recorded_at` authored by this device. Used to
    /// populate the manifest without a second query pass.
    struct ManifestMeta: Sendable {
        let rowCount: Int
        let lastEntryAt: Date?
    }

    func manifestMeta(deviceID: String) throws -> ManifestMeta {
        let sql = """
            SELECT COUNT(*), MAX(recorded_at)
            FROM ledger_entries
            WHERE device_id = ?1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceID, -1, SQLITE_TRANSIENT_DEST)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return ManifestMeta(rowCount: 0, lastEntryAt: nil)
        }
        let count = Int(sqlite3_column_int64(stmt, 0))
        let last: Date? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)))
        return ManifestMeta(rowCount: count, lastEntryAt: last)
    }

    /// Distinct device IDs that have ever contributed a row.
    func knownDeviceIDs() throws -> [String] {
        let sql = """
            SELECT DISTINCT device_id
            FROM ledger_entries
            ORDER BY device_id;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: cStr))
            }
        }
        return ids
    }

    /// All latest rows authored by a device, in a stable order suitable for
    /// rewriting that device's sync JSONL from the local SQLite source of truth.
    func entries(forDevice deviceID: String) throws -> [LedgerEntry] {
        let sql = """
            SELECT device_id, account_id, provider, day, cost_usd,
                   source_hash, recorded_at, schema_ver
            FROM ledger_entries
            WHERE device_id = ?1
            ORDER BY provider, account_id, day, source_hash;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceID, -1, SQLITE_TRANSIENT_DEST)

        var entries: [LedgerEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let deviceCStr = sqlite3_column_text(stmt, 0),
                  let accountCStr = sqlite3_column_text(stmt, 1),
                  let providerCStr = sqlite3_column_text(stmt, 2),
                  let dayCStr = sqlite3_column_text(stmt, 3),
                  let sourceCStr = sqlite3_column_text(stmt, 5)
            else { continue }

            entries.append(LedgerEntry(
                deviceId: String(cString: deviceCStr),
                accountId: String(cString: accountCStr),
                providerRaw: String(cString: providerCStr),
                day: String(cString: dayCStr),
                costUSD: sqlite3_column_double(stmt, 4),
                sourceHash: String(cString: sourceCStr),
                recordedAt: sqlite3_column_int64(stmt, 6),
                v: Int(sqlite3_column_int64(stmt, 7))
            ))
        }
        return entries
    }

    /// Delete all rows authored by a given device. Used by the "Remove"
    /// action in Settings → Devices — removes the peer *locally* only.
    func deleteRows(forDevice deviceId: String) throws {
        let sql = "DELETE FROM ledger_entries WHERE device_id = ?1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceId, -1, SQLITE_TRANSIENT_DEST)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.step(
                sql: sql,
                code: rc,
                message: String(cString: sqlite3_errmsg(db))
            )
        }

        // Drop any peer-state checkpoint too — next read starts fresh.
        try exec(
            "DELETE FROM peer_state WHERE device_id = "
            + "'" + deviceId.replacingOccurrences(of: "'", with: "''") + "';"
        )
    }

    // MARK: - Peer byte-offset checkpointing

    /// Remember how many bytes of `<deviceId>/ledger.jsonl` we've imported.
    /// Next sync resumes from there so we don't re-parse the whole file.
    func setPeerOffset(deviceId: String, offset: Int64, at date: Date = .now) throws {
        let sql = """
            INSERT INTO peer_state (device_id, byte_offset, updated_at)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(device_id) DO UPDATE SET
                byte_offset = excluded.byte_offset,
                updated_at  = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceId, -1, SQLITE_TRANSIENT_DEST)
        sqlite3_bind_int64(stmt, 2, offset)
        sqlite3_bind_int64(stmt, 3, Int64(date.timeIntervalSince1970))

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.step(
                sql: sql,
                code: rc,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    func peerOffset(deviceId: String) throws -> Int64 {
        let sql = "SELECT byte_offset FROM peer_state WHERE device_id = ?1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceId, -1, SQLITE_TRANSIENT_DEST)
        return sqlite3_step(stmt) == SQLITE_ROW
            ? sqlite3_column_int64(stmt, 0)
            : 0
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        guard rc == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.step(sql: sql, code: rc, message: message)
        }
    }

    private func selectInt(_ sql: String) throws -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(
                sql: sql,
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW
            ? Int(sqlite3_column_int64(stmt, 0))
            : nil
    }
}
