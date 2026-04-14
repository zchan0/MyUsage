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

    // MARK: - Helpers

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
