import AppKit
import Darwin
import Foundation
import os

/// Top-level orchestrator exposed to the rest of the app. Owns the
/// SQLite store + writer + reader, drives the peer watcher, and publishes
/// current aggregates via `@Observable`.
///
/// Life-cycle: one instance per `UsageManager`. Call `start()` during
/// app launch to kick off the first peer import + begin watching the
/// configured sync folder.
@Observable
@MainActor
final class LedgerSync {

    // MARK: - Published state

    /// `YYYY-MM` → provider → USD (all devices combined). The UI reads
    /// this to decide whether to show the aggregate monthly cost + ⊕ badge.
    private(set) var monthlyTotals: [String: [ProviderKind: Double]] = [:]

    /// `YYYY-MM` → provider → [DeviceContribution] for the popover.
    private(set) var monthlyByDevice: [String: [ProviderKind: [DeviceContribution]]] = [:]

    /// The current device's UUID — "Mine" in UI rows.
    let selfDeviceID: String

    /// Last successful peer sweep (or launch, if none yet). Drives the
    /// "Last synced" label in Settings → Devices.
    private(set) var lastSyncedAt: Date?

    /// Last time we observed the sync folder change locally or via a peer.
    /// Drives the "last change" note in Settings → General.
    private(set) var lastFolderChangeAt: Date?

    private(set) var syncFolderDisplayPath = "—"
    private(set) var syncFolderStatusText =
        "Choose a shared folder. iCloud Drive, Syncthing, Dropbox, and NAS shares all work."
    private(set) var syncFolderStatusKind: SyncFolderStatusKind = .idle
    private var lastWriteIssue: LedgerWriter.SyncWriteIssue?

    enum SyncFolderStatusKind: Sendable {
        case idle
        case available
        case warning
        case error
    }

    struct DeviceContribution: Sendable, Equatable, Identifiable {
        let deviceId: String
        let displayName: String
        let costUSD: Double
        var id: String { deviceId }

        /// True when this row represents the current Mac.
        let isSelf: Bool
    }

    // MARK: - Dependencies

    let store: LedgerStore
    let writer: LedgerWriter
    private let reader: LedgerReader
    private let syncRoot: SyncRoot
    private let configuredSyncRoot: SyncFolderRoot?
    private var peerNames: [String: String] = [:]
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var watcherDebounceTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Init

    /// Default init: production store + bookmark-backed sync folder root.
    convenience init() {
        let store: LedgerStore
        do {
            store = try LedgerStore(url: LedgerSync.defaultDatabaseURL)
        } catch {
            Logger.ledger.error(
                "Ledger DB open failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)"
            )
            store = (try? LedgerStore(path: LedgerStore.inMemoryPath))!
        }
        self.init(store: store, syncRoot: SyncFolderRoot())
    }

    init(store: LedgerStore, syncRoot: SyncRoot) {
        self.store = store
        self.syncRoot = syncRoot
        self.configuredSyncRoot = syncRoot as? SyncFolderRoot
        self.selfDeviceID = DeviceIdentity.currentID()
        self.writer = LedgerWriter(
            store: store,
            deviceID: selfDeviceID,
            deviceName: DeviceIdentity.displayName(),
            syncRoot: syncRoot
        )
        self.reader = LedgerReader(
            store: store,
            selfDeviceID: selfDeviceID,
            syncRoot: syncRoot
        )
    }

    // No `deinit` cleanup: `LedgerSync` is owned by `UsageManager` and
    // lives for the full process lifetime. Tests that need explicit teardown
    // can call `stopWatching()`.

    // MARK: - Default DB location

