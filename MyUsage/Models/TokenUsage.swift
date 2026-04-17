import Foundation

/// Aggregated token counts for a single model across one or more requests.
///
/// Fields are named to cover both Anthropic and OpenAI billing breakdowns.
/// Parsers are responsible for splitting totals into the correct buckets
/// before handing the struct to `CostCalculator`.
struct TokenUsage: Sendable, Equatable {
    /// Non-cached input tokens.
    /// - Anthropic: the raw `input_tokens` field.
    /// - OpenAI: `input_tokens − cached_input_tokens`.
    var input: Int = 0

    /// Output tokens. For OpenAI, parsers add `reasoning_output_tokens` here
    /// because they bill at the same output rate.
    var output: Int = 0

    /// Anthropic cache-creation (write) input tokens. 0 for OpenAI.
    var cacheWrite: Int = 0

    /// Anthropic cache-read input tokens. 0 for OpenAI.
    var cacheRead: Int = 0

    /// OpenAI cached input tokens. 0 for Anthropic.
    var cachedInput: Int = 0

    static let zero = TokenUsage()

    static func + (lhs: Self, rhs: Self) -> Self {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cachedInput: lhs.cachedInput + rhs.cachedInput
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

/// Token usage aggregated by model name.
typealias UsageByModel = [String: TokenUsage]

extension Dictionary where Key == String, Value == TokenUsage {
    mutating func add(_ usage: TokenUsage, for model: String) {
        self[model, default: .zero] += usage
    }
}
