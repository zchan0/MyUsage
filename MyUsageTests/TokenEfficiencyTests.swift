import XCTest
@testable import MyUsage

final class TokenEfficiencyTests: XCTestCase {

    private func day(
        _ key: String,
        cost: Double,
        input: Int = 0,
        output: Int = 0,
        write5m: Int = 0,
        write1h: Int = 0,
        read: Int = 0
    ) -> LedgerStore.DailyCost {
        LedgerStore.DailyCost(
            day: key, totalUSD: cost, byModel: [:],
            tokens: TokenUsage(
                input: input, output: output,
                cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: read
            )
        )
    }

    // MARK: - Rate and ratios

    func testEffectiveRateIsDollarsPerMillionTokens() {
        let reading = TokenEfficiency.reading(from: [
            day("2026-08-01", cost: 4, input: 1_000_000, output: 1_000_000)
        ])

        XCTAssertEqual(try XCTUnwrap(reading).effectiveRate, 2, accuracy: 1e-9)
    }

    func testRatiosAreTakenOverTheRightDenominators() {
        // 100 output + 900 prompt (100 fresh input, 700 read, 100 re-cached).
        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: [
            day("2026-08-01", cost: 1,
                input: 100, output: 100, write1h: 100, read: 700)
        ]))

        XCTAssertEqual(reading.cacheHitPercent, 700.0 / 900 * 100, accuracy: 1e-6,
                       "hits are a share of prompt tokens, not of everything")
        XCTAssertEqual(reading.reCachePercent, 100.0 / 900 * 100, accuracy: 1e-6)
        XCTAssertEqual(reading.outputPercent, 10, accuracy: 1e-6,
                       "output is a share of all tokens")
        XCTAssertEqual(reading.totalTokens, 1_000)
    }

    func testDaysWithoutTokenAttributionAreExcluded() {
        let reading = TokenEfficiency.reading(from: [
            day("2026-07-30", cost: 999),               // pre-attribution row
            day("2026-08-01", cost: 2, input: 1_000_000)
        ])

        XCTAssertEqual(try XCTUnwrap(reading).effectiveRate, 2, accuracy: 1e-9,
                       "a costed day with no tokens would otherwise inflate the rate")
    }

    func testNoAttributedDaysYieldsNoReading() {
        XCTAssertNil(TokenEfficiency.reading(from: [day("2026-08-01", cost: 5)]))
        XCTAssertNil(TokenEfficiency.reading(from: []))
    }

    // MARK: - Sparkline series

    func testThinDaysAreDroppedFromTheSeries() {
        let rates = TokenEfficiency.dailyRates(from: [
            day("2026-07-30", cost: 5, input: 1_000),       // one request; noise
            day("2026-07-31", cost: 2, input: 1_000_000),
            day("2026-08-01", cost: 4, input: 1_000_000)
        ], limit: 14)

        XCTAssertEqual(rates, [2, 4], "a 1k-token day would plot at $5000/Mtok")
    }

    func testSeriesKeepsTheMostRecentDays() {
        let series = (1...20).map {
            day(String(format: "2026-08-%02d", $0), cost: Double($0), input: 1_000_000)
        }

        let rates = TokenEfficiency.dailyRates(from: series, limit: 14)

        XCTAssertEqual(rates.count, 14)
        XCTAssertEqual(rates.last, 20, "newest day is last")
        XCTAssertEqual(rates.first, 7)
    }

    // MARK: - Cache TTL state

    func testAllOneHourWritesReadAsStandard() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-08-01", cost: 1, write1h: 1_000_000)
        ])

        XCTAssertEqual(state, .standard)
    }

    func testSustainedShortLivedWritesReadAsDowngraded() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-08-01", cost: 1, write5m: 400_000, write1h: 600_000)
        ])

        XCTAssertEqual(state, .downgraded(sharePercent: 40))
    }

    /// A session that happens to straddle a quota boundary contributes a sliver
    /// of 5-minute writes; that is not a degraded state worth alerting on.
    func testSliverOfShortLivedWritesStaysStandard() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-08-01", cost: 1, write5m: 50_000, write1h: 1_000_000)
        ])

        XCTAssertEqual(state, .standard)
    }

    /// Transcripts predating the per-TTL split land wholly in the 5-minute
    /// bucket. Reporting that as a downgrade would alarm every user on old
    /// data, so it is explicitly not knowable.
    func testLegacyDataWithNoOneHourVolumeIsUnknown() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-06-01", cost: 1, write5m: 1_000_000)
        ])

        XCTAssertEqual(state, .unknown)
    }

    func testNoCacheWritesIsUnknown() {
        XCTAssertEqual(
            TokenEfficiency.ttlState(from: [day("2026-08-01", cost: 1, input: 500)]),
            .unknown
        )
    }

    /// Regression: the notice answers "am I degraded now". Averaged over a
    /// month, a live downgrade dilutes below the threshold and the alert
    /// silently never fires — which is exactly what happened on first build.
    func testLiveDowngradeIsNotDilutedByAMonthOfHealthyHistory() {
        var series = (1...28).map {
            day(String(format: "2026-07-%02d", $0), cost: 1,
                input: 1_000_000, write1h: 1_000_000)
        }
        series.append(day("2026-07-31", cost: 1, input: 1_000_000,
                          write5m: 400_000, write1h: 600_000))
        series.append(day("2026-08-01", cost: 1, input: 1_000_000,
                          write5m: 400_000, write1h: 600_000))

        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: series))

        XCTAssertEqual(reading.cacheTTL, .downgraded(sharePercent: 40))
        XCTAssertEqual(
            TokenEfficiency.ttlState(from: series), .standard,
            "the whole-window view is what dilutes it — that is why reading() scopes to recent days"
        )
    }
}
