import XCTest
@testable import MyUsage

/// The extra-usage window is derived, not reported — the API carries no reset
/// or period field. These pin the derivation so a wrong boundary fails loudly.
final class ExtraUsagePeriodTests: XCTestCase {

    private func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - Bounds

    func testBoundsCoverTheUTCCalendarMonth() {
        let (start, end) = ExtraUsagePeriod.bounds(now: utc("2026-08-14T09:30:00Z"))

        XCTAssertEqual(start, utc("2026-08-01T00:00:00Z"))
        XCTAssertEqual(end, utc("2026-09-01T00:00:00Z"))
    }

    /// The observed rollover: still spending late on 7-31, zeroed on 8-1.
    func testBoundsFlipAtTheObservedResetInstant() {
        let before = ExtraUsagePeriod.bounds(now: utc("2026-07-31T18:00:00Z"))
        let after = ExtraUsagePeriod.bounds(now: utc("2026-08-01T00:00:00Z"))

        XCTAssertEqual(before.end, utc("2026-08-01T00:00:00Z"))
        XCTAssertEqual(after.start, utc("2026-08-01T00:00:00Z"))
    }

    func testMonthLengthsVaryWithTheCalendar() {
        let feb = ExtraUsagePeriod.bounds(now: utc("2028-02-10T00:00:00Z"))
        XCTAssertEqual(feb.end, utc("2028-03-01T00:00:00Z"), "leap February is 29 days")

        let dec = ExtraUsagePeriod.bounds(now: utc("2026-12-20T00:00:00Z"))
        XCTAssertEqual(dec.end, utc("2027-01-01T00:00:00Z"), "December rolls the year")
    }

    // MARK: - Window

    func testWindowResetsAtPeriodEndWithFullMonthDuration() {
        let window = ExtraUsagePeriod.window(percentUsed: 50, now: utc("2026-08-16T00:00:00Z"))

        XCTAssertEqual(window.resetsAt, utc("2026-09-01T00:00:00Z"))
        XCTAssertEqual(window.windowDuration, 31 * 86_400)
    }

    // MARK: - Projection

    func testProjectionExtrapolatesToTheFullMonth() {
        // Half of a 31-day August elapsed, $100 spent → ~$200 by reset.
        let projected = ExtraUsagePeriod.projectedSpend(
            spent: 100,
            now: utc("2026-08-16T12:00:00Z")
        )

        XCTAssertEqual(try XCTUnwrap(projected), 200, accuracy: 0.001)
    }

    /// Early in the month a small spend extrapolates to an absurd figure, so
    /// the projection stays hidden until the rate means something.
    func testNoProjectionEarlyInThePeriod() {
        XCTAssertNil(ExtraUsagePeriod.projectedSpend(
            spent: 40,
            now: utc("2026-08-02T00:00:00Z")
        ))
    }

    func testProjectionOpensAfterTheReliabilityGate() {
        XCTAssertNotNil(ExtraUsagePeriod.projectedSpend(
            spent: 40,
            now: utc("2026-08-09T00:00:00Z")
        ))
    }

    /// A fresh period — exactly today's state — has nothing to project.
    func testNoProjectionWithoutSpend() {
        XCTAssertNil(ExtraUsagePeriod.projectedSpend(
            spent: 0,
            now: utc("2026-08-20T00:00:00Z")
        ))
    }
}
