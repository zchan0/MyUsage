import Testing
import Foundation
@testable import MyUsage

@Suite("ClaudeProvider Tests")
struct ClaudeProviderTests {

    // MARK: - Credential Parsing

    @Test("Parse valid credentials JSON")
    func parseCredentials() throws {
        let json = """
        {
            "claudeAiOauth": {
                "accessToken": "test-token",
                "refreshToken": "test-refresh",
                "expiresAt": 1738300000000,
                "scopes": ["user:profile"],
                "subscriptionType": "pro",
                "rateLimitTier": "tier1"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let creds = try JSONDecoder().decode(ClaudeCredentials.self, from: data)

        #expect(creds.claudeAiOauth != nil)
        #expect(creds.claudeAiOauth?.accessToken == "test-token")
        #expect(creds.claudeAiOauth?.refreshToken == "test-refresh")
        #expect(creds.claudeAiOauth?.subscriptionType == "pro")
    }

    @Test("Expired token detected (past expiry)")
    func tokenExpired() throws {
        let pastMs = Int64(Date.now.timeIntervalSince1970 * 1000) - 60_000 // 1 min ago
        let creds = makeCredentials(expiresAt: pastMs)
        #expect(creds.isExpired == true)
    }

    @Test("Token not expired (far future)")
    func tokenNotExpired() throws {
        let futureMs = Int64(Date.now.timeIntervalSince1970 * 1000) + 3_600_000 // 1 hr future
        let creds = makeCredentials(expiresAt: futureMs)
        #expect(creds.isExpired == false)
    }

    @Test("Token about to expire (within 5min buffer)")
    func tokenAboutToExpire() throws {
        let soonMs = Int64(Date.now.timeIntervalSince1970 * 1000) + 200_000 // ~3.3 min future
        let creds = makeCredentials(expiresAt: soonMs)
        #expect(creds.isExpired == true) // within 5-min buffer
    }

    @Test("Plan name from subscriptionType")
    func planName() {
        let creds = makeCredentials(subscriptionType: "max")
        #expect(creds.planName == "Max")
    }

    @Test("Plan name capitalization")
    func planNameCapitalized() {
        let creds = makeCredentials(subscriptionType: "pro")
        #expect(creds.planName == "Pro")
    }

    // MARK: - Usage Response Parsing

    @Test("Parse full usage response")
    func parseUsageResponse() throws {
        let json = """
        {
            "five_hour": {
                "utilization": 35,
                "resets_at": "2026-04-14T20:00:00Z"
            },
            "seven_day": {
                "utilization": 18,
                "resets_at": "2026-04-20T00:00:00Z"
            },
            "extra_usage": {
                "is_enabled": true,
                "used_credits": 500,
                "monthly_limit": 10000,
                "currency": "USD"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

        #expect(response.fiveHour?.utilization == 35)
        #expect(response.sevenDay?.utilization == 18)
        #expect(response.extraUsage?.isEnabled == true)
        #expect(response.extraUsage?.usedCredits == 500)
        #expect(response.extraUsage?.monthlyLimit == 10000)
    }

    @Test("Parse usage response without extra_usage")
    func parseUsageWithoutExtra() throws {
        let json = """
        {
            "five_hour": { "utilization": 10, "resets_at": "2026-04-14T20:00:00Z" },
            "seven_day": { "utilization": 5 }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

        #expect(response.fiveHour?.utilization == 10)
        #expect(response.sevenDay?.utilization == 5)
        #expect(response.extraUsage == nil)
    }

    // MARK: - Snapshot Mapping

    @Test("Map usage response to snapshot — session and weekly")
    func mapSnapshot() {
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 35, resetsAt: "2026-04-14T20:00:00Z"),
            sevenDay: .init(utilization: 18, resetsAt: "2026-04-20T00:00:00Z"),
            sevenDayOscar: nil,
            extraUsage: nil
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: "Pro")

        #expect(snapshot.sessionUsage?.percentUsed == 35)
        #expect(snapshot.weeklyUsage?.percentUsed == 18)
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.onDemandSpend == nil)
        #expect(snapshot.sessionUsage?.resetsAt != nil)
    }

    @Test("Map usage response with extra usage")
    func mapSnapshotWithExtra() {
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 50, resetsAt: nil),
            sevenDay: .init(utilization: 25, resetsAt: nil),
            sevenDayOscar: nil,
            extraUsage: .init(isEnabled: true, usedCredits: 500, monthlyLimit: 10000, currency: "USD")
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

        #expect(snapshot.onDemandSpend != nil)
        #expect(snapshot.onDemandSpend?.amount == 5.0)   // 500 cents → $5.00
        #expect(snapshot.onDemandSpend?.limit == 100.0)   // 10000 cents → $100.00
    }

    @Test("mapToSnapshot propagates explicit fetchedAt to lastRefreshed")
    func mapSnapshotFetchedAt() {
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 5, resetsAt: nil),
            sevenDayOscar: nil,
            extraUsage: nil
        )
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil, fetchedAt: past)
        #expect(snapshot.lastRefreshed == past)
    }

    @Test("mapToSnapshot defaults fetchedAt to now")
    func mapSnapshotDefaultFetchedAt() {
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 5, resetsAt: nil),
            sevenDayOscar: nil,
            extraUsage: nil
        )
        let before = Date.now
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)
        let after = Date.now
        #expect(snapshot.lastRefreshed >= before)
        #expect(snapshot.lastRefreshed <= after)
    }

    @Test("Map usage response with disabled extra usage")
    func mapSnapshotDisabledExtra() {
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 5, resetsAt: nil),
            sevenDayOscar: nil,
            extraUsage: .init(isEnabled: false, usedCredits: 0, monthlyLimit: 0, currency: "USD")
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)
        #expect(snapshot.onDemandSpend == nil)
    }

    // MARK: - Rate-limit messaging

    @Test("Rate-limit error message includes retry seconds and recovery hint")
    func rateLimitMessageIncludesHint() {
        let message = ClaudeProvider.rateLimitErrorMessage(retryAfter: 30)
        #expect(message.contains("Retry in 30s"))
        #expect(message.contains("claude logout && claude login"))
    }

    @Test("Rate-limit error message clamps sub-second retry to 1s")
    func rateLimitMessageClampsToOneSecond() {
        let message = ClaudeProvider.rateLimitErrorMessage(retryAfter: 0.2)
        #expect(message.contains("Retry in 1s"))
    }

    @Test("ProviderError.rateLimited description reflects retry value")
    func providerErrorRateLimitedDescription() {
        let withRetry = ProviderError.rateLimited(retryAfter: 45)
        #expect(withRetry.errorDescription == "Rate limited (retry in 45s)")

        let withoutRetry = ProviderError.rateLimited(retryAfter: nil)
        #expect(withoutRetry.errorDescription == "Rate limited")
    }

    // MARK: - Exponential backoff

    @Test("Backoff is 0 for zero consecutive failures")
    func backoffZero() {
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 0) == 0)
    }

    @Test("Backoff doubles starting at 30s")
    func backoffDoubles() {
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 1) == 30)
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 2) == 60)
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 3) == 120)
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 4) == 240)
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 5) == 480)
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 6) == 960)
    }

    @Test("Backoff caps at 30 minutes")
    func backoffCaps() {
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 7) == 1800)
        #expect(ClaudeProvider.backoffDelay(consecutiveFailures: 20) == 1800)
    }

    @Test("Transient error message formats underlying + retry seconds")
    func transientErrorMessageFormat() {
        let message = ClaudeProvider.transientErrorMessage(
            underlying: "API error (503)",
            retryAfter: 60
        )
        #expect(message.contains("API error (503)"))
        #expect(message.contains("Retrying in 60s"))
    }

    // MARK: - Token expiry

    @Test("Token-expired message points user at `claude` CLI")
    func tokenExpiredMessage() {
        let message = ClaudeProvider.tokenExpiredErrorMessage()
        #expect(message.contains("expired"))
        #expect(message.contains("`claude`"))
    }

    // MARK: - Credential access error

    @Test("errSecItemNotFound yields “run claude login” guidance")
    func credentialErrorNotFound() {
        let message = ClaudeProvider.credentialAccessErrorMessage(status: errSecItemNotFound)
        #expect(message.contains("claude login"))
    }

    @Test("Other OSStatus yields Keychain ACL guidance with status code")
    func credentialErrorAccessDenied() {
        let message = ClaudeProvider.credentialAccessErrorMessage(status: errSecAuthFailed)
        #expect(message.contains("Keychain"))
        #expect(message.contains("\(errSecAuthFailed)"))
    }

    // MARK: - Monthly cost cache

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
            computedAt: .now
        )
        try ClaudeCostCache.write(bogus, to: fixture.cacheURL)

        let total = ClaudeProvider.computeMonthlyCostSync(
            roots: [fixture.root],
            now: .now,
            cacheURL: fixture.cacheURL
        )
        #expect(total == 99.99)
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

    private func makeCredentials(
        expiresAt: Int64 = 9999999999999,
        subscriptionType: String? = "pro"
    ) -> ClaudeCredentials {
        ClaudeCredentials(claudeAiOauth: .init(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: expiresAt,
            scopes: nil,
            subscriptionType: subscriptionType,
            rateLimitTier: nil
        ))
    }
}
