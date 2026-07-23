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

    func testEarlyWindowClearPaceLeadRequiresAttention() {
        let metric = metric(.codex, "Weekly", 65, reset: 5 * 86_400, pace: 19)

        guard case .earlyDeficit(let multiplier) = metric.riskSignal else {
            return XCTFail("Expected an early-window pace warning")
        }
        XCTAssertEqual(multiplier, 65.0 / 19.0, accuracy: 0.001)
        XCTAssertEqual(metric.paceBalance, .deficit(percent: 46))
        XCTAssertEqual(CapacityPaceText.detailSummary(for: metric, now: now), "46% in deficit")
        XCTAssertTrue(metric.needsAttention)
        XCTAssertTrue(metric.requiresOverviewAttention)
    }

    func testEarlySinglePromptDoesNotFalseAlarm() {
        let metric = metric(.codex, "5-hour", 5, reset: 4 * 3_600, pace: 1)

        XCTAssertEqual(metric.riskSignal, .none)
        XCTAssertEqual(metric.paceBalance, .deficit(percent: 4))
        XCTAssertFalse(metric.needsAttention)
        XCTAssertFalse(metric.requiresOverviewAttention)
    }

    func testSmallPaceLeadDoesNotFalseAlarm() {
        let metric = metric(.claude, "Weekly", 20, reset: 5 * 86_400, pace: 15)

        XCTAssertEqual(metric.riskSignal, .none)
        XCTAssertEqual(metric.paceBalance, .deficit(percent: 5))
        XCTAssertFalse(metric.requiresOverviewAttention)
    }

    func testReserveAndOnPaceUsePercentagePointDistance() {
        let reserve = metric(.codex, "Weekly", 24, reset: 4 * 86_400, pace: 40)
        let onPace = metric(.claude, "5-hour", 31, reset: 2_000, pace: 30)

        XCTAssertEqual(reserve.paceBalance, .reserve(percent: 16))
        XCTAssertEqual(CapacityPaceText.balanceLabel(for: reserve), "16% in reserve")
        XCTAssertEqual(onPace.paceBalance, .onPace)
        XCTAssertEqual(CapacityPaceText.balanceLabel(for: onPace), "On pace")
    }

    func testReliableProjectionTakesPrecedenceOverPaceFallback() {
        let exhaustion = now.addingTimeInterval(3_600)
        let metric = metric(
            .claude,
            "Weekly",
            65,
            reset: 4 * 86_400,
            pace: 30,
            projected: 217,
            exhaustion: exhaustion
        )

        XCTAssertEqual(metric.riskSignal, .projectedOvershoot(percent: 217))
        XCTAssertEqual(metric.paceOutcome, .runsOut(at: exhaustion))
        XCTAssertEqual(
            CapacityPaceText.detailSummary(for: metric, now: now),
            "35% in deficit · Runs out in 1h 0m"
        )
        XCTAssertEqual(
            CapacityPaceText.overviewSummary(for: metric, now: now),
            "35% deficit · runs out in 1h 0m"
        )
        XCTAssertTrue(metric.requiresOverviewAttention)
    }

    func testReliableReserveReportsLastingUntilReset() {
        let metric = metric(
            .codex,
            "Weekly",
            30,
            reset: 4 * 86_400,
            pace: 50,
            projected: 60
        )

        XCTAssertEqual(metric.paceOutcome, .lastsUntilReset)
        XCTAssertEqual(
            CapacityPaceText.detailSummary(for: metric, now: now),
            "20% in reserve · Lasts until reset"
        )
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
        pace: Double? = nil,
        projected: Double? = nil,
        exhaustion: Date? = nil
    ) -> CapacityFocus.Metric {
        CapacityFocus.Metric(
            providerKind: provider,
            label: label,
            percentUsed: percent,
            resetsAt: reset.map { now.addingTimeInterval($0) },
            pacePercent: pace,
            projectedFinalPercent: projected,
            projectedExhaustionAt: exhaustion
        )
    }
}
