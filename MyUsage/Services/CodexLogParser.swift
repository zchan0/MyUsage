import Foundation

/// Parses Codex CLI's local JSONL session logs to build `LocalUsageReport`.
///
/// Log location: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and
/// `~/.codex/archived_sessions/*.jsonl`.
///
/// Codex logs are stateful:
/// * `turn_context.payload.model` updates the current model for subsequent turns.
/// * `event_msg.payload.type == "token_count"` carries per-turn `last_token_usage`
///   deltas accumulated against the active model.
enum CodexLogParser {

    // MARK: - Decoded shape

    private struct Row: Decodable {
        let type: String?
        let payload: Payload?
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

        var tokens: TokenUsage {
            let cached = cachedInputTokens ?? 0
            return TokenUsage(
                input: max(0, (inputTokens ?? 0) - cached),
                output: (outputTokens ?? 0) + (reasoningOutputTokens ?? 0),
                cachedInput: cached
            )
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

    /// Normalise a raw Codex model identifier into a display family:
    /// strips a trailing date snapshot ("gpt-5-2025-08-07" → "GPT-5"),
    /// uppercases the gpt prefix and capitalises word tokens
    /// ("gpt-5.2-codex" → "GPT-5.2 Codex"). Version tokens stay as-is.
    static func normalizeModelFamily(_ raw: String) -> String? {
        var lc = raw.lowercased()
        guard !lc.isEmpty else { return nil }
        // Drop a trailing -YYYY-MM-DD snapshot suffix.
        if let match = lc.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            lc.removeSubrange(match)
        }
        var out = ""
        for part in lc.split(separator: "-") {
            let token = String(part)
            let display = token.hasPrefix("gpt") ? token.uppercased() : token.capitalized
            if out.isEmpty {
                out = display
            } else if token.first?.isNumber == true {
                // Version tokens attach to the name: "gpt" + "5.2" → "GPT-5.2".
                out += "-" + token
            } else {
                out += " " + display
            }
        }
        return out.isEmpty ? nil : out
    }

    static func scanLocalUsage(
        roots: [URL] = defaultRoots(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LocalUsageReport {
        var scan = LocalUsageLogScan(now: now, calendar: calendar)
        let decoder = JSONDecoder()
        for file in scan.files(in: roots) {
            var currentModel: String?
            LocalUsageLogScan.readRows(in: file, decoder: decoder, timestamp: \Row.timestamp) { row, time in
                switch row.type {
                case "turn_context":
                    currentModel = row.payload?.model.flatMap(normalizeModelFamily)
                case "event_msg":
                    guard row.payload?.type == "token_count", let usage = row.payload?.info?.lastTokenUsage,
                          let model = currentModel, let time else { return }
                    let tokens = usage.tokens
                    guard !tokens.isEmpty else { return }
                    scan.add(.init(tokens: tokens), for: model, at: time)
                default:
                    break
                }
            }
        }
        return scan.report()
    }
}