    static let defaultDatabaseURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("MyUsage", isDirectory: true)
            .appendingPathComponent("ledger.sqlite3")
    }()

    // MARK: - Public API

    /// Kick off an initial peer import + refresh state, then start the
    /// sync-folder watcher. Safe to call multiple times.
    func start() async {
        configuredSyncRoot?.migrateLegacyIfNeeded()
        lastWriteIssue = nil
        reloadSyncFolderState()
        await refresh()
        restartWatching()
    }

    /// Stops file watchers, polling, and wake observers. Intended for tests.
    func stopWatching() {
        watcherDebounceTask?.cancel()
        watcherDebounceTask = nil

        pollingTask?.cancel()
        pollingTask = nil

        folderWatcher?.cancel()
        folderWatcher = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Re-import peers and recompute published totals. Called on launch,
    /// after a writer commits rows, and from the folder watcher / poller.
    func refresh() async {
        if syncRoot.isAvailable {
            let report = await reader.importAllPeers()
            lastSyncedAt = .now
            if report.applied > 0 {
                lastFolderChangeAt = .now
                Logger.ledger.info(
                    "Imported \(report.applied) ledger rows from \(report.peers.count) peers"
                )
            }
            reloadManifestNames()
        }
        reloadAggregates()
        reloadSyncFolderState()
    }

    /// Record the current device's daily costs for a provider. Thin wrapper
    /// that refreshes published aggregates after a successful write.
    func recordDailyCosts(
        provider: ProviderKind,
        byDay: [String: Double]
    ) async {
        let result = await writer.recordDailyCosts(
            provider: provider,
            dailyCostsByDay: byDay
        )
        lastWriteIssue = result.issue
        guard !result.applied.isEmpty else {
            reloadSyncFolderState()
            return
        }
        lastFolderChangeAt = .now
        reloadAggregates()
        reloadSyncFolderState()
    }

    /// Fetch aggregated contributions for a provider in the given month —
    /// used by the popover when the user clicks the ⊕ badge.
    func contributions(
        provider: ProviderKind,
        monthKey: String
    ) -> [DeviceContribution] {
        monthlyByDevice[monthKey]?[provider] ?? []
    }

    /// Forget a peer device locally — drops its rows from SQLite and
    /// stops counting its contributions. The remote file is left alone
    /// (not ours to touch).
    func forgetPeer(deviceID: String) {
        guard deviceID != selfDeviceID else { return }
        do {
            try store.deleteRows(forDevice: deviceID)
        } catch {
            Logger.ledger.error(
                "Forget peer failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        peerNames.removeValue(forKey: deviceID)
        reloadAggregates()
    }

    var canRevealSyncFolder: Bool {
        configuredSyncRoot?.snapshot().baseURL != nil
    }

    func chooseSyncFolder() async {
        guard let configuredSyncRoot else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = configuredSyncRoot.currentOrSuggestedBaseURL()
        panel.prompt = "Choose"
        panel.message = "Pick a folder shared across the Macs you want to aggregate."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try configuredSyncRoot.setBaseURL(url)
            lastFolderChangeAt = nil
            lastWriteIssue = nil
            reloadSyncFolderState()
            restartWatching()
            await refresh()
        } catch {
            Logger.ledger.error(
                "Sync folder bookmark save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func revealSyncFolderInFinder() {
        guard let baseURL = configuredSyncRoot?.snapshot().baseURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([baseURL])
    }

    /// Resolve a device ID to a human-readable name — self first, then
    /// any peer manifest we've read, else a truncated UUID.
    func displayName(for deviceID: String) -> String {
        if deviceID == selfDeviceID {
            return DeviceIdentity.displayName()
        }
        if let fromManifest = peerNames[deviceID] {
            return fromManifest
        }
        return "Device \(deviceID.prefix(6))"
    }

    // MARK: - Aggregates

    private func reloadAggregates() {
        let now = Date.now
        let monthKey = LedgerCalendar.monthKey(for: now)

        var totals: [ProviderKind: Double] = [:]
        var byDevice: [ProviderKind: [DeviceContribution]] = [:]

        for provider in [ProviderKind.claude, .codex] {
            let sum = (try? store.monthlyTotal(
                provider: provider,
                monthKey: monthKey
            )) ?? 0
            totals[provider] = sum

            let devTotals = (try? store.monthlyTotalsByDevice(
                provider: provider,
                monthKey: monthKey
            )) ?? []

            byDevice[provider] = devTotals.map { row in
                DeviceContribution(
                    deviceId: row.deviceId,
                    displayName: displayName(for: row.deviceId),
                    costUSD: row.costUSD,
                    isSelf: row.deviceId == selfDeviceID
                )
            }
        }

        monthlyTotals[monthKey] = totals
        monthlyByDevice[monthKey] = byDevice
    }

    // MARK: - Peer manifest names

    private func reloadManifestNames() {
        guard syncRoot.isAvailable, let root = syncRoot.rootURL else { return }
        let devicesFolder = SyncLayout.devicesFolder(in: root)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: devicesFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var names: [String: String] = [:]
        for folder in folders {
            let id = folder.lastPathComponent
            guard id != selfDeviceID else { continue }
            let manifestURL = folder.appendingPathComponent(SyncLayout.manifestFilename)
            if let m = LedgerManifestCodec.read(from: manifestURL) {
                names[id] = m.deviceName
            }
        }
        peerNames = names
    }

    // MARK: - Sync-folder watching

    private func restartWatching() {
        stopWatching()
        startPolling()
        startFolderWatcher()
        installWakeObserver()
    }

    private func startFolderWatcher() {
        guard syncRoot.isAvailable, let root = syncRoot.rootURL else { return }
        let devicesFolder = SyncLayout.devicesFolder(in: root)

        do {
            try FileManager.default.createDirectory(
                at: devicesFolder,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            Logger.ledger.error(
                "Sync folder watch setup failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let fd = open(devicesFolder.path, O_EVTONLY)
        guard fd >= 0 else {
            Logger.ledger.error(
                "Sync folder watch open failed for \(devicesFolder.path, privacy: .private)"
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        folderWatcher = source
    }

    private func startPolling() {
        let interval = configuredSyncRoot?.pollInterval() ?? SyncFolderRoot.defaultPollInterval
        guard interval > 0 else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleWake()
            }
        }
    }

    private func scheduleDebouncedRefresh() async {
        watcherDebounceTask?.cancel()
        watcherDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.handleObservedFolderChange()
        }
    }

    private func handleObservedFolderChange() async {
        lastFolderChangeAt = .now
        await refresh()
    }

    private func handleWake() async {
        restartWatching()
        await refresh()
    }

    private func reloadSyncFolderState() {
        guard let configuredSyncRoot else { return }

        let snapshot = configuredSyncRoot.snapshot()
        syncFolderDisplayPath = snapshot.baseURL.map { abbreviate($0.path) }
            ?? snapshot.pathHint.map(abbreviate(_:))
            ?? "—"

        switch snapshot.state {
        case .idle:
            syncFolderStatusKind = .idle
            syncFolderStatusText =
                "Choose a shared folder. iCloud Drive, Syncthing, Dropbox, and NAS shares all work."
        case .available:
            if case .failed(let message) = lastWriteIssue {
                syncFolderStatusKind = .warning
                syncFolderStatusText = "Last write failed. Retrying on the next refresh. (\(message))"
                return
            }
            if case .readOnly = lastWriteIssue { lastWriteIssue = nil }
            if case .unavailable = lastWriteIssue { lastWriteIssue = nil }
            syncFolderStatusKind = .available
            let changeDetection = changeDetectionDescription(
                pollInterval: configuredSyncRoot.pollInterval()
            )
            if let lastFolderChangeAt {
                let relative = RelativeDateTimeFormatter().localizedString(
                    for: lastFolderChangeAt,
                    relativeTo: .now
                )
                syncFolderStatusText = "\(changeDetection) · last change \(relative)"
            } else {
                syncFolderStatusText = changeDetection
            }
        case .readOnly:
            syncFolderStatusKind = .warning
            syncFolderStatusText =
                "Sync folder is read-only. This Mac can import peer data but cannot publish new ledger entries."
        case .unavailable:
            syncFolderStatusKind = .warning
            syncFolderStatusText = "Sync folder unavailable. Check that it exists and is readable."
        case .notFound:
            syncFolderStatusKind = .error
            syncFolderStatusText = "Sync folder not found. Pick it again."
        }
    }

    private func changeDetectionDescription(pollInterval: TimeInterval) -> String {
        if pollInterval == 0 {
            return "File-system events only"
        }
        return "File-system events + \(Int(pollInterval))s polling"
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
