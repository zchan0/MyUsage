import Testing
@testable import MyUsage

@Suite("DailyCostChart breakdown")
struct DailyCostChartTests {
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

        let breakdown = DailyCostChartBreakdown.daily(
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

    @Test("Period breakdown sums days and folds long-tail and unattributed costs")
    func periodBreakdown() {
        let series = [
            LedgerStore.DailyCost(
                day: "2026-07-22",
                totalUSD: 10,
                byModel: [
                    "GPT-5.6 Sol": 6,
                    "GPT-5.5": 2,
                    "Long tail": 1,
                ]
            ),
            LedgerStore.DailyCost(
                day: "2026-07-23",
                totalUSD: 5,
                byModel: [
                    "GPT-5.6 Sol": 3,
                    "GPT-5.5": 1,
                ]
            ),
        ]

        let breakdown = DailyCostChartBreakdown.period(
            in: series,
            families: ["GPT-5.6 Sol", "Missing", "GPT-5.5", "Other"]
        )

        #expect(breakdown == [
            DailyModelCost(name: "GPT-5.6 Sol", costUSD: 9),
            DailyModelCost(name: "Missing", costUSD: nil),
            DailyModelCost(name: "GPT-5.5", costUSD: 3),
            DailyModelCost(name: "Other", costUSD: 3),
        ])
    }
}
