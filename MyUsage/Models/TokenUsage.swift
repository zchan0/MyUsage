import Foundation

/// Aggregated token counts for a single model across one or more requests.
///
/// Fields cover Anthropic, OpenAI, and Antigravity token breakdowns used for
/// local usage totals and cache hit rate calculations.
struct TokenUsage: Sendable, Equatable, Codable {
    /// Non-cached input tokens.
    /// - Anthropic: the raw `input_tokens` field.
    /// - OpenAI: `input_tokens − cached_input_tokens`.
    var input: Int = 0

    /// Output tokens. For OpenAI, parsers add `reasoning_output_tokens` here.
    var output: Int = 0

    /// Anthropic cache-creation (write) input tokens at the 5-minute TTL.
    var cacheWrite5m: Int = 0

    /// Anthropic cache-creation (write) input tokens at the 1-hour TTL.
    var cacheWrite1h: Int = 0

    /// Anthropic / Antigravity cache-read input tokens.
    var cacheRead: Int = 0

    /// OpenAI cached input tokens.
    var cachedInput: Int = 0

    static let zero = TokenUsage()

    /// Cache-write tokens across both TTLs.
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    /// Every cache bucket normalised into a single total.
    var cache: Int { cacheWrite + cacheRead + cachedInput }

    /// Total processed tokens across input, output, and all cache buckets.
    var total: Int { input + output + cache }

    var isEmpty: Bool { total == 0 }

    init(
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        cachedInput: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite
        self.cacheWrite1h = 0
        self.cacheRead = cacheRead
        self.cachedInput = cachedInput
    }

    init(
        input: Int,
        output: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        cacheRead: Int,
        cachedInput: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.cachedInput = cachedInput
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cachedInput: lhs.cachedInput + rhs.cachedInput
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}
