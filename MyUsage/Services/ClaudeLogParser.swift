import Foundation

/// Parses Claude Code's JSONL session logs to aggregate token usage by model.
///
/// Log location: `~/.claude/projects/**/*.jsonl` (legacy) or
/// `~/.config/claude/projects/**/*.jsonl` (Claude Code v1.0.30+).
///
/// Each `type=assistant` line looks like:
/// ```
/// { "type": "assistant",
///   "message": {
///     "model": "claude-sonnet-4-5",
///     "usage": {
///       "input_tokens": 19258,
///       "output_tokens": 2,
///       "cache_creation_input_tokens": 0,
///       "cache_read_input_tokens": 0
///     }
///   }, ... }
/// ```
enum ClaudeLogParser {

    // MARK: - Decoded shape (lenient)

    private struct Row: Decodable {
        let type: String?
        let message: Message?
        /// Pre-computed USD cost written by Claude Code v1.x. When present we
        /// trust it instead of re-pricing tokens locally (matches ccusage's
        /// `auto` mode).
        let costUSD: Double?
        /// ISO 8601 timestamp at the top level of each JSONL row (Claude Code
        /// writes this for assistant / user messages). Used by the ledger
        /// to bucket costs by UTC day. Falls back to file mtime when missing.
        let timestamp: String?

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    // MARK: - Breakdown (cost-aware)

    /// Output of a cost-aware scan.
    ///
    /// - `preComputedCost`: sum of `costUSD` fields from rows that already
    ///   carry a server-computed dollar amount.
    /// - `tokensByModel`: tokens from rows that did **not** have `costUSD`;
    ///   callers should price these via `CostCalculator` and add the result
    ///   to `preComputedCost` for the final monthly estimate.
    struct Breakdown: Equatable {
        var preComputedCost: Double = 0
        var tokensByModel: UsageByModel = [:]
    }

    // MARK: - Default roots

