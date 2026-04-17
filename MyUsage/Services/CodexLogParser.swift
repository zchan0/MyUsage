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
