import Testing
import Foundation
@testable import MyUsage

@Suite("PricingCatalog Tests")
struct PricingCatalogTests {

    // MARK: - Helpers

    private func makeCatalog() -> PricingCatalog {
        let json = """
        {
          "version": 1,
          "updated": "2026-04-17",
          "models": {
            "claude-sonnet-4-5": { "input": 3.00, "output": 15.00, "cache_write": 3.75, "cache_read": 0.30 },
            "claude-opus-4-5":   { "input": 15.0, "output": 75.00, "cache_write": 18.75, "cache_read": 1.50 },
            "gpt-5-codex":       { "input": 1.25, "output": 10.00, "cached_input": 0.125 }
          }
        }
        """.data(using: .utf8)!
        return try! PricingCatalog.load(from: json)
    }

    // MARK: - Parsing

    @Test("Loads model count and metadata")
    func loadMetadata() {
        let catalog = makeCatalog()
        #expect(catalog.version == 1)
        #expect(catalog.updated == "2026-04-17")
        #expect(catalog.modelCount == 3)
    }

    @Test("Parses Anthropic cache fields")
    func anthropicCacheFields() {
        let catalog = makeCatalog()
        let pricing = catalog.pricing(for: "claude-sonnet-4-5")
        #expect(pricing?.input == 3.0)
        #expect(pricing?.output == 15.0)
        #expect(pricing?.cacheWrite == 3.75)
        #expect(pricing?.cacheRead == 0.30)
        #expect(pricing?.cachedInput == nil)
    }

    @Test("Parses OpenAI cached_input field")
    func openaiCachedInput() {
        let catalog = makeCatalog()
        let pricing = catalog.pricing(for: "gpt-5-codex")
        #expect(pricing?.input == 1.25)
        #expect(pricing?.output == 10.0)
        #expect(pricing?.cachedInput == 0.125)
        #expect(pricing?.cacheWrite == nil)
        #expect(pricing?.cacheRead == nil)
    }

    // MARK: - Prefix matching

    @Test("Exact model name hits")
    func exactMatch() {
        let catalog = makeCatalog()
        #expect(catalog.pricing(for: "claude-sonnet-4-5") != nil)
    }

    @Test("Prefix match for -thinking suffix")
    func prefixMatchThinking() {
        let catalog = makeCatalog()
        let pricing = catalog.pricing(for: "claude-sonnet-4-5-thinking")
        #expect(pricing?.input == 3.0)
    }

    @Test("Longest prefix wins when multiple keys match")
    func longestPrefixWins() {
        let json = """
        {
          "version": 1,
          "models": {
            "claude":            { "input": 100, "output": 100 },
            "claude-sonnet":     { "input": 50,  "output": 50 },
            "claude-sonnet-4-5": { "input": 3,   "output": 15 }
          }
        }
        """.data(using: .utf8)!
        let catalog = try! PricingCatalog.load(from: json)
        let pricing = catalog.pricing(for: "claude-sonnet-4-5-thinking")
        #expect(pricing?.input == 3)
    }

    @Test("Case-insensitive lookup")
    func caseInsensitive() {
        let catalog = makeCatalog()
        let pricing = catalog.pricing(for: "Claude-Sonnet-4-5")
        #expect(pricing?.input == 3.0)
    }

    @Test("Unknown model returns nil")
    func unknownModel() {
        let catalog = makeCatalog()
        #expect(catalog.pricing(for: "mystery-model-9") == nil)
    }

    // MARK: - Error handling

    @Test("Malformed JSON throws decodingFailed")
    func malformedJSON() {
        let data = "{ not valid json".data(using: .utf8)!
        #expect(throws: PricingCatalog.LoadError.self) {
            _ = try PricingCatalog.load(from: data)
        }
    }

    // MARK: - Bundled resource

    @Test("Bundled pricing.json loads and has expected models")
    func bundledResourceLoads() throws {
        let catalog = try PricingCatalog.loadBundled()
        #expect(catalog.modelCount > 0)
        #expect(catalog.pricing(for: "claude-sonnet-4-5") != nil)
        #expect(catalog.pricing(for: "gpt-5-codex") != nil)
    }
}
