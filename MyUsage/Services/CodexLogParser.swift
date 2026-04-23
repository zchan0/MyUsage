import Foundation

/// Parses Codex CLI's JSONL session logs to aggregate token usage by model.
///
/// Log location: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and
/// `~/.codex/archived_sessions/*.jsonl`.
///
/// Codex logs are stateful:
/// * `turn_context.payload.model` updates the current model for subsequent turns.
/// * `event_msg.payload.type == "token_count"` contains BOTH a cumulative
///   `total_token_usage` and a per-turn `last_token_usage`. We accumulate the
///   `last_token_usage` deltas against the current model.
enum CodexLogParser {

    // MARK: - Decoded shape

    private struct Row: Decodable {
        let type: String?
        let payload: Payload?
        /// Top-level ISO 8601 timestamp written by Codex CLI (≥ 0.55). Used
        /// by the multi-device ledger (spec 12) to bucket costs by UTC day.
        /// Falls back to the containing directory date when missing.
        let timestamp: String?
    }

    private struct Payload: Decodable {
        // turn_context
        let model: String?
        // event_msg
        let type: String?
        let info: Info?
    }

    private struct Info: Decodable {
        let lastTokenUsage: Usage?
        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
        }
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
        }
    }

    // MARK: - Default roots

    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions")
        ]
    }

    // MARK: - Public API

    static func scan(since: Date) -> UsageByModel {
        scan(roots: defaultRoots(), since: since)
    }

    static func scan(roots: [URL], since: Date) -> UsageByModel {
        var result: UsageByModel = [:]
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

                parseFile(url: url, into: &result)
            }
        }
        return result
    }

    static func parseFile(url: URL, into result: inout UsageByModel) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        parse(data: data, into: &result)
    }

    // MARK: - Per-day cost breakdown (ledger)

    /// Scan default roots, producing a `YYYY-MM-DD` (UTC) → USD map for all
    /// JSONL files modified since `since`. Used by the multi-device ledger.
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
        // Fallback: prefer the folder date (sessions/YYYY/MM/DD/…) when the
        // row itself doesn't carry a timestamp; else the file mtime.
        let fallbackDay = folderDayKey(url: url) ?? LedgerCalendar.dayKey(for: mtime)

        var currentModel: String?
        var lastDay = fallbackDay
        var acc = result

        text.enumerateLines { line, _ in
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return }
            guard let row = try? decoder.decode(Row.self, from: lineData) else { return }

            if let ts = row.timestamp, let parsed = Self.parseTimestamp(ts) {
                lastDay = LedgerCalendar.dayKey(for: parsed)
            }

            switch row.type {
            case "turn_context":
                if let m = row.payload?.model, !m.isEmpty {
                    currentModel = m.lowercased()
                }
            case "event_msg":
                guard row.payload?.type == "token_count",
                      let u = row.payload?.info?.lastTokenUsage,
                      let model = currentModel
                else { return }
                let cached = u.cachedInputTokens ?? 0
                let rawInput = u.inputTokens ?? 0
                let nonCachedInput = max(0, rawInput - cached)
                let output = (u.outputTokens ?? 0) + (u.reasoningOutputTokens ?? 0)
                let tokens = TokenUsage(
                    input: nonCachedInput,
                    output: output,
                    cachedInput: cached
                )
                guard tokens.input + tokens.output + tokens.cachedInput > 0 else { return }
                let usd = CostCalculator.cost(
                    usage: tokens,
                    model: model,
                    catalog: catalog
                )
                guard usd > 0 else { return }
                acc[lastDay, default: 0] += usd
            default:
                return
            }
        }
        result = acc
    }

    /// Extract a `YYYY-MM-DD` key from a Codex session path like
    /// `…/sessions/2026/04/22/rollout-foo.jsonl`.
    private static func folderDayKey(url: URL) -> String? {
        let parts = url.pathComponents
        // …/YYYY/MM/DD/<file.jsonl>
        guard parts.count >= 4 else { return nil }
        let year = parts[parts.count - 4]
        let month = parts[parts.count - 3]
        let day = parts[parts.count - 2]
        guard year.count == 4, Int(year) != nil,
              month.count == 2, Int(month) != nil,
              day.count == 2,   Int(day)   != nil
        else { return nil }
        return "\(year)-\(month)-\(day)"
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return d }
        let basic = ISO8601DateFormatter()
        return basic.date(from: raw)
    }

    /// Parse raw JSONL bytes. Tracks current model across turn_context rows.
    static func parse(data: Data, into result: inout UsageByModel) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        var currentModel: String? = nil
        var acc = result
        text.enumerateLines { line, _ in
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return }
            guard let row = try? decoder.decode(Row.self, from: lineData) else { return }

            switch row.type {
            case "turn_context":
                if let m = row.payload?.model, !m.isEmpty {
                    currentModel = m.lowercased()
                }
            case "event_msg":
                guard row.payload?.type == "token_count",
                      let u = row.payload?.info?.lastTokenUsage,
                      let model = currentModel
                else { return }
                let cached = u.cachedInputTokens ?? 0
                let rawInput = u.inputTokens ?? 0
                let nonCachedInput = max(0, rawInput - cached)
                let output = (u.outputTokens ?? 0) + (u.reasoningOutputTokens ?? 0)
                let tokens = TokenUsage(
                    input: nonCachedInput,
                    output: output,
                    cachedInput: cached
                )
                guard tokens.input + tokens.output + tokens.cachedInput > 0 else { return }
                acc.add(tokens, for: model)
            default:
                return
            }
        }
        result = acc
    }
}
