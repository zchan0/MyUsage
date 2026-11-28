import Foundation
import Testing
@testable import MyUsage

struct LocalUsageReportTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5" as String?),
        ("claude-fable-5-2-20261001", "Fable 5.2"),
        ("CLAUDE-SONNET-4-5-20250929", "Sonnet 4.5"),
        ("claude-sonnet-4", "Sonnet 4"),
        ("claude-haiku-4-5-latest", "Haiku 4.5"),
        ("claude-haiku", "Haiku"),
        ("<synthetic>", nil),
        ("gpt-5", nil),
        ("claude-", nil),
        ("", nil)
    ])
    func normalizesClaudeDisplayModel(raw: String, expected: String?) {
        #expect(ClaudeLogParser.normalizeDisplayModel(raw) == expected)
    }

    @Test func claudeTokensReportedCostsAndLocalBuckets() throws {
        let logs = try Logs()
        defer { logs.cleanup() }
        try logs.write("""
        {"type":"assistant","timestamp":"2026-10-27T05:59:59Z","message":{"model":"claude-haiku","usage":{"input_tokens":999}}}
        {"type":"assistant","timestamp":"2026-11-23T23:30:00.123Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":40},"cache_read_input_tokens":50}}}
        {"type":"cost-state","modelUsage":{"claude-opus-5-5":{"costUSD":1.5}}}
        {"type":"cost-state","timestamp":"2026-11-24T07:05:00Z","modelUsage":{"claude-opus-5-5":{"costUSD":4.25}}}
        {"type":"assistant","timestamp":"2026-11-25T11:17:00Z","costUSD":0.75,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":90}}}
        {"type":"assistant","costUSD":2,"message":{"model":"<synthetic>","usage":{"input_tokens":25}}}
        {"type":"assistant","timestamp":"2026-11-26T07:00:00Z","message":{"model":"claude-fable-5-2","usage":{"input_tokens":999}}}
        """)
        try logs.write("""
        {"type":"assistant","timestamp":"2026-11-25T11:17:00Z","message":{"model":"claude-haiku","usage":{"input_tokens":999}}}
        """, name: "old.jsonl", modifiedAt: Self.date("2026-10-27T05:59:59Z"))

        let report = ClaudeLogParser.scanLocalUsage(roots: [logs.root], now: Self.now, calendar: Self.calendar)
        #expect(report.days.count == 30)
        #expect(report.days.first?.id == "2026-10-27")
        #expect(report.days.first?.label == "Oct 27")
        #expect(report.days.first?.date == Self.date("2026-10-27T06:00:00Z"))
        #expect(report.days.last?.id == "2026-11-25")
        #expect(report.days.last?.label == "Today")
        #expect(report.hours.count == 24)
        #expect(report.hours.first?.id == "00:00")
        #expect(report.hours.last?.id == "23:00")

        let tokensDay = try #require(report.days.first { $0.id == "2026-11-23" })
        #expect(tokensDay.combinedTokens == TokenUsage(input: 100, output: 20, cacheWrite5m: 10, cacheWrite1h: 40, cacheRead: 50))
        #expect(tokensDay.cacheHitRate == 25)
        #expect(tokensDay.reportedCostUSD == 1.5)

        let settlement = try #require(report.days.first { $0.id == "2026-11-24" })
        #expect(settlement.totalTokens == 0)
        #expect(settlement.cacheHitRate == nil)
        #expect(settlement.reportedCostUSD == 2.75)

        #expect(report.hours[4].id == "04:00")
        #expect(report.hours[4].date == Self.date("2026-11-25T11:00:00Z"))
        #expect(report.hours[4].totalTokens == 105)
        #expect(report.hours[4].reportedCostUSD == 0.75)
        #expect(report.summaryToday.cacheHitRate == 90)
        #expect(report.summaryToday.reportedCostUSD == 0.75)
        #expect(report.hasReportedCost)
        #expect(report.summary30d.reportedCostUSD == 5)
        #expect(report.summary30d.totalTokens == 325)
        let weightedCacheHitRate = try #require(report.summary30d.cacheHitRate)
        #expect(abs(weightedCacheHitRate - 140.0 / 300 * 100) < 0.000_001)

        #expect(report.orderedModelNames == ["Opus 5.5", "Sonnet 4.5"])
        let todayRows = report.modelRows(for: report.hours[4])
        #expect(todayRows.map(\.id) == report.orderedModelNames)
        #expect(todayRows.first == .init(name: "Opus 5.5", tokens: 0, cacheHitRate: nil, reportedCostUSD: 0))
        #expect(report.modelRows(for: report.summaryToday) == todayRows)
        #expect(report.modelRows(for: settlement).map(\.id) == report.orderedModelNames)
    }

    @Test func claudeCostBaselineTracksEachFileAndCounterReset() throws {
        let logs = try Logs()
        defer { logs.cleanup() }
        try logs.write("""
        {"type":"cost-state","timestamp":"2026-10-26T20:00:00Z","modelUsage":{"claude-opus-5-5":{"costUSD":5}}}
        {"type":"cost-state","timestamp":"2026-10-27T06:00:00Z","modelUsage":{"claude-opus-5-5":{"costUSD":6.25}}}
        {"type":"cost-state","timestamp":"2026-11-25T11:17:00Z","modelUsage":{"claude-opus-5-5":{"costUSD":6.25}}}
        {"type":"cost-state","modelUsage":{"claude-opus-5-5":{"costUSD":-4}}}
        {"type":"cost-state","modelUsage":{"claude-opus-5-5":{"costUSD":1.5},"claude-fable-5-2":{"costUSD":"invalid"}}}
        {"type":"cost-state","modelUsage":{"claude-opus-5-5":{"costUSD":2}}}
        """)
        try logs.write("""
        {"type":"cost-state","modelUsage":{"claude-opus-5-5":{"costUSD":100}}}
        {"type":"cost-state","timestamp":"2026-11-25T11:17:00Z","modelUsage":{"claude-opus-5-5":{"costUSD":3}}}
        """, name: "other-session.jsonl")

        let report = ClaudeLogParser.scanLocalUsage(roots: [logs.root], now: Self.now, calendar: Self.calendar)
        #expect(report.days.first?.reportedCostUSD == 1.25)
        #expect(report.summaryToday.reportedCostUSD == 5)
        #expect(report.hours[4].reportedCostUSD == 5)
        #expect(report.summary30d.reportedCostUSD == 6.25)
        #expect(report.summary30d.totalTokens == 0)
        #expect(report.orderedModelNames == ["Opus 5.5"])
    }

    @Test func claudeTracksUndatedCostsWithoutAttributingThemToAnHour() throws {
        let logs = try Logs()
        defer { logs.cleanup() }
        try logs.write("""
        {"type":"cost-state","modelUsage":{"claude-opus-5-5":{"costUSD":2}}}

        {"type":"cost-state","timestamp":"2026-11-25T11:17:00Z","modelUsage":{"claude-opus-5-5":{"costUSD":3.5}}}
        """)

        let report = ClaudeLogParser.scanLocalUsage(roots: [logs.root], now: Self.now, calendar: Self.calendar)
        #expect(report.summary30d.reportedCostUSD == 1.5)
        #expect(report.hours[4].reportedCostUSD == 1.5)
    }

    @Test func codexTracksModelAndTimestampWithinEachFile() throws {
        let logs = try Logs()
        defer { logs.cleanup() }
        try logs.write("""
        {"type":"turn_context","timestamp":"2026-10-27T05:59:59Z","payload":{"model":"gpt-5-old"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999}}}}
        {"type":"turn_context","timestamp":"2026-11-25T11:01:00.456Z","payload":{"model":"gpt-5.2-codex"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"cached_input_tokens":30,"output_tokens":7,"reasoning_output_tokens":3}}}}
        {"type":"turn_context","timestamp":"2026-11-25T12:05:00Z","payload":{"model":"gpt-5.5-2026-11-01"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":30,"output_tokens":2,"reasoning_output_tokens":3}}}}
        """)
        try logs.write("""
        {"type":"event_msg","timestamp":"2026-11-25T11:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999}}}}
        """, name: "other-session.jsonl")

        let report = CodexLogParser.scanLocalUsage(roots: [logs.root], now: Self.now, calendar: Self.calendar)
        #expect(!report.hasReportedCost)
        #expect(report.hasEstimatedCost)
        #expect(report.hasCost)
        #expect(report.costBasis == .estimated)
        #expect(report.summary30d.reportedCostUSD == 0)
        // gpt-5.2-codex -> gpt-5.2 (1.75 / 14 / 0.175): (50*1.75 + 10*14 + 30*0.175) / 1e6 = 0.00023275
        // gpt-5.5-2026-11-01 -> gpt-5.5 (5 / 30 / 0.5): (0*5 + 5*30 + 30*0.5) / 1e6 = 0.000165
        let expectedCodexTotal = (50 * 1.75 + 10 * 14 + 30 * 0.175 + 5 * 30 + 30 * 0.5) / 1_000_000.0
        #expect(abs(report.summary30d.estimatedCostUSD - expectedCodexTotal) < 1e-12)
        #expect(!report.summary30d.hasUnpricedTokens)
        #expect(report.orderedModelNames == ["GPT-5.2 Codex", "GPT-5.5"])
        #expect(report.days.count == 30)
        #expect(report.days.last?.label == "Today")
        #expect(report.days.last?.totalTokens == 125)
        #expect(report.hours.count == 24)
        #expect(report.hours[4].id == "04:00")
        #expect(report.hours[4].combinedTokens == TokenUsage(input: 50, output: 10, cachedInput: 30))
        #expect(report.hours[4].cacheHitRate == 37.5)
        #expect(report.hours[5].combinedTokens == TokenUsage(output: 5, cachedInput: 30))
        #expect(report.hours[5].cacheHitRate == 100)
        #expect(report.modelRows(for: report.summary30d).map(\.tokens) == [90, 35])
    }

    @Test(arguments: [
        ("gemini-4-neon-xhigh", "Gemini 4 Neon" as String?),
        ("gemini-4-carbon-medium", "Gemini 4 Carbon"),
        ("gemini-2-5-pro-high", "Gemini 2.5 Pro"),
        ("claude-opus-5-5-high", "Claude Opus 5.5"),
        ("gpt-5.4-medium", "GPT-5.4"),
        ("<synthetic>", nil),
        ("", nil)
    ])
    func normalizesAntigravityDisplayModel(raw: String, expected: String?) {
        #expect(AntigravityLogParser.normalizeDisplayModel(raw) == expected)
    }

    @Test func antigravityScansTranscriptOnlyAndComputesCacheHitRate() throws {
        let brain = FileManager.default.temporaryDirectory.appendingPathComponent("myusage-ag-brain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: brain) }

        let logsDir = brain
            .appendingPathComponent("conv-1", isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let transcript = """
        {"type":"USER_INPUT","created_at":"2026-11-25T11:05:00Z"}
        {"type":"PLANNER_RESPONSE","created_at":"2026-11-25T11:10:00Z","model":"gemini-4-neon-xhigh","input_tokens":1000,"output_tokens":200,"cache_read_tokens":4000}
        {"type":"PLANNER_RESPONSE","created_at":"2026-11-24T12:00:00Z","model":"claude-opus-5-5-high","input_tokens":500,"output_tokens":100,"cache_read_tokens":1500}
        {"type":"PLANNER_RESPONSE","created_at":"2026-10-20T12:00:00Z","model":"gemini-4-carbon-medium","input_tokens":9999,"output_tokens":100,"cache_read_tokens":0}
        """
        let transcriptURL = logsDir.appendingPathComponent("transcript.jsonl")
        try Data(transcript.utf8).write(to: transcriptURL)
        try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: transcriptURL.path)

        // Duplicate full transcript must be ignored to prevent double-counting.
        let fullURL = logsDir.appendingPathComponent("transcript_full.jsonl")
        try Data(transcript.utf8).write(to: fullURL)
        try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: fullURL.path)

        let report = AntigravityLogParser.scanLocalUsage(roots: [brain], now: Self.now, calendar: Self.calendar)
        #expect(!report.hasReportedCost)
        #expect(report.hasEstimatedCost)
        #expect(report.costBasis == .estimated)
        // gemini-4-neon (3 / 15 / 0.15): (1000*3 + 200*15 + 4000*0.15) / 1e6 = 0.0066
        // claude-opus-5-5 (4 / 20 / 0.2): (500*4 + 100*20 + 1500*0.2) / 1e6 = 0.0043
        #expect(abs(report.summaryToday.estimatedCostUSD - 0.0066) < 1e-12)
        #expect(abs(report.summary30d.estimatedCostUSD - 0.0109) < 1e-12)
        #expect(!report.summary30d.hasUnpricedTokens)
        #expect(report.orderedModelNames == ["Gemini 4 Neon", "Claude Opus 5.5"])
        #expect(report.summary30d.totalTokens == 7300)
        #expect(report.summaryToday.totalTokens == 5200)
        #expect(report.hours[4].totalTokens == 5200)
        let hitToday = try #require(report.summaryToday.cacheHitRate)
        #expect(abs(hitToday - 80.0) < 0.000_001)
    }

    @Test func builderOrdersTiesAndUsesCombinedCacheHitRate() {
        let today = Self.calendar.startOfDay(for: Self.now)
        let models: [String: LocalUsageReport.ModelMetrics] = [
            "Z": .init(tokens: TokenUsage(input: 50), reportedCostUSD: 1),
            "B": .init(tokens: TokenUsage(input: 50), reportedCostUSD: 2),
            "A": .init(tokens: TokenUsage(output: 40, cachedInput: 10), reportedCostUSD: 2)
        ]
        let report = LocalUsageReport.build(
            daily: [today: models], hourlyToday: [4: models], now: Self.now, calendar: Self.calendar
        )
        #expect(report.orderedModelNames == ["A", "B", "Z"])
        #expect(report.summary30d == report.summaryToday)
        #expect(report.summaryToday.totalTokens == 150)
        #expect(report.summaryToday.reportedCostUSD == 5)
        #expect(report.hours[4].cacheHitRate == 10.0 / 110 * 100)
        #expect(report.summaryToday.cacheHitRate == report.hours[4].cacheHitRate)
    }

    @Test(arguments: ["2026-03-08T20:00:00Z", "2026-11-01T20:00:00Z"])
    func builderKeepsWallClockSlotsAcrossDST(rawNow: String) {
        let now = Self.date(rawNow)
        let report = LocalUsageReport.build(daily: [:], hourlyToday: [:], now: now, calendar: Self.calendar)
        let dates = report.hours.map(\.date)
        #expect(report.hours.count == 24)
        #expect(Set(report.hours.map(\.id)).count == 24)
        #expect(dates == dates.sorted())
        #expect(dates.allSatisfy { Self.calendar.isDate($0, inSameDayAs: now) })
        #expect(Self.calendar.component(.hour, from: report.hours[4].date) == 4)
    }

    private static let now = date("2026-11-25T20:00:00Z")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }

    private struct Logs {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("myusage-local-logs-\(UUID())")

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func write(_ rows: String, name: String = "session.jsonl", modifiedAt: Date = LocalUsageReportTests.now) throws {
            let file = root.appendingPathComponent(name)
            try Data(rows.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        }
    }
}
