import Foundation

/// This Mac's stable identity inside the multi-device ledger. The ID is a
/// UUIDv4 generated on first launch and persisted in `UserDefaults`; the
/// display name is best-effort and only surfaces in the "Devices" UI.
///
/// Wiping `~/Library/Preferences` produces a new device ID — the old device's
/// rows stay in iCloud until the user removes them from Settings → Devices,
/// which is acceptable per `specs/12-usage-ledger.md`.
enum DeviceIdentity {

    static let idKey = "MyUsage.deviceID"

    /// Current device UUID. First access persists a new UUIDv4 if none exists.
    static func currentID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idKey)
        return fresh
    }

    /// Human-readable label for UI use ("zhengcc-mbp"). Falls back to
    /// "Mac" if the host name isn't available. Never used as a sync key.
    static func displayName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}
