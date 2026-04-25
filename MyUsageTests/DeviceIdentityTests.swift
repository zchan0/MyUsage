import Testing
import Foundation
@testable import MyUsage

@Suite("DeviceIdentity Tests")
struct DeviceIdentityTests {

    @Test("currentID persists the first stable ID and returns it thereafter")
    func persistsFirst() throws {
        let defaultsKey = "DeviceIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsKey)!
        defer { defaults.removePersistentDomain(forName: defaultsKey) }

        let a = DeviceIdentity.currentID(
            defaults: defaults,
            platformUUIDProvider: { "hardware-A" },
            fallbackUUIDProvider: { "fallback-A" }
        )
        let b = DeviceIdentity.currentID(
            defaults: defaults,
            platformUUIDProvider: { "hardware-B" },
            fallbackUUIDProvider: { "fallback-B" }
        )
        #expect(a == b)
        #expect(UUID(uuidString: a) != nil)
    }

    @Test("currentID re-derives the same ID after UserDefaults is cleared")
    func clearingDefaultsKeepsStableID() {
        let defaultsKey = "DeviceIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsKey)!
        defer { defaults.removePersistentDomain(forName: defaultsKey) }

        let first = DeviceIdentity.currentID(
            defaults: defaults,
            platformUUIDProvider: { "hardware-A" },
            fallbackUUIDProvider: { "fallback-A" }
        )
        defaults.removeObject(forKey: DeviceIdentity.idKey)
        let second = DeviceIdentity.currentID(
            defaults: defaults,
            platformUUIDProvider: { "hardware-A" },
            fallbackUUIDProvider: { "fallback-B" }
        )

        #expect(first == second)
    }

    @Test("stableID is deterministic for the same platform UUID")
    func stableIDIsDeterministic() {
        let a = DeviceIdentity.stableID(platformUUID: "hardware-A")
        let b = DeviceIdentity.stableID(platformUUID: "hardware-A")
        #expect(a == b)
    }

    @Test("stableID differs when the platform UUID differs")
    func stableIDDiffers() {
        let a = DeviceIdentity.stableID(platformUUID: "hardware-A")
        let b = DeviceIdentity.stableID(platformUUID: "hardware-B")
        #expect(a != b)
    }

    @Test("stableID produces a valid RFC 4122 UUIDv4 string")
    func stableIDIsValidUUIDv4() {
        let id = DeviceIdentity.stableID(platformUUID: "hardware-A")
        #expect(UUID(uuidString: id) != nil)

        // Format: XXXXXXXX-XXXX-VXXX-NXXX-XXXXXXXXXXXX
        let chars = Array(id)
        #expect(chars[14] == "4", "Version nibble must be 4")
        let variant = chars[19]
        #expect(["8", "9", "A", "B"].contains(variant), "Variant nibble must be 10xx (8/9/A/B)")
    }

    @Test("currentID falls back to random UUID when platform UUID is unavailable")
    func fallbackWhenPlatformUUIDUnavailable() {
        let defaultsKey = "DeviceIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsKey)!
        defer { defaults.removePersistentDomain(forName: defaultsKey) }
        let fallback = "11111111-2222-3333-4444-555555555555"

        let id = DeviceIdentity.currentID(
            defaults: defaults,
            platformUUIDProvider: { nil },
            fallbackUUIDProvider: { fallback }
        )

        #expect(id == fallback)
        #expect(defaults.string(forKey: DeviceIdentity.idKey) == fallback)
    }
}
