import Foundation
import Testing
@testable import MyUsage

@Suite("Claude monthly cost")
struct ClaudeMonthlyCostTests {
    @Test("computeMonthlyCostSync returns 0 and writes nothing when no logs exist")
    func costSyncEmptyRoots() {
        let fm = FileManager.default
        let roots = [fm.temporaryDirectory.appendingPathComponent("__absent_\(UUID())__")]
        let cacheURL = tempCacheURL()

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: roots,
            now: .now,
            cacheURL: cacheURL
        )
        #expect(total == 0)
        #expect(fm.fileExists(atPath: cacheURL.path) == false)
    }

    @Test("computeMonthlyCostSync scans fresh and writes cache on miss")
    func costSyncFreshScan() throws {
        let fixture = try makeCostFixture(costUSD: 0.05)
        defer { fixture.cleanup() }

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        #expect(abs(total - 0.05) < 1e-9)

        let cached = try #require(ClaudeCostCache.read(from: fixture.cacheURL))
        #expect(abs(cached.totalUSD - 0.05) < 1e-9)
        #expect(cached.month == ClaudeCostCache.monthKey(for: .now))
    }

    @Test("computeMonthlyCostSync returns cached total when month + mtime match")
    func costSyncCacheHit() throws {
        let fixture = try makeCostFixture(costUSD: 0.05)
        defer { fixture.cleanup() }

        // Pre-seed cache with a deliberately wrong total so we can detect
        // that a hit short-circuited the scan.
        let mtime = try #require(
            ClaudeLogParser.maxMtime(roots: [fixture.root], since: .distantPast)
        )
        let bogus = ClaudeCostCache.Payload(
            v: ClaudeCostCache.currentVersion,
            month: ClaudeCostCache.monthKey(for: .now),
            totalUSD: 99.99,
            preComputedCost: 99.99,
            tokensByModel: [:],
            maxSourceMtime: mtime,
            computedAt: .now,
            pricingFingerprint: PricingCatalog.shared.fingerprint
        )
        try ClaudeCostCache.write(bogus, to: fixture.cacheURL)

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        #expect(total == 99.99)
    }

    @Test("computeMonthlyCostSync invalidates cache when pricing changed")
    func costSyncPricingRollover() throws {
        let fixture = try makeCostFixture(costUSD: 0.05)
        defer { fixture.cleanup() }

        // Same month + mtime, but a fingerprint from an older price table:
        // the cached total was computed at superseded rates and must be
        // recomputed, not served.
        let mtime = try #require(
            ClaudeLogParser.maxMtime(roots: [fixture.root], since: .distantPast)
        )
        let stale = ClaudeCostCache.Payload(
            v: ClaudeCostCache.currentVersion,
            month: ClaudeCostCache.monthKey(for: .now),
            totalUSD: 99.99,
            preComputedCost: 99.99,
            tokensByModel: [:],
            maxSourceMtime: mtime,
            computedAt: .now,
            pricingFingerprint: "outdated0"
        )
        try ClaudeCostCache.write(stale, to: fixture.cacheURL)

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        #expect(abs(total - 0.05) < 1e-9, "stale-pricing cache must be recomputed")
    }

    @Test("computeMonthlyCostSync invalidates cache on month rollover")
    func costSyncMonthRollover() throws {
        let fixture = try makeCostFixture(costUSD: 0.05)
        defer { fixture.cleanup() }

        let mtime = try #require(
            ClaudeLogParser.maxMtime(roots: [fixture.root], since: .distantPast)
        )
        let staleMonth = ClaudeCostCache.Payload(
            v: ClaudeCostCache.currentVersion,
            month: "1999-01",
            totalUSD: 99.99,
            preComputedCost: 99.99,
            tokensByModel: [:],
            maxSourceMtime: mtime,
            computedAt: .now
        )
        try ClaudeCostCache.write(staleMonth, to: fixture.cacheURL)

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        // Month mismatch → cache ignored → real scan wins.
        #expect(abs(total - 0.05) < 1e-9)

        let overwritten = try #require(ClaudeCostCache.read(from: fixture.cacheURL))
        #expect(overwritten.month == ClaudeCostCache.monthKey(for: .now))
    }

    @Test("computeMonthlyCostSync invalidates cache when a JSONL is updated")
    func costSyncMtimeBump() throws {
        let fixture = try makeCostFixture(costUSD: 0.05)
        defer { fixture.cleanup() }

        // First run: populate cache.
        _ = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        let first = try #require(ClaudeCostCache.read(from: fixture.cacheURL))

        // Append another priced row and bump mtime.
        let extra = """

        {"type":"assistant","costUSD":0.20,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let handle = try FileHandle(forWritingTo: fixture.jsonl)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: fixture.jsonl.path
        )

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        #expect(abs(total - 0.25) < 1e-9)

        let second = try #require(ClaudeCostCache.read(from: fixture.cacheURL))
        #expect(second.maxSourceMtime > first.maxSourceMtime)
    }

    // MARK: - Helpers

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cost-\(UUID()).json")
    }

    private struct CostFixture {
        let root: URL
        let jsonl: URL
        let cacheURL: URL
        let cleanup: () -> Void
    }

    /// Creates a temp `root/-Users-me/session.jsonl` containing one priced
    /// assistant row plus a matching temp cache URL.
    private func makeCostFixture(costUSD: Double) throws -> CostFixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-cost-fixture-\(UUID())", isDirectory: true)
        let nested = root.appendingPathComponent("-Users-me/proj", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        let jsonl = nested.appendingPathComponent("session.jsonl")
        let row = """
        {"type":"assistant","costUSD":\(costUSD),"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        try row.write(to: jsonl, atomically: true, encoding: .utf8)

        let cacheURL = tempCacheURL()
        return CostFixture(root: root, jsonl: jsonl, cacheURL: cacheURL) {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: cacheURL)
        }
    }

}
