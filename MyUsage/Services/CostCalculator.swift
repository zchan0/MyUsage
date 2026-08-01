import Foundation

/// Converts `TokenUsage` into USD using a `PricingCatalog`.
enum CostCalculator {

    /// Cost for a single model's token usage. Returns 0 when no pricing entry is found.
    static func cost(usage: TokenUsage, model: String, catalog: PricingCatalog) -> Double {
        guard let price = catalog.pricing(for: model) else { return 0 }
        var total = 0.0
        total += Double(usage.input)  * price.input  / 1_000_000
        total += Double(usage.output) * price.output / 1_000_000
        // The two cache-write TTLs bill differently (1.25× vs 2× input), so
        // they are priced separately. A table without the 1-hour rate falls
        // back to the 5-minute one rather than dropping the tokens.
        if let cw = price.cacheWrite {
            total += Double(usage.cacheWrite5m) * cw / 1_000_000
        }
        if let cw1h = price.cacheWrite1h ?? price.cacheWrite {
            total += Double(usage.cacheWrite1h) * cw1h / 1_000_000
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