    /// Default search roots, in priority order. Non-existent paths are OK.
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects")
        ]
    }

    // MARK: - Public API

    /// Scan the default roots, summing tokens by model for all `.jsonl` files
    /// modified on or after `since`.
    static func scan(since: Date) -> UsageByModel {
        scan(roots: defaultRoots(), since: since)
    }

    /// Scan the given roots. Useful for tests.
    static func scan(roots: [URL], since: Date) -> UsageByModel {
        scanBreakdown(roots: roots, since: since).tokensByModel
    }

    /// Parse a single JSONL file, adding tokens into `into`.
    /// Errors are swallowed silently — logs may be partial or mid-write.
    static func parseFile(url: URL, into result: inout UsageByModel) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        parse(data: data, into: &result)
    }

    /// Parse raw JSONL bytes.
    static func parse(data: Data, into result: inout UsageByModel) {
        var breakdown = Breakdown(tokensByModel: result)
        parseBreakdown(data: data, into: &breakdown)
        result = breakdown.tokensByModel
    }

    // MARK: - Cost-aware API

    /// Scan default roots, producing a cost-aware breakdown.
    static func scanBreakdown(since: Date) -> Breakdown {
        scanBreakdown(roots: defaultRoots(), since: since)
    }

    /// Scan the given roots, producing a cost-aware breakdown.
    static func scanBreakdown(roots: [URL], since: Date) -> Breakdown {
        var result = Breakdown()
        let fm = FileManager.default
        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      mtime >= since
                else { continue }

                parseFileBreakdown(url: url, into: &result)
            }
        }
        return result
    }

    /// Latest `contentModificationDate` across all in-scope JSONL files,
    /// or `nil` if no such files exist. Used by the cost cache as the
    /// invalidation key — cheap stat-only walk, no parsing.
    static func maxMtime(roots: [URL] = defaultRoots(), since: Date) -> Date? {
        let fm = FileManager.default
        var best: Date?
        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      mtime >= since
                else { continue }

                if best.map({ mtime > $0 }) ?? true {
                    best = mtime
                }
            }
        }
        return best
    }

    /// Parse a single JSONL file into a cost-aware breakdown.
    static func parseFileBreakdown(url: URL, into result: inout Breakdown) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        parseBreakdown(data: data, into: &result)
    }

    // MARK: - Per-day cost breakdown (ledger)

    /// Scan default roots, producing a `YYYY-MM-DD` (UTC) → USD map for all
    /// JSONL files modified since `since`. Used by the multi-device ledger
    /// (spec 12) — each day is one ledger entry.
    static func scanDailyCost(
        since: Date,
        catalog: PricingCatalog = .shared
    ) -> [String: Double] {
        scanDailyCost(roots: defaultRoots(), since: since, catalog: catalog)
    }

    /// Testable core of `scanDailyCost`.
    static func scanDailyCost(
        roots: [URL],
        since: Date,
        catalog: PricingCatalog = .shared
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        let fm = FileManager.default
        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      mtime >= since
                else { continue }

                parseFileDaily(url: url, mtime: mtime, into: &result, catalog: catalog)
            }
        }
        return result
    }

    private static func parseFileDaily(
        url: URL,
        mtime: Date,
        into result: inout [String: Double],
        catalog: PricingCatalog
    ) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
        else { return }

        let decoder = JSONDecoder()
        let fallbackDay = LedgerCalendar.dayKey(for: mtime)
        var acc = result

        text.enumerateLines { line, _ in
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return }
            guard let row = try? decoder.decode(Row.self, from: lineData) else { return }
            guard row.type == "assistant",
                  let message = row.message,
                  let model = message.model,
                  let usage = message.usage
            else { return }

            let day = row.timestamp
                .flatMap(Self.parseTimestamp)
                .map(LedgerCalendar.dayKey) ?? fallbackDay

            if let cost = row.costUSD, cost > 0 {
                acc[day, default: 0] += cost
                return
            }

            let tokens = TokenUsage(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0
            )
            let total = tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead
            guard total > 0 else { return }

            let usd = CostCalculator.cost(
                usage: tokens,
                model: model.lowercased(),
                catalog: catalog
            )
            guard usd > 0 else { return }

            acc[day, default: 0] += usd
        }
        result = acc
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return d }
        let basic = ISO8601DateFormatter()
        return basic.date(from: raw)
    }

    /// Parse raw JSONL bytes into a cost-aware breakdown.
    static func parseBreakdown(data: Data, into result: inout Breakdown) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        var acc = result
        text.enumerateLines { line, _ in
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return }
            Self.handleLine(lineData, decoder: decoder, result: &acc)
        }
        result = acc
    }

    // MARK: - Single-line dispatch

    private static func handleLine(_ lineData: Data, decoder: JSONDecoder, result: inout Breakdown) {
        guard let row = try? decoder.decode(Row.self, from: lineData) else { return }
        guard row.type == "assistant",
              let message = row.message,
              let model = message.model,
              let usage = message.usage
        else { return }

        // Prefer server-computed costUSD when present. Matches ccusage `auto`
        // mode and insulates us from pricing drift / prompt-cache quirks.
        if let cost = row.costUSD, cost > 0 {
            result.preComputedCost += cost
            return
        }

        let tokens = TokenUsage(
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheWrite: usage.cacheCreationInputTokens ?? 0,
            cacheRead: usage.cacheReadInputTokens ?? 0
        )
        // Skip no-op rows that all sum to 0 (queue-ops, errors, etc.)
        guard tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead > 0 else { return }

        result.tokensByModel.add(tokens, for: model.lowercased())
    }
}

// MARK: - Calendar helper

extension Date {
    /// Start of the current calendar month in the provided calendar (local time).
    static func startOfCurrentMonth(calendar: Calendar = .current, now: Date = .now) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: comps) ?? now
    }
}
