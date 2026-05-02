import Testing
import Foundation
@testable import MyUsage

@Suite("UsageSnapshot Tests")
struct UsageSnapshotTests {

    @Test("Default snapshot has zero worst usage")
    func defaultWorstUsage() {
        let snapshot = UsageSnapshot()
        #expect(snapshot.worstUsagePercent == 0)
    }

    @Test("Worst usage returns session when higher")
    func worstUsageSession() {
        var snapshot = UsageSnapshot()
        snapshot.sessionUsage = UsageWindow(percentUsed: 75, resetsAt: nil)
        snapshot.weeklyUsage = UsageWindow(percentUsed: 30, resetsAt: nil)
        #expect(snapshot.worstUsagePercent == 75)
    }

    @Test("Worst usage returns weekly when higher")
    func worstUsageWeekly() {
        var snapshot = UsageSnapshot()
        snapshot.sessionUsage = UsageWindow(percentUsed: 20, resetsAt: nil)
        snapshot.weeklyUsage = UsageWindow(percentUsed: 60, resetsAt: nil)
        #expect(snapshot.worstUsagePercent == 60)
    }

    @Test("Worst usage considers model quotas")
    func worstUsageModels() {
        var snapshot = UsageSnapshot()
        snapshot.modelQuotas = [
            ModelQuota(label: "Model A", remainingFraction: 0.2, resetsAt: nil), // 80% used
            ModelQuota(label: "Model B", remainingFraction: 0.9, resetsAt: nil), // 10% used
        ]
        #expect(snapshot.worstUsagePercent == 80)
    }

    @Test("Worst usage considers total usage percent")
    func worstUsageTotalPercent() {
        var snapshot = UsageSnapshot()
        snapshot.totalUsagePercent = 55
        #expect(snapshot.worstUsagePercent == 55)
    }

    @Test("UsageWindow reset countdown formatting")
    func resetCountdown() {
        let future2h = Date.now.addingTimeInterval(2 * 3600 + 15 * 60)
        let window = UsageWindow(percentUsed: 30, resetsAt: future2h)
        let countdown = window.resetCountdown
        #expect(countdown != nil)
        #expect(countdown!.contains("h"))
    }

    @Test("UsageWindow past reset shows Resetting")
    func resetCountdownPast() {
        let past = Date.now.addingTimeInterval(-60)
        let window = UsageWindow(percentUsed: 100, resetsAt: past)
        #expect(window.resetCountdown == "Resetting…")
    }

    @Test("UsageWindow percent remaining is correct")
    func percentRemaining() {
        let window = UsageWindow(percentUsed: 35, resetsAt: nil)
        #expect(window.percentRemaining == 65)
    }

    @Test("ModelQuota percent used from remaining fraction")
    func modelQuotaPercent() {
        let quota = ModelQuota(label: "Test", remainingFraction: 0.3, resetsAt: nil)
        #expect(quota.percentUsed == 70)
    }

    @Test("CreditInfo formatted without limit")
    func creditFormatNoLimit() {
        let credit = CreditInfo(amount: 5.39, limit: nil, currency: "USD")
        #expect(credit.formatted == "$5.39")
    }

    @Test("CreditInfo formatted with limit")
    func creditFormatWithLimit() {
        let credit = CreditInfo(amount: 232.22, limit: 400.0, currency: "USD")
        #expect(credit.formatted == "$232.22 / $400.00")
    }
}

@Suite("RefreshInterval Tests")
struct RefreshIntervalTests {

    @Test("All intervals have display names")
    func displayNames() {
        for interval in RefreshInterval.allCases {
            #expect(!interval.displayName.isEmpty)
        }
    }

    @Test("Manual has no seconds")
    func manualNoSeconds() {
        #expect(RefreshInterval.manual.seconds == nil)
    }

    @Test("Timed intervals have positive seconds")
    func timedSeconds() {
        #expect(RefreshInterval.oneMinute.seconds == 60)
        #expect(RefreshInterval.twoMinutes.seconds == 120)
        #expect(RefreshInterval.fiveMinutes.seconds == 300)
        #expect(RefreshInterval.fifteenMinutes.seconds == 900)
    }
}

@Suite("UsageWindow burn-rate projection")
struct UsageWindowProjectionTests {

