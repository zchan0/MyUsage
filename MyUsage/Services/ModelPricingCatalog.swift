import Foundation
import os

/// Reference model pricing catalog used to compute API-equivalent cost estimates
/// from local token logs when a tool (such as Codex or Antigravity) does not
/// natively record dollar amounts.
///
/// Primary source: `https://models.dev/api.json` (cached locally with a 24-hour
/// TTL via `ModelPricingStore`), layered on top of a bundled static fallback
/// snapshot so offline launches and unit tests remain deterministic.
struct ModelPricingCatalog: Sendable, Equatable {
    enum Vendor: String, CaseIterable, Sendable, Codable, Hashable {
        case openai
        case anthropic
        case google
    }

    struct ContextTier: Sendable, Equatable, Codable {
        let thresholdTokens: Int
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double?
        let cacheWritePerMillion: Double?
    }

    struct Rates: Sendable, Equatable, Codable {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double?
        let cacheWritePerMillion: Double?
        let longContextTier: ContextTier?

        init(
            inputPerMillion: Double,
            outputPerMillion: Double,
            cacheReadPerMillion: Double? = nil,
            cacheWritePerMillion: Double? = nil,
            longContextTier: ContextTier? = nil
        ) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cacheReadPerMillion = cacheReadPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
            self.longContextTier = longContextTier
        }

