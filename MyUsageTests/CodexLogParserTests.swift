import Testing
import Foundation
@testable import MyUsage

@Suite("CodexLogParser Tests")
struct CodexLogParserTests {

    @Test("Normalizes Codex model identifiers to display families")
    func normalizeFamilies() {
        #expect(CodexLogParser.normalizeModelFamily("gpt-5-codex") == "GPT-5 Codex")
        #expect(CodexLogParser.normalizeModelFamily("gpt-5.2-codex") == "GPT-5.2 Codex")
        #expect(CodexLogParser.normalizeModelFamily("gpt-5.1-codex-max") == "GPT-5.1 Codex Max")
        #expect(CodexLogParser.normalizeModelFamily("gpt-5") == "GPT-5")
        #expect(CodexLogParser.normalizeModelFamily("gpt-5-2025-08-07") == "GPT-5")
        #expect(CodexLogParser.normalizeModelFamily("codex-mini-latest") == "Codex Mini Latest")
        #expect(CodexLogParser.normalizeModelFamily("") == nil)
    }

    @Test("Skips malformed lines and unrelated payloads in local usage scan")
    func skipsMalformedAndUnrelated() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-local-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-25T15:00:00Z")!

        let jsonl = """
        {"type":"event_msg","timestamp":"2026-11-25T14:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999,"output_tokens":999}}}}
        {"type":"turn_context","timestamp":"2026-11-25T14:00:00Z","payload":{"model":"GPT-5-Codex"}}
        {not valid json
        {"type":"session_meta","payload":{"id":"abc"}}
        {"type":"event_msg","timestamp":"2026-11-25T14:05:00Z","payload":{"type":"stream_error","info":null}}
        {"type":"event_msg","timestamp":"2026-11-25T14:10:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"reasoning_output_tokens":5}}}}
        """
        let file = root.appendingPathComponent("rollout.jsonl")
        try jsonl.write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let report = CodexLogParser.scanLocalUsage(roots: [root], now: now, calendar: cal)
        #expect(report.orderedModelNames == ["GPT-5 Codex"])
        #expect(report.hours[14].combinedTokens == TokenUsage(input: 60, output: 15, cachedInput: 40))
    }
}
