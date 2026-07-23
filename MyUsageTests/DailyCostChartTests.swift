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

    @Test("Selected-day breakdown keeps family order and folds remainder into Other")
    func dailyBreakdown() {
        let day = LedgerStore.DailyCost(
            day: "2026-07-23",
            totalUSD: 10,
            byModel: [
                "GPT-5.6 Sol": 6,
                "GPT-5.5": 2,
                "Long tail": 1,
            ]
        )

        let breakdown = DailyCostChartInsights.dailyBreakdown(
            for: day,
            families: ["GPT-5.6 Sol", "Missing", "GPT-5.5", "Other"]
        )

        #expect(breakdown == [
            DailyModelCost(name: "GPT-5.6 Sol", costUSD: 6),
            DailyModelCost(name: "Missing", costUSD: nil),
            DailyModelCost(name: "GPT-5.5", costUSD: 2),
            DailyModelCost(name: "Other", costUSD: 2),
        ])
    }

    @Test("Selected-day top model uses the visible daily breakdown")
    func dailyTopModel() throws {
        let breakdown = [
            DailyModelCost(name: "GPT-5.6 Sol", costUSD: 6),
            DailyModelCost(name: "GPT-5.5", costUSD: 2),
            DailyModelCost(name: "Other", costUSD: 2),
        ]

        let insight = try #require(
            DailyCostChartInsights.topModel(in: breakdown, totalUSD: 10)
        )
        #expect(insight.name == "GPT-5.6 Sol")
        #expect(abs(insight.sharePercent - 60) < 0.001)
    }
}
