import Foundation
import os

/// Serializes ledger writes: upsert into SQLite first, then append to the
/// per-device JSONL in the configured sync folder (best-effort). Also rewrites the
/// compact `manifest.json` summary so peers can show per-device totals
/// without reparsing our JSONL.
///
/// Single-writer invariant: only the current Mac ever touches
/// `devices/<selfID>/*`. That guarantees no cross-device file conflicts
/// by construction.
actor LedgerWriter {
    enum SyncWriteIssue: Equatable, Sendable {
        case unavailable
        case readOnly
        case failed(String)
    }

    struct WriteResult: Sendable {
        let applied: [LedgerEntry]
        let issue: SyncWriteIssue?
    }


    private let store: LedgerStore
    private let deviceID: String
    private let deviceName: String
    private let syncRoot: SyncRoot

    /// Encoder used both for JSONL lines and `manifest.json`. Each JSONL
    /// line is a single JSON object with no trailing newline inside.
    private let jsonlEncoder: JSONEncoder

    init(
        store: LedgerStore,
        deviceID: String = DeviceIdentity.currentID(),
        deviceName: String = DeviceIdentity.displayName(),
        syncRoot: SyncRoot = SyncFolderRoot()
    ) {
        self.store = store
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.syncRoot = syncRoot

        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        self.jsonlEncoder = e
    }

    /// Upsert daily costs for a single provider. `dailyCostsByDay` maps
    /// `YYYY-MM-DD` (UTC) → USD and should cover at least the current
    /// calendar month.
    ///
    /// Returns the entries that actually changed on disk (new or updated),
    /// so callers can log + decide whether to refresh UI caches.
    @discardableResult
    func recordDailyCosts(
        provider: ProviderKind,
        dailyCostsByDay: [String: Double],
        accountID: String = "default",
        now: Date = .now
    ) async -> WriteResult {
        let entries = dailyCostsByDay.map { (day, cost) in
            LedgerEntry(
                deviceId: deviceID,
                accountId: accountID,
                provider: provider,
                day: day,
                costUSD: cost,
                recordedAt: now
            )
        }
        return await append(entries)
    }

    /// Lower-level entry point: upsert a list of entries.
    @discardableResult
    func append(_ entries: [LedgerEntry]) async -> WriteResult {
        guard !entries.isEmpty else { return WriteResult(applied: [], issue: nil) }

        let applied: [LedgerEntry]
        do {
            applied = try store.upsert(entries)
        } catch {
            Logger.ledger.error(
                "Ledger upsert failed: \(error.localizedDescription, privacy: .public)"
            )
            return WriteResult(applied: [], issue: .failed(error.localizedDescription))
        }
        guard !applied.isEmpty else { return WriteResult(applied: [], issue: nil) }

        let exportIssue = await exportJSONL(applied)
        let manifestIssue = await rewriteManifest()

        return WriteResult(
            applied: applied,
            issue: manifestIssue ?? exportIssue
        )
    }

    // MARK: - Sync folder export

    private func exportJSONL(_ entries: [LedgerEntry]) async -> SyncWriteIssue? {
        guard syncRoot.isAvailable, let root = syncRoot.rootURL else { return .unavailable }

        let folder = SyncLayout.deviceFolder(in: root, deviceID: deviceID)
        let file = SyncLayout.ledgerFile(in: root, deviceID: deviceID)

        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        } catch {
            Logger.ledger.error(
                "Ledger export failed: cannot create folder \(folder.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return writeIssue(for: error)
        }

        var buffer = Data()
        for entry in entries {
            do {
                var line = try jsonlEncoder.encode(entry)
                line.append(0x0A)  // LF
                buffer.append(line)
            } catch {
                Logger.ledger.error(
                    "Ledger JSONL encode failed: \(error.localizedDescription, privacy: .public)"
                )
                return .failed(error.localizedDescription)
            }
        }
        guard !buffer.isEmpty else { return nil }

        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try buffer.write(to: file, options: .atomic)
            } catch {
                Logger.ledger.error(
                    "Ledger JSONL write failed for \(file.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                return writeIssue(for: error)
            }
            return nil
        }

        do {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            Logger.ledger.error(
                "Ledger JSONL append failed for \(file.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return writeIssue(for: error)
        }
        return nil
    }

    private func rewriteManifest() async -> SyncWriteIssue? {
        guard syncRoot.isAvailable, let root = syncRoot.rootURL else { return .unavailable }

        let byProvider: [String: [String: Double]]
        let rowCount: Int
        let lastEntryAt: Date?
        do {
            byProvider = try store.monthlyTotalsForManifest(
                deviceID: deviceID,
                monthKey: LedgerCalendar.monthKey(for: .now)
            )
            let meta = try store.manifestMeta(deviceID: deviceID)
            rowCount = meta.rowCount
            lastEntryAt = meta.lastEntryAt
        } catch {
            Logger.ledger.error(
                "Ledger manifest query failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }

        let manifest = LedgerManifest(
            deviceId: deviceID,
            deviceName: deviceName,
            updatedAt: .now,
            rowCount: rowCount,
            lastEntryAt: lastEntryAt,
            monthlyTotals: byProvider
        )

        let folder = SyncLayout.deviceFolder(in: root, deviceID: deviceID)
        let file = SyncLayout.manifestFile(in: root, deviceID: deviceID)

        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            try LedgerManifestCodec.write(manifest, to: file)
        } catch {
            Logger.ledger.error(
                "Ledger manifest write failed for \(file.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return writeIssue(for: error)
        }
        return nil
    }

    private func writeIssue(for error: Error) -> SyncWriteIssue {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError,
                 NSFileReadNoPermissionError,
                 NSFileWriteVolumeReadOnlyError,
                 NSFileWriteUnknownError:
                return .readOnly
            default:
                break
            }
        }
        return .failed(error.localizedDescription)
    }
}

extension Logger {
    /// Structured logging for the ledger layer. Category matches other
    /// provider loggers so `log stream --category Ledger` is filterable.
    static let ledger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.myusage",
        category: "Ledger"
    )
}
