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

    /// Parse a single JSONL file, adding tokens into `into`.
    /// Errors are swallowed silently — logs may be partial or mid-write.
    static func parseFile(url: URL, into result: inout UsageByModel) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        parse(data: data, into: &result)
    }

    /// Parse raw JSONL bytes.
    static func parse(data: Data, into result: inout UsageByModel) {
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

    private static func handleLine(_ lineData: Data, decoder: JSONDecoder, result: inout UsageByModel) {
        guard let row = try? decoder.decode(Row.self, from: lineData) else { return }
        guard row.type == "assistant",
              let message = row.message,
              let model = message.model,
              let usage = message.usage
        else { return }

        let tokens = TokenUsage(
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheWrite: usage.cacheCreationInputTokens ?? 0,
            cacheRead: usage.cacheReadInputTokens ?? 0
        )
        // Skip no-op rows that all sum to 0 (queue-ops, errors, etc.)
        guard tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead > 0 else { return }

        result.add(tokens, for: model.lowercased())
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
