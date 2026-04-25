import Testing
import Foundation
@testable import MyUsage

/// End-to-end coverage for the multi-device sync contract:
/// "two LedgerWriters pointed at the same sync folder, each owning a
/// distinct device folder, must aggregate correctly without ever
/// touching each other's files."
///
/// Single-component tests (LedgerStore / LedgerWriter / LedgerReader) cover
/// each piece in isolation. This suite wires them together with a shared
/// `LocalSyncRoot` so the actual cross-device flows have a regression net.
@Suite("Ledger sync integration")
struct LedgerSyncIntegrationTests {

    /// One device's full pipeline (SQLite + writer + reader) pointed at a
    /// shared sync folder.
    private struct Device {
        let id: String
        let name: String
        let store: LedgerStore
        let writer: LedgerWriter
        let reader: LedgerReader

        static func make(id: String, name: String, syncRoot: SyncRoot) throws -> Device {
            let store = try LedgerStore(path: LedgerStore.inMemoryPath)
            return Device(
                id: id,
                name: name,
                store: store,
                writer: LedgerWriter(
                    store: store,
                    deviceID: id,
                    deviceName: name,
                    syncRoot: syncRoot
                ),
                reader: LedgerReader(
                    store: store,
                    selfDeviceID: id,
                    syncRoot: syncRoot
                )
            )
        }
    }

    /// Spin up `n` devices wired to the same fresh on-disk sync folder.
    /// Returns the devices plus the temp folder so tests can clean up.
    private func makeDevices(_ n: Int) throws -> (devices: [Device], tmp: URL, syncRoot: LocalSyncRoot) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let syncRoot = LocalSyncRoot(url: tmp)

