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
            sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayHaiku: nil,
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
            extraUsage: nil
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: "Pro")

        #expect(snapshot.sessionUsage?.percentUsed == 35)
        #expect(snapshot.weeklyUsage?.percentUsed == 18)
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.onDemandSpend == nil)
        #expect(snapshot.sessionUsage?.resetsAt != nil)
    }

    @Test("Per-model breakdown sorted by percent desc, returned 0% buckets kept")
    func mapSnapshotWeeklyByModel() {
        // Buckets the API *returns* are kept even at 0% — that means the
        // cap exists on this plan but is unused this week, which is real
        // information for the user. Only nil windows (cap doesn't exist
        // on this plan) are filtered.
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 62, resetsAt: nil),
            sevenDayOpus: .init(utilization: 24, resetsAt: nil),
            sevenDaySonnet: .init(utilization: 38, resetsAt: nil),
            sevenDayHaiku: .init(utilization: 0, resetsAt: nil),
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
            extraUsage: nil
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

        #expect(snapshot.weeklyByModel.count == 3)
        #expect(snapshot.weeklyByModel[0].label == "Sonnet")
        #expect(snapshot.weeklyByModel[0].percent == 38)
        #expect(snapshot.weeklyByModel[1].label == "Opus")
        #expect(snapshot.weeklyByModel[1].percent == 24)
        #expect(snapshot.weeklyByModel[2].label == "Haiku")
        #expect(snapshot.weeklyByModel[2].percent == 0)
    }

    @Test("Per-bucket breakdown also surfaces product caps")
    func mapSnapshotWeeklyBucketsProducts() {
        // Some Enterprise/Team plans expose product-line sub-caps in
        // addition to (or instead of) model-family caps. Surface every
        // returned bucket — including the 0% OAuth apps cap, which
        // exists on this plan but is unused this week.
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 50, resetsAt: nil),
            sevenDayOpus: nil,
            sevenDaySonnet: .init(utilization: 12, resetsAt: nil),
            sevenDayHaiku: nil,
            sevenDayOmelette: .init(utilization: 22, resetsAt: nil),  // Claude Design
            sevenDayCowork: .init(utilization: 8, resetsAt: nil),     // legacy Daily Routines key
            sevenDayOauthApps: .init(utilization: 0, resetsAt: nil),  // exists @ 0% — kept
            extraUsage: nil
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

        #expect(snapshot.weeklyByModel.count == 4)
        #expect(snapshot.weeklyByModel[0].label == "Design")
        #expect(snapshot.weeklyByModel[0].percent == 22)
        #expect(snapshot.weeklyByModel[1].label == "Sonnet")
        #expect(snapshot.weeklyByModel[1].percent == 12)
        #expect(snapshot.weeklyByModel[2].label == "Daily Routines")
        #expect(snapshot.weeklyByModel[2].percent == 8)
        #expect(snapshot.weeklyByModel[3].label == "OAuth apps")
        #expect(snapshot.weeklyByModel[3].percent == 0)
    }

    @Test("Per-model breakdown is empty when API returns no model fields")
    func mapSnapshotWeeklyByModelEmpty() {
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 50, resetsAt: nil),
            sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayHaiku: nil,
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
            extraUsage: nil
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)
        #expect(snapshot.weeklyByModel.isEmpty)
    }

    // MARK: - Structured `limits` array (current API shape)

    /// Helper: build a `weekly_scoped` limit for a model display name.
    private func scopedLimit(_ name: String, percent: Double) -> ClaudeUsageResponse.ClaudeLimit {
        .init(
            kind: "weekly_scoped",
            group: "weekly",
            percent: percent,
            severity: "normal",
            resetsAt: nil,
            scope: .init(model: .init(id: nil, displayName: name)),
            isActive: false
        )
    }

    @Test("Fable weekly-scoped cap in `limits` surfaces as a per-model row at 0%")
    func mapSnapshotLimitsFable() {
        // Mirrors the live response: a `weekly_scoped` entry for Fable at
        // 0% alongside session + weekly_all entries. The scoped cap exists
        // on the plan but is unused this week, so it's kept at 0%.
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 3, resetsAt: nil),
            sevenDay: .init(utilization: 6, resetsAt: nil),
            limits: [
                .init(kind: "session", group: "session", percent: 3,
                      severity: "normal", resetsAt: nil, scope: nil, isActive: false),
                .init(kind: "weekly_all", group: "weekly", percent: 6,
                      severity: "normal", resetsAt: nil, scope: nil, isActive: true),
                scopedLimit("Fable", percent: 0)
            ]
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

        #expect(snapshot.weeklyByModel.count == 1)
        #expect(snapshot.weeklyByModel[0].label == "Fable")
        #expect(snapshot.weeklyByModel[0].percent == 0)
        // Top-level session/weekly still drive the primary bars.
        #expect(snapshot.sessionUsage?.percentUsed == 3)
        #expect(snapshot.weeklyUsage?.percentUsed == 6)
    }

    @Test("`limits` scoped rows sort by percent desc; non-scoped kinds ignored")
    func mapSnapshotLimitsSorted() {
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 40, resetsAt: nil),
            limits: [
                .init(kind: "weekly_all", group: "weekly", percent: 40,
                      severity: "normal", resetsAt: nil, scope: nil, isActive: true),
                scopedLimit("Fable", percent: 12),
                scopedLimit("Opus", percent: 55)
            ]
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

        #expect(snapshot.weeklyByModel.count == 2)
        #expect(snapshot.weeklyByModel[0].label == "Opus")
        #expect(snapshot.weeklyByModel[0].percent == 55)
        #expect(snapshot.weeklyByModel[1].label == "Fable")
        #expect(snapshot.weeklyByModel[1].percent == 12)
    }

    @Test("Present `limits` is authoritative — legacy codename fields ignored")
    func mapSnapshotLimitsTrumpLegacy() {
        // When the API returns the new array, we trust it exclusively. A
        // response carrying both a populated `limits` array (no scoped
        // rows) AND stale legacy fields must yield an empty breakdown, not
        // fall back to the legacy path.
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 50, resetsAt: nil),
            sevenDayOpus: .init(utilization: 99, resetsAt: nil),
            limits: [
                .init(kind: "weekly_all", group: "weekly", percent: 50,
                      severity: "normal", resetsAt: nil, scope: nil, isActive: true)
            ]
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)
        #expect(snapshot.weeklyByModel.isEmpty)
    }

    @Test("Absent `limits` falls back to legacy codename fields")
    func mapSnapshotLimitsLegacyFallback() {
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 50, resetsAt: nil),
            sevenDaySonnet: .init(utilization: 20, resetsAt: nil)
            // limits omitted → nil → legacy path
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)
        #expect(snapshot.weeklyByModel.count == 1)
        #expect(snapshot.weeklyByModel[0].label == "Sonnet")
        #expect(snapshot.weeklyByModel[0].percent == 20)
    }

    @Test("Decodes the live `limits` wire shape (Fable weekly-scoped)")
    func decodeLiveLimitsJSON() throws {
        // Trimmed from an actual /api/oauth/usage response.
        let json = """
        {
          "five_hour": {"utilization": 3.0, "resets_at": "2026-07-11T08:10:00.394920+00:00"},
          "seven_day": {"utilization": 6.0, "resets_at": "2026-07-13T10:00:00.394943+00:00"},
          "seven_day_opus": null,
          "limits": [
            {"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-07-11T08:10:00.394920+00:00","scope":null,"is_active":false},
            {"kind":"weekly_all","group":"weekly","percent":6,"severity":"normal","resets_at":"2026-07-13T10:00:00.394943+00:00","scope":null,"is_active":true},
            {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
          ]
        }
        """
        let response = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(json.utf8)
        )
        let scoped = response.limits?.first { $0.kind == "weekly_scoped" }
        #expect(scoped?.scope?.model?.displayName == "Fable")
        #expect(scoped?.percent == 0)

        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)
        #expect(snapshot.weeklyByModel.map(\.label) == ["Fable"])
    }

    @Test("Decodes fractional usage with Fable and Daily Routines")
    func decodeFableAndDailyRoutines() throws {
        let json = """
        {
          "five_hour": {"utilization": 3.5, "resets_at": null},
          "seven_day": {"utilization": 6.25, "resets_at": null},
          "seven_day_routines": {
            "utilization": 21.5,
            "resets_at": "2026-07-30T10:00:00Z"
          },
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 12.5,
              "resets_at": "2026-07-30T10:00:00Z",
              "scope": {"model": {"id": "claude-fable-5", "display_name": "Fable"}}
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(json.utf8)
        )
        let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

        #expect(snapshot.sessionUsage?.percentUsed == 3.5)
        #expect(snapshot.weeklyUsage?.percentUsed == 6.25)
        #expect(snapshot.weeklyByModel.map(\.label) == ["Daily Routines", "Fable"])
        #expect(snapshot.weeklyByModel.map(\.percent) == [21.5, 12.5])
        #expect(snapshot.weeklyByModel.allSatisfy { $0.resetsAt != nil })
    }

    @Test("A reported null Daily Routines alias remains visible at zero")
    func decodeNullDailyRoutinesAlias() throws {
        let aliases = [
            "seven_day_routines",
            "seven_day_claude_routines",
            "claude_routines",
            "routines",
            "routine",
            "seven_day_cowork",
            "cowork",
        ]

        for alias in aliases {
            let json = """
            {
              "seven_day": {"utilization": 6, "resets_at": null},
              "\(alias)": null
            }
            """
            let response = try JSONDecoder().decode(
                ClaudeUsageResponse.self,
                from: Data(json.utf8)
            )
            let snapshot = ClaudeProvider.mapToSnapshot(response, plan: nil)

            #expect(response.routinesLimitReported)
            #expect(snapshot.weeklyByModel == [
                WeeklyModelUsage(label: "Daily Routines", percent: 0)
            ])

            let cachedData = try JSONEncoder().encode(response)
            let cachedResponse = try JSONDecoder().decode(
                ClaudeUsageResponse.self,
                from: cachedData
            )
            #expect(cachedResponse.routinesLimitReported)
            #expect(
                ClaudeProvider.mapToSnapshot(cachedResponse, plan: nil).weeklyByModel
                    == [WeeklyModelUsage(label: "Daily Routines", percent: 0)]
            )
        }
    }

    @Test("Scoped limits ignore all-model and duplicate model entries")
    func scopedLimitsFilterGenericAndDuplicateRows() {
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: .init(utilization: 20, resetsAt: nil),
            limits: [
                .init(
                    kind: "weekly_scoped",
                    group: "weekly",
                    percent: 20,
                    severity: nil,
                    resetsAt: nil,
                    scope: .init(model: .init(id: "all-models", displayName: "All models")),
                    isActive: true
                ),
                .init(
                    kind: "weekly_scoped",
                    group: "weekly",
                    percent: 15,
                    severity: nil,
                    resetsAt: nil,
                    scope: .init(model: .init(id: "claude-fable-5", displayName: "Fable")),
                    isActive: true
                ),
                .init(
                    kind: "weekly_scoped",
                    group: "weekly",
                    percent: 10,
                    severity: nil,
                    resetsAt: nil,
                    scope: .init(model: .init(id: "claude-fable-5", displayName: "Fable duplicate")),
                    isActive: true
                ),
            ]
        )

        #expect(ClaudeProvider.weeklyModelRows(from: response).map(\.label) == ["Fable"])
    }

    @Test("Map usage response with extra usage")
    func mapSnapshotWithExtra() {
        let response = ClaudeUsageResponse(
            fiveHour: .init(utilization: 50, resetsAt: nil),
            sevenDay: .init(utilization: 25, resetsAt: nil),
            sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayHaiku: nil,
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
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
            sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayHaiku: nil,
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
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
            sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayHaiku: nil,
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
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
            sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayHaiku: nil,
            sevenDayOmelette: nil, sevenDayCowork: nil, sevenDayOauthApps: nil,
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

    @Test("Rate-limit error message renders a long cooldown in minutes")
    func rateLimitMessageFormatsMinutes() {
        // A real server retry-after (2504s) must read as minutes, not "2504s".
        let message = ClaudeProvider.rateLimitErrorMessage(retryAfter: 2504)
        #expect(message.contains("Retry in ~42 min"))
        #expect(!message.contains("2504"))
    }

    @Test("formatRetryDelay picks a human unit per magnitude")
    func formatRetryDelayUnits() {
        #expect(ClaudeProvider.formatRetryDelay(0.2) == "1s")
        #expect(ClaudeProvider.formatRetryDelay(45) == "45s")
        #expect(ClaudeProvider.formatRetryDelay(60) == "~1 min")
        #expect(ClaudeProvider.formatRetryDelay(2504) == "~42 min")
        #expect(ClaudeProvider.formatRetryDelay(3600) == "~1h")
        #expect(ClaudeProvider.formatRetryDelay(5400) == "~1h 30m")
    }

    @Test("ProviderError.rateLimited description reflects retry value")
    func providerErrorRateLimitedDescription() {
        let withRetry = ProviderError.rateLimited(retryAfter: 45)
        #expect(withRetry.errorDescription == "Rate limited (retry in 45s)")

        let longWait = ProviderError.rateLimited(retryAfter: 2504)
        #expect(longWait.errorDescription == "Rate limited (retry in ~42 min)")

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
        #expect(message.contains("Retrying in ~1 min"))
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

@Suite("ClaudeProfile Tests")
struct ClaudeProfileTests {

    @Test("planName prefers has_claude_max")
    func maxAccount() throws {
        let raw = """
        {"account":{"has_claude_max":true,"has_claude_pro":false,"email":"x@y"},
         "organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: raw)
        #expect(profile.planName == "Max")
    }

    @Test("planName falls back to has_claude_pro")
    func proAccount() throws {
        let raw = """
        {"account":{"has_claude_max":false,"has_claude_pro":true,"email":"x@y"},
         "organization":{"organization_type":"claude_pro","rate_limit_tier":"default_claude_pro"}}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: raw)
        #expect(profile.planName == "Pro")
    }

    @Test("planName derives Team from organization_type when account flags are nil")
    func teamFromOrgType() throws {
        let raw = """
        {"account":{"email":"x@y"},
         "organization":{"organization_type":"claude_team","rate_limit_tier":"team"}}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: raw)
        #expect(profile.planName == "Team")
    }

    @Test("planName is nil when nothing is signaled")
    func nilWhenUnknown() throws {
        let raw = """
        {"account":{"email":"x@y"},
         "organization":{"organization_type":null,"rate_limit_tier":null}}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: raw)
        #expect(profile.planName == nil)
    }

    @Test("decodes the real /api/oauth/profile shape")
    func realResponseShape() throws {
        // Mirrors the payload observed in the wild that triggered the
        // v0.6.0 bug: credentials.subscriptionType is null but
        // profile.has_claude_max is true.
        let raw = """
        {
          "account": {
            "uuid": "ce190740",
            "email": "u@e.com",
            "has_claude_max": true,
            "has_claude_pro": false
          },
          "organization": {
            "uuid": "a4daae40",
            "organization_type": "claude_max",
            "rate_limit_tier": "default_claude_max_5x"
          },
          "application": { "slug": "claude-code" }
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: raw)
        #expect(profile.planName == "Max")
        #expect(profile.account?.email == "u@e.com")
    }
}
