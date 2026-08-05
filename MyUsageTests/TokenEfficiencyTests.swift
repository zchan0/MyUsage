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

    /// The headline is the latest day, not the window mean. An average over a
    /// month is the one window guaranteed to hide the anomaly this reading
    /// exists to catch.
    func testHeadlineIsTheLatestDayNotTheWindowAverage() {
        let series = (1...9).map {
            day(String(format: "2026-08-%02d", $0), cost: 1, input: 1_000_000)
        } + [day("2026-08-10", cost: 4, input: 1_000_000)]

        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: series))

        XCTAssertEqual(reading.effectiveRate, 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(reading.baselineRate), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(reading.deltaPercent), 300, accuracy: 1e-6,
                       "a 4x day must read as 4x, not as a few percent on a mean")
    }

    func testRatiosAreTakenOverTheRightDenominators() {
        // 100 output + 900 prompt (100 fresh input, 700 read, 100 re-cached).
        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: [
            day("2026-08-01", cost: 1,
                input: 100_000, output: 100_000, write1h: 100_000, read: 700_000)
        ]))

        XCTAssertEqual(reading.outputPercent, 10, accuracy: 1e-6,
                       "output is a share of all tokens")
        XCTAssertEqual(reading.totalTokens, 1_000_000)
        XCTAssertEqual(reading.generatedTokens, 100_000,
                       "the footnote reports counts, so they must be carried as counts")
        XCTAssertEqual(reading.reCachedTokens, 100_000)
    }

    /// One runaway day should not redefine what "usual" means.
    func testBaselineIsAMedianNotAMean() {
        let series = [1.0, 1.0, 1.0, 30.0].enumerated().map { index, cost in
            day(String(format: "2026-08-%02d", index + 1), cost: cost, input: 1_000_000)
        } + [day("2026-08-09", cost: 2, input: 1_000_000)]

        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: series))

        XCTAssertEqual(try XCTUnwrap(reading.baselineRate), 1, accuracy: 1e-9)
    }

    func testBaselineNeedsEnoughHistory() {
        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: [
            day("2026-08-01", cost: 1, input: 1_000_000),
            day("2026-08-02", cost: 2, input: 1_000_000)
        ]))

        XCTAssertNil(reading.baselineRate, "two prior days is not a baseline")
        XCTAssertNil(reading.deltaPercent)
    }

    func testThinLatestDayIsNotUsedAsTheHeadline() {
        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: [
            day("2026-08-01", cost: 2, input: 1_000_000),
            day("2026-08-02", cost: 5, input: 1_000)      // two requests; noise
        ]))

        XCTAssertEqual(reading.effectiveRate, 2, accuracy: 1e-9,
                       "a 1k-token day would headline at $5000/Mtok")
    }

    func testDaysWithoutTokenAttributionAreExcluded() {
        let reading = TokenEfficiency.reading(from: [
            day("2026-07-30", cost: 999),               // pre-attribution row
            day("2026-08-01", cost: 2, input: 1_000_000)
        ])

        XCTAssertEqual(try XCTUnwrap(reading).effectiveRate, 2, accuracy: 1e-9,
                       "a costed day with no tokens would otherwise inflate the rate")
    }

    func testNoUsableDaysYieldsNoReading() {
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

    // MARK: - Headline day identity

    /// A quiet stretch drops every recent day below the volume floor, so the
    /// headline falls back to the last day with real volume. Presenting that
    /// as "today" misreports the reading.
    func testHeadlineCarriesTheDayItActuallyDescribes() {
        let reading = try! XCTUnwrap(TokenEfficiency.reading(
            from: [
                day("2026-08-01", cost: 2, input: 1_000_000),
                day("2026-08-05", cost: 0.01, input: 1_000)     // below the floor
            ],
            today: "2026-08-05"
        ))

        XCTAssertEqual(reading.day, "2026-08-01")
        XCTAssertFalse(reading.isCurrentDay,
                       "four-day-old numbers must not be labelled today")
    }

    func testCurrentDayIsFlaggedWhenItClearsTheFloor() {
        let reading = try! XCTUnwrap(TokenEfficiency.reading(
            from: [day("2026-08-05", cost: 2, input: 1_000_000)],
            today: "2026-08-05"
        ))

        XCTAssertTrue(reading.isCurrentDay)
    }

    // MARK: - Cache TTL state

    func testAllOneHourWritesReadAsStandard() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-08-01", cost: 1, write1h: 1_000_000)
        ], today: "2026-08-01")

        XCTAssertEqual(state, .standard)
    }

    func testSustainedShortLivedWritesReadAsDowngraded() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-08-01", cost: 1, write5m: 400_000, write1h: 600_000)
        ], today: "2026-08-01")

        XCTAssertEqual(state, .downgraded(sharePercent: 40))
    }

    /// A session that happens to straddle a quota boundary contributes a sliver
    /// of 5-minute writes; that is not a degraded state worth alerting on.
    func testSliverOfShortLivedWritesStaysStandard() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-08-01", cost: 1, write5m: 50_000, write1h: 1_000_000)
        ], today: "2026-08-01")

        XCTAssertEqual(state, .standard)
    }

    /// Transcripts predating the per-TTL split land wholly in the 5-minute
    /// bucket. Reporting that as a downgrade would alarm every user on old
    /// data, so it is explicitly not knowable.
    func testAllShortLivedWritesWithNoSplitAnywhereIsUnknown() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-05-31", cost: 1, write5m: 2_000_000),
            day("2026-06-01", cost: 1, write5m: 1_000_000)
        ], today: "2026-06-01")

        XCTAssertEqual(state, .unknown)
    }

    /// ...but once the account has produced 1-hour writes, its transcripts
    /// demonstrably carry the split, so an all-5m day is a real all-day
    /// downgrade rather than missing data.
    func testAllShortLivedWritesAreADowngradeOnceTheSplitIsObservable() {
        let state = TokenEfficiency.ttlState(from: [
            day("2026-07-30", cost: 1, write1h: 2_000_000),
            day("2026-08-01", cost: 1, write5m: 1_000_000)
        ], today: "2026-08-01")

        XCTAssertEqual(state, .downgraded(sharePercent: 100))
    }

    func testNoCacheWritesIsUnknown() {
        XCTAssertEqual(
            TokenEfficiency.ttlState(from: [day("2026-08-01", cost: 1, input: 500)],
                                     today: "2026-08-01"),
            .unknown
        )
    }

    /// A day that has barely started carries too few writes for the ratio to
    /// mean anything — one context rebuild can be the whole sample.
    func testTooFewWritesToJudgeIsUnknown() {
        XCTAssertEqual(
            TokenEfficiency.ttlState(from: [
                day("2026-08-01", cost: 1, write5m: 80_000, write1h: 20_000)
            ], today: "2026-08-01"),
            .unknown
        )
    }

    // MARK: - Cache TTL staleness

    /// Regression: the notice answers "am I degraded **now**", and the window
    /// that answers it was "the last two rows of the series" — rows, not days.
    /// A gap in usage pinned the verdict to whenever the user last worked hard,
    /// so a downgrade from four days ago stayed on screen indefinitely.
    func testDowngradeOnAnEarlierDayDoesNotSurviveIntoToday() {
        let series = [
            day("2026-07-31", cost: 1, input: 1_000_000, write5m: 1_500_000, write1h: 1_700_000),
            day("2026-08-01", cost: 1, input: 1_000_000, write5m: 2_600_000, write1h: 5_000_000),
            // Three days off, then a clean day.
            day("2026-08-05", cost: 1, input: 1_000_000, write1h: 600_000)
        ]

        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: series, today: "2026-08-05"))

        XCTAssertEqual(reading.cacheTTL, .standard,
                       "today has no short-lived writes; the alert is about today")
    }

    /// The same staleness bug in its other form: the old window summed write
    /// volume across days, so a heavy downgraded day outweighed a light clean
    /// one by 50:1 and the verdict could not be cleared by working normally.
    func testCleanCurrentDayIsNotOutweighedByAHeavierDowngradedOne() {
        let series = [
            day("2026-08-01", cost: 1, input: 1_000_000, write5m: 2_600_000, write1h: 5_000_000),
            day("2026-08-02", cost: 1, input: 1_000_000, write1h: 600_000)
        ]

        XCTAssertEqual(
            TokenEfficiency.ttlState(from: series, today: "2026-08-02"), .standard
        )
    }

    /// A live downgrade must still be reported, and must not be diluted by a
    /// month of healthy history behind it.
    func testLiveDowngradeIsNotDilutedByAMonthOfHealthyHistory() {
        var series = (1...28).map {
            day(String(format: "2026-07-%02d", $0), cost: 1,
                input: 1_000_000, write1h: 1_000_000)
        }
        series.append(day("2026-07-31", cost: 1, input: 1_000_000,
                          write5m: 400_000, write1h: 600_000))

        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: series, today: "2026-07-31"))

        XCTAssertEqual(reading.cacheTTL, .downgraded(sharePercent: 40))
    }

    /// The current day may be too thin to headline the rate and still carry
    /// plenty of cache writes. The TTL verdict has its own floor and must not
    /// inherit the rate's.
    func testTTLVerdictIsNotGatedOnTheRateVolumeFloor() {
        let series = [
            day("2026-08-01", cost: 5, input: 5_000_000, write1h: 2_000_000),
            // No cost recorded yet, so this day never enters `usable`.
            day("2026-08-02", cost: 0, write5m: 900_000, write1h: 100_000)
        ]

        let reading = try! XCTUnwrap(TokenEfficiency.reading(from: series, today: "2026-08-02"))

        XCTAssertEqual(reading.day, "2026-08-01", "the rate still comes from the last real day")
        XCTAssertEqual(reading.cacheTTL, .downgraded(sharePercent: 90),
                       "but the TTL verdict is read off today")
    }
}
