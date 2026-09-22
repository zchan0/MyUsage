import XCTest
@testable import MyUsage

final class GatewayPresentationTests: XCTestCase {
    private let scope = GatewayScope(kind: .user, id: "fixture-user")

    func testZeroCostModelsAreHiddenAfterAggregationWithoutChangingTotals() {
        let history = GatewayHistory(scope: scope, startDate: "2026-09-01", endDate: "2026-09-02", days: [
            .init(date: "2026-09-01", metrics: .init(cost: 1, totalTokens: 300), models: [
                "free": .init(cost: 0, totalTokens: 100),
                "paid": .init(cost: 0, totalTokens: 100),
                "unpriced": .init(totalTokens: 100)
            ]),
            .init(date: "2026-09-02", metrics: .init(cost: 2, totalTokens: 200), models: [
                "free": .init(cost: 0, totalTokens: 100),
                "paid": .init(cost: 2, totalTokens: 100)
            ])
        ], complete: true)
        XCTAssertEqual(history.models.map(\.name), ["paid", "unpriced"])
        XCTAssertEqual(history.models.first?.metrics.cost, 2)
        XCTAssertEqual(history.totals.totalTokens, 500)
        XCTAssertEqual(history.totals.cost, 3)
    }

    func testSmallPositiveModelCostNeverLooksLikeZero() {
        XCTAssertEqual(GatewayFormatting.modelCost(Decimal(string: "0.000002")!), "<" + GatewayFormatting.money(Decimal(string: "0.01")!))
        XCTAssertEqual(GatewayFormatting.modelCost(Decimal(string: "0.01")!), GatewayFormatting.money(Decimal(string: "0.01")!))
    }

    func testFooterUsesOldestDisplayedSuccessfulDataAndPreservesItOnFailure() {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        var snapshot = GatewaySnapshot()
        snapshot.summary = .init(value: .init(scope: scope, spend: 10, budget: .finite(100), currency: "USD", budgetDuration: nil, resetsAt: nil), updatedAt: newDate)
        XCTAssertEqual(snapshot.displayUpdatedAt, newDate)
        snapshot.history = .init(value: .init(scope: scope, startDate: "2026-09-01", endDate: "2026-09-02", days: [], complete: true), updatedAt: oldDate)
        XCTAssertEqual(snapshot.displayUpdatedAt, oldDate)
        XCTAssertFalse(snapshot.hasDisplayIssue)
        snapshot.history.merge(.init(issue: .network))
        XCTAssertEqual(snapshot.displayUpdatedAt, oldDate)
        XCTAssertTrue(snapshot.hasDisplayIssue)
    }

    func testNeverLoadedOrForbiddenHistoryDoesNotInventARefreshTime() {
        var snapshot = GatewaySnapshot()
        XCTAssertNil(snapshot.displayUpdatedAt)
        snapshot.history = .init(updatedAt: .now, issue: .forbidden)
        XCTAssertNil(snapshot.displayUpdatedAt)
        XCTAssertFalse(snapshot.hasDisplayIssue)
    }
}