        /// Estimate USD cost for a single request/turn's token breakdown.
        func estimateCost(for tokens: TokenUsage) -> Double {
            let promptTokens = tokens.input + tokens.cacheWrite + tokens.cacheRead + tokens.cachedInput
            let useTier = longContextTier.map { promptTokens > $0.thresholdTokens } ?? false

            let inputRate = useTier ? (longContextTier?.inputPerMillion ?? inputPerMillion) : inputPerMillion
            let outputRate = useTier ? (longContextTier?.outputPerMillion ?? outputPerMillion) : outputPerMillion
            let cacheReadRate = (useTier ? longContextTier?.cacheReadPerMillion : nil) ?? cacheReadPerMillion ?? inputRate
            let cacheWrite5mRate = (useTier ? longContextTier?.cacheWritePerMillion : nil) ?? cacheWritePerMillion ?? (inputRate * 1.25)
            let cacheWrite1hRate = inputRate * 2.0

            let cachedReads = tokens.cacheRead + tokens.cachedInput
            let total = (
                Double(max(0, tokens.input)) * inputRate
                + Double(max(0, tokens.output)) * outputRate
                + Double(max(0, cachedReads)) * cacheReadRate
                + Double(max(0, tokens.cacheWrite5m)) * cacheWrite5mRate
                + Double(max(0, tokens.cacheWrite1h)) * cacheWrite1hRate
            ) / 1_000_000.0

            return total.isFinite && total >= 0 ? total : 0
        }
    }

    private let tables: [Vendor: [String: Rates]]

    init(tables: [Vendor: [String: Rates]]) {
        self.tables = tables
    }

    /// Merge `overrides` on top of `self` so fresher remote catalog rates win
    /// while bundled fallback aliases remain available for older/retired models.
    func merging(_ overrides: ModelPricingCatalog) -> ModelPricingCatalog {
        var merged = tables
        for (vendor, models) in overrides.tables {
            var bucket = merged[vendor] ?? [:]
            for (id, rates) in models {
                bucket[id] = rates
            }
            merged[vendor] = bucket
        }
        return ModelPricingCatalog(tables: merged)
    }

    /// Resolve per-million-token rates for a raw model identifier from local logs.
    func rates(for rawModel: String, preferredVendor: Vendor? = nil) -> Rates? {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }

        let (explicitVendor, bareID) = Self.splitVendorPrefix(trimmed)
        let candidates = Self.candidateKeys(for: bareID)
        let searchOrder = Self.vendorOrder(explicit: explicitVendor, preferred: preferredVendor, bareID: bareID)

        for vendor in searchOrder {
            guard let table = tables[vendor] else { continue }
            for key in candidates {
                if let rates = table[key] {
                    return rates
                }
            }
        }
        return nil
    }

    /// Estimate API-equivalent USD cost for one turn, or `nil` if the model has no known rate.
    func estimateCost(for tokens: TokenUsage, rawModel: String, preferredVendor: Vendor? = nil) -> Double? {
        guard !tokens.isEmpty, let rates = rates(for: rawModel, preferredVendor: preferredVendor) else {
            return nil
        }
        return rates.estimateCost(for: tokens)
    }

    // MARK: - Key Normalization

    private static let effortSuffixes: [String] = [
        "-xhigh", "-high", "-medium", "-low", "-minimal", "-thinking"
    ]

    private static let variantSuffixes: [String] = [
        "-codex-max", "-codex-mini", "-codex", "-customtools", "-latest"
    ]

    private static func splitVendorPrefix(_ model: String) -> (Vendor?, String) {
        for vendor in Vendor.allCases {
            let prefix = vendor.rawValue + "/"
            if model.hasPrefix(prefix) {
                return (vendor, String(model.dropFirst(prefix.count)))
            }
        }
        return (nil, model)
    }

    private static func vendorOrder(explicit: Vendor?, preferred: Vendor?, bareID: String) -> [Vendor] {
        var order: [Vendor] = []
        func append(_ vendor: Vendor?) {
            guard let vendor, !order.contains(vendor) else { return }
            order.append(vendor)
        }
        append(explicit)
        if bareID.hasPrefix("claude-") {
            append(.anthropic)
        } else if bareID.hasPrefix("gemini-") || bareID.hasPrefix("gemma-") || bareID.hasPrefix("deep-research") {
            append(.google)
        } else if bareID.hasPrefix("gpt-") || bareID.hasPrefix("o1") || bareID.hasPrefix("o3")
            || bareID.hasPrefix("o4") || bareID.hasPrefix("codex-") {
            append(.openai)
        }
        append(preferred)
        for vendor in Vendor.allCases {
            append(vendor)
        }
        return order
    }

    static func candidateKeys(for rawBareID: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        func push(_ value: String) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return }
            result.append(cleaned)
        }

        // 1. Exact ID as logged.
        push(rawBareID)

        // 2. Strip Antigravity / reasoning effort suffixes (e.g. "-xhigh", "-thinking").
        var stripped = rawBareID
        var changed = true
        while changed {
            changed = false
            for suffix in effortSuffixes where stripped.hasSuffix(suffix) {
                stripped.removeLast(suffix.count)
                changed = true
            }
        }
        push(stripped)

        // 3. Strip trailing -YYYY-MM-DD or -YYYYMMDD date stamps.
        let dateless = stripDateSuffix(stripped)
        push(dateless)

        // 4. Normalize version separator differences between logs and models.dev:
        //    - Gemini & GPT use dots in models.dev ("gemini-2.5-pro", "gpt-5.4"),
        //      while Antigravity logs may emit hyphens ("gemini-2-5-pro").
        //    - Claude uses hyphens in models.dev ("claude-opus-5-5").
        let normalizedVersions = normalizeVersionSeparators(dateless)
        push(normalizedVersions)

        // 5. Try "-preview" variant for Gemini 3.x models whose catalog key carries "-preview".
        if normalizedVersions.hasPrefix("gemini-3") && !normalizedVersions.hasSuffix("-preview") {
            push(normalizedVersions + "-preview")
        }

        // 6. Strip CLI/routing variant suffixes ("-codex", "-codex-max", "-latest", "-customtools").
        for base in [dateless, normalizedVersions] {
            for suffix in variantSuffixes where base.hasSuffix(suffix) {
                let shorter = String(base.dropLast(suffix.count))
                push(shorter)
                push(normalizeVersionSeparators(shorter))
            }
        }

        return result
    }

    private static func stripDateSuffix(_ id: String) -> String {
        if let range = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return String(id[..<range.lowerBound])
        }
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(id[..<range.lowerBound])
        }
        return id
    }

    private static func normalizeVersionSeparators(_ id: String) -> String {
        if id.hasPrefix("claude-") {
            // "claude-opus-5.5" -> "claude-opus-5-5"
            return id.replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1-$2", options: .regularExpression)
        }
        if id.hasPrefix("gemini-") || id.hasPrefix("gpt-") {
            // "gemini-2-5-pro" -> "gemini-2.5-pro", "gpt-5-4" -> "gpt-5.4"
            return id.replacingOccurrences(of: #"(?<=-)(\d{1,2})-(\d{1,2})(?=-|$)"#, with: "$1.$2", options: .regularExpression)
        }
        return id
    }

    // MARK: - models.dev/api.json Decoder

    /// Parse the public `https://models.dev/api.json` payload into a normalized catalog
    /// covering OpenAI, Anthropic, and Google models with valid non-negative costs.
    static func parseModelsDevJSON(_ data: Data) throws -> ModelPricingCatalog {
        struct ProviderPayload: Decodable {
            let models: [String: ModelPayload]?
        }
        struct ModelPayload: Decodable {
            let cost: CostPayload?
        }
        struct CostPayload: Decodable {
            let input: Double?
            let output: Double?
            let cacheRead: Double?
            let cacheWrite: Double?
            let tiers: [TierPayload]?
            let contextOver200k: TierRatesPayload?

            enum CodingKeys: String, CodingKey {
                case input
                case output
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
                case tiers
                case contextOver200k = "context_over_200k"
            }
        }
        struct TierPayload: Decodable {
            let input: Double?
            let output: Double?
            let cacheRead: Double?
            let cacheWrite: Double?
            let tier: TierSpec?

            enum CodingKeys: String, CodingKey {
                case input
                case output
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
                case tier
            }
        }
        struct TierSpec: Decodable {
            let type: String?
            let size: Int?
        }
        struct TierRatesPayload: Decodable {
            let input: Double?
            let output: Double?
            let cacheRead: Double?
            let cacheWrite: Double?

            enum CodingKeys: String, CodingKey {
                case input
                case output
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
            }
        }

        let root = try JSONDecoder().decode([String: ProviderPayload].self, from: data)
        var tables: [Vendor: [String: Rates]] = [:]

        for vendor in Vendor.allCases {
            guard let models = root[vendor.rawValue]?.models else { continue }
            var vendorTable: [String: Rates] = [:]

            for (rawID, payload) in models {
                guard let cost = payload.cost,
                      let input = cost.input, input.isFinite, input >= 0,
                      let output = cost.output, output.isFinite, output >= 0 else { continue }

                let cacheRead = cost.cacheRead.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let cacheWrite = cost.cacheWrite.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

                var longContext: ContextTier?
                if let tier = cost.tiers?.first(where: { $0.tier?.type == "context" && ($0.tier?.size ?? 0) > 0 }),
                   let threshold = tier.tier?.size,
                   let tInput = tier.input, tInput.isFinite, tInput >= 0,
                   let tOutput = tier.output, tOutput.isFinite, tOutput >= 0 {
                    longContext = ContextTier(
                        thresholdTokens: threshold,
                        inputPerMillion: tInput,
                        outputPerMillion: tOutput,
                        cacheReadPerMillion: tier.cacheRead.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                        cacheWritePerMillion: tier.cacheWrite.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                    )
                } else if let over = cost.contextOver200k,
                          let tInput = over.input, tInput.isFinite, tInput >= 0,
                          let tOutput = over.output, tOutput.isFinite, tOutput >= 0 {
                    longContext = ContextTier(
                        thresholdTokens: 200_000,
                        inputPerMillion: tInput,
                        outputPerMillion: tOutput,
                        cacheReadPerMillion: over.cacheRead.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                        cacheWritePerMillion: over.cacheWrite.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                    )
                }

                let key = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { continue }
                vendorTable[key] = Rates(
                    inputPerMillion: input,
                    outputPerMillion: output,
                    cacheReadPerMillion: cacheRead,
                    cacheWritePerMillion: cacheWrite,
                    longContextTier: longContext
                )
            }

            if !vendorTable.isEmpty {
                tables[vendor] = vendorTable
            }
        }

        return ModelPricingCatalog(tables: tables)
    }

    // MARK: - Bundled Fallback Snapshot (models.dev baseline)

    static let bundledFallback = ModelPricingCatalog(tables: [
        .openai: [
            "gpt-4o": Rates(inputPerMillion: 2.5, outputPerMillion: 10, cacheReadPerMillion: 1.25),
            "gpt-4o-mini": Rates(inputPerMillion: 0.15, outputPerMillion: 0.6, cacheReadPerMillion: 0.075),
            "gpt-4.1": Rates(inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: 0.5),
            "gpt-4.1-mini": Rates(inputPerMillion: 0.4, outputPerMillion: 1.6, cacheReadPerMillion: 0.1),
            "o3": Rates(inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: 0.5),
            "o3-pro": Rates(inputPerMillion: 20, outputPerMillion: 80),
            "o4-mini": Rates(inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.275),
            "codex-mini-latest": Rates(inputPerMillion: 1.5, outputPerMillion: 6, cacheReadPerMillion: 0.375),
            "gpt-5": Rates(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125),
            "gpt-5-mini": Rates(inputPerMillion: 0.25, outputPerMillion: 2, cacheReadPerMillion: 0.025),
            "gpt-5-nano": Rates(inputPerMillion: 0.05, outputPerMillion: 0.4, cacheReadPerMillion: 0.005),
            "gpt-5-pro": Rates(inputPerMillion: 15, outputPerMillion: 120),
            "gpt-5.1": Rates(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125),
            "gpt-5.2": Rates(inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: 0.175),
            "gpt-5.2-pro": Rates(inputPerMillion: 21, outputPerMillion: 168),
            "gpt-5.3-codex": Rates(inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: 0.175),
            "gpt-5.4": Rates(
                inputPerMillion: 2.5, outputPerMillion: 15, cacheReadPerMillion: 0.25,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 5, outputPerMillion: 22.5, cacheReadPerMillion: 0.5, cacheWritePerMillion: nil)
            ),
            "gpt-5.4-mini": Rates(inputPerMillion: 0.75, outputPerMillion: 4.5, cacheReadPerMillion: 0.075),
            "gpt-5.4-nano": Rates(inputPerMillion: 0.2, outputPerMillion: 1.25, cacheReadPerMillion: 0.02),
            "gpt-5.4-pro": Rates(
                inputPerMillion: 30, outputPerMillion: 180,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 60, outputPerMillion: 270, cacheReadPerMillion: nil, cacheWritePerMillion: nil)
            ),
            "gpt-5.5": Rates(
                inputPerMillion: 5, outputPerMillion: 30, cacheReadPerMillion: 0.5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 10, outputPerMillion: 45, cacheReadPerMillion: 1, cacheWritePerMillion: nil)
            ),
            "gpt-5.5-pro": Rates(
                inputPerMillion: 30, outputPerMillion: 180,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 60, outputPerMillion: 270, cacheReadPerMillion: nil, cacheWritePerMillion: nil)
            ),
            "gpt-5.6": Rates(
                inputPerMillion: 4, outputPerMillion: 20, cacheReadPerMillion: 0.4, cacheWritePerMillion: 5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 8, outputPerMillion: 30, cacheReadPerMillion: 0.8, cacheWritePerMillion: 10)
            ),
            "gpt-5.6-sol": Rates(
                inputPerMillion: 4, outputPerMillion: 20, cacheReadPerMillion: 0.4, cacheWritePerMillion: 5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 8, outputPerMillion: 30, cacheReadPerMillion: 0.8, cacheWritePerMillion: 10)
            ),
            "gpt-5.6-terra": Rates(
                inputPerMillion: 2, outputPerMillion: 12, cacheReadPerMillion: 0.2, cacheWritePerMillion: 2.5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 4, outputPerMillion: 18, cacheReadPerMillion: 0.4, cacheWritePerMillion: 5)
            ),
            "gpt-5.6-luna": Rates(
                inputPerMillion: 0.2, outputPerMillion: 1.2, cacheReadPerMillion: 0.02, cacheWritePerMillion: 0.25,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 0.4, outputPerMillion: 1.8, cacheReadPerMillion: 0.04, cacheWritePerMillion: 0.5)
            ),
            "gpt-6-astra": Rates(
                inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 1, cacheWritePerMillion: 12.5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 20, outputPerMillion: 75, cacheReadPerMillion: 2, cacheWritePerMillion: 25)
            ),
            "gpt-6-sol": Rates(
                inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.2, cacheWritePerMillion: 2.5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 4, outputPerMillion: 15, cacheReadPerMillion: 0.4, cacheWritePerMillion: 5)
            ),
            "gpt-6-luna": Rates(
                inputPerMillion: 0.1, outputPerMillion: 0.5, cacheReadPerMillion: 0.01, cacheWritePerMillion: 0.125,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 0.2, outputPerMillion: 0.75, cacheReadPerMillion: 0.02, cacheWritePerMillion: 0.25)
            ),
            "gpt-6.1-sol": Rates(
                inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.1, cacheWritePerMillion: 2.5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 4, outputPerMillion: 15, cacheReadPerMillion: 0.2, cacheWritePerMillion: 5)
            ),
            "gpt-6.1-terra": Rates(
                inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: 0.05, cacheWritePerMillion: 1.25,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 2, outputPerMillion: 7.5, cacheReadPerMillion: 0.1, cacheWritePerMillion: 2.5)
            ),
            "gpt-6.2-sol": Rates(
                inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.1, cacheWritePerMillion: 2.5,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 4, outputPerMillion: 15, cacheReadPerMillion: 0.2, cacheWritePerMillion: 5)
            ),
            "gpt-6.2-astra": Rates(
                inputPerMillion: 8, outputPerMillion: 40, cacheReadPerMillion: 0.4, cacheWritePerMillion: 10,
                longContextTier: .init(thresholdTokens: 272_000, inputPerMillion: 16, outputPerMillion: 60, cacheReadPerMillion: 0.8, cacheWritePerMillion: 20)
            ),
        ],
        .anthropic: [
            "claude-opus-4-5": Rates(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25),
            "claude-opus-4-6": Rates(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25),
            "claude-opus-4-7": Rates(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25),
            "claude-opus-4-8": Rates(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25),
            "claude-opus-5": Rates(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25),
            "claude-opus-5-5": Rates(inputPerMillion: 4, outputPerMillion: 20, cacheReadPerMillion: 0.2, cacheWritePerMillion: 5),
            "claude-sonnet-4-5": Rates(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75),
            "claude-sonnet-4-6": Rates(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75),
            "claude-sonnet-5": Rates(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.2, cacheWritePerMillion: 2.5),
            "claude-sonnet-5-5": Rates(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.1, cacheWritePerMillion: 2.5),
            "claude-haiku-4-5": Rates(inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: 0.1, cacheWritePerMillion: 1.25),
            "claude-haiku-5-5": Rates(
                inputPerMillion: 0.1, outputPerMillion: 0.5, cacheReadPerMillion: 0.01, cacheWritePerMillion: 0.125,
                longContextTier: .init(thresholdTokens: 100_000, inputPerMillion: 0.5, outputPerMillion: 2.5, cacheReadPerMillion: 0.05, cacheWritePerMillion: 0.625)
            ),
            "claude-fable-5": Rates(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 1, cacheWritePerMillion: 12.5),
            "claude-fable-5-1": Rates(inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 0.25, cacheWritePerMillion: 12.5),
            "claude-fable-5-2": Rates(inputPerMillion: 8, outputPerMillion: 40, cacheReadPerMillion: 0.2, cacheWritePerMillion: 10),
        ],
        .google: [
            "gemini-2.5-pro": Rates(
                inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125,
                longContextTier: .init(thresholdTokens: 200_000, inputPerMillion: 2.5, outputPerMillion: 15, cacheReadPerMillion: 0.25, cacheWritePerMillion: nil)
            ),
            "gemini-2.5-flash": Rates(inputPerMillion: 0.3, outputPerMillion: 2.5, cacheReadPerMillion: 0.03),
            "gemini-2.5-flash-lite": Rates(inputPerMillion: 0.1, outputPerMillion: 0.4, cacheReadPerMillion: 0.01),
            "gemini-3-flash-preview": Rates(inputPerMillion: 0.5, outputPerMillion: 3, cacheReadPerMillion: 0.05),
            "gemini-3.1-pro-preview": Rates(
                inputPerMillion: 2, outputPerMillion: 12, cacheReadPerMillion: 0.2,
                longContextTier: .init(thresholdTokens: 200_000, inputPerMillion: 4, outputPerMillion: 18, cacheReadPerMillion: 0.4, cacheWritePerMillion: nil)
            ),
            "gemini-3.1-flash-lite": Rates(inputPerMillion: 0.25, outputPerMillion: 1.5, cacheReadPerMillion: 0.025),
            "gemini-3.5-flash": Rates(inputPerMillion: 1.5, outputPerMillion: 9, cacheReadPerMillion: 0.15),
            "gemini-3.5-flash-lite": Rates(inputPerMillion: 0.3, outputPerMillion: 2.5, cacheReadPerMillion: 0.03),
            "gemini-3.6-flash": Rates(inputPerMillion: 0.75, outputPerMillion: 3.75, cacheReadPerMillion: 0.075),
            "gemini-3.7-flash": Rates(inputPerMillion: 0.75, outputPerMillion: 3.75, cacheReadPerMillion: 0.075),
            "gemini-3.8-flash": Rates(inputPerMillion: 0.75, outputPerMillion: 3.75, cacheReadPerMillion: 0.075),
            "gemini-4-argon": Rates(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.1),
            "gemini-4-carbon": Rates(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.1),
            "gemini-4-hydrogen": Rates(inputPerMillion: 1.5, outputPerMillion: 7.5, cacheReadPerMillion: 0.075),
            "gemini-4-neon": Rates(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.15),
            "gemini-flash-latest": Rates(inputPerMillion: 0.75, outputPerMillion: 3.75, cacheReadPerMillion: 0.075),
            "gemini-flash-lite-latest": Rates(inputPerMillion: 0.3, outputPerMillion: 2.5, cacheReadPerMillion: 0.03),
            "gemini-pro-latest": Rates(
                inputPerMillion: 2, outputPerMillion: 12, cacheReadPerMillion: 0.2,
                longContextTier: .init(thresholdTokens: 200_000, inputPerMillion: 4, outputPerMillion: 18, cacheReadPerMillion: 0.4, cacheWritePerMillion: nil)
            ),
        ],
    ])
}

