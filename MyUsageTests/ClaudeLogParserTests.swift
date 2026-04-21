import Testing
import Foundation
@testable import MyUsage

@Suite("ClaudeLogParser Tests")
struct ClaudeLogParserTests {

    // MARK: - Line parsing

    @Test("Parses a typical assistant row")
    func parsesAssistantRow() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":200}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["claude-sonnet-4-5"] == TokenUsage(input: 100, output: 50, cacheWrite: 10, cacheRead: 200))
    }

    @Test("Lowercases model name for stable lookup")
    func lowercasesModel() {
        let jsonl = """
        {"type":"assistant","message":{"model":"Claude-Sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["claude-sonnet-4-5"] != nil)
    }

    @Test("Ignores non-assistant rows")
    func ignoresNonAssistant() {
        let jsonl = """
        {"type":"user","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":2000}}}
        {"type":"progress"}
        {"type":"queue-operation"}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc.isEmpty)
    }

    @Test("Ignores rows with zero tokens")
    func ignoresZero() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":0}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc.isEmpty)
    }

    @Test("Handles missing optional cache fields")
    func missingCacheFields() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-opus-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["claude-opus-4-5"] == TokenUsage(input: 100, output: 50))
    }

    @Test("Skips malformed lines and continues")
    func skipsMalformed() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}
        {not json
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":20,"output_tokens":10}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["claude-sonnet-4-5"] == TokenUsage(input: 30, output: 15))
    }

    @Test("Aggregates multiple models")
    func multipleModels() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","message":{"model":"claude-opus-4-5","usage":{"input_tokens":200,"output_tokens":100}}}
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}
        """.data(using: .utf8)!
        var acc: UsageByModel = [:]
        ClaudeLogParser.parse(data: jsonl, into: &acc)
        #expect(acc["claude-sonnet-4-5"] == TokenUsage(input: 110, output: 55))
        #expect(acc["claude-opus-4-5"] == TokenUsage(input: 200, output: 100))
    }

    // MARK: - File scanning

    @Test("Scans only files modified since the cutoff")
    func scansSinceCutoff() throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("claude-log-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        let nested = tmpRoot.appendingPathComponent("-Users-me/proj")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        let recentFile = nested.appendingPathComponent("recent.jsonl")
        let oldFile    = nested.appendingPathComponent("old.jsonl")
        let irrelevantFile = nested.appendingPathComponent("ignore.txt")

        let row = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        try row.write(to: recentFile, atomically: true, encoding: .utf8)
        try row.write(to: oldFile, atomically: true, encoding: .utf8)
        try "plain text".write(to: irrelevantFile, atomically: true, encoding: .utf8)

        // Push old file's mtime 60 days back
        let oldDate = Date(timeIntervalSinceNow: -60 * 24 * 3600)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)

        let cutoff = Date(timeIntervalSinceNow: -24 * 3600) // yesterday
        let result = ClaudeLogParser.scan(roots: [tmpRoot], since: cutoff)

        // Only the recent one should count
        #expect(result["claude-sonnet-4-5"] == TokenUsage(input: 100, output: 50))
    }

    @Test("Non-existent root is OK")
    func nonexistentRoot() {
        let fake = URL(fileURLWithPath: "/tmp/__nope_\(UUID().uuidString)__")
        let result = ClaudeLogParser.scan(roots: [fake], since: .distantPast)
        #expect(result.isEmpty)
    }

    // MARK: - costUSD breakdown

    @Test("costUSD row contributes to preComputedCost and skips tokens")
    func costUSDPreferred() {
        let jsonl = """
        {"type":"assistant","costUSD":0.1234,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":500}}}
        """.data(using: .utf8)!
        var acc = ClaudeLogParser.Breakdown()
        ClaudeLogParser.parseBreakdown(data: jsonl, into: &acc)
        #expect(acc.preComputedCost == 0.1234)
        #expect(acc.tokensByModel.isEmpty)
    }

    @Test("Row without costUSD falls back to token bucket")
    func noCostUSDFallsBackToTokens() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        """.data(using: .utf8)!
        var acc = ClaudeLogParser.Breakdown()
        ClaudeLogParser.parseBreakdown(data: jsonl, into: &acc)
        #expect(acc.preComputedCost == 0)
        #expect(acc.tokensByModel["claude-sonnet-4-5"] == TokenUsage(input: 100, output: 50))
    }

    @Test("Mixed rows split between cost and token buckets")
    func mixedRows() {
        let jsonl = """
        {"type":"assistant","costUSD":0.05,"message":{"model":"claude-opus-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","costUSD":0.10,"message":{"model":"claude-opus-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """.data(using: .utf8)!
        var acc = ClaudeLogParser.Breakdown()
        ClaudeLogParser.parseBreakdown(data: jsonl, into: &acc)
        #expect(abs(acc.preComputedCost - 0.15) < 1e-9)
        #expect(acc.tokensByModel["claude-sonnet-4-5"] == TokenUsage(input: 100, output: 50))
        #expect(acc.tokensByModel["claude-opus-4-5"] == nil)
    }

    @Test("Zero costUSD is treated as missing and falls back to tokens")
    func zeroCostUSDFallsBack() {
        let jsonl = """
        {"type":"assistant","costUSD":0,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}
        """.data(using: .utf8)!
        var acc = ClaudeLogParser.Breakdown()
        ClaudeLogParser.parseBreakdown(data: jsonl, into: &acc)
        #expect(acc.preComputedCost == 0)
        #expect(acc.tokensByModel["claude-sonnet-4-5"] == TokenUsage(input: 10, output: 5))
    }

    // MARK: - Start-of-month helper

    @Test("startOfCurrentMonth returns day 1 at 00:00 in given calendar")
    func startOfMonthHelper() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 4, day: 17, hour: 15))!
        let start = Date.startOfCurrentMonth(calendar: cal, now: now)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 1)
        #expect(comps.hour == 0)
        #expect(comps.minute == 0)
    }
}
