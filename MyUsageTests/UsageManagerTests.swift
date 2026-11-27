import XCTest
import Foundation
@testable import MyUsage

final class UsageManagerTests: XCTestCase {
    @MainActor
    private final class TriggerRecordingProvider: BuiltinUsageProvider {
        let kind = ProviderKind.claude
        let isAvailable = true
        var isEnabled = true
        var snapshot: UsageSnapshot?
        var error: String?
        var isLoading = false
        var triggers: [UsageRefreshTrigger] = []

        func refresh() async {
            triggers.append(.automatic)
        }

        func refresh(trigger: UsageRefreshTrigger) async {
            triggers.append(trigger)
        }
    }

    func testJitteredIntervalStaysWithinDefaultBand() {
        let base = 300.0
        for _ in 0..<200 {
            let value = UsageManager.jitteredInterval(base: base)
            XCTAssertGreaterThanOrEqual(value, base * 0.8)
            XCTAssertLessThanOrEqual(value, base * 1.2)
        }
    }

    func testJitteredIntervalRespectsCustomFraction() {
        let base = 60.0
        for _ in 0..<200 {
            let value = UsageManager.jitteredInterval(base: base, jitterFraction: 0.1)
            XCTAssertGreaterThanOrEqual(value, base * 0.9)
            XCTAssertLessThanOrEqual(value, base * 1.1)
        }
    }

    func testJitteredIntervalClampsNegativeFractionToZero() {
        let base = 120.0
        let value = UsageManager.jitteredInterval(base: base, jitterFraction: -0.5)
        XCTAssertEqual(value, base, accuracy: 0.0001)
    }

    func testJitteredIntervalNeverReturnsNegative() {
        for _ in 0..<200 {
            let value = UsageManager.jitteredInterval(base: 0, jitterFraction: 0.5)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }

    func testMinRefreshIntervalFloorIsAtLeastOneMinute() {
        XCTAssertGreaterThanOrEqual(UsageManager.minRefreshIntervalFloor, 60)
    }

    @MainActor
    func testManualRefreshTriggerIsForwardedToProviders() async {
        let provider = TriggerRecordingProvider()
        let manager = UsageManager(
            providers: [provider],
            backgroundServicesEnabled: false
        )
        provider.isEnabled = true

        await manager.refreshAll(trigger: .manual)

        XCTAssertEqual(provider.triggers, [.manual])
    }
}
