import Testing
import Foundation
@testable import MyUsage

@Suite("CodexLogParser Tests")
struct CodexLogParserTests {

    // MARK: - Basic row handling

    @Test("Parses a full turn_context + token_count pair")
    func parsesBasic() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3540,"cached_input_tokens":3072,"output_tokens":46,"reasoning_output_tokens":0}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        // non_cached = 3540 - 3072 = 468
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 468, output: 46, cachedInput: 3072))
    }

    @Test("Aggregates last_token_usage across multiple events")
    func aggregatesTurns() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":50,"output_tokens":20,"reasoning_output_tokens":10}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        // turn 1: input 100, output 50, cached 0
        // turn 2: input 150 (200-50), output 30 (20+10), cached 50
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 250, output: 80, cachedInput: 50))
    }

    @Test("Reasoning tokens are billed at the output rate")
    func reasoningRollsIntoOutput() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":90}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 0, output: 100))
    }

    @Test("Switches model when a later turn_context arrives")
    func modelSwitch() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}}
        {"type":"turn_context","payload":{"model":"gpt-5-mini"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 100, output: 10))
        #expect(acc["gpt-5-mini"] == TokenUsage(input: 50, output: 5))
    }

    @Test("Drops token_count rows that arrive before any turn_context")
    func tokenCountBeforeModel() {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999,"cached_input_tokens":0,"output_tokens":999}}}}
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        #expect(acc.count == 1)
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 10, output: 5))
    }

    @Test("Ignores unrelated event payloads")
    func ignoresUnrelated() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"session_meta","payload":{"id":"abc"}}
        {"type":"response_item","payload":{"type":"message"}}
        {"type":"event_msg","payload":{"type":"stream_error","info":null}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 10, output: 5))
    }

    @Test("Skips malformed lines")
    func skipsMalformed() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {not valid json
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["gpt-5-codex"] == TokenUsage(input: 10, output: 5))
    }

    @Test("Model name is lowercased")
    func lowercasesModel() {
        let jsonl = """
        {"type":"turn_context","payload":{"model":"GPT-5-Codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        CodexLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["gpt-5-codex"] != nil)
    }

    // MARK: - File scanning

    @Test("Scans only jsonl files modified since the cutoff")
    func scanCutoff() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("codex-log-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let sub = tmp.appendingPathComponent("2026/04/01")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        let recent = sub.appendingPathComponent("rollout-new.jsonl")
        let old    = sub.appendingPathComponent("rollout-old.jsonl")
        let rollout = """
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":50}}}}
        """
        try rollout.write(to: recent, atomically: true, encoding: .utf8)
        try rollout.write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60*86400)], ofItemAtPath: old.path)

        let result = CodexLogParser.scan(roots: [tmp], since: Date(timeIntervalSinceNow: -86400))
        #expect(result["gpt-5-codex"] == TokenUsage(input: 100, output: 50))
    }
}