        let devices = try (0..<n).map { i in
            try Device.make(
                id: "device-\(i)-\(UUID().uuidString.prefix(6))",
                name: "Mac \(i)",
                syncRoot: syncRoot
            )
        }
        return (devices, tmp, syncRoot)
    }

    private func deviceFolders(in tmp: URL) -> [String] {
        let devicesRoot = SyncLayout.devicesFolder(in: tmp)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: devicesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.map { $0.lastPathComponent }.sorted()
    }

    // MARK: - Cross-device propagation

    @Test("Device A's writes are visible to Device B after publish + import")
    func aWritesPropagateToB() async throws {
        let (devs, tmp, _) = try makeDevices(2)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = devs[0]
        let b = devs[1]

        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.25, "2026-04-18": 2.75]
        )

        let report = await b.reader.importAllPeers()
        #expect(report.peers.contains(a.id))
        #expect(report.applied == 2)

        let aTotalSeenByB = try b.store.monthlyTotal(provider: .claude, monthKey: "2026-04")
        #expect(aTotalSeenByB == 4.0)
    }

    @Test("Both devices' totals aggregate on each side after a sync round-trip")
    func aggregateAcrossDevices() async throws {
        let (devs, tmp, _) = try makeDevices(2)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = devs[0]
        let b = devs[1]

        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 10.0]
        )
        await b.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 3.0]
        )

        _ = await a.reader.importAllPeers()
        _ = await b.reader.importAllPeers()

        let aTotal = try a.store.monthlyTotal(provider: .claude, monthKey: "2026-04")
        let bTotal = try b.store.monthlyTotal(provider: .claude, monthKey: "2026-04")
        #expect(aTotal == 13.0)
        #expect(bTotal == 13.0)

        let aByDevice = try a.store.monthlyTotalsByDevice(provider: .claude, monthKey: "2026-04")
        #expect(aByDevice.count == 2)
        #expect(aByDevice.first { $0.deviceId == a.id }?.costUSD == 10.0)
        #expect(aByDevice.first { $0.deviceId == b.id }?.costUSD == 3.0)
    }

    @Test("Latest-wins: republishing with a newer recordedAt updates peers")
    func latestWinsAcrossDevices() async throws {
        let (devs, tmp, _) = try makeDevices(2)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = devs[0]
        let b = devs[1]

        let day = "2026-04-17"
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_001_000)

        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: [day: 5.0],
            now: early
        )
        _ = await b.reader.importAllPeers()
        #expect(try b.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 5.0)

        // A revises the same day with a later recordedAt; publishSnapshot
        // rewrites JSONL from SQLite truth.
        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: [day: 7.5],
            now: later
        )
        _ = await a.writer.publishSnapshot()

        // Reset B's cursor on A so it re-reads the rewritten file.
        try b.store.deleteRows(forDevice: a.id)
        _ = await b.reader.importAllPeers()

        #expect(try b.store.monthlyTotal(provider: .claude, monthKey: "2026-04") == 7.5)
    }

    // MARK: - Single-writer invariant

    @Test("Reader never touches files in its own device folder")
    func readerSkipsSelfFolder() async throws {
        let (devs, tmp, _) = try makeDevices(2)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = devs[0]
        let b = devs[1]

        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.0]
        )

        // B has not written anything yet, so its folder shouldn't exist.
        let bFolder = SyncLayout.deviceFolder(in: tmp, deviceID: b.id)
        #expect(!FileManager.default.fileExists(atPath: bFolder.path))

        // After B imports peers, B's folder still shouldn't exist — readers
        // are strictly read-only against peer folders and never create their
        // own folder as a side effect.
        _ = await b.reader.importAllPeers()
        #expect(!FileManager.default.fileExists(atPath: bFolder.path))
    }

    @Test("publishSnapshot rewrites JSONL from SQLite source of truth")
    func publishSnapshotHealsMissingFile() async throws {
        let (devs, tmp, _) = try makeDevices(1)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = devs[0]

        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 9.0]
        )

        // Simulate the sync folder going stale: nuke A's JSONL on disk while
        // SQLite still holds the truth.
        let file = SyncLayout.ledgerFile(in: tmp, deviceID: a.id)
        try FileManager.default.removeItem(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        _ = await a.writer.publishSnapshot()
        #expect(FileManager.default.fileExists(atPath: file.path))

        let restored = try Data(contentsOf: file)
        let lines = String(data: restored, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
    }

    // MARK: - Reinstall regression — the bug that motivated spec 14

    @Test("Reinstalling on the same hardware does not create a duplicate device folder")
    func reinstallDoesNotDuplicate() async throws {
        let (devs, tmp, syncRoot) = try makeDevices(2)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = devs[0]
        let b = devs[1]

        await a.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 4.0]
        )
        await b.writer.recordDailyCosts(
            provider: .claude,
            dailyCostsByDay: ["2026-04-17": 1.0]
        )

        let foldersAfterFirstInstall = deviceFolders(in: tmp)
        #expect(foldersAfterFirstInstall.count == 2)
        #expect(Set(foldersAfterFirstInstall) == Set([a.id, b.id]))

        // Simulate process restart on A (reinstall): same deviceID, same on-
        // disk SQLite store (Application Support is untouched by an app
        // reinstall), but a fresh writer instance. The spec-14 fix guarantees
        // the hardware-derived deviceID is stable across preferences wipes,
        // so the new writer must reuse A's existing folder rather than mint
        // a new one.
        let aWriterReborn = LedgerWriter(
            store: a.store,
            deviceID: a.id,
            deviceName: a.name,
            syncRoot: syncRoot
        )
        _ = await aWriterReborn.publishSnapshot()

        let foldersAfterReinstall = deviceFolders(in: tmp)
        #expect(foldersAfterReinstall.count == 2,
                "reinstall must not orphan A's old folder under a fresh ID")
        #expect(Set(foldersAfterReinstall) == Set([a.id, b.id]))

        // B re-imports and still sees exactly two contributors, not three.
        _ = await b.reader.importAllPeers()
        let contributors = try b.store.monthlyTotalsByDevice(
            provider: .claude,
            monthKey: "2026-04"
        )
        #expect(contributors.map(\.deviceId).sorted() == [a.id, b.id].sorted())
    }
}
