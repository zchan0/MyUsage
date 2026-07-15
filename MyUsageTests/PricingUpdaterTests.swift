import Foundation
import Testing
@testable import MyUsage

@Suite("PricingUpdater Tests")
struct PricingUpdaterTests {

    /// A trimmed-down LiteLLM payload: relevant models, an irrelevant
    /// provider-prefixed duplicate, a non-model sample_spec entry with
    /// documentation strings, and a zero-priced entry.
    private static let litellmFixture = Data("""
    {
      "sample_spec": {
        "input_cost_per_token": "one of: number",
        "output_cost_per_token": "one of: number",
        "litellm_provider": "one of https://docs..."
      },
      "claude-fable-5": {
        "input_cost_per_token": 1e-05,
        "output_cost_per_token": 5e-05,
        "cache_read_input_token_cost": 1e-06,
        "cache_creation_input_token_cost": 1.25e-05,
        "litellm_provider": "anthropic"
      },
      "claude-sonnet-4-5": {
        "input_cost_per_token": 3e-06,
        "output_cost_per_token": 1.5e-05,
        "cache_read_input_token_cost": 3e-07,
        "cache_creation_input_token_cost": 3.75e-06
      },
      "gpt-5.2-codex": {
        "input_cost_per_token": 1.75e-06,
        "output_cost_per_token": 1.4e-05,
        "cache_read_input_token_cost": 1.75e-07
      },
      "gpt-5": {
        "input_cost_per_token": 1.25e-06,
        "output_cost_per_token": 1e-05,
        "cache_read_input_token_cost": 1.25e-07
      },
      "openrouter/anthropic/claude-fable-5": {
        "input_cost_per_token": 1e-05,
        "output_cost_per_token": 5e-05
      },
      "anthropic.claude-fable-5": {
        "input_cost_per_token": 1e-05,
        "output_cost_per_token": 5e-05
      },
      "claude-mythos-preview": {
        "input_cost_per_token": 0,
        "output_cost_per_token": 0
      }
    }
    """.utf8)

    // MARK: - Conversion

    @Test("Converts per-token rates to per-million and splits cache fields by provider")
    func convertsRates() throws {
        let file = try PricingUpdater.convert(litellmData: Self.litellmFixture)
        let catalog = PricingCatalog(file: file)

        let fable = try #require(catalog.pricing(for: "claude-fable-5"))
        #expect(fable.input == 10.0)
        #expect(fable.output == 50.0)
        #expect(fable.cacheRead == 1.0)
        #expect(fable.cacheWrite == 12.5)
        #expect(fable.cachedInput == nil)

        let gpt = try #require(catalog.pricing(for: "gpt-5.2-codex"))
        #expect(gpt.input == 1.75)
        #expect(gpt.output == 14.0)
        #expect(gpt.cachedInput == 0.175)
        #expect(gpt.cacheRead == nil)
    }

    @Test("Skips provider-prefixed keys, non-model entries, and zero-priced models")
    func skipsIrrelevant() throws {
        let file = try PricingUpdater.convert(litellmData: Self.litellmFixture)

        #expect(file.models["openrouter/anthropic/claude-fable-5"] == nil, "path-prefixed duplicates are routing markup")
        #expect(file.models["anthropic.claude-fable-5"] == nil, "dotted vendor prefixes never match our log model IDs")
        #expect(file.models["sample_spec"] == nil)
        #expect(file.models["claude-mythos-preview"] == nil, "zero-priced models carry no signal")
        #expect(file.models.count == 4)
    }

    @Test("Conversion fails loudly on a non-dictionary payload")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try PricingUpdater.convert(litellmData: Data("[1,2,3]".utf8))
        }
    }

    // MARK: - Plausibility gate

    @Test("Plausibility requires anchor models, not just a count")
    func plausibility() throws {
        let good = PricingCatalog(file: try PricingUpdater.convert(litellmData: Self.litellmFixture))
        // The fixture has only 4-5 models — below the count floor.
        #expect(!PricingUpdater.isPlausible(good))

        let bundled = try PricingCatalog.loadBundled()
        #expect(PricingUpdater.isPlausible(bundled))

        let empty = PricingCatalog(file: PricingFile(version: 2, updated: nil, models: [:]))
        #expect(!PricingUpdater.isPlausible(empty))
    }

    // MARK: - Cached catalog loading

    @Test("loadCachedCatalog rejects missing and implausible files")
    func cachedCatalogValidation() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(PricingUpdater.loadCachedCatalog(from: tmp) == nil)

        try Data(#"{"version":2,"updated":null,"models":{}}"#.utf8).write(to: tmp)
        #expect(PricingUpdater.loadCachedCatalog(from: tmp) == nil, "empty catalog must not replace bundled")

        // A plausible file loads.
        let bundledURL = try #require(
            (AppResources.bundle ?? Bundle.main).url(forResource: "pricing", withExtension: "json")
        )
        try Data(contentsOf: bundledURL).write(to: tmp)
        #expect(PricingUpdater.loadCachedCatalog(from: tmp) != nil)
    }

    // MARK: - Fingerprint semantics

    @Test("Fingerprint tracks prices, not the updated timestamp")
    func fingerprintStability() {
        let models = ["claude-x": ModelPricing(
            input: 1, output: 2, cacheWrite: nil, cacheRead: nil, cachedInput: nil
        )]
        let a = PricingCatalog(file: PricingFile(version: 2, updated: "2026-07-15", models: models))
        let b = PricingCatalog(file: PricingFile(version: 2, updated: "2026-07-16", models: models))
        #expect(a.fingerprint == b.fingerprint, "daily refetch with identical prices must not churn caches")

        let changed = ["claude-x": ModelPricing(
            input: 1, output: 3, cacheWrite: nil, cacheRead: nil, cachedInput: nil
        )]
        let c = PricingCatalog(file: PricingFile(version: 2, updated: "2026-07-16", models: changed))
        #expect(a.fingerprint != c.fingerprint)
    }
}
