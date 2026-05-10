import XCTest
@testable import MyUsage

final class AccountSnapshotTests: XCTestCase {

    func testRoundTripThroughUsageSnapshot() {
        var live = UsageSnapshot()
        live.planName = "Max"
        live.sessionUsage = UsageWindow(
            percentUsed: 47, resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowDuration: 5 * 3600
        )
        live.weeklyUsage = UsageWindow(
            percentUsed: 62, resetsAt: Date(timeIntervalSince1970: 1_800_500_000),
            windowDuration: 7 * 86_400
        )
        live.weeklyByModel = [
            WeeklyModelUsage(label: "Sonnet", percent: 38),
            WeeklyModelUsage(label: "Opus", percent: 24)
        ]
        live.spentAmount = CreditInfo(amount: 12.34, limit: 50, currency: "USD")
        live.onDemandSpend = CreditInfo(amount: 4.56, limit: 100, currency: "USD")
        live.monthlyEstimatedCost = 321.00

        let captured = Date(timeIntervalSince1970: 1_780_000_000)
        let snap = AccountSnapshot(from: live, capturedAt: captured)

        // Encode → decode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(snap)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try! decoder.decode(AccountSnapshot.self, from: data)

        let restored = decoded.asUsageSnapshot
        XCTAssertEqual(restored.planName, "Max")
        XCTAssertEqual(restored.sessionUsage?.percentUsed, 47)
        XCTAssertEqual(restored.sessionUsage?.windowDuration, 5 * 3600)
        XCTAssertEqual(restored.weeklyUsage?.percentUsed, 62)
        XCTAssertEqual(restored.weeklyByModel.count, 2)
        XCTAssertEqual(restored.weeklyByModel.first?.label, "Sonnet")
        XCTAssertEqual(restored.spentAmount?.amount, 12.34)
        XCTAssertEqual(restored.spentAmount?.limit, 50)
        XCTAssertEqual(restored.onDemandSpend?.amount, 4.56)
        XCTAssertEqual(restored.monthlyEstimatedCost, 321.00)
        XCTAssertEqual(restored.lastRefreshed, captured)
    }

    func testEmptyLiveSnapshotProducesEmptySerialized() {
        let snap = AccountSnapshot(from: UsageSnapshot())
        XCTAssertNil(snap.sessionPercent)
        XCTAssertNil(snap.weeklyPercent)
        XCTAssertNil(snap.spentAmount)
        XCTAssertEqual(snap.weeklyByModel.count, 0)
    }
}
