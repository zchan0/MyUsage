import Foundation
import os

/// On-disk cache of every (provider, account) pair MyUsage has observed
/// on this Mac. Drives:
///   - the popover account switcher (live data for the active account,
///     cached `AccountSnapshot` for the rest);
///   - Settings → Providers' inline accounts strip;
///   - the per-provider "currently active accountID" used for ledger writes.
///
/// Single-file JSON at `~/Library/Application Support/MyUsage/accounts.json`,
/// rewritten atomically on every observation. Workload is small (≤ a few
/// KB per provider, a handful of accounts max), so we don't need SQLite —
/// the entire file fits in memory and rewriting is cheap.
@MainActor
@Observable
final class AccountStore {

    /// Per-account record stored under `providers[kind].accounts[accountID]`.
    /// Identifiable so SwiftUI lists can iterate it without ad-hoc keying.
    struct AccountRecord: Codable, Sendable, Identifiable, Equatable {
        let accountID: String       // matches `LedgerEntry.accountId`
        var displayName: String     // email verbatim, or `Account id:abc12345`
        var email: String?          // nil for the opaque-fallback path
        var lastSeenAt: Date        // last successful refresh while signed in
        var snapshot: AccountSnapshot?

        var id: String { accountID }
        var isOpaque: Bool { email == nil }
    }

    private struct ProviderEntry: Codable, Sendable, Equatable {
        var active: String?         // accountID currently signed in, if any
        var accounts: [String: AccountRecord] = [:]
    }

    private struct DiskShape: Codable, Sendable {
        var v: Int = 1
        var providers: [String: ProviderEntry] = [:]
    }

    // MARK: - State (observed)

    private var disk: DiskShape

    // MARK: - Storage

    private let fileURL: URL

    static let defaultFileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support
            .appendingPathComponent("MyUsage", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }()

    init(fileURL: URL = AccountStore.defaultFileURL) {
        self.fileURL = fileURL
        self.disk = Self.load(from: fileURL) ?? DiskShape()
    }

    // MARK: - Reads

    /// All accounts seen for `provider`, sorted by `lastSeenAt` desc.
    /// The popover uses this to decide whether to show the switcher
    /// (count >= 2) and in what order.
    func accounts(for provider: ProviderKind) -> [AccountRecord] {
        let entry = disk.providers[provider.rawValue] ?? ProviderEntry()
        return entry.accounts.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Number of accounts observed for `provider`. The popover keeps the
    /// single-account UX identical to today when this is `<= 1`.
    func count(for provider: ProviderKind) -> Int {
        disk.providers[provider.rawValue]?.accounts.count ?? 0
    }

    /// The accountID currently signed in for `provider` (if any). Returned
    /// as the raw `accountID` string so callers can pass it straight into
    /// `LedgerEntry.accountId`.
    func activeAccountID(for provider: ProviderKind) -> String? {
        disk.providers[provider.rawValue]?.active
    }

    func record(for provider: ProviderKind, accountID: String) -> AccountRecord? {
        disk.providers[provider.rawValue]?.accounts[accountID]
    }

    // MARK: - Writes

    /// Called by each provider after a successful refresh. Updates the
    /// account's `lastSeenAt` + cached snapshot, marks it active for this
    /// provider, and persists atomically.
    func recordObservation(
        provider: ProviderKind,
        identity: AccountIdentity,
        snapshot: UsageSnapshot,
        at time: Date = .now
    ) {
        var entry = disk.providers[provider.rawValue] ?? ProviderEntry()
        var record = entry.accounts[identity.id] ?? AccountRecord(
            accountID: identity.id,
            displayName: identity.displayName,
            email: identity.email,
            lastSeenAt: time,
            snapshot: nil
        )
        record.displayName = identity.displayName
        record.email = identity.email
        record.lastSeenAt = time
        record.snapshot = AccountSnapshot(from: snapshot, capturedAt: time)
        entry.accounts[identity.id] = record
        entry.active = identity.id
        disk.providers[provider.rawValue] = entry
        save()
    }

    /// Flip the active pointer for a provider without recording a fresh
    /// observation. Useful when the active credentials haven't changed
    /// but extra accounts were injected (e.g. demo / mock multi-account
    /// mode) — we want them visible in the registry but the real account
    /// to remain the live one.
    func activate(provider: ProviderKind, accountID: String?) {
        var entry = disk.providers[provider.rawValue] ?? ProviderEntry()
        entry.active = accountID
        disk.providers[provider.rawValue] = entry
        save()
    }

    /// Drop one account from the registry — the user has clicked Forget
    /// in Settings → Providers. Leaves ledger entries alone; those still
    /// surface under the account's email in cross-device aggregates and
    /// remain correct historically. Removing them is a separate "wipe"
    /// op we can add later if anyone asks.
    func forget(provider: ProviderKind, accountID: String) {
        guard var entry = disk.providers[provider.rawValue] else { return }
        entry.accounts.removeValue(forKey: accountID)
        if entry.active == accountID { entry.active = nil }
        disk.providers[provider.rawValue] = entry
        save()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> DiskShape? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiskShape.self, from: data)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(disk)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.general.error(
                "AccountStore save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
