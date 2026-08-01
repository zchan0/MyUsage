import Foundation

/// Per-million-token prices for a single model.
/// All fields are USD per 1,000,000 tokens.
struct ModelPricing: Codable, Sendable, Equatable {
    /// Regular (non-cached) input tokens.
    let input: Double
    /// Output tokens. For Codex, reasoning tokens are billed at this rate too.
    let output: Double
    /// Cache-write rate for the 5-minute TTL (Anthropic prompt caching),
    /// billed at 1.25× input. nil if the model doesn't support caching.
    let cacheWrite: Double?
    /// Cache-write rate for the 1-hour TTL, billed at 2× input.
    ///
    /// Claude Code writes with the 1-hour TTL by default, so this — not
    /// `cacheWrite` — is the rate that applies to most of its cache writes.
    /// The server downgrades a session to the 5-minute TTL once the 5-hour
    /// quota is exhausted, which is why both rates have to be carried.
    ///
    /// nil when the upstream table omits it; callers fall back to `cacheWrite`.
    let cacheWrite1h: Double?
    /// Cache-read rate (Anthropic prompt caching). nil if model doesn't support.
    let cacheRead: Double?
    /// Cached-input rate (OpenAI prompt caching). nil if model doesn't support.
    let cachedInput: Double?

    init(
        input: Double,
        output: Double,
        cacheWrite: Double? = nil,
        cacheWrite1h: Double? = nil,
        cacheRead: Double? = nil,
        cachedInput: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.cachedInput = cachedInput
    }

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheWrite = "cache_write"
        case cacheWrite1h = "cache_write_1h"
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
