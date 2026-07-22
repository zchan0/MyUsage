import Testing
import Foundation
import SQLite3
@testable import MyUsage

@Suite("LedgerStore Tests")
struct LedgerStoreTests {

    private func makeStore() throws -> LedgerStore {
        try LedgerStore(path: LedgerStore.inMemoryPath)
    }

    @Test("Opening a v2 database adds token_usage without losing rows")
    func migratesV2TokenColumn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-v2-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE schema_meta (version INTEGER NOT NULL);
        INSERT INTO schema_meta (version) VALUES (2);
        CREATE TABLE ledger_entries (
          device_id TEXT NOT NULL, account_id TEXT NOT NULL, provider TEXT NOT NULL,
          day TEXT NOT NULL, cost_usd REAL NOT NULL, cost_by_model TEXT,
          source_hash TEXT NOT NULL, schema_ver INTEGER NOT NULL DEFAULT 1,
          recorded_at INTEGER NOT NULL,
          PRIMARY KEY (device_id, account_id, provider, source_hash)
        );
        INSERT INTO ledger_entries VALUES
          ('old','default','claude','2026-04-01',1.0,NULL,'2026-04-01',2,1000);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let store = try LedgerStore(path: url.path)
        let updated = LedgerEntry(
            deviceId: "old", provider: .claude, day: "2026-04-01", costUSD: 1,
            tokenUsage: TokenUsage(input: 42),
            recordedAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(try store.upsert([updated]).count == 1)
        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1)
        #expect(try store.tokenUsage(provider: .claude, fromDay: "2026-04-01")
            == TokenUsage(input: 42))
    }

    @Test("Upsert inserts new rows and reports them as applied")
    func upsertInsertsNew() throws {
        let store = try makeStore()
        let entries = [
            LedgerEntry(
                deviceId: "dev-A",
                provider: .claude,
                day: "2026-04-17",
                costUSD: 1.23,
                recordedAt: Date(timeIntervalSince1970: 1_000_000)
            )
        ]
        let applied = try store.upsert(entries)
        #expect(applied.count == 1)
        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1.23)
    }

    @Test("Upsert is idempotent when costs are unchanged")
    func upsertIdempotent() throws {
        let store = try makeStore()
        let entry = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 1.00,
            recordedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = try store.upsert([entry])
        let second = try store.upsert([entry])
        #expect(second.isEmpty)
        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1.00)
    }

    @Test("Upsert replaces when cost differs")
    func upsertReplacesDifferentCost() throws {
        let store = try makeStore()
        let first = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 1.00,
            recordedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = try store.upsert([first])

        let replacement = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 2.50,
            recordedAt: Date(timeIntervalSince1970: 1_000_100)
        )
        let applied = try store.upsert([replacement])

        #expect(applied.count == 1)
        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 2.50)
    }

    @Test("Upsert keeps newer row when older arrives second")
    func upsertOlderRowLoses() throws {
        let store = try makeStore()
        let newer = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 5.00,
            recordedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        _ = try store.upsert([newer])

        let older = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 1.00,
            recordedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let applied = try store.upsert([older])
        #expect(applied.isEmpty)
        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 5.00)
    }

    @Test("monthlyTotal sums across devices and days")
    func monthlyTotalAcrossDevices() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-02", costUSD: 2, recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-02", costUSD: 3, recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .codex,  day: "2026-04-02", costUSD: 10, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-03-31", costUSD: 99, recordedAt: now)
        ])

        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 6)
        #expect(try store.monthlyTotal(provider: .codex,  monthKey: "2026-04") == 10)
        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-03") == 99)
    }

    @Test("monthlyTotalsByDevice returns one row per device sorted by cost")
    func monthlyTotalsByDevice() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-02", costUSD: 2, recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-02", costUSD: 10, recordedAt: now)
        ])

        let totals = try store.monthlyTotalsByDevice(provider: .claude, monthKey: "2026-04")
        #expect(totals.count == 2)
        #expect(totals[0].deviceId == "B")
        #expect(totals[0].costUSD == 10)
        #expect(totals[1].deviceId == "A")
        #expect(totals[1].costUSD == 3)
    }

    @Test("deleteRows removes only the target device's rows and resets peer_state")
    func deleteRowsForDevice() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-01", costUSD: 5, recordedAt: now)
        ])
        try store.setPeerOffset(deviceId: "B", offset: 100)

        try store.deleteRows(forDevice: "B")

        #expect(try store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1)
        #expect(try store.peerOffset(deviceId: "B") == 0)
    }

    @Test("peer offset round-trip")
    func peerOffsetRoundTrip() throws {
        let store = try makeStore()
        #expect(try store.peerOffset(deviceId: "X") == 0)
        try store.setPeerOffset(deviceId: "X", offset: 4096)
        #expect(try store.peerOffset(deviceId: "X") == 4096)
        try store.setPeerOffset(deviceId: "X", offset: 8192)
        #expect(try store.peerOffset(deviceId: "X") == 8192)
    }

    @Test("manifestMeta reports row count + last entry date")
    func manifestMeta() throws {
        let store = try makeStore()
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: t1),
            LedgerEntry(deviceId: "A", provider: .codex,  day: "2026-04-02", costUSD: 2, recordedAt: t2),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-02", costUSD: 9, recordedAt: t2)
        ])

        let meta = try store.manifestMeta(deviceID: "A")
        #expect(meta.rowCount == 2)
        #expect(meta.lastEntryAt.map { $0.timeIntervalSince1970 } == 2_000_000)
    }

    @Test("monthlyTotalsForManifest includes only the target device")
    func monthlyTotalsForManifest() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .codex,  day: "2026-04-02", costUSD: 2, recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-02", costUSD: 9, recordedAt: now)
        ])

        let totals = try store.monthlyTotalsForManifest(deviceID: "A", monthKey: "2026-04")
        #expect(totals["claude"]?["2026-04"] == 1)
        #expect(totals["codex"]?["2026-04"] == 2)
        #expect(totals.count == 2)
    }

    @Test("entriesForDevice returns stable latest rows for snapshot publishing")
    func entriesForDevice() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .codex, day: "2026-04-02", costUSD: 2, recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-01", costUSD: 9, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: now)
        ])

        let entries = try store.entries(forDevice: "A")
        #expect(entries.map(\.provider) == ["claude", "codex"])
        #expect(entries.map(\.day) == ["2026-04-01", "2026-04-02"])
        #expect(entries.map(\.costUSD) == [1, 2])
    }

    // MARK: - dailyCosts (chart query)

    @Test("dailyCosts aggregates across devices per day, sorted ascending")
    func dailyCostsAggregates() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-02", costUSD: 1.5,
                        costByModel: ["Opus": 1.0, "Sonnet": 0.5], recordedAt: now),
            LedgerEntry(deviceId: "B", provider: .claude, day: "2026-04-02", costUSD: 2.0,
                        costByModel: ["Opus": 2.0], recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 3.0,
                        costByModel: ["Sonnet": 3.0], recordedAt: now)
        ])

        let days = try store.dailyCosts(provider: .claude, fromDay: "2026-04-01")
        #expect(days.map(\.day) == ["2026-04-01", "2026-04-02"])
        #expect(days[0].totalUSD == 3.0)
        #expect(days[1].totalUSD == 3.5)
        #expect(days[1].byModel == ["Opus": 3.0, "Sonnet": 0.5])
    }

    @Test("dailyCosts respects fromDay cutoff and provider filter")
    func dailyCostsCutoff() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-03-31", costUSD: 9, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: now),
            LedgerEntry(deviceId: "A", provider: .codex,  day: "2026-04-01", costUSD: 7, recordedAt: now)
        ])

        let days = try store.dailyCosts(provider: .claude, fromDay: "2026-04-01")
        #expect(days.map(\.day) == ["2026-04-01"])
        #expect(days[0].totalUSD == 1)
    }

    @Test("dailyCosts keeps totals for rows without model breakdown")
    func dailyCostsUnattributed() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 4.0,
                        recordedAt: now)
        ])

        let days = try store.dailyCosts(provider: .claude, fromDay: "2026-04-01")
        #expect(days[0].totalUSD == 4.0)
        #expect(days[0].byModel.isEmpty)
    }

    @Test("tokenUsage aggregates v3 buckets across devices and ignores older rows")
    func tokenUsageAggregates() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.upsert([
            LedgerEntry(
                deviceId: "A", provider: .claude, day: "2026-04-01", costUSD: 1,
                tokenUsage: TokenUsage(input: 10, output: 2, cacheRead: 30), recordedAt: now
            ),
            LedgerEntry(
                deviceId: "B", provider: .claude, day: "2026-04-02", costUSD: 2,
                tokenUsage: TokenUsage(input: 20, output: 3, cacheWrite: 4), recordedAt: now
            ),
            LedgerEntry(deviceId: "legacy", provider: .claude, day: "2026-04-02", costUSD: 3, recordedAt: now),
            LedgerEntry(
                deviceId: "C", provider: .codex, day: "2026-04-02", costUSD: 4,
                tokenUsage: TokenUsage(input: 999), recordedAt: now
            ),
        ])

        let usage = try store.tokenUsage(provider: .claude, fromDay: "2026-04-01")
        #expect(usage == TokenUsage(input: 30, output: 5, cacheWrite: 4, cacheRead: 30))
        #expect(try store.tokenUsage(provider: .claude, fromDay: "2026-05-01") == nil)
    }

    @Test("token-only change replaces an otherwise identical ledger row")
    func tokenChangeReplacesRow() throws {
        let store = try makeStore()
        let first = LedgerEntry(
            deviceId: "A", provider: .codex, day: "2026-04-01", costUSD: 1,
            tokenUsage: TokenUsage(input: 10),
            recordedAt: Date(timeIntervalSince1970: 1_000)
        )
        let replacement = LedgerEntry(
            deviceId: "A", provider: .codex, day: "2026-04-01", costUSD: 1,
            tokenUsage: TokenUsage(input: 25, cachedInput: 50),
            recordedAt: Date(timeIntervalSince1970: 2_000)
        )

        _ = try store.upsert([first])
        #expect(try store.upsert([replacement]).count == 1)
        #expect(try store.tokenUsage(provider: .codex, fromDay: "2026-04-01")
            == TokenUsage(input: 25, cachedInput: 50))
    }
}
