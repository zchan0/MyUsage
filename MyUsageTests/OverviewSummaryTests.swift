import XCTest
@testable import MyUsage

final class OverviewSummaryTests: XCTestCase {

    // Fixed clock: 2026-07-16 12:00 UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!

    private func day(_ offset: Int) -> String {
        LedgerCalendar.dayKey(for: now.addingTimeInterval(Double(offset) * 86_400))
    }

    private func cost(_ day: String, _ usd: Double) -> LedgerStore.DailyCost {
        LedgerStore.DailyCost(day: day, totalUSD: usd, byModel: [:])
    }

    // MARK: - todayTotal

    func testTodayTotalSumsAcrossProviders() {
        let daily: [ProviderKind: [LedgerStore.DailyCost]] = [
            .claude: [cost(day(0), 4.20), cost(day(-1), 9.99)],
            .codex: [cost(day(0), 2.64)],
        ]
        XCTAssertEqual(OverviewSummary.todayTotal(dailyCosts: daily, now: now), 6.84, accuracy: 0.001)
    }

    func testTodayTotalIsZeroWithNoRowsToday() {
        let daily: [ProviderKind: [LedgerStore.DailyCost]] = [
            .claude: [cost(day(-1), 9.99)]
        ]
        XCTAssertEqual(OverviewSummary.todayTotal(dailyCosts: daily, now: now), 0)
    }

    // MARK: - trailingDailyAverage

    func testTrailingAverageDividesByWindowNotByRecordedDays() {
        // $14 across two recorded days in the prior week → avg $2/day,
        // NOT $7/day (empty days count as $0).
        let daily: [ProviderKind: [LedgerStore.DailyCost]] = [
            .claude: [cost(day(-1), 10), cost(day(-3), 4)]
        ]
        let avg = OverviewSummary.trailingDailyAverage(dailyCosts: daily, days: 7, now: now)
        XCTAssertEqual(avg!, 2.0, accuracy: 0.001)
    }

    func testTrailingAverageExcludesTodayAndOlderDays() {
        let daily: [ProviderKind: [LedgerStore.DailyCost]] = [
            .claude: [
                cost(day(0), 100),   // today — excluded
                cost(day(-7), 7),    // inside window (7 days back)
                cost(day(-8), 100),  // outside window — excluded
            ]
        ]
        let avg = OverviewSummary.trailingDailyAverage(dailyCosts: daily, days: 7, now: now)
        XCTAssertEqual(avg!, 1.0, accuracy: 0.001)
    }

    func testTrailingAverageNilWhenWindowEmpty() {
        let daily: [ProviderKind: [LedgerStore.DailyCost]] = [
            .claude: [cost(day(0), 5)]  // only today
        ]
        XCTAssertNil(OverviewSummary.trailingDailyAverage(dailyCosts: daily, days: 7, now: now))
    }

    // MARK: - monthTotal / previousMonthKey

    func testMonthTotalSumsProvidersAndNilForMissingMonth() {
        let totals: [String: [ProviderKind: Double]] = [
            "2026-07": [.claude: 112.40, .codex: 1.81]
        ]
        XCTAssertEqual(OverviewSummary.monthTotal(monthlyTotals: totals, monthKey: "2026-07")!, 114.21, accuracy: 0.001)
        XCTAssertNil(OverviewSummary.monthTotal(monthlyTotals: totals, monthKey: "2026-06"))
    }

    func testPreviousMonthKeyCrossesYearBoundary() {
        let january = ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")!
        XCTAssertEqual(OverviewSummary.previousMonthKey(now: january), "2025-12")
        XCTAssertEqual(OverviewSummary.previousMonthKey(now: now), "2026-06")
    }

    // MARK: - deltaCaption

    func testDeltaCaptionPercentBothDirections() {
        XCTAssertEqual(OverviewSummary.deltaCaption(today: 4.14, average: 3.0), "↑ 38% vs 7d avg")
        XCTAssertEqual(OverviewSummary.deltaCaption(today: 2.4, average: 3.0), "↓ 20% vs 7d avg")
    }

    func testDeltaCaptionSwitchesToRatioPast4x() {
        XCTAssertEqual(OverviewSummary.deltaCaption(today: 386.49, average: 29.7), "13× 7d avg")
        XCTAssertEqual(OverviewSummary.deltaCaption(today: 12, average: 3.0), "4× 7d avg")
        // Just under the 4× cliff stays percent
        XCTAssertEqual(OverviewSummary.deltaCaption(today: 11.9, average: 3.0), "↑ 297% vs 7d avg")
    }

    func testDeltaCaptionNilWithoutBaseline() {
        XCTAssertNil(OverviewSummary.deltaCaption(today: 5, average: nil))
        XCTAssertNil(OverviewSummary.deltaCaption(today: 5, average: 0))
    }

    // MARK: - trailingDailySeries

    func testTrailingSeriesIsDenseOldestToNewestEndingToday() {
        let series = [cost(day(0), 5), cost(day(-2), 3)]
        let values = OverviewSummary.trailingDailySeries(series: series, days: 4, now: now)
        // day -3, -2, -1, 0 → [0, 3, 0, 5]
        XCTAssertEqual(values, [0, 3, 0, 5])
    }

    func testTrailingSeriesNilWhenWindowHasNoRows() {
        let series = [cost(day(-30), 9)]
        XCTAssertNil(OverviewSummary.trailingDailySeries(series: series, days: 14, now: now))
    }

    // MARK: - nextReset

    func testNextResetPicksSoonestFutureAndSkipsPast() {
        let candidates: [OverviewSummary.ResetCandidate] = [
            .init(providerName: "Claude", windowLabel: "5h", resetsAt: now.addingTimeInterval(2 * 3600)),
            .init(providerName: "Codex", windowLabel: "5h", resetsAt: now.addingTimeInterval(4 * 3600)),
            .init(providerName: "Claude", windowLabel: "weekly", resetsAt: now.addingTimeInterval(-60)), // past
            .init(providerName: "Cursor", windowLabel: "cycle", resetsAt: nil), // unknown
        ]
        let next = OverviewSummary.nextReset(from: candidates, now: now)
        XCTAssertEqual(next?.providerName, "Claude")
        XCTAssertEqual(next?.windowLabel, "5h")
    }

    func testNextResetNilWhenNothingUpcoming() {
        XCTAssertNil(OverviewSummary.nextReset(from: [], now: now))
        XCTAssertNil(OverviewSummary.nextReset(
            from: [.init(providerName: "Claude", windowLabel: "5h", resetsAt: now.addingTimeInterval(-1))],
            now: now
        ))
    }

    // MARK: - shortCountdown

    func testShortCountdownFormats() {
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now), "2h 14m")
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(5 * 86_400 + 12 * 3600), now: now), "5d 12h")
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(8 * 60), now: now), "8m")
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(-5), now: now), "now")
    }
}
