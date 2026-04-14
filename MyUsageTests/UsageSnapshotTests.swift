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
