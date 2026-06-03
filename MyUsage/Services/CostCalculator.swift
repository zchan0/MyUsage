import Foundation

/// Converts `TokenUsage` into USD using a `PricingCatalog`.
enum CostCalculator {

    /// Cost for a single model's token usage. Returns 0 when no pricing entry is found.
    static func cost(usage: TokenUsage, model: String, catalog: PricingCatalog) -> Double {
        guard let price = catalog.pricing(for: model) else { return 0 }
        var total = 0.0
        total += Double(usage.input)  * price.input  / 1_000_000
        total += Double(usage.output) * price.output / 1_000_000
        if let cw = price.cacheWrite {
            total += Double(usage.cacheWrite) * cw / 1_000_000
        }
        if let cr = price.cacheRead {
            total += Double(usage.cacheRead) * cr / 1_000_000
        }
        if let ci = price.cachedInput {
            total += Double(usage.cachedInput) * ci / 1_000_000
        }
        return total
    }

    /// Sum of costs across all models.
    static func totalCost(of byModel: UsageByModel, catalog: PricingCatalog) -> Double {
        byModel.reduce(0.0) { acc, entry in
            acc + cost(usage: entry.value, model: entry.key, catalog: catalog)
        }
    }

    /// Per-bucket dollars for a single model. Returns four `Double`s
    /// whose sum equals `cost(usage:model:catalog:)`. The "cached
    /// input" OpenAI bucket is folded into `freshInput` so v1's
    /// four-bucket UI stays coherent for mixed-provider catalogs —
    /// callers that need the Anthropic-only breakdown should only
    /// pass Anthropic models.
    static func perBucketCost(
        usage: TokenUsage,
        model: String,
        catalog: PricingCatalog
    ) -> PerBucketCost {
        guard let price = catalog.pricing(for: model) else { return .zero }
        let freshInput = Double(usage.input) * price.input / 1_000_000
            + Double(usage.cachedInput) * (price.cachedInput ?? 0) / 1_000_000
        let output = Double(usage.output) * price.output / 1_000_000
        let cacheCreation = Double(usage.cacheWrite) * (price.cacheWrite ?? 0) / 1_000_000
        let cacheRead = Double(usage.cacheRead) * (price.cacheRead ?? 0) / 1_000_000
        return PerBucketCost(
            freshInput: freshInput,
            output: output,
            cacheCreation: cacheCreation,
            cacheRead: cacheRead
        )
    }

    /// Per-bucket dollars summed across every model in the breakdown.
    /// Total is guaranteed to equal `totalCost(of:catalog:)` for the
    /// same inputs — covered by a regression test.
    static func perBucketTotalCost(
        of byModel: UsageByModel,
        catalog: PricingCatalog
    ) -> PerBucketCost {
        byModel.reduce(PerBucketCost.zero) { acc, entry in
            acc + perBucketCost(usage: entry.value, model: entry.key, catalog: catalog)
        }
    }
}

/// Per-bucket dollar split of a single model (or aggregate). Sum of
/// the four fields equals the scalar produced by
/// `CostCalculator.cost(usage:model:catalog:)`.
struct PerBucketCost: Equatable, Sendable {
    var freshInput: Double
    var output: Double
    var cacheCreation: Double
    var cacheRead: Double

    var total: Double { freshInput + output + cacheCreation + cacheRead }

    static let zero = PerBucketCost(
        freshInput: 0, output: 0, cacheCreation: 0, cacheRead: 0
    )

    static func + (lhs: PerBucketCost, rhs: PerBucketCost) -> PerBucketCost {
        PerBucketCost(
            freshInput: lhs.freshInput + rhs.freshInput,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}
