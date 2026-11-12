import Foundation

/// Parses Antigravity's local conversation transcript logs to aggregate token
/// usage and prompt-cache hit rates by model.
///
/// Log location: `~/.gemini/antigravity/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`
///
/// Only `transcript.jsonl` is read (never `transcript_full.jsonl`, which mirrors
/// the same steps with untruncated payloads and would double-count tokens).
enum AntigravityLogParser {

    private struct Row: Decodable {
        let createdAt: String?
        let model: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?

        enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case model
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
        }

        var tokens: TokenUsage {
            TokenUsage(
                input: max(0, inputTokens ?? 0),
                output: max(0, outputTokens ?? 0),
                cacheRead: max(0, cacheReadTokens ?? 0)
            )
        }
    }

    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)]
    }

    private static let effortSuffixes: Set<String> = [
        "xhigh", "high", "medium", "low", "minimal", "thinking"
    ]

    /// Normalize raw Antigravity model identifiers (e.g. `"gemini-4-neon-xhigh"`,
    /// `"claude-opus-5-5-high"`) into concise display labels.
    static func normalizeDisplayModel(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, !cleaned.hasPrefix("<") else { return nil }

        // Strip trailing -YYYY-MM-DD or -YYYYMMDD date stamps.
        if let match = cleaned.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            cleaned.removeSubrange(match)
        } else if let match = cleaned.range(of: #"-\d{8}$"#, options: .regularExpression) {
            cleaned.removeSubrange(match)
        }

        var parts = cleaned.split(separator: "-").map(String.init)
        while let last = parts.last, effortSuffixes.contains(last) {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return nil }

        if parts.first == "claude" {
            let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
            let rest = Array(parts.dropFirst())
            guard let family = rest.first, !family.isEmpty else { return "Claude" }
            let version = rest.dropFirst().filter {
                (1...2).contains($0.utf8.count) && $0.utf8.allSatisfy(digits.contains)
            }
            return version.isEmpty
                ? "Claude \(family.capitalized)"
                : "Claude \(family.capitalized) \(version.joined(separator: "."))"
        }

        if parts.first == "gpt" {
            return CodexLogParser.normalizeModelFamily(parts.joined(separator: "-"))
        }

        // Default (Gemini and other families): join words with spaces, merging
        // consecutive short numeric version segments like "2" + "5" → "2.5".
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        var formatted: [String] = []
        var index = 0
        while index < parts.count {
            let part = parts[index]
            let isShortNumber = (1...2).contains(part.utf8.count) && part.utf8.allSatisfy(digits.contains)
            if isShortNumber {
                var versionParts = [part]
                while index + 1 < parts.count {
                    let next = parts[index + 1]
                    if (1...2).contains(next.utf8.count) && next.utf8.allSatisfy(digits.contains) {
                        versionParts.append(next)
                        index += 1
                    } else {
                        break
                    }
                }
                formatted.append(versionParts.joined(separator: "."))
            } else {
                formatted.append(part.capitalized)
            }
            index += 1
        }

        return formatted.isEmpty ? nil : formatted.joined(separator: " ")
    }

    static func scanLocalUsage(
        roots: [URL] = defaultRoots(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LocalUsageReport {
        var scan = LocalUsageLogScan(now: now, calendar: calendar)
        let decoder = JSONDecoder()

        for file in transcriptFiles(in: roots, modifiedSince: scan.windowStart) {
            LocalUsageLogScan.readRows(in: file, decoder: decoder, timestamp: \Row.createdAt) { row, time in
                guard let time,
                      let rawModel = row.model,
                      let model = normalizeDisplayModel(rawModel) else { return }
                let tokens = row.tokens
                guard !tokens.isEmpty else { return }
                scan.add(.init(tokens: tokens), for: model, at: time)
            }
        }

        return scan.report()
    }

    /// Locate `<root>/<conversation-id>/.system_generated/logs/transcript.jsonl`
    /// without recursing into hidden folders or picking up `transcript_full.jsonl`.
    private static func transcriptFiles(in roots: [URL], modifiedSince cutoff: Date) -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var files: Set<URL> = []

        for root in roots {
            guard let conversations = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for conversation in conversations {
                let candidate = conversation
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl", isDirectory: false)
                guard let values = try? candidate.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      mtime >= cutoff else { continue }
                files.insert(candidate.standardizedFileURL)
            }
        }

        return files.sorted { $0.path < $1.path }
    }
}
