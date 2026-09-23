import XCTest
@testable import MyUsage

final class OverviewSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testShortCountdownFormats() {
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now), "2h 14m")
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(5 * 86_400 + 12 * 3600), now: now), "5d 12h")
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(8 * 60), now: now), "8m")
        XCTAssertEqual(OverviewSummary.shortCountdown(until: now.addingTimeInterval(-5), now: now), "now")
    }
}
