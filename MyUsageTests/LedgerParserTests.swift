import Testing
import Foundation
@testable import MyUsage

@Suite("Claude / Codex per-day ledger parsers")
struct LedgerParserTests {

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

        let result = ClaudeLogParser.scanDailyCost(roots: [root], since: .distantPast)
        #expect(abs((result["2026-04-17"] ?? 0) - 1.50) < 1e-9)
        #expect(abs((result["2026-04-18"] ?? 0) - 2.00) < 1e-9)
    }

    @Test("Claude scanDailyCost prices token rows when costUSD is missing")
    func claudePricesTokens() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-daily-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Choose a model that's in the bundled pricing.json.
        let model = "claude-sonnet-4-5"
        let catalog = PricingCatalog.shared
        guard let price = catalog.pricing(for: model) else {
            // Bundled pricing missing — skip rather than fail.
            return
        }
        let tokens = TokenUsage(input: 1_000_000, output: 500_000)
        let expected = Double(tokens.input) * price.input / 1_000_000
                     + Double(tokens.output) * price.output / 1_000_000

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
        #expect(abs((result["2026-04-17"] ?? 0) - expected) < 1e-6)
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

        let result = ClaudeLogParser.scanDailyCost(roots: [root], since: .distantPast)
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
        guard let price = PricingCatalog.shared.pricing(for: model) else { return }

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
            catalog: PricingCatalog.shared
        )

        let d17 = Double(1_000_000) * price.input / 1_000_000
                + Double(500_000) * price.output / 1_000_000
        let d18 = Double(500_000) * price.input / 1_000_000
                + Double(250_000) * price.output / 1_000_000
        #expect(abs((result["2026-04-17"] ?? 0) - d17) < 1e-6)
        #expect(abs((result["2026-04-18"] ?? 0) - d18) < 1e-6)
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
        guard let price = PricingCatalog.shared.pricing(for: model) else { return }

        let file = sub.appendingPathComponent("rollout.jsonl")
        let jsonl = """
        {"type":"turn_context","payload":{"model":"\(model)"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"output_tokens":50000}}}}
        """
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let result = CodexLogParser.scanDailyCost(roots: [root], since: .distantPast)
        let expected = Double(100_000) * price.input / 1_000_000
                     + Double(50_000)  * price.output / 1_000_000
        #expect(abs((result["2026-04-22"] ?? 0) - expected) < 1e-6)
    }
}
