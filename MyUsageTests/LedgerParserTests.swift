import Testing
import Foundation
@testable import MyUsage

@Suite("Claude / Codex per-day ledger parsers")
struct LedgerParserTests {

    // Fixed fixture prices: these parser tests must not depend on a user's
    // cached catalog or silently pass when a real model is absent from it.
    private let catalog = PricingCatalog(file: PricingFile(version: 1, updated: nil, models: [
        "claude-sonnet-4-5": ModelPricing(input: 2, output: 8),
        "gpt-5-codex": ModelPricing(input: 4, output: 12),
    ]))

    // MARK: - Claude

    @Test("Claude scanDailyCost buckets rows by UTC day from timestamp")
    func claudeDailyCostBuckets() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-daily-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"type":"assistant","timestamp":"2026-04-17T10:00:00.000Z","costUSD":1.00,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        {"type":"assistant","timestamp":"2026-04-17T23:59:59.000Z","costUSD":0.50,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        {"type":"assistant","timestamp":"2026-04-18T00:00:01.000Z","costUSD":2.00,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let result = ClaudeLogParser.scanDailyCost(roots: [root], since: .distantPast, catalog: catalog)
        #expect(abs((result["2026-04-17"] ?? 0) - 1.50) < 1e-9)
        #expect(abs((result["2026-04-18"] ?? 0) - 2.00) < 1e-9)
    }

    @Test("Claude daily breakdown retains tokens even for server-priced rows")
    func claudeDailyTokensWithServerCost() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-daily-tokens-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"type":"assistant","timestamp":"2026-04-17T10:00:00Z","costUSD":1.0,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":400}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let breakdown = ClaudeLogParser.scanDailyBreakdown(roots: [root], since: .distantPast)
        #expect(breakdown.tokensByDay["2026-04-17"]
            == TokenUsage(input: 100, output: 20, cacheWrite: 30, cacheRead: 400))
    }

    @Test("Claude scanDailyCost prices token rows when costUSD is missing")
    func claudePricesTokens() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-daily-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let model = "claude-sonnet-4-5"
        let tokens = TokenUsage(input: 1_000_000, output: 500_000)

        let file = root.appendingPathComponent("s.jsonl")
        let jsonl = """
        {"type":"assistant","timestamp":"2026-04-17T10:00:00.000Z","message":{"model":"\(model)","usage":{"input_tokens":\(tokens.input),"output_tokens":\(tokens.output)}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let result = ClaudeLogParser.scanDailyCost(
            roots: [root],
            since: .distantPast,
            catalog: catalog
        )
        #expect(abs((result["2026-04-17"] ?? 0) - 6) < 1e-6)
    }

    @Test("Claude missing timestamp falls back to file mtime")
    func claudeMissingTimestampUsesMtime() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-fallback-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = root.appendingPathComponent("s.jsonl")
        let jsonl = """
        {"type":"assistant","costUSD":1.23,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let mtime = Date(timeIntervalSince1970: 1_776_000_000) // 2026-04-12
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let result = ClaudeLogParser.scanDailyCost(roots: [root], since: .distantPast, catalog: catalog)
        let expectedDay = LedgerCalendar.dayKey(for: mtime)
        #expect(result[expectedDay] == 1.23)
    }

    // MARK: - Codex

    @Test("Codex scanDailyCost buckets by timestamp when available")
    func codexBucketsByTimestamp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("codex-daily-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let model = "gpt-5-codex"

        let file = root.appendingPathComponent("rollout.jsonl")
        let jsonl = """
        {"type":"session_meta","payload":{"id":"abc"}}
        {"type":"turn_context","payload":{"model":"\(model)"}}
        {"type":"event_msg","timestamp":"2026-04-17T10:00:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"output_tokens":500000}}}}
        {"type":"event_msg","timestamp":"2026-04-18T10:00:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500000,"output_tokens":250000}}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let result = CodexLogParser.scanDailyCost(
            roots: [root],
            since: .distantPast,
            catalog: catalog
        )

        #expect(abs((result["2026-04-17"] ?? 0) - 10) < 1e-6)
        #expect(abs((result["2026-04-18"] ?? 0) - 5) < 1e-6)
    }

    @Test("Codex falls back to sessions/YYYY/MM/DD folder when row has no timestamp")
    func codexFolderFallback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("codex-folder-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("sessions/2026/04/22")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let model = "gpt-5-codex"

        let file = sub.appendingPathComponent("rollout.jsonl")
        let jsonl = """
        {"type":"turn_context","payload":{"model":"\(model)"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"output_tokens":50000}}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let result = CodexLogParser.scanDailyCost(roots: [root], since: .distantPast, catalog: catalog)
        #expect(abs((result["2026-04-22"] ?? 0) - 1) < 1e-6)
    }
}
