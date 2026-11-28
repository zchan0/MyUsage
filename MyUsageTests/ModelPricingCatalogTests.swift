import Foundation
import Testing
@testable import MyUsage

@Suite("ModelPricingCatalog & Store")
struct ModelPricingCatalogTests {

    @Test("Resolves raw model IDs across effort suffixes, date stamps, version separators, and codex aliases")
    func resolvesNormalizedModelIDs() {
        let catalog = ModelPricingCatalog.bundledFallback

        // OpenAI / Codex variants
        #expect(catalog.rates(for: "gpt-6.2-sol", preferredVendor: .openai)?.inputPerMillion == 2)
        #expect(catalog.rates(for: "gpt-5.2-codex", preferredVendor: .openai)?.inputPerMillion == 1.75)
        #expect(catalog.rates(for: "gpt-5.5-2026-11-01", preferredVendor: .openai)?.outputPerMillion == 30)
        #expect(catalog.rates(for: "GPT-5-Codex", preferredVendor: .openai)?.inputPerMillion == 1.25)

        // Antigravity multi-vendor variants
        #expect(catalog.rates(for: "gemini-4-neon-xhigh")?.inputPerMillion == 3)
        #expect(catalog.rates(for: "gemini-2-5-pro-high")?.inputPerMillion == 1.25)
        #expect(catalog.rates(for: "gemini-3-1-pro-high")?.inputPerMillion == 2)
        #expect(catalog.rates(for: "claude-opus-5-5-high")?.inputPerMillion == 4)
        #expect(catalog.rates(for: "claude-sonnet-4-6-thinking")?.outputPerMillion == 15)
        #expect(catalog.rates(for: "gpt-5.4-medium")?.inputPerMillion == 2.5)

        // Synthetic / unknown models return nil instead of inventing a price
        #expect(catalog.rates(for: "<synthetic>") == nil)
        #expect(catalog.rates(for: "mystery-model-9000") == nil)
    }

    @Test("Applies long-context tier rates when a single request exceeds the context threshold")
    func appliesLongContextTier() throws {
        let catalog = ModelPricingCatalog.bundledFallback
        let baseTurn = TokenUsage(input: 100_000, output: 1_000, cachedInput: 50_000)
        let baseCost = try #require(catalog.estimateCost(for: baseTurn, rawModel: "gpt-6.2-sol", preferredVendor: .openai))
        // 150k prompt <= 272k: (100k*2 + 1k*10 + 50k*0.1) / 1M = 0.215
        #expect(abs(baseCost - 0.215) < 1e-12)

        let longTurn = TokenUsage(input: 200_000, output: 1_000, cachedInput: 100_000)
        let longCost = try #require(catalog.estimateCost(for: longTurn, rawModel: "gpt-6.2-sol", preferredVendor: .openai))
        // 300k prompt > 272k: (200k*4 + 1k*15 + 100k*0.2) / 1M = 0.835
        #expect(abs(longCost - 0.835) < 1e-12)
    }

    @Test("Parses models.dev JSON payload including tiers and context_over_200k")
    func parsesModelsDevPayload() throws {
        let json = """
        {
          "openai": {
            "models": {
              "gpt-7-test": {
                "cost": {
                  "input": 3.5,
                  "output": 14,
                  "cache_read": 0.35,
                  "tiers": [
                    {
                      "input": 7,
                      "output": 21,
                      "cache_read": 0.7,
                      "tier": { "type": "context", "size": 272000 }
                    }
                  ]
                }
              },
              "broken-negative": {
                "cost": { "input": -1, "output": 5 }
              }
            }
          },
          "google": {
            "models": {
              "gemini-5-test": {
                "cost": {
                  "input": 2.0,
                  "output": 12.0,
                  "cache_read": 0.2,
                  "context_over_200k": { "input": 4.0, "output": 18.0, "cache_read": 0.4 }
                }
              }
            }
          }
        }
        """

        let parsed = try ModelPricingCatalog.parseModelsDevJSON(Data(json.utf8))
        let gpt = try #require(parsed.rates(for: "gpt-7-test", preferredVendor: .openai))
        #expect(gpt.inputPerMillion == 3.5)
        #expect(gpt.cacheReadPerMillion == 0.35)
        #expect(gpt.longContextTier?.thresholdTokens == 272_000)
        #expect(gpt.longContextTier?.outputPerMillion == 21)
        #expect(parsed.rates(for: "broken-negative", preferredVendor: .openai) == nil)

        let gemini = try #require(parsed.rates(for: "gemini-5-test", preferredVendor: .google))
        #expect(gemini.longContextTier?.thresholdTokens == 200_000)
        #expect(gemini.longContextTier?.inputPerMillion == 4.0)
    }

