import XCTest
@testable import MyUsage

/// Pooled Claude plans report no `weekly_scoped` caps, so the per-model rail is
/// derived from local cost instead. These pin the arithmetic and the window.
final class WeeklyModelSplitTests: XCTestCase {

    private static let resetsAt = ISO8601DateFormatter()
        .date(from: "2026-08-03T10:00:00Z")!

    /// `now` inside the window, two days before reset.
    private static let now = resetsAt.addingTimeInterval(-2 * 86400)

    private func day(_ key: String, total: Double, byModel: [String: Double]) -> LedgerStore.DailyCost {
        LedgerStore.DailyCost(day: key, totalUSD: total, byModel: byModel)
    }

    private func rows(_ series: [LedgerStore.DailyCost], weekly: Double = 40) -> [WeeklyModelUsage] {
        WeeklyModelSplit.rows(
            series: series,
            weeklyPercentUsed: weekly,
            weeklyResetsAt: Self.resetsAt,
            now: Self.now
        )
    }

    // MARK: - Shares

    func testSharesSumToWeeklyPercentAndSortDescending() {
        let result = rows([
            day("2026-07-29", total: 100, byModel: ["Fable": 75, "Opus": 25])
        ])

        XCTAssertEqual(result.map(\.label), ["Fable", "Opus"])
        XCTAssertEqual(result[0].percent, 30, accuracy: 0.001)
        XCTAssertEqual(result[1].percent, 10, accuracy: 0.001)
        XCTAssertEqual(result.map(\.percent).reduce(0, +), 40, accuracy: 0.001)
    }

    /// Rows share the weekly reset — they are a decomposition of that bar, not
    /// windows of their own, so the Weekly instrument's countdown and pace apply.
    func testRowsCarryTheWeeklyReset() {
        let result = rows([day("2026-07-29", total: 10, byModel: ["Fable": 10])])

        XCTAssertEqual(result.first?.resetsAt, Self.resetsAt)
    }

    /// Unattributed spend (pre-v2 ledger rows) inflates `totalUSD` only. Shares
    /// are taken over attributed cost so they still sum to the weekly figure.
    func testUnattributedSpendDoesNotDiluteShares() {
        let result = rows([
            day("2026-07-29", total: 1000, byModel: ["Fable": 60, "Opus": 40])
        ])

        XCTAssertEqual(result[0].percent, 24, accuracy: 0.001)
        XCTAssertEqual(result[1].percent, 16, accuracy: 0.001)
    }

    // MARK: - Window

    func testOnlyDaysInsideTheWeeklyWindowCount() {
        // Window is 2026-07-27T10:00Z → 2026-08-03T10:00Z.
        let result = rows([
            day("2026-07-26", total: 100, byModel: ["Stale": 100]),
            day("2026-07-28", total: 100, byModel: ["Fable": 100])
        ])

        XCTAssertEqual(result.map(\.label), ["Fable"])
    }

    /// The window opens mid-day, so its first UTC day is partially outside it.
    /// Day-granularity data cannot be split finer, and dropping the day would
    /// lose real usage — it is included, and the estimate is labelled as such.
    func testPartialFirstDayIsIncluded() {
        let result = rows([day("2026-07-27", total: 10, byModel: ["Fable": 10])])

        XCTAssertEqual(result.map(\.label), ["Fable"])
    }

    func testDaysAfterNowAreExcluded() {
        let result = rows([
            day("2026-07-29", total: 10, byModel: ["Fable": 10]),
            day("2026-08-02", total: 10, byModel: ["Future": 10])
        ])

        XCTAssertEqual(result.map(\.label), ["Fable"])
    }

    // MARK: - Empty results

    func testNoRowsWithoutWeeklyUsage() {
        XCTAssertTrue(rows([day("2026-07-29", total: 10, byModel: ["Fable": 10])], weekly: 0).isEmpty)
    }

    func testNoRowsWithoutAReset() {
        let result = WeeklyModelSplit.rows(
            series: [day("2026-07-29", total: 10, byModel: ["Fable": 10])],
            weeklyPercentUsed: 40,
            weeklyResetsAt: nil,
            now: Self.now
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testNoRowsWithoutPerModelAttribution() {
        XCTAssertTrue(rows([day("2026-07-29", total: 10, byModel: [:])]).isEmpty)
    }

    func testSlicesThatRoundToZeroAreDropped() {
        let result = rows([
            day("2026-07-29", total: 100, byModel: ["Fable": 999, "Dust": 1])
        ])

        XCTAssertEqual(result.map(\.label), ["Fable"], "a 0.04% row costs a line and says nothing")
    }
}
