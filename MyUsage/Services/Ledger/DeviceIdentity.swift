import Foundation
import CryptoKit
import IOKit
import os

/// This Mac's stable identity inside the multi-device ledger. The ID is a
/// deterministic RFC 4122 UUIDv4 string derived from `IOPlatformUUID` and
/// cached in `UserDefaults`; the display name is best-effort and only
/// surfaces in the "Devices" UI.
///
/// `UserDefaults` is only a cache. If preferences are deleted, the same Mac
/// derives the same ID again instead of appearing as a new synced device.
/// IOPlatformUUID itself is never written to disk — only the salted SHA-256
/// digest reshaped to UUIDv4 form.
enum DeviceIdentity {

    static let idKey = "MyUsage.deviceID"
    private static let salt = "MyUsage.v1"

    /// Current device UUID. First access persists a stable hardware-derived ID
    /// if possible, falling back to a random UUID when IOKit cannot provide the
    /// platform UUID.
    static func currentID(defaults: UserDefaults = .standard) -> String {
        currentID(
            defaults: defaults,
            platformUUIDProvider: platformUUID,
            fallbackUUIDProvider: { UUID().uuidString }
        )
    }

    /// Testable core used to inject platform UUID / fallback behavior without
    /// touching IOKit or the real defaults domain.
    static func currentID(
        defaults: UserDefaults,
        platformUUIDProvider: () -> String?,
        fallbackUUIDProvider: () -> String
    ) -> String {
        if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
            return existing
        }
        let id: String
        if let hwUUID = platformUUIDProvider() {
            id = stableID(platformUUID: hwUUID)
        } else {
            id = fallbackUUIDProvider()
            Logger.ledger.error(
                "IOPlatformUUID unavailable; minted random device ID. This Mac will appear as a new device after each preferences wipe."
            )
        }
        defaults.set(id, forKey: idKey)
        return id
    }

    /// Human-readable label for UI use ("zhengcc-mbp"). Falls back to
    /// "Mac" if the host name isn't available. Never used as a sync key.
    static func displayName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    /// Deterministically map an IOPlatformUUID into an RFC 4122 UUIDv4
    /// string. `internal` so the test target can call it via `@testable
    /// import` and verify stability — production code should go through
    /// `currentID(...)` instead.
    static func stableID(platformUUID: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt)|\(platformUUID)".utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122: version 4 in the high nibble of byte 6, variant 10 in the
        // top two bits of byte 8. Anything else is just a hex blob and may
        // trip strict UUID validators downstream.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let value = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return value?.takeRetainedValue() as? String
    }
}
