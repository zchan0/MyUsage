import Foundation

/// Parses Claude Code's local JSONL session logs to build `LocalUsageReport`
/// (token activity, prompt-cache hit rates, and agent-reported costs).
///
/// Log location: `~/.claude/projects/**/*.jsonl` (legacy) or
/// `~/.config/claude/projects/**/*.jsonl` (Claude Code v1.0.30+).
enum ClaudeLogParser {

    // MARK: - Decoded shape (lenient)

    private struct LocalUsageRow: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?
        let costUSD: Double?
        let modelUsage: [String: ModelCostEntry]?

        enum CodingKeys: String, CodingKey {
            case type, timestamp, message, costUSD, modelUsage
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try? values.decode(String.self, forKey: .type)
            timestamp = try? values.decode(String.self, forKey: .timestamp)
            message = type == "assistant" ? try? values.decode(Message.self, forKey: .message) : nil
            costUSD = type == "assistant" ? try? values.decode(Double.self, forKey: .costUSD) : nil
            modelUsage = type == "cost-state" ? try? values.decode([String: ModelCostEntry].self, forKey: .modelUsage) : nil
        }

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
            }

            struct CacheCreation: Decodable {
                let ephemeral5mInputTokens: Int?
                let ephemeral1hInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
                    case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
                }
            }

            var cacheWriteByTTL: (fiveMinute: Int, oneHour: Int) {
                guard let cacheCreation,
                      cacheCreation.ephemeral5mInputTokens != nil
                        || cacheCreation.ephemeral1hInputTokens != nil
                else {
                    return (cacheCreationInputTokens ?? 0, 0)
                }
                return (
                    cacheCreation.ephemeral5mInputTokens ?? 0,
                    cacheCreation.ephemeral1hInputTokens ?? 0
                )
            }

            var tokens: TokenUsage {
                let cacheWrite = cacheWriteByTTL
                return TokenUsage(
                    input: inputTokens ?? 0,
                    output: outputTokens ?? 0,
                    cacheWrite5m: cacheWrite.fiveMinute,
                    cacheWrite1h: cacheWrite.oneHour,
                    cacheRead: cacheReadInputTokens ?? 0
                )
            }
        }
    }

    private struct ModelCostEntry: Decodable {
        let costUSD: Double?

        enum CodingKeys: String, CodingKey { case costUSD }

        init(from decoder: Decoder) {
            // Decode each model total independently.
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            costUSD = try? values?.decode(Double.self, forKey: .costUSD)
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

    /// Keep the display version while dropping dated releases and tags.
    static func normalizeDisplayModel(_ raw: String) -> String? {
        let lowercased = raw.lowercased()
        let prefix = "claude-"
        guard lowercased.hasPrefix(prefix) else { return nil }
        let parts = lowercased.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard let family = parts.first, !family.isEmpty else { return nil }
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        let version = parts.dropFirst().filter { (1...2).contains($0.utf8.count) && $0.utf8.allSatisfy(digits.contains) }
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version.joined(separator: "."))"
    }

    static func scanLocalUsage(
        roots: [URL] = defaultRoots(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LocalUsageReport {
        var scan = LocalUsageLogScan(now: now, calendar: calendar)
        let decoder = JSONDecoder()
        for file in scan.files(in: roots) {
            var previousCostByModel: [String: Double] = [:]
            LocalUsageLogScan.readRows(in: file, decoder: decoder, timestamp: \LocalUsageRow.timestamp) { row, time in
                switch row.type {
                case "assistant":
                    guard let time, let rawModel = row.message?.model, let usage = row.message?.usage,
                          let model = normalizeDisplayModel(rawModel) else { return }
                    let cost = row.costUSD ?? 0
                    let reportedCost = cost.isFinite && cost > 0 ? cost : 0
                    let tokens = usage.tokens
                    guard !tokens.isEmpty || reportedCost > 0 else { return }
                    scan.add(.init(tokens: tokens, reportedCostUSD: reportedCost), for: model, at: time)
                case "cost-state":
                    guard let entries = row.modelUsage else { return }
                    for rawModel in entries.keys.sorted() {
                        guard let cost = entries[rawModel]?.costUSD, cost.isFinite, cost >= 0 else { continue }
                        let previous = previousCostByModel.updateValue(cost, forKey: rawModel) ?? 0
                        let delta = cost >= previous ? cost - previous : cost
                        guard let time, delta > 0, let model = normalizeDisplayModel(rawModel) else { continue }
                        scan.add(.init(reportedCostUSD: delta), for: model, at: time)
                    }
                default:
                    break
                }
            }
        }
        return scan.report()
    }
}
