import XCTest
@testable import MyUsage

/// Claude's two prompt-cache TTLs bill differently — 1.25× input for the
/// 5-minute cache, 2× for the 1-hour one. Claude Code writes with the 1-hour
/// TTL by default, so collapsing the two priced most Claude cache writes at
/// the cheaper rate. These pin the split end to end: log → tokens → dollars.
final class CacheTTLPricingTests: XCTestCase {

    /// Fable's published rates: $10 input, $12.50 5m write, $20 1h write.
    private var catalog: PricingCatalog {
        PricingCatalog(file: PricingFile(version: 1, updated: nil, models: [
            "claude-fable-5": ModelPricing(
                input: 10, output: 50,
                cacheWrite: 12.5, cacheWrite1h: 20, cacheRead: 1
            ),
            "no-1h-rate": ModelPricing(
                input: 10, output: 50,
                cacheWrite: 12.5, cacheWrite1h: nil, cacheRead: 1
            )
        ]))
    }

    // MARK: - Pricing

    func testEachTTLBucketIsPricedAtItsOwnRate() {
        let usage = TokenUsage(
            input: 0, output: 0,
            cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 0
        )

        let cost = CostCalculator.cost(usage: usage, model: "claude-fable-5", catalog: catalog)

        XCTAssertEqual(cost, 32.5, accuracy: 1e-9, "1M at $12.50 + 1M at $20.00")
    }

    /// The regression this whole change exists for: 1-hour writes charged at
    /// the 5-minute rate come out 37.5% light.
    func testOneHourWritesAreNotChargedAtTheFiveMinuteRate() {
        let usage = TokenUsage(
            input: 0, output: 0,
            cacheWrite5m: 0, cacheWrite1h: 1_000_000, cacheRead: 0
        )

        let cost = CostCalculator.cost(usage: usage, model: "claude-fable-5", catalog: catalog)

        XCTAssertEqual(cost, 20, accuracy: 1e-9)
        XCTAssertNotEqual(cost, 12.5, "would be the old, undercounting behaviour")
    }

    /// A price table that predates the 1-hour field must not drop the tokens.
    func testMissingOneHourRateFallsBackToTheFiveMinuteRate() {
        let usage = TokenUsage(
            input: 0, output: 0,
            cacheWrite5m: 0, cacheWrite1h: 1_000_000, cacheRead: 0
        )

        let cost = CostCalculator.cost(usage: usage, model: "no-1h-rate", catalog: catalog)

        XCTAssertEqual(cost, 12.5, accuracy: 1e-9)
    }

    // MARK: - Parsing

    private func tokens(_ jsonl: String) -> TokenUsage {
        var acc = ClaudeLogParser.Breakdown()
        ClaudeLogParser.parseBreakdown(data: Data(jsonl.utf8), into: &acc)
        return acc.tokensByModel["claude-fable-5"] ?? .zero
    }

    func testCacheCreationBreakdownIsSplitByTTL() {
        let usage = tokens("""
        {"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":24704,"cache_read_input_tokens":100,"cache_creation":{"ephemeral_1h_input_tokens":24704,"ephemeral_5m_input_tokens":0}}}}
        """)

        XCTAssertEqual(usage.cacheWrite1h, 24_704)
        XCTAssertEqual(usage.cacheWrite5m, 0)
        XCTAssertEqual(usage.cacheWrite, 24_704, "combined view still reports the total")
    }

    /// The server downgrades a session to the 5-minute TTL once the 5-hour
    /// quota is exhausted; both buckets can appear in one scan.
    func testDowngradedSessionLandsInTheFiveMinuteBucket() {
        let usage = tokens("""
        {"type":"assistant","message":{"model":"claude-fable-5","usage":{"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":8000}}}}
        {"type":"assistant","message":{"model":"claude-fable-5","usage":{"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":2000,"ephemeral_5m_input_tokens":0}}}}
        """)

        XCTAssertEqual(usage.cacheWrite5m, 8_000)
        XCTAssertEqual(usage.cacheWrite1h, 2_000)
    }

    /// Older transcripts carry only the flat total. Charging it at the 1-hour
    /// rate would revalue history upward on a guess, so it goes to 5m.
    func testTranscriptWithoutTheBreakdownFallsBackToFiveMinute() {
        let usage = tokens("""
        {"type":"assistant","message":{"model":"claude-fable-5","usage":{"output_tokens":1,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0}}}
        """)

        XCTAssertEqual(usage.cacheWrite5m, 5_000)
        XCTAssertEqual(usage.cacheWrite1h, 0)
    }

    // MARK: - Ledger round-trip

    func testTTLSplitSurvivesEncodingAndDecoding() throws {
        let original = TokenUsage(
            input: 1, output: 2,
            cacheWrite5m: 30, cacheWrite1h: 40, cacheRead: 5, cachedInput: 6
        )

        let decoded = try JSONDecoder().decode(
            TokenUsage.self, from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    /// Ledger rows written before the split carry only `cacheWrite`.
    func testLegacyLedgerRowDecodesIntoTheFiveMinuteBucket() throws {
        let legacy = Data("""
        {"input":1,"output":2,"cacheWrite":900,"cacheRead":5,"cachedInput":0}
        """.utf8)

        let decoded = try JSONDecoder().decode(TokenUsage.self, from: legacy)

        XCTAssertEqual(decoded.cacheWrite5m, 900)
        XCTAssertEqual(decoded.cacheWrite1h, 0)
        XCTAssertEqual(decoded.cacheWrite, 900)
    }

    /// An older build reading a new row must still see the cache-write volume.
    func testEncodedRowStillCarriesTheCombinedLegacyField() throws {
        let usage = TokenUsage(
            input: 0, output: 0, cacheWrite5m: 30, cacheWrite1h: 40, cacheRead: 0
        )

        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(usage)
        ) as? [String: Any]

        XCTAssertEqual(json?["cacheWrite"] as? Int, 70)
    }
}
