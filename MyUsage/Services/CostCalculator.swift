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
}
