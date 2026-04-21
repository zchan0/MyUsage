import XCTest
@testable import MyUsage

final class RetryAfterParserTests: XCTestCase {
    func testParsesIntegerSeconds() {
        XCTAssertEqual(RetryAfterParser.seconds(from: "30"), 30)
    }

    func testParsesZeroSeconds() {
        XCTAssertEqual(RetryAfterParser.seconds(from: "0"), 0)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(RetryAfterParser.seconds(from: "  45  "), 45)
    }

    func testRejectsNegativeSeconds() {
        XCTAssertNil(RetryAfterParser.seconds(from: "-10"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(RetryAfterParser.seconds(from: ""))
        XCTAssertNil(RetryAfterParser.seconds(from: "   "))
    }

    func testRejectsGarbage() {
        XCTAssertNil(RetryAfterParser.seconds(from: "soon"))
    }

    func testParsesHTTPDateInFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let future = "Tue, 14 Nov 2023 22:14:20 GMT" // +60s
        let delta = RetryAfterParser.seconds(from: future, now: now)
        XCTAssertNotNil(delta)
        XCTAssertEqual(delta ?? 0, 60, accuracy: 1)
    }

    func testHTTPDateInPastClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = "Tue, 14 Nov 2023 22:00:00 GMT" // 13m 20s before `now`
        XCTAssertEqual(RetryAfterParser.seconds(from: past, now: now), 0)
    }
}