    /// Steady state: half the window elapsed, half the budget used → on
    /// pace to land exactly at the same rate the user started at.
    @Test("steady-state projection equals current percent")
    func steadyState() {
        // 5h window, 2.5h elapsed (so 2.5h until reset), used 50%.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(2.5 * 3600)
        let window = UsageWindow(
            percentUsed: 50,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        let projected = window.projectedFinalPercent(now: now)
        #expect(projected != nil)
        // 50 * (5 / 2.5) = 100
        #expect(abs(projected! - 100) < 0.01)
    }

    @Test("burning twice as fast → 2x current % at reset")
    func burningHot() {
        // 5h window, 1.25h elapsed, used 50% → burn rate is 2x normal.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(3.75 * 3600)
        let window = UsageWindow(
            percentUsed: 50,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        let projected = window.projectedFinalPercent(now: now)
        #expect(projected != nil)
        // 50 * (5 / 1.25) = 200
        #expect(abs(projected! - 200) < 0.01)
    }

    @Test("burning slow → projection well below 100")
    func burningCool() {
        // 7d window, 6d elapsed, used 30% → very chill rate.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(1 * 86400)
        let window = UsageWindow(
            percentUsed: 30,
            resetsAt: resetsAt,
            windowDuration: 7 * 86400
        )
        let projected = window.projectedFinalPercent(now: now)
        #expect(projected != nil)
        // 30 * (7 / 6) = 35
        #expect(abs(projected! - 35) < 0.01)
    }

    @Test("projection is nil when window just opened (< 60s elapsed)")
    func tooEarlyForProjection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 5h window, only 30s in
        let resetsAt = now.addingTimeInterval(5 * 3600 - 30)
        let window = UsageWindow(
            percentUsed: 1,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        #expect(window.projectedFinalPercent(now: now) == nil)
    }

    /// Regression for the user-reported false-arrow case: Codex 5h window,
    /// 14 minutes elapsed, 6% used → math projects ~129% but the data is
    /// way too noisy to trust. New 20%-of-window minimum suppresses it.
    @Test("projection is nil when < 20% of window has elapsed")
    func notEnoughElapsedForProjection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 5h window, 14 min elapsed (< 1h = 20% of 5h)
        let resetsAt = now.addingTimeInterval(5 * 3600 - 14 * 60)
        let window = UsageWindow(
            percentUsed: 6,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        #expect(window.projectedFinalPercent(now: now) == nil)
    }

    @Test("projection kicks in once at least 20% of the window has elapsed")
    func projectionKicksInAtTwentyPercent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 5h window, exactly 1h elapsed (20% of window)
        let resetsAt = now.addingTimeInterval(5 * 3600 - 1 * 3600)
        let window = UsageWindow(
            percentUsed: 30,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        let projected = window.projectedFinalPercent(now: now)
        #expect(projected != nil)
        // 30 * (5 / 1) = 150
        #expect(abs(projected! - 150) < 0.01)
    }

    @Test("projection is nil when reset is in the past")
    func resetInPast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(-60)
        let window = UsageWindow(
            percentUsed: 50,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        #expect(window.projectedFinalPercent(now: now) == nil)
    }

    @Test("projection is nil when window duration unknown")
    func noWindowDuration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(
            percentUsed: 50,
            resetsAt: now.addingTimeInterval(3600),
            windowDuration: nil
        )
        #expect(window.projectedFinalPercent(now: now) == nil)
    }

    // MARK: - On-pace tick position

    @Test("on-pace position equals elapsed fraction")
    func onPaceMatchesElapsed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 5h window, 2.5h elapsed (50% of window)
        let resetsAt = now.addingTimeInterval(2.5 * 3600)
        let window = UsageWindow(
            percentUsed: 30,   // doesn't affect on-pace position
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        let onPace = window.onPacePercent(now: now)
        #expect(onPace != nil)
        #expect(abs(onPace! - 50) < 0.01)
    }

    /// Unlike projection (which gates on noise), the on-pace position
    /// is deterministic from time alone — even a fresh window has a
    /// meaningful (very-small) on-pace value. Make sure we don't
    /// accidentally re-introduce a noise gate that hides the marker
    /// for the first hour of a 5h window.
    @Test("on-pace position is non-nil even early in the window")
    func onPaceShowsEarly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 5h window, 14 min elapsed — would have been gated under the
        // projection function, but onPace is deterministic so it shows.
        let resetsAt = now.addingTimeInterval(5 * 3600 - 14 * 60)
        let window = UsageWindow(
            percentUsed: 6,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        let onPace = window.onPacePercent(now: now)
        #expect(onPace != nil)
        // 14m / 5h * 100 ≈ 4.67
        #expect(abs(onPace! - 4.67) < 0.1)
    }

    @Test("on-pace position caps at 100 even at end of window")
    func onPaceCapsAt100() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(1)
        let window = UsageWindow(
            percentUsed: 80,
            resetsAt: resetsAt,
            windowDuration: 5 * 3600
        )
        let onPace = window.onPacePercent(now: now)
        #expect(onPace != nil)
        #expect(onPace! <= 100)
        #expect(onPace! > 99)
    }

    @Test("on-pace nil when window duration unknown")
    func onPaceNeedsDuration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(
            percentUsed: 50,
            resetsAt: now.addingTimeInterval(3600),
            windowDuration: nil
        )
        #expect(window.onPacePercent(now: now) == nil)
    }
}
