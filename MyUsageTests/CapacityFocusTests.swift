import XCTest
@testable import MyUsage

final class CapacityFocusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAttentionWindowOutranksSoonerHealthyReset() {
        let healthy = metric(.claude, "5-hour", 30, reset: 300)
        let pressured = metric(.codex, "Weekly", 81, reset: 10_000)
        XCTAssertEqual(CapacityFocus.select(from: [healthy, pressured], now: now), pressured)
    }

    func testProjectedOvershootOutranksHigherCurrentUsage() {
        let highCurrent = metric(.claude, "Weekly", 78, reset: 3_000)
        let overshoot = metric(.codex, "5-hour", 62, reset: 4_000, projected: 145)
        XCTAssertEqual(CapacityFocus.select(from: [highCurrent, overshoot], now: now), overshoot)
    }

    func testHealthyWindowsChooseSoonestFutureReset() {
        let later = metric(.claude, "Weekly", 60, reset: 4_000)
        let sooner = metric(.codex, "5-hour", 12, reset: 400)
        XCTAssertEqual(CapacityFocus.select(from: [later, sooner], now: now), sooner)
    }

    func testMissingAndPastResetFallBackToHighestUsage() {
        let unknown = metric(.claude, "Weekly", 55, reset: nil)
        let past = metric(.codex, "5-hour", 62, reset: -10)
        XCTAssertEqual(CapacityFocus.select(from: [unknown, past], now: now), past)
    }

    private func metric(
        _ provider: ProviderKind,
        _ label: String,
        _ percent: Double,
        reset: TimeInterval?,
        projected: Double? = nil
    ) -> CapacityFocus.Metric {
        CapacityFocus.Metric(
            providerKind: provider,
            label: label,
            percentUsed: percent,
            resetsAt: reset.map { now.addingTimeInterval($0) },
            pacePercent: nil,
            projectedFinalPercent: projected
        )
    }
}
