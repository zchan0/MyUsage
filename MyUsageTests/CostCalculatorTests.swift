import Testing
import Foundation
@testable import MyUsage

@Suite("CostCalculator Tests")
struct CostCalculatorTests {

    // MARK: - Helpers

    private func catalog() -> PricingCatalog {
        let json = """
        {
          "version": 1,
          "models": {
            "claude-sonnet-4-5": { "input": 3.00, "output": 15.00, "cache_write": 3.75, "cache_read": 0.30 },
            "gpt-5-codex":       { "input": 1.25, "output": 10.00, "cached_input": 0.125 }
          }
        }
        """.data(using: .utf8)!
        return try! PricingCatalog.load(from: json)
    }

    // MARK: - Anthropic formula

    @Test("Claude: pure input + output cost")
    func claudePlainCost() {
        let usage = TokenUsage(input: 1_000_000, output: 100_000)
        let cost = CostCalculator.cost(usage: usage, model: "claude-sonnet-4-5", catalog: catalog())
        // 1M * $3 = $3.00 ; 0.1M * $15 = $1.50 ; total $4.50
        #expect(abs(cost - 4.50) < 1e-6)
    }

    @Test("Claude: cache read costs 10x less than input")
    func claudeCacheRead() {
        let usage = TokenUsage(input: 0, output: 0, cacheWrite: 0, cacheRead: 1_000_000)
        let cost = CostCalculator.cost(usage: usage, model: "claude-sonnet-4-5", catalog: catalog())
        // 1M * $0.30 = $0.30
        #expect(abs(cost - 0.30) < 1e-6)
    }

    @Test("Claude: cache write costs 1.25x input")
    func claudeCacheWrite() {
        let usage = TokenUsage(input: 0, output: 0, cacheWrite: 1_000_000, cacheRead: 0)
        let cost = CostCalculator.cost(usage: usage, model: "claude-sonnet-4-5", catalog: catalog())
        // 1M * $3.75 = $3.75
        #expect(abs(cost - 3.75) < 1e-6)
    }

    @Test("Claude: combined fields")
    func claudeCombined() {
        let usage = TokenUsage(input: 100_000, output: 20_000, cacheWrite: 50_000, cacheRead: 200_000)
        let cost = CostCalculator.cost(usage: usage, model: "claude-sonnet-4-5", catalog: catalog())
        let expected = 100_000.0 * 3.00  / 1e6
                     +  20_000.0 * 15.00 / 1e6
                     +  50_000.0 * 3.75  / 1e6
                     + 200_000.0 * 0.30  / 1e6
        #expect(abs(cost - expected) < 1e-6)
    }

    // MARK: - OpenAI formula

    @Test("Codex: pure input + output cost (no cache)")
    func codexPlainCost() {
        let usage = TokenUsage(input: 1_000_000, output: 100_000)
        let cost = CostCalculator.cost(usage: usage, model: "gpt-5-codex", catalog: catalog())
        // 1M * $1.25 + 0.1M * $10 = $1.25 + $1.00 = $2.25
        #expect(abs(cost - 2.25) < 1e-6)
    }

    @Test("Codex: cached input at 10% of input rate")
    func codexCachedInput() {
        let usage = TokenUsage(input: 0, output: 0, cachedInput: 1_000_000)
        let cost = CostCalculator.cost(usage: usage, model: "gpt-5-codex", catalog: catalog())
        // 1M * $0.125 = $0.125
        #expect(abs(cost - 0.125) < 1e-6)
    }

    @Test("Codex: Anthropic-only fields are ignored")
    func codexIgnoresCacheWriteRead() {
        // gpt-5-codex has no cache_write/cache_read entries — these must not be counted
        let usage = TokenUsage(input: 0, output: 0, cacheWrite: 999_999, cacheRead: 999_999)
        let cost = CostCalculator.cost(usage: usage, model: "gpt-5-codex", catalog: catalog())
        #expect(cost == 0)
    }

    // MARK: - Missing pricing

    @Test("Unknown model → cost = 0")
    func unknownModel() {
        let usage = TokenUsage(input: 100, output: 100)
        let cost = CostCalculator.cost(usage: usage, model: "mystery-pro-9000", catalog: catalog())
        #expect(cost == 0)
    }

    // MARK: - Aggregation

    @Test("totalCost sums across multiple models")
    func totalAcrossModels() {
        let byModel: UsageByModel = [
            "claude-sonnet-4-5": TokenUsage(input: 1_000_000, output: 100_000),
            "gpt-5-codex":       TokenUsage(input: 1_000_000, output: 100_000)
        ]
        let total = CostCalculator.totalCost(of: byModel, catalog: catalog())
        #expect(abs(total - (4.50 + 2.25)) < 1e-6)
    }

    @Test("totalCost skips unknown models silently")
    func totalWithUnknown() {
        let byModel: UsageByModel = [
            "claude-sonnet-4-5": TokenUsage(input: 1_000_000, output: 0),
            "unknown-model":     TokenUsage(input: 10_000_000, output: 0)
        ]
        let total = CostCalculator.totalCost(of: byModel, catalog: catalog())
        #expect(abs(total - 3.00) < 1e-6)
    }

    // MARK: - TokenUsage math

    @Test("TokenUsage + adds all fields")
    func tokenUsageAddition() {
        let a = TokenUsage(input: 10, output: 20, cacheWrite: 30, cacheRead: 40, cachedInput: 50)
        let b = TokenUsage(input: 1,  output: 2,  cacheWrite: 3,  cacheRead: 4,  cachedInput: 5)
        let sum = a + b
        #expect(sum == TokenUsage(input: 11, output: 22, cacheWrite: 33, cacheRead: 44, cachedInput: 55))
    }

    @Test("Dictionary.add merges into existing key")
    func dictAddMerges() {
        var byModel: UsageByModel = [:]
        byModel.add(TokenUsage(input: 100), for: "claude-sonnet-4-5")
        byModel.add(TokenUsage(input: 50, output: 5), for: "claude-sonnet-4-5")
        #expect(byModel["claude-sonnet-4-5"] == TokenUsage(input: 150, output: 5))
    }
}
