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

    // MARK: - Reset Credit Parsing

    @Test("Parse, filter, and sort available reset credits")
    func parseResetCredits() throws {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let json = """
        {
            "available_count": 2,
            "credits": [
                {
                    "id": "later",
                    "status": "available",
                    "granted_at": "2026-06-17T04:00:00.123Z",
                    "expires_at": "2026-08-05T04:00:00Z"
                },
                {
                    "id": "redeemed",
                    "status": "redeemed",
                    "expires_at": "2026-08-01T04:00:00Z"
                },
                {
                    "id": "earlier",
                    "status": "available",
                    "expires_at": "2026-08-01T04:00:00.500Z"
                },
                {
                    "id": "expired",
                    "status": "available",
                    "expires_at": "2026-01-01T00:00:00Z"
                }
            ]
        }
        """

        let inventory = try CodexProvider.decodeResetCredits(
            Data(json.utf8),
            now: now
        )

        #expect(inventory.reportedAvailableCount == 2)
        #expect(inventory.availableCredits.map(\.id) == ["earlier", "later"])
        #expect(inventory.earliestExpiration == inventory.availableCredits.first?.expiresAt)
    }

    @Test("Available credit without expiry remains visible after dated credits")
    func parseResetCreditWithoutExpiry() throws {
        let json = """
        {
            "available_count": 2,
            "credits": [
                { "id": "no-expiry", "status": "available", "expires_at": null },
                { "id": "dated", "status": "AVAILABLE", "expires_at": "2027-01-01T00:00:00Z" }
            ]
        }
        """
        let inventory = try CodexProvider.decodeResetCredits(Data(json.utf8), now: .distantPast)
        #expect(inventory.availableCredits.map(\.id) == ["dated", "no-expiry"])
    }

    @Test("Reject negative reset credit count")
    func rejectNegativeResetCreditCount() {
        let json = #"{"available_count":-1,"credits":[]}"#
        #expect(throws: DecodingError.self) {
            try CodexProvider.decodeResetCredits(Data(json.utf8), now: .now)
        }
    }

    @Test("Reject reset credit inventory whose count contradicts its records")
    func rejectContradictoryResetCreditCount() {
        let json = """
        {
            "available_count": 1,
            "credits": [
                { "id": "one", "status": "available" },
                { "id": "two", "status": "available" }
            ]
        }
        """
        #expect(throws: DecodingError.self) {
            try CodexProvider.decodeResetCredits(Data(json.utf8), now: .now)
        }
    }

    @Test("Reset credit request carries Codex headers and bounded timeout")
    func resetCreditRequest() {
        let request = CodexProvider.makeResetCreditsRequest(
            accessToken: "secret",
            accountId: "account-123"
        )
        #expect(request.url?.absoluteString.hasSuffix("rate-limit-reset-credits") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
        #expect(request.timeoutInterval == 4)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
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

    @Test("Weekly-only response renders no bogus 5h window")
    func mapWeeklyOnly() {
        // Current Codex plans without a session limit return a single
        // weekly window as primary_window. It must land in weeklyUsage.
        let response = CodexUsageResponse(
            planType: "plus",
            rateLimit: CodexRateLimit(
                primaryWindow: CodexWindow(usedPercent: 37, resetAt: 1738900000, limitWindowSeconds: 604800),
                secondaryWindow: nil
            ),
            credits: nil,
            codeReviewRateLimit: nil
        )
        let snapshot = CodexProvider.mapToSnapshot(response)

        #expect(snapshot.sessionUsage == nil)
        #expect(snapshot.weeklyUsage?.percentUsed == 37)
        #expect(snapshot.weeklyUsage?.windowDuration == 604800)
    }

    @Test("Windows classify by duration even when positions are swapped")
    func mapSwappedWindows() {
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: CodexRateLimit(
                primaryWindow: CodexWindow(usedPercent: 41, resetAt: nil, limitWindowSeconds: 604800),
                secondaryWindow: CodexWindow(usedPercent: 62, resetAt: nil, limitWindowSeconds: 18000)
            ),
            credits: nil,
            codeReviewRateLimit: nil
        )
        let snapshot = CodexProvider.mapToSnapshot(response)

        #expect(snapshot.sessionUsage?.percentUsed == 62)
        #expect(snapshot.weeklyUsage?.percentUsed == 41)
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
