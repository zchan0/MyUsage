import Testing
import Foundation
@testable import MyUsage

@Suite("LedgerWriter Tests")
struct LedgerWriterTests {

    private struct Harness {
        let store: LedgerStore
        let writer: LedgerWriter
        let syncRoot: LocalSyncRoot
        let deviceID: String

        func folder() -> URL {
            SyncLayout.deviceFolder(in: syncRoot.rootURL!, deviceID: deviceID)
        }
        func ledgerFile() -> URL {
            SyncLayout.ledgerFile(in: syncRoot.rootURL!, deviceID: deviceID)
        }
        func manifestFile() -> URL {
            SyncLayout.manifestFile(in: syncRoot.rootURL!, deviceID: deviceID)
        }
    }

    private func makeHarness() throws -> (Harness, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let syncRoot = LocalSyncRoot(url: tmp)
        let store = try LedgerStore(path: LedgerStore.inMemoryPath)
        let deviceID = "test-device-\(UUID().uuidString.prefix(6))"
        let writer = LedgerWriter(
            store: store,
            deviceID: deviceID,
            deviceName: "Test Mac",
            syncRoot: syncRoot
        )
        return (
            Harness(store: store, writer: writer, syncRoot: syncRoot, deviceID: deviceID),
            tmp
        )
    }

    @Test("recordDailyCosts writes JSONL + manifest for new entries")
    func recordDailyCostsExports() async throws {
        let (h, tmp) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let applied = await h.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.23, "2026-04-18": 4.56]
        )
        #expect(applied.count == 2)

        let ledgerData = try Data(contentsOf: h.ledgerFile())
        let lines = String(data: ledgerData, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)

        let manifest = LedgerManifestCodec.read(from: h.manifestFile())
        #expect(manifest != nil)
        #expect(manifest?.deviceId == h.deviceID)
        #expect(manifest?.rowCount == 2)
        #expect(manifest?.monthlyTotals["claude"]?["2026-04"] == 1.23 + 4.56)
    }

    @Test("JSONL append does not duplicate on re-entry with same costs")
    func reEntryIsIdempotent() async throws {
        let (h, tmp) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = await h.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.23]
        )
        #expect(first.count == 1)

        let second = await h.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.23]
        )
        #expect(second.isEmpty)

        let ledgerData = try Data(contentsOf: h.ledgerFile())
        let lines = String(data: ledgerData, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
    }

    @Test("Cost update appends a new line and updates manifest total")
    func costUpdateAppends() async throws {
        let (h, tmp) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = await h.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.00]
        )
        _ = await h.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 2.50]
        )

        let ledgerData = try Data(contentsOf: h.ledgerFile())
        let lines = String(data: ledgerData, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)

        let manifest = LedgerManifestCodec.read(from: h.manifestFile())
        #expect(manifest?.monthlyTotals["claude"]?["2026-04"] == 2.50)
    }

    @Test("Manifest round-trip")
    func manifestCodecRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = LedgerManifest(
            deviceId: "dev-A",
            deviceName: "Zheng's MBP",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rowCount: 42,
            lastEntryAt: Date(timeIntervalSince1970: 1_700_000_500),
            monthlyTotals: ["claude": ["2026-04": 12.34]]
        )
        try LedgerManifestCodec.write(original, to: tmp)

        let roundtrip = LedgerManifestCodec.read(from: tmp)
        #expect(roundtrip == original)
    }
}
