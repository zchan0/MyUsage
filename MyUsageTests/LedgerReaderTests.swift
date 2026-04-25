import Testing
import Foundation
@testable import MyUsage

@Suite("LedgerReader Tests")
struct LedgerReaderTests {

    private struct Setup {
        let root: URL
        let store: LedgerStore
        let reader: LedgerReader
        let syncRoot: LocalSyncRoot
        let selfID: String
    }

    private func makeSetup() throws -> Setup {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let syncRoot = LocalSyncRoot(url: root)
        let store = try LedgerStore(path: LedgerStore.inMemoryPath)
        let selfID = "self-\(UUID().uuidString.prefix(6))"
        let reader = LedgerReader(
            store: store,
            selfDeviceID: selfID,
            syncRoot: syncRoot
        )
        return Setup(root: root, store: store, reader: reader, syncRoot: syncRoot, selfID: selfID)
    }

    private func writeJSONL(
        _ entries: [LedgerEntry],
        to url: URL,
        append: Bool = false
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var buffer = Data()
        for e in entries {
            var line = try encoder.encode(e)
            line.append(0x0A)
            buffer.append(line)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: buffer)
            try handle.close()
        } else {
            try buffer.write(to: url, options: .atomic)
        }
    }

    @Test("importAllPeers imports a peer's JSONL and skips self")
    func importsPeers() async throws {
        let s = try makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let peerID = "peer-A"
        let peerFile = SyncLayout.ledgerFile(in: s.root, deviceID: peerID)
        try writeJSONL([
            LedgerEntry(
                deviceId: peerID,
                provider: .claude,
                day: "2026-04-17",
                costUSD: 1.23,
                recordedAt: Date(timeIntervalSince1970: 1_000_000)
            )
        ], to: peerFile)

        // Self folder: should be skipped.
        let selfFile = SyncLayout.ledgerFile(in: s.root, deviceID: s.selfID)
        try writeJSONL([
            LedgerEntry(
                deviceId: s.selfID,
                provider: .claude,
                day: "2026-04-17",
                costUSD: 99.99,
                recordedAt: Date(timeIntervalSince1970: 1_000_000)
            )
        ], to: selfFile)

        let report = await s.reader.importAllPeers()
        #expect(report.applied == 1)
        #expect(report.peers == [peerID])
        #expect(try s.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1.23)
    }

    @Test("Re-importing same peer is a no-op (offset checkpoint)")
    func offsetCheckpoint() async throws {
        let s = try makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let peerID = "peer-A"
        let peerFile = SyncLayout.ledgerFile(in: s.root, deviceID: peerID)
        try writeJSONL([
            LedgerEntry(
                deviceId: peerID,
                provider: .claude,
                day: "2026-04-17",
                costUSD: 1.00,
                recordedAt: Date(timeIntervalSince1970: 1_000_000)
            )
        ], to: peerFile)

        let first = await s.reader.importAllPeers()
        #expect(first.applied == 1)

        let second = await s.reader.importAllPeers()
        #expect(second.applied == 0)
    }

    @Test("Appended rows are imported on next sweep")
    func appendedRowsImported() async throws {
        let s = try makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let peerID = "peer-A"
        let peerFile = SyncLayout.ledgerFile(in: s.root, deviceID: peerID)

        try writeJSONL([
            LedgerEntry(
                deviceId: peerID,
                provider: .claude,
                day: "2026-04-17",
                costUSD: 1.00,
                recordedAt: Date(timeIntervalSince1970: 1_000_000)
            )
        ], to: peerFile)
        _ = await s.reader.importAllPeers()

        try writeJSONL([
            LedgerEntry(
                deviceId: peerID,
                provider: .codex,
                day: "2026-04-18",
                costUSD: 2.00,
                recordedAt: Date(timeIntervalSince1970: 2_000_000)
            )
        ], to: peerFile, append: true)

        let second = await s.reader.importAllPeers()
        #expect(second.applied == 1)
        #expect(try s.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1.00)
        #expect(try s.store.monthlyTotal(provider: .codex,  monthKey: "2026-04") == 2.00)
    }

    @Test("File shrink triggers a full replay")
    func fileShrinkReplays() async throws {
        let s = try makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let peerID = "peer-A"
        let peerFile = SyncLayout.ledgerFile(in: s.root, deviceID: peerID)

        try writeJSONL([
            LedgerEntry(deviceId: peerID, provider: .claude, day: "2026-04-01", costUSD: 10, recordedAt: Date(timeIntervalSince1970: 1_000_000)),
            LedgerEntry(deviceId: peerID, provider: .claude, day: "2026-04-02", costUSD: 20, recordedAt: Date(timeIntervalSince1970: 1_000_001)),
            LedgerEntry(deviceId: peerID, provider: .claude, day: "2026-04-03", costUSD: 30, recordedAt: Date(timeIntervalSince1970: 1_000_002))
        ], to: peerFile)
        _ = await s.reader.importAllPeers()
        #expect(try s.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 60)

        // Peer reset: shorter file with different data.
        try writeJSONL([
            LedgerEntry(deviceId: peerID, provider: .claude, day: "2026-04-01", costUSD: 1, recordedAt: Date(timeIntervalSince1970: 2_000_000))
        ], to: peerFile)

        _ = await s.reader.importAllPeers()
        #expect(try s.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 1)
    }

    @Test("Partial trailing line is NOT consumed")
    func partialTrailingLineHeld() async {
        let s = try! makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let complete = try! encoder.encode(
            LedgerEntry(deviceId: "p", provider: .claude, day: "2026-04-01",
                        costUSD: 1, recordedAt: Date(timeIntervalSince1970: 1))
        )
        var buffer = complete
        buffer.append(0x0A)
        let partial = try! encoder.encode(
            LedgerEntry(deviceId: "p", provider: .claude, day: "2026-04-02",
                        costUSD: 2, recordedAt: Date(timeIntervalSince1970: 2))
        )
        buffer.append(partial.dropLast())  // Truncated and no trailing LF.

        let (entries, consumed) = await s.reader.parseJSONL(data: buffer)
        #expect(entries.count == 1)
        #expect(consumed == complete.count + 1)
    }

    @Test("Valid final line without LF is consumed")
    func finalLineWithoutNewlineConsumed() async {
        let s = try! makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let complete = try! encoder.encode(
            LedgerEntry(deviceId: "p", provider: .claude, day: "2026-04-01",
                        costUSD: 1, recordedAt: Date(timeIntervalSince1970: 1))
        )

        let (entries, consumed) = await s.reader.parseJSONL(data: complete)
        #expect(entries.count == 1)
        #expect(consumed == complete.count)
    }

    @Test("Peer file without final LF imports")
    func importsFileWithoutFinalNewline() async throws {
        let s = try makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let peerID = "peer-A"
        let peerFile = SyncLayout.ledgerFile(in: s.root, deviceID: peerID)
        try FileManager.default.createDirectory(
            at: peerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let raw = """
        {"accountId":"default","costUSD":3.21,"day":"2026-04-17","deviceId":"peer-A","provider":"claude","recordedAt":1000000,"sourceHash":"2026-04-17","v":1}
        """.data(using: .utf8)!
        try raw.write(to: peerFile, options: .atomic)

        let report = await s.reader.importAllPeers()
        #expect(report.applied == 1)
        #expect(try s.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 3.21)
    }

    @Test("Unknown wire-version rows are skipped")
    func unknownWireVersionSkipped() async throws {
        let s = try makeSetup()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let peerID = "peer-A"
        let peerFile = SyncLayout.ledgerFile(in: s.root, deviceID: peerID)

        try FileManager.default.createDirectory(
            at: peerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Build a line with v=999 manually.
        let raw = """
        {"accountId":"default","costUSD":99,"day":"2026-04-17","deviceId":"peer-A","provider":"claude","recordedAt":1000000,"sourceHash":"2026-04-17","v":999}
        """.data(using: .utf8)!
        var buffer = raw
        buffer.append(0x0A)
        try buffer.write(to: peerFile, options: .atomic)

        let report = await s.reader.importAllPeers()
        #expect(report.applied == 0)
        #expect(try s.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 0)
    }
}
