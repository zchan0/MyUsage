import Foundation
import os

/// Top-level orchestrator exposed to the rest of the app. Owns the
/// SQLite store + writer + reader, drives the peer watcher, and publishes
/// current aggregates via `@Observable`.
///
/// Life-cycle: one instance per `UsageManager`. Call `start()` during
/// app launch to kick off the first peer import + begin watching iCloud.
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

    private var metadataQuery: NSMetadataQuery?
    private var peerNames: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    /// Default init: production store + ubiquity sync root.
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
        self.init(store: store, syncRoot: UbiquitySyncRoot())
    }

    init(store: LedgerStore, syncRoot: SyncRoot) {
        self.store = store
        self.syncRoot = syncRoot
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
    // lives for the full process lifetime. Tests that need to tear down
    // the metadata query can call `stopWatching()` explicitly.

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
    /// iCloud watcher. Safe to call multiple times.
    func start() async {
        await refresh()
        startMetadataQuery()
    }

    /// Stops the `NSMetadataQuery` and releases observers. Intended for
    /// tests — the production singleton lives for the full app lifetime.
    func stopWatching() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        metadataQuery?.stop()
        metadataQuery = nil
    }

    /// Re-import peers and recompute published totals. Called on launch,
    /// after a writer commits rows, and from the metadata watcher.
    func refresh() async {
        let report = await reader.importAllPeers()
        lastSyncedAt = .now
        if report.applied > 0 {
            Logger.ledger.info(
                "Imported \(report.applied) ledger rows from \(report.peers.count) peers"
            )
        }
        reloadManifestNames()
        reloadAggregates()
    }

    /// Record the current device's daily costs for a provider. Thin wrapper
    /// that refreshes published aggregates after a successful write.
    func recordDailyCosts(
        provider: ProviderKind,
        byDay: [String: Double]
    ) async {
        let applied = await writer.recordDailyCosts(
            provider: provider,
            dailyCostsByDay: byDay
        )
        guard !applied.isEmpty else { return }
        reloadAggregates()
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
    /// stops counting its contributions. The iCloud file is left alone
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
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root,
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

    // MARK: - NSMetadataQuery

    private func startMetadataQuery() {
        guard syncRoot.isAvailable, let root = syncRoot.rootURL else { return }
        guard metadataQuery == nil else { return }

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            root.path
        )
        q.notificationBatchingInterval = 2.0

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSMetadataQueryDidUpdate,
            .NSMetadataQueryDidFinishGathering
        ]

        for name in names {
            let token = center.addObserver(
                forName: name,
                object: q,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.refresh()
                }
            }
            observers.append(token)
        }

        q.start()
        metadataQuery = q
    }
}
