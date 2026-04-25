import Foundation
import os

/// Imports other devices' `ledger.jsonl` files into the local SQLite store.
///
/// The reader is **strictly read-only** for peer folders — it never writes
/// into another device's folder, enforcing the "one writer per device"
/// invariant described in `specs/12-usage-ledger.md`.
///
/// Resume-friendly: we remember each peer's byte offset in `peer_state`, so
/// subsequent calls only parse the newly appended tail.
actor LedgerReader {

    private let store: LedgerStore
    private let selfDeviceID: String
    private let syncRoot: SyncRoot
    private let decoder: JSONDecoder

    init(
        store: LedgerStore,
        selfDeviceID: String = DeviceIdentity.currentID(),
        syncRoot: SyncRoot = SyncFolderRoot()
    ) {
        self.store = store
        self.selfDeviceID = selfDeviceID
        self.syncRoot = syncRoot
        self.decoder = JSONDecoder()
    }

    struct ImportReport: Sendable, Equatable {
        /// Peer device IDs seen during this sweep.
        let peers: [String]
        /// Rows newly inserted or updated across all peers.
        let applied: Int
    }

    /// Scan the sync root for peer folders and import any new rows.
    /// Silently no-ops when the configured sync folder is unavailable.
    @discardableResult
    func importAllPeers() async -> ImportReport {
        guard syncRoot.isAvailable, let root = syncRoot.rootURL else {
            return ImportReport(peers: [], applied: 0)
        }

        let devicesRoot = SyncLayout.devicesFolder(in: root)

        let fm = FileManager.default
        guard fm.fileExists(atPath: devicesRoot.path) else {
            return ImportReport(peers: [], applied: 0)
        }

        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: devicesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Logger.ledger.error(
                "Ledger peer scan failed: \(error.localizedDescription, privacy: .public)"
            )
            return ImportReport(peers: [], applied: 0)
        }

        var peers: [String] = []
        var applied = 0
        for folder in children {
            let deviceID = folder.lastPathComponent
            guard deviceID != selfDeviceID else { continue }
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) == true else { continue }

            let n = await importPeer(deviceID: deviceID, folder: folder)
            peers.append(deviceID)
            applied += n
        }

        return ImportReport(peers: peers, applied: applied)
    }

    /// Import one peer's `ledger.jsonl` from `offset` to end of file.
    @discardableResult
    func importPeer(deviceID: String, folder: URL) async -> Int {
        let file = folder.appendingPathComponent(SyncLayout.ledgerFilename)
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }

        let previousOffset: Int64
        do {
            previousOffset = try store.peerOffset(deviceId: deviceID)
        } catch {
            Logger.ledger.error(
                "Ledger peer offset read failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        let size: Int64
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            size = Int64(end)
        } catch {
            Logger.ledger.error(
                "Ledger peer open failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        // File shrank (peer did "Reset ledger" or conflict copy replaced it) —
        // drop our old rows for this peer and replay from scratch.
        if size < previousOffset {
            do {
                try store.deleteRows(forDevice: deviceID)
                try store.setPeerOffset(deviceId: deviceID, offset: 0)
            } catch {
                Logger.ledger.error(
                    "Ledger peer reset failed: \(error.localizedDescription, privacy: .public)"
                )
                return 0
            }
            return await importPeer(deviceID: deviceID, folder: folder)
        }

        // Nothing new appended since the last sync.
        if size == previousOffset { return 0 }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(previousOffset))
            data = handle.readDataToEndOfFile()
        } catch {
            Logger.ledger.error(
                "Ledger peer read failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        let (entries, consumed) = parseJSONL(data: data)
        guard !entries.isEmpty else {
            // All we got was a partial trailing line — don't advance offset.
            if consumed > 0 {
                try? store.setPeerOffset(
                    deviceId: deviceID,
                    offset: previousOffset + Int64(consumed)
                )
            }
            return 0
        }

        let applied: Int
        do {
            applied = try store.upsert(entries).count
        } catch {
            Logger.ledger.error(
                "Ledger peer upsert failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        // Only advance past bytes we fully consumed — a partial trailing
        // line is retried next sweep.
        let newOffset = previousOffset + Int64(consumed)
        do {
            try store.setPeerOffset(deviceId: deviceID, offset: newOffset)
        } catch {
            Logger.ledger.error(
                "Ledger peer offset save failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        return applied
    }

    // MARK: - JSONL parsing

    /// Parse an LF-delimited chunk of JSON lines. Returns decoded entries
    /// plus the byte count that was *fully consumed*. A partial trailing
    /// line (no terminating LF) is NOT consumed so the next sweep retries.
    func parseJSONL(data: Data) -> (entries: [LedgerEntry], consumed: Int) {
        guard !data.isEmpty else { return ([], 0) }

        var entries: [LedgerEntry] = []
        var consumed = 0
        var cursor = 0
        let bytes = [UInt8](data)

        while cursor < bytes.count {
            guard let lfIndex = bytes[cursor...].firstIndex(of: 0x0A) else {
                // No more LFs. If the remainder is valid JSON, accept it as a
                // complete final line; otherwise keep it for the next sweep.
                let lineData = data.subdata(in: cursor..<bytes.count)
                if let entry = decodeEntry(lineData) {
                    entries.append(entry)
                    consumed = bytes.count
                }
                break
            }

            let length = lfIndex - cursor
            if length > 0 {
                let lineData = data.subdata(in: cursor..<lfIndex)
                if let entry = decodeEntry(lineData) {
                    entries.append(entry)
                }
            }
            // +1 for the LF byte itself.
            consumed = lfIndex + 1
            cursor = consumed
        }

        return (entries, consumed)
    }

    private func decodeEntry(_ lineData: Data) -> LedgerEntry? {
        guard let entry = try? decoder.decode(LedgerEntry.self, from: lineData) else {
            return nil
        }
        // Reject rows whose wire version we don't recognise; future schemas
        // can be ignored without corrupting our state.
        guard entry.v == LedgerEntry.wireVersion else { return nil }
        return entry
    }
}
