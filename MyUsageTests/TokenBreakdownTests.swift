import Testing
import Foundation
@testable import MyUsage

@Suite("TokenBreakdown")
struct TokenBreakdownTests {

    @Test("realTotal sums all four buckets including cacheRead")
    func realTotalIncludesCacheRead() {
        let b = TokenBreakdown(
            freshInput: 100, output: 200,
            cacheCreation: 50, cacheRead: 1_000,
            preComputedCost: 0
        )
        #expect(b.realTotal == 1_350)
    }

    @Test("cacheableInput excludes output")
    func cacheableExcludesOutput() {
        let b = TokenBreakdown(
            freshInput: 100, output: 9_999_999,
            cacheCreation: 50, cacheRead: 1_000,
            preComputedCost: 0
        )
        #expect(b.cacheableInput == 1_150)
    }

    @Test("cacheHitRate uses cache_read / cacheable")
    func cacheHitRateMath() {
        // 800 / (100 + 100 + 800) = 0.8
        let b = TokenBreakdown(
            freshInput: 100, output: 5_000,
            cacheCreation: 100, cacheRead: 800,
            preComputedCost: 0
        )
        #expect(abs(b.cacheHitRate - 0.8) < 1e-9)
    }

    @Test("cacheHitRate returns 0 (not NaN) on zero-token input")
    func cacheHitRateZeroSafe() {
        let b = TokenBreakdown.empty
        #expect(b.cacheHitRate == 0)
        #expect(!b.cacheHitRate.isNaN)
    }

    @Test("cacheHitRate is 0 when only output is non-zero")
    func cacheHitRateOutputOnly() {
        let b = TokenBreakdown(
            freshInput: 0, output: 1_000,
            cacheCreation: 0, cacheRead: 0,
            preComputedCost: 0
        )
        #expect(b.cacheHitRate == 0)
    }

    @Test("isEmpty true only when nothing was billed")
    func isEmptyReports() {
        #expect(TokenBreakdown.empty.isEmpty)
        var b = TokenBreakdown.empty
        b.preComputedCost = 0.01
        #expect(!b.isEmpty)
        b = TokenBreakdown.empty
        b.cacheRead = 1
        #expect(!b.isEmpty)
    }
}