extension ModelPricingCatalog: Codable {
    private enum CodingKeys: String, CodingKey {
        case openai, anthropic, google
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var tables: [Vendor: [String: Rates]] = [:]
        if let openai = try container.decodeIfPresent([String: Rates].self, forKey: .openai) {
            tables[.openai] = openai
        }
        if let anthropic = try container.decodeIfPresent([String: Rates].self, forKey: .anthropic) {
            tables[.anthropic] = anthropic
        }
        if let google = try container.decodeIfPresent([String: Rates].self, forKey: .google) {
            tables[.google] = google
        }
        self.tables = tables
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tables[.openai], forKey: .openai)
        try container.encodeIfPresent(tables[.anthropic], forKey: .anthropic)
        try container.encodeIfPresent(tables[.google], forKey: .google)
    }
}

/// Manages disk-cached `models.dev/api.json` refreshes with a 24-hour TTL and
/// offline fallback to `ModelPricingCatalog.bundledFallback`.
actor ModelPricingStore {
    static let shared = ModelPricingStore()
    static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    static let defaultTTL: TimeInterval = 24 * 3_600
    static let failureCooldown: TimeInterval = 15 * 60
    private static let maxResponseBytes = 8 * 1_048_576

    private struct CachedSnapshot: Codable {
        let fetchedAt: Date
        let catalog: ModelPricingCatalog
    }

    private let cacheURL: URL
    private let ttl: TimeInterval
    private let fetcher: @Sendable () async throws -> Data
    private let now: @Sendable () -> Date

    private var loadedFromDisk = false
    private var cachedSnapshot: CachedSnapshot?
    private var lastFailureAt: Date?

    init(
        cacheURL: URL = ModelPricingStore.defaultCacheURL(),
        ttl: TimeInterval = ModelPricingStore.defaultTTL,
        now: @escaping @Sendable () -> Date = { .now },
        fetcher: @escaping @Sendable () async throws -> Data = ModelPricingStore.fetchModelsDevData
    ) {
        self.cacheURL = cacheURL
        self.ttl = ttl
        self.now = now
        self.fetcher = fetcher
    }

    static func defaultCacheURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zchan0.MyUsage"
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("model-pricing", isDirectory: true)
            .appendingPathComponent("models-dev-v1.json", isDirectory: false)
    }

    /// Returns the best available pricing catalog (remote cache overlaid on the
    /// bundled fallback), refreshing from `models.dev` if the 24-hour cache is
    /// missing or expired.
    func catalog() async -> ModelPricingCatalog {
        loadDiskCacheIfNeeded()

        let currentDate = now()
        let isFresh = cachedSnapshot.map { currentDate.timeIntervalSince($0.fetchedAt) < ttl } ?? false
        if isFresh, let cached = cachedSnapshot {
            return ModelPricingCatalog.bundledFallback.merging(cached.catalog)
        }

        let recentlyFailed = lastFailureAt.map { currentDate.timeIntervalSince($0) < Self.failureCooldown } ?? false
        if !recentlyFailed {
            await refreshFromRemote(at: currentDate)
        }

        if let cached = cachedSnapshot {
            return ModelPricingCatalog.bundledFallback.merging(cached.catalog)
        }
        return .bundledFallback
    }

    private func loadDiskCacheIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(CachedSnapshot.self, from: data) else { return }
        cachedSnapshot = snapshot
    }

    private func refreshFromRemote(at date: Date) async {
        do {
            let data = try await fetcher()
            guard data.count <= Self.maxResponseBytes else {
                lastFailureAt = date
                return
            }
            let parsed = try ModelPricingCatalog.parseModelsDevJSON(data)
            let snapshot = CachedSnapshot(fetchedAt: date, catalog: parsed)
            cachedSnapshot = snapshot
            lastFailureAt = nil
            saveDiskCache(snapshot)
        } catch {
            lastFailureAt = date
            Logger.general.debug("models.dev pricing refresh skipped/failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveDiskCache(_ snapshot: CachedSnapshot) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        try? encoded.write(to: cacheURL, options: .atomic)
    }

    private static func fetchModelsDevData() async throws -> Data {
        var request = URLRequest(url: modelsDevURL)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
