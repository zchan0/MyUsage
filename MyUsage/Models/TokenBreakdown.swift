import Foundation

/// Per-bucket token counters for a single provider's month-to-date
/// usage, plus any pre-priced cost that bypassed the local pricing
/// table. Surfaced in Settings → Cost so the user can see *why* their
/// dollar total landed where it did — and in particular, the cache
/// hit rate, which swings Anthropic costs by 5–10×.
///
/// v1 is Claude-only. Extending to Codex would change the meaning of
/// `freshInput` (OpenAI's `input_tokens` includes cached); the Codex
/// breakdown belongs in a follow-up spec.
struct TokenBreakdown: Equatable, Codable, Sendable {
    /// Anthropic `input_tokens` — already excludes cache reads/writes.
    var freshInput: Int
    var output: Int
    /// `cache_creation_input_tokens` (Anthropic "cache write").
    var cacheCreation: Int
    /// `cache_read_input_tokens`.
    var cacheRead: Int
    /// Sum of server-provided `costUSD` values for rows the local
    /// pricing table didn't price. Surfaced as a separate
    /// "Pre-priced by Claude Code" line so the per-bucket dollar
    /// math stays clean.
    var preComputedCost: Double

    /// Total real tokens billed this period — sum of all four buckets.
    /// Used as the headline "Real total tokens" number; explicitly
    /// includes `cacheRead` so the cache hit rate has a meaningful
    /// denominator.
    var realTotal: Int {
        freshInput + output + cacheCreation + cacheRead
    }

    /// Denominator of `cacheHitRate`. Output is **not** included —
    /// it's not cacheable. Matches cc-switch's
    /// `derive_real_total_and_hit_rate`.
    var cacheableInput: Int {
        freshInput + cacheCreation + cacheRead
    }

    /// `cache_read / (fresh_input + cache_creation + cache_read)`.
    /// Returns 0 (not NaN) when no cacheable tokens were billed.
    var cacheHitRate: Double {
        cacheableInput > 0
            ? Double(cacheRead) / Double(cacheableInput)
            : 0
    }

    /// True when no tokens were billed in any bucket and no
    /// pre-priced rows exist — the Cost tab uses this to swap in
    /// the "No usage this month" empty state.
    var isEmpty: Bool {
        realTotal == 0 && preComputedCost == 0
    }

    static let empty = TokenBreakdown(
        freshInput: 0, output: 0,
        cacheCreation: 0, cacheRead: 0,
        preComputedCost: 0
    )
}
