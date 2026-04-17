import Foundation

/// Per-million-token prices for a single model.
/// All fields are USD per 1,000,000 tokens.
struct ModelPricing: Codable, Sendable, Equatable {
    /// Regular (non-cached) input tokens.
    let input: Double
    /// Output tokens. For Codex, reasoning tokens are billed at this rate too.
    let output: Double
    /// Cache-write rate (Anthropic prompt caching). nil if model doesn't support.
    let cacheWrite: Double?
    /// Cache-read rate (Anthropic prompt caching). nil if model doesn't support.
    let cacheRead: Double?
    /// Cached-input rate (OpenAI prompt caching). nil if model doesn't support.
    let cachedInput: Double?

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheWrite = "cache_write"
        case cacheRead = "cache_read"
        case cachedInput = "cached_input"
    }
}

/// On-disk format of `pricing.json`.
struct PricingFile: Codable, Sendable {
    let version: Int
    let updated: String?
    let models: [String: ModelPricing]
}
