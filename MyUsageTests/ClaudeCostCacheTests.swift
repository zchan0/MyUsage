import Foundation
import Testing
@testable import MyUsage

@Suite("ClaudeCostCache Tests")
struct ClaudeCostCacheTests {

    // MARK: - Round-trip

    @Test("Write then read returns identical payload")
    func roundTrip() throws {
        let url = tempURL()
        defer { cleanup(url) }

        let mtime = Date(timeIntervalSince1970: 1_745_235_000)
        let computedAt = Date(timeIntervalSince1970: 1_745_240_000)
        let payload = ClaudeCostCache.Payload(
            v: ClaudeCostCache.currentVersion,
            month: "2026-04",
            totalUSD: 12.347,
            preComputedCost: 10.001,
            tokensByModel: [
                "claude-sonnet-4-5": ClaudeCostCache.CachedTokenCounts(
                    input: 100, output: 50, cacheWrite: 0, cacheRead: 0, cachedInput: 0
                )
            ],
            maxSourceMtime: mtime,
            computedAt: computedAt
        )

        try ClaudeCostCache.write(payload, to: url)
        let read = try #require(ClaudeCostCache.read(from: url))
        #expect(read == payload)
    }

    @Test("Convenience init mirrors TokenUsage fields")
    func cachedTokenCountsFromTokenUsage() {
        let usage = TokenUsage(
            input: 10, output: 20, cacheWrite: 30, cacheRead: 40, cachedInput: 50
        )
        let counts = ClaudeCostCache.CachedTokenCounts(usage)
        #expect(counts.input == 10)
        #expect(counts.output == 20)
        #expect(counts.cacheWrite == 30)
        #expect(counts.cacheRead == 40)
        #expect(counts.cachedInput == 50)
    }

    // MARK: - Failure modes

    @Test("Missing file returns nil")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID()).json")
        #expect(ClaudeCostCache.read(from: url) == nil)
    }

    @Test("Corrupt JSON returns nil")
    func corruptJSON() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try Data("not json".utf8).write(to: url)
        #expect(ClaudeCostCache.read(from: url) == nil)
    }

    @Test("Empty file returns nil")
    func emptyFile() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try Data().write(to: url)
        #expect(ClaudeCostCache.read(from: url) == nil)
    }

    @Test("Unknown schema version returns nil")
    func schemaVersionMismatch() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let future = """
        {"v":99,"month":"2026-04","totalUSD":1.0,"preComputedCost":0.5,"tokensByModel":{},"maxSourceMtime":0,"computedAt":0}
        """
        try Data(future.utf8).write(to: url)
        #expect(ClaudeCostCache.read(from: url) == nil)
    }

    // MARK: - Month key

    @Test("monthKey formats YYYY-MM with leading zeros")
    func monthKeyFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 17))!
        #expect(ClaudeCostCache.monthKey(for: date, calendar: cal) == "2026-04")

        let jan = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        #expect(ClaudeCostCache.monthKey(for: jan, calendar: cal) == "2027-01")
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cost-\(UUID()).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
