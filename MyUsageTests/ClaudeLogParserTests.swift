import Testing
import Foundation
@testable import MyUsage

@Suite("ClaudeLogParser Tests")
struct ClaudeLogParserTests {

    @Test("Non-existent root yields empty local usage report")
    func nonexistentRoot() {
        let fake = URL(fileURLWithPath: "/tmp/__nope_\(UUID().uuidString)__")
        let report = ClaudeLogParser.scanLocalUsage(roots: [fake], now: .now)
        #expect(report.summary30d.totalTokens == 0)
        #expect(report.orderedModelNames.isEmpty)
        #expect(!report.hasReportedCost)
    }

    @Test("Skips malformed lines, non-assistant rows, and zero-token rows")
    func skipsMalformedAndNoise() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("claude-local-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-25T15:00:00Z")!

        let jsonl = """
        {"type":"user","timestamp":"2026-11-25T14:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":2000}}}
        {"type":"progress"}
        {not json
        {"type":"assistant","timestamp":"2026-11-25T14:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-11-25T14:10:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}
        {"type":"assistant","timestamp":"2026-11-25T14:20:00Z","message":{"model":"CLAUDE-SONNET-4-5","usage":{"input_tokens":20,"output_tokens":10}}}
        """
        let file = root.appendingPathComponent("session.jsonl")
        try jsonl.write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let report = ClaudeLogParser.scanLocalUsage(roots: [root], now: now, calendar: cal)
        #expect(report.orderedModelNames == ["Sonnet 4.5"])
        #expect(report.summaryToday.totalTokens == 45)
        #expect(report.hours[14].totalTokens == 45)
    }
}