    @Test("ModelPricingStore caches models.dev payload on disk, respects TTL, and falls back offline")
    func storeCachesAndFallsBackOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pricing-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("models-dev-v1.json")

        let payload = """
        {
          "openai": {
            "models": {
              "gpt-9-custom": { "cost": { "input": 6, "output": 24, "cache_read": 0.6 } }
            }
          }
        }
        """

        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let fetchCount = LockedBox(0)

        let store = ModelPricingStore(
            cacheURL: cacheURL,
            ttl: 24 * 3_600,
            now: { clock.get() },
            fetcher: {
                fetchCount.modify { $0 += 1 }
                return Data(payload.utf8)
            }
        )

        // First call fetches and overlays onto bundled fallback.
        let first = await store.catalog()
        #expect(fetchCount.get() == 1)
        #expect(first.rates(for: "gpt-9-custom", preferredVendor: .openai)?.inputPerMillion == 6)
        #expect(first.rates(for: "gpt-6.2-sol", preferredVendor: .openai)?.inputPerMillion == 2)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Within TTL, returns cached data without refetching.
        clock.set(Date(timeIntervalSince1970: 1_800_000_000 + 3_600))
        _ = await store.catalog()
        #expect(fetchCount.get() == 1)

        // Cold store instance with failing network loads previously written disk cache.
        let offlineStore = ModelPricingStore(
            cacheURL: cacheURL,
            ttl: 24 * 3_600,
            now: { clock.get() },
            fetcher: { throw URLError(.notConnectedToInternet) }
        )
        let cachedOffline = await offlineStore.catalog()
        #expect(cachedOffline.rates(for: "gpt-9-custom", preferredVendor: .openai)?.inputPerMillion == 6)

        // Brand-new store with no disk cache and failing network degrades cleanly to bundledFallback.
        let noCacheOffline = ModelPricingStore(
            cacheURL: dir.appendingPathComponent("missing.json"),
            ttl: 24 * 3_600,
            now: { clock.get() },
            fetcher: { throw URLError(.notConnectedToInternet) }
        )
        let fallbackOnly = await noCacheOffline.catalog()
        #expect(fallbackOnly.rates(for: "gpt-9-custom", preferredVendor: .openai) == nil)
        #expect(fallbackOnly.rates(for: "gemini-4-neon")?.inputPerMillion == 3)
    }

    @Test("Marks unpriced models cleanly so partial estimates can be surfaced as lower bounds")
    func marksUnpricedModelsInLocalUsageScan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-unpriced-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-25T15:00:00Z")!

        let jsonl = """
        {"type":"turn_context","timestamp":"2026-11-25T14:00:00Z","payload":{"model":"gpt-6.2-sol"}}
        {"type":"event_msg","timestamp":"2026-11-25T14:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":10000}}}}
        {"type":"turn_context","timestamp":"2026-11-25T14:02:00Z","payload":{"model":"gpt-99-unpriced"}}
        {"type":"event_msg","timestamp":"2026-11-25T14:03:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50000,"cached_input_tokens":0,"output_tokens":5000}}}}
        """
        let file = dir.appendingPathComponent("rollout.jsonl")
        try Data(jsonl.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let report = CodexLogParser.scanLocalUsage(roots: [dir], now: now, calendar: cal)
        #expect(report.hasEstimatedCost)
        #expect(!report.hasReportedCost)
        #expect(report.summary30d.hasUnpricedTokens)
        // gpt-6.2-sol: (100k*2 + 10k*10)/1M = 0.30
        #expect(abs(report.summary30d.estimatedCostUSD - 0.30) < 1e-12)

        let rows = report.modelRows(for: report.summary30d)
        let solRow = try #require(rows.first { $0.name == "GPT-6.2 Sol" })
        let unknownRow = try #require(rows.first { $0.name == "GPT-99 Unpriced" })
        #expect(!solRow.hasUnpricedTokens)
        #expect(abs(solRow.estimatedCostUSD - 0.30) < 1e-12)
        #expect(unknownRow.hasUnpricedTokens)
        #expect(unknownRow.estimatedCostUSD == 0)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.withLock { value }
    }

    func set(_ newValue: T) {
        lock.withLock { value = newValue }
    }

    func modify(_ body: (inout T) -> Void) {
        lock.withLock { body(&value) }
    }
}
