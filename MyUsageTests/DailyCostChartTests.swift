import Testing
@testable import MyUsage

@Suite("DailyCostChart insights")
struct DailyCostChartTests {
    @Test("Top model sums the full 30-day series and reports total-cost share")
    func topModel() throws {
        let series = [
            LedgerStore.DailyCost(
                day: "2026-07-22",
                totalUSD: 10,
                byModel: ["GPT-5.6 Sol": 6, "GPT-5.5": 4]
            ),
            LedgerStore.DailyCost(
                day: "2026-07-23",
                totalUSD: 5,
                byModel: ["GPT-5.6 Sol": 3, "GPT-5.5": 2]
            ),
        ]

        let insight = try #require(DailyCostChartInsights.topModel(in: series))
        #expect(insight.name == "GPT-5.6 Sol")
        #expect(abs(insight.sharePercent - 60) < 0.001)
    }

    @Test("Top model is absent when the ledger has no model attribution")
    func noModelAttribution() {
        let series = [
            LedgerStore.DailyCost(day: "2026-07-23", totalUSD: 5, byModel: [:])
        ]

        #expect(DailyCostChartInsights.topModel(in: series) == nil)
    }

    @Test("Top model share is clamped for inconsistent legacy rows")
    func clampsShare() throws {
        let series = [
            LedgerStore.DailyCost(
                day: "2026-07-23",
                totalUSD: 2,
                byModel: ["GPT-5.6 Sol": 3]
            )
        ]

        let insight = try #require(DailyCostChartInsights.topModel(in: series))
        #expect(insight.sharePercent == 100)
    }
}
