import Foundation

/// Aggregated token counts for a single model across one or more requests.
///
/// Fields are named to cover both Anthropic and OpenAI billing breakdowns.
/// Parsers are responsible for splitting totals into the correct buckets
/// before handing the struct to `CostCalculator`.
struct TokenUsage: Sendable, Equatable, Codable {
    /// Non-cached input tokens.
    /// - Anthropic: the raw `input_tokens` field.
    /// - OpenAI: `input_tokens − cached_input_tokens`.
    var input: Int = 0

    /// Output tokens. For OpenAI, parsers add `reasoning_output_tokens` here
    /// because they bill at the same output rate.
    var output: Int = 0

    /// Anthropic cache-creation (write) input tokens at the 5-minute TTL,
    /// billed at 1.25× input. 0 for OpenAI.
    var cacheWrite5m: Int = 0

    /// Anthropic cache-creation (write) input tokens at the 1-hour TTL,
    /// billed at 2× input — a 60% premium over the 5-minute rate.
    ///
    /// Claude Code writes with the 1-hour TTL, so on Claude this is normally
    /// the whole of the cache-write volume. It flips to `cacheWrite5m` when
    /// the server downgrades the session's TTL, which happens once the 5-hour
    /// quota is exhausted. Keeping the two apart is what makes that downgrade
    /// visible — and what keeps the cost estimate honest, since collapsing
    /// them charges 1-hour writes at the cheaper 5-minute rate.
    var cacheWrite1h: Int = 0

    /// Anthropic cache-read input tokens. 0 for OpenAI.
    var cacheRead: Int = 0

    /// OpenAI cached input tokens. 0 for Anthropic.
    var cachedInput: Int = 0

    static let zero = TokenUsage()

    /// Cache-write tokens across both TTLs. Callers that only need the volume
    /// (the UI's cache total, the ledger's aggregate) use this; anything that
    /// prices them must read the two buckets, which bill differently.
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    /// Every cache bucket normalised into the one number the UI presents.
    /// Claude contributes cache reads + writes; Codex contributes cached
    /// input. Keeping the wire fields separate preserves pricing semantics.
    var cache: Int { cacheWrite + cacheRead + cachedInput }

    /// Total processed tokens across input, output, and all cache buckets.
    var total: Int { input + output + cache }

    var isEmpty: Bool { total == 0 }

    /// Convenience for the common case where the TTL split is unknown or
    /// irrelevant (tests, OpenAI, legacy rows): everything lands in the
    /// 5-minute bucket, which is the conservative — cheaper — rate.
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

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cachedInput
        case cacheWrite5m, cacheWrite1h
        /// Pre-split ledger rows stored a single combined figure.
        case legacyCacheWrite = "cacheWrite"
    }

    /// Ledger rows written before the TTL split carry only `cacheWrite`. They
    /// cannot be attributed after the fact, so they decode into the 5-minute
    /// bucket — the cheaper rate, which preserves the cost those rows were
    /// originally recorded with rather than silently revaluing history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cachedInput = try c.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        cacheWrite5m = try c.decodeIfPresent(Int.self, forKey: .cacheWrite5m)
            ?? c.decodeIfPresent(Int.self, forKey: .legacyCacheWrite)
            ?? 0
    }

    /// Also emits the combined `cacheWrite` so a ledger row stays readable by
    /// an older build during a downgrade.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        try c.encode(cacheWrite5m, forKey: .cacheWrite5m)
        try c.encode(cacheWrite1h, forKey: .cacheWrite1h)
        try c.encode(cacheRead, forKey: .cacheRead)
        try c.encode(cachedInput, forKey: .cachedInput)
        try c.encode(cacheWrite, forKey: .legacyCacheWrite)
    }
}

/// Token usage aggregated by model name.
typealias UsageByModel = [String: TokenUsage]

extension Dictionary where Key == String, Value == TokenUsage {
    mutating func add(_ usage: TokenUsage, for model: String) {
        self[model, default: .zero] += usage
    }
}
