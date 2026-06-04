import Testing
import Foundation
@testable import MyUsage

@Suite("LedgerStore Tests")
struct LedgerStoreTests {

    private func makeStore() throws -> LedgerStore {
        try LedgerStore(path: LedgerStore.inMemoryPath)
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
}
