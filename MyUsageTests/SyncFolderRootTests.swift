import Testing
import Foundation
@testable import MyUsage

@Suite("SyncFolderRoot Tests")
struct SyncFolderRootTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "SyncFolderRootTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    private func makeRoot(
        defaults: UserDefaults,
        homeDirectory: URL,
        iCloudAvailable: Bool = false
    ) -> SyncFolderRoot {
        SyncFolderRoot(
            defaults: defaults,
            fileManager: .default,
            homeDirectory: homeDirectory,
            isICloudDriveAvailable: { iCloudAvailable }
        )
    }

    @Test("Bookmark round-trip resolves the same folder")
    func bookmarkRoundTrip() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folder = tmp.appendingPathComponent("MyUsage", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let root = makeRoot(defaults: defaults, homeDirectory: tmp)
        try root.setBaseURL(folder)

        let snapshot = root.snapshot()
        #expect(snapshot.isConfigured)
        #expect(snapshot.baseURL?.standardizedFileURL.path
             == folder.standardizedFileURL.path)
        #expect(snapshot.isAvailable)
        #expect(snapshot.state == .available)
        #expect(root.rootURL?.standardizedFileURL.path
             == folder.standardizedFileURL.path)
    }

    @Test("Legacy iCloud tree is auto-migrated on first launch")
    func migrateLegacyICloudPath() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = makeRoot(defaults: defaults, homeDirectory: tmp, iCloudAvailable: true)
        let legacyBase = SyncFolderRoot.legacyICloudBaseURL(homeDirectory: tmp)
        let peerFolder = SyncLayout.deviceFolder(in: legacyBase, deviceID: "peer-A")
        try FileManager.default.createDirectory(at: peerFolder, withIntermediateDirectories: true)

        root.migrateLegacyIfNeeded()

        let snapshot = root.snapshot()
        #expect(snapshot.baseURL?.standardizedFileURL.path
             == legacyBase.standardizedFileURL.path)
        #expect(snapshot.isAvailable)
        #expect(snapshot.state == .available)
    }

    @Test("Availability follows folder existence")
    func availabilityTracksMissingFolder() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folder = tmp.appendingPathComponent("SharedLedger", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let root = makeRoot(defaults: defaults, homeDirectory: tmp)
        try root.setBaseURL(folder)
        #expect(root.snapshot().isAvailable)

        try FileManager.default.removeItem(at: folder)

        let snapshot = root.snapshot()
        #expect(snapshot.isConfigured)
        #expect(snapshot.pathHint == folder.path)
        #expect(!snapshot.isAvailable)
        #expect(snapshot.state == .unavailable)
    }

    @Test("Broken bookmark with an existing path shows not found")
    func brokenBookmarkShowsNotFound() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-broken-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folder = tmp.appendingPathComponent("SharedLedger", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        defaults.set(Data("not-a-bookmark".utf8), forKey: SyncFolderRoot.bookmarkKey)
        defaults.set(folder.path, forKey: SyncFolderRoot.pathHintKey)

        let root = makeRoot(defaults: defaults, homeDirectory: tmp)
        let snapshot = root.snapshot()
        #expect(snapshot.isConfigured)
        #expect(snapshot.state == .notFound)
        #expect(!snapshot.isAvailable)
    }
}
