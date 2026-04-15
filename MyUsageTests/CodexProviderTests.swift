import Testing
import Foundation
@testable import MyUsage

@Suite("CodexProvider Tests")
struct CodexProviderTests {

    // MARK: - Auth File Parsing

    @Test("Parse valid auth.json")
    func parseAuthFile() throws {
        let json = """
        {
            "tokens": {
                "access_token": "test-access",
                "refresh_token": "test-refresh",
                "id_token": "test-id",
                "account_id": "test-account"
            },
            "last_refresh": "2026-04-14T08:05:37Z"
        }
        """
        let data = json.data(using: .utf8)!
        let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)

        #expect(auth.tokens?.accessToken == "test-access")
        #expect(auth.tokens?.refreshToken == "test-refresh")
        #expect(auth.tokens?.accountId == "test-account")
        #expect(auth.lastRefresh == "2026-04-14T08:05:37Z")
    }

    @Test("Needs refresh when last_refresh > 8 days ago")
    func needsRefreshOld() {
        let oldDate = Date.now.addingTimeInterval(-9 * 24 * 3600) // 9 days ago
        let isoString = ISO8601DateFormatter().string(from: oldDate)
        let auth = CodexAuthFile(
            openaiApiKey: nil,
            tokens: CodexTokens(accessToken: "t", refreshToken: "r", idToken: nil, accountId: nil),
            lastRefresh: isoString
        )
        #expect(auth.needsRefresh == true)
    }

    @Test("No refresh needed when last_refresh is recent")
    func noRefreshNeeded() {
        let recentDate = Date.now.addingTimeInterval(-3600) // 1 hour ago
        let isoString = ISO8601DateFormatter().string(from: recentDate)
        let auth = CodexAuthFile(
            openaiApiKey: nil,
            tokens: CodexTokens(accessToken: "t", refreshToken: "r", idToken: nil, accountId: nil),
            lastRefresh: isoString
        )
        #expect(auth.needsRefresh == false)
    }

    @Test("Needs refresh when last_refresh is nil")
    func needsRefreshNil() {
        let auth = CodexAuthFile(
            openaiApiKey: nil,
            tokens: CodexTokens(accessToken: "t", refreshToken: "r", idToken: nil, accountId: nil),
            lastRefresh: nil
        )
        #expect(auth.needsRefresh == true)
    }

    // MARK: - Usage Response Parsing

    @Test("Parse full usage response")
    func parseUsageResponse() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 6,
                    "reset_at": 1738300000,
                    "limit_window_seconds": 18000
                },
                "secondary_window": {
                    "used_percent": 24,
                    "reset_at": 1738900000,
                    "limit_window_seconds": 604800
                }
            },
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": 5.39
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

        #expect(response.planType == "plus")
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 6)
        #expect(response.rateLimit?.secondaryWindow?.usedPercent == 24)
        #expect(response.credits?.hasCredits == true)
        #expect(response.credits?.balance == 5.39)
    }

    @Test("Parse usage response with balance as string")
    func parseUsageBalanceString() throws {
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": { "used_percent": 10, "reset_at": 1738300000 }
            },
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": "150.0"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

        #expect(response.credits?.balance == 150.0)
        #expect(response.credits?.hasCredits == true)
    }

    @Test("Parse usage without credits")
    func parseUsageNoCredits() throws {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "primary_window": { "used_percent": 10, "reset_at": 1738300000 },
                "secondary_window": { "used_percent": 5, "reset_at": 1738900000 }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

        #expect(response.credits == nil)
    }

    // MARK: - Snapshot Mapping

    @Test("Map usage response to snapshot")
    func mapSnapshot() {
        let response = CodexUsageResponse(
            planType: "plus",
            rateLimit: CodexRateLimit(
                primaryWindow: CodexWindow(usedPercent: 62, resetAt: 1738300000, limitWindowSeconds: 18000),
                secondaryWindow: CodexWindow(usedPercent: 41, resetAt: 1738900000, limitWindowSeconds: 604800)
            ),
            credits: CodexCredits(hasCredits: true, unlimited: false, balance: 5.39),
            codeReviewRateLimit: nil
        )
        let snapshot = CodexProvider.mapToSnapshot(response)

        #expect(snapshot.sessionUsage?.percentUsed == 62)
        #expect(snapshot.weeklyUsage?.percentUsed == 41)
        #expect(snapshot.planName == "Plus")
        #expect(snapshot.credits?.amount == 5.39)
    }

    @Test("Map usage response without credits")
    func mapSnapshotNoCredits() {
        let response = CodexUsageResponse(
            planType: "pro",
            rateLimit: CodexRateLimit(
                primaryWindow: CodexWindow(usedPercent: 10, resetAt: nil, limitWindowSeconds: nil),
                secondaryWindow: nil
            ),
            credits: nil,
            codeReviewRateLimit: nil
        )
        let snapshot = CodexProvider.mapToSnapshot(response)

        #expect(snapshot.sessionUsage?.percentUsed == 10)
        #expect(snapshot.weeklyUsage == nil)
        #expect(snapshot.credits == nil)
    }

    @Test("Map credits with has_credits false")
    func mapCreditsDisabled() {
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: nil,
            credits: CodexCredits(hasCredits: false, unlimited: false, balance: 0),
            codeReviewRateLimit: nil
        )
        let snapshot = CodexProvider.mapToSnapshot(response)
        #expect(snapshot.credits == nil)
    }

    @Test("Reset timestamp from unix seconds")
    func resetTimestamp() {
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: CodexRateLimit(
                primaryWindow: CodexWindow(usedPercent: 5, resetAt: 1738300000, limitWindowSeconds: nil),
                secondaryWindow: nil
            ),
            credits: nil,
            codeReviewRateLimit: nil
        )
        let snapshot = CodexProvider.mapToSnapshot(response)
        #expect(snapshot.sessionUsage?.resetsAt != nil)
        #expect(snapshot.sessionUsage?.resetsAt == Date(timeIntervalSince1970: 1738300000))
    }
}
