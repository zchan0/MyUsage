import Foundation
import os

/// Claude Code credential file structure.
/// Located at `~/.claude/.credentials.json` or Keychain `Claude Code-credentials`.
struct ClaudeCredentials: Codable, Sendable {
    let claudeAiOauth: ClaudeOAuthInfo?

    struct ClaudeOAuthInfo: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64  // Unix milliseconds
        let scopes: [String]?
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    /// Whether the access token has expired (with 5-minute buffer).
    var isExpired: Bool {
        guard let oauth = claudeAiOauth else { return true }
        let expiryDate = Date(timeIntervalSince1970: Double(oauth.expiresAt) / 1000.0)
        return expiryDate.timeIntervalSinceNow < 300 // 5 min buffer
    }

    /// Infer plan name from subscription type or rate limit tier.
    var planName: String? {
        guard let oauth = claudeAiOauth else { return nil }
        if let sub = oauth.subscriptionType {
            return sub.prefix(1).uppercased() + sub.dropFirst()
        }
        return oauth.rateLimitTier
    }
}

/// Claude usage API response.
struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?
    let sevenDayOscar: ClaudeWindow?  // Opus-specific
    let extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOscar = "seven_day_opus"
        case extraUsage = "extra_usage"
    }

    struct ClaudeWindow: Codable, Sendable {
        let utilization: Int       // % used (0-100)
        let resetsAt: String?     // ISO 8601

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct ClaudeExtraUsage: Codable, Sendable {
        let isEnabled: Bool?
        let usedCredits: Int?     // cents
        let monthlyLimit: Int?    // cents (0 = unlimited)
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
            case currency
        }
    }
}

/// Claude OAuth token refresh response.
struct ClaudeTokenRefreshResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int  // seconds

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Claude Code usage provider.
@Observable
@MainActor
final class ClaudeProvider: UsageProvider {

    let kind = ProviderKind.claude
    private(set) var isAvailable = false
    var isEnabled = true
    private(set) var snapshot: UsageSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false

    // MARK: - Constants

    private static let credentialFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/.credentials.json"
    }()
    private static let keychainService = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    // MARK: - State

    private var credentials: ClaudeCredentials?

    /// After a 429, skip API calls until this time. `refresh()` becomes a no-op
    /// and we keep showing the last good snapshot and error message.
    private var nextAllowedRefreshAt: Date?

    /// After a 429, the current access token has been counted against
    /// Anthropic's rate limit bucket. Force a token refresh on the next attempt
    /// (regardless of `expiresAt`) so we come back with a fresh token.
    private var forceTokenRefreshOnNextCall = false

    /// Consecutive non-429 failures (5xx, network, token refresh, …). Drives
    /// exponential backoff so outages don't turn into tight retry loops.
    /// Reset to 0 on any response from the server (200 or 429).
    private var consecutiveFailures = 0

    /// Default cooldown when the server returns 429 without `Retry-After`.
    private static let defaultRateLimitCooldown: TimeInterval = 60

    /// Exponential-backoff base delay for transient failures (seconds).
    nonisolated private static let backoffBase: TimeInterval = 30

    /// Exponential-backoff cap — don't sleep longer than this (seconds).
    nonisolated private static let backoffCap: TimeInterval = 30 * 60

    // MARK: - Init

    init() {
        detectAvailability()
    }

    // MARK: - UsageProvider

    func refresh() async {
        guard isAvailable else { return }

        // Respect cooldown from a prior 429 — keep stale data + error intact.
        if let until = nextAllowedRefreshAt, until > .now {
            return
        }

        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            guard var creds = loadCredentials(), let oauth = creds.claudeAiOauth else {
                error = "No credentials found"
                return
            }

            // Refresh token if expired, or if a previous 429 told us the
            // current token bucket is already burnt.
            var accessToken = oauth.accessToken
            if forceTokenRefreshOnNextCall || creds.isExpired {
                let refreshed = try await refreshToken(oauth.refreshToken)
                accessToken = refreshed.accessToken
                creds = updateCredentials(creds, with: refreshed)
                forceTokenRefreshOnNextCall = false
            }

            let usage = try await fetchUsage(accessToken: accessToken)

            var mapped = Self.mapToSnapshot(usage, plan: creds.planName)
            mapped.monthlyEstimatedCost = await Self.computeMonthlyCost()
            snapshot = mapped
            nextAllowedRefreshAt = nil
            consecutiveFailures = 0

        } catch ProviderError.rateLimited(let retryAfter) {
            let delay = retryAfter ?? Self.defaultRateLimitCooldown
            nextAllowedRefreshAt = Date.now.addingTimeInterval(delay)
            forceTokenRefreshOnNextCall = true
            // 429 means we did reach the server — not a transient outage.
            consecutiveFailures = 0
            error = Self.rateLimitErrorMessage(retryAfter: delay)
            Logger.claude.warning(
                "Rate limited by Anthropic, retryAfter=\(Int(delay), privacy: .public)s"
            )
            // Intentionally keep `snapshot` as-is so the card still shows data.
        } catch {
            consecutiveFailures += 1
            let delay = Self.backoffDelay(consecutiveFailures: consecutiveFailures)
            nextAllowedRefreshAt = Date.now.addingTimeInterval(delay)
            self.error = Self.transientErrorMessage(
                underlying: error.localizedDescription,
                retryAfter: delay
            )
            Logger.claude.error(
                "Transient failure (\(error.localizedDescription, privacy: .public)), consecutiveFailures=\(self.consecutiveFailures, privacy: .public), backoff=\(Int(delay), privacy: .public)s"
            )
            // Keep `snapshot` as-is so we still show the last known numbers.
        }
    }

    /// Formats the user-facing message shown on a 429. Kept internal + static
    /// so it's easy to unit-test without spinning up the full provider.
    nonisolated static func rateLimitErrorMessage(retryAfter: TimeInterval) -> String {
        let seconds = max(1, Int(retryAfter.rounded()))
        return "Rate limited. Retry in \(seconds)s. If this persists, run `claude logout && claude login` in Terminal."
    }

    /// Formats the user-facing message shown during exponential backoff.
    nonisolated static func transientErrorMessage(
        underlying: String,
        retryAfter: TimeInterval
    ) -> String {
        let seconds = max(1, Int(retryAfter.rounded()))
        return "\(underlying). Retrying in \(seconds)s."
    }

    /// Exponential-backoff delay in seconds for the Nth consecutive failure.
    ///
    /// - 1 failure →  30s
    /// - 2        →  60s
    /// - 3        → 120s
    /// - 4        → 240s (4m)
    /// - 5        → 480s (8m)
    /// - 6        → 960s (16m)
    /// - 7+       → capped at `backoffCap` (30m)
    nonisolated static func backoffDelay(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        let exponent = Double(consecutiveFailures - 1)
        let raw = backoffBase * pow(2.0, exponent)
        return min(raw, backoffCap)
    }

    /// Scan `~/.claude/projects/**/*.jsonl` modified since the first of the
    /// current calendar month and compute estimated spend.
    ///
    /// For rows that already carry a `costUSD` value we trust that number
    /// directly; for older rows without it, we fall back to token × pricing.
    nonisolated static func computeMonthlyCost() async -> Double {
        await Task.detached(priority: .utility) {
            let since = Date.startOfCurrentMonth()
            let breakdown = ClaudeLogParser.scanBreakdown(since: since)
            let tokenCost = CostCalculator.totalCost(
                of: breakdown.tokensByModel,
                catalog: PricingCatalog.shared
            )
            return breakdown.preComputedCost + tokenCost
        }.value
    }

    // MARK: - Detection

    private func detectAvailability() {
        isAvailable = FileManager.default.fileExists(atPath: Self.credentialFilePath)
    }

    // MARK: - Credentials

    func loadCredentials() -> ClaudeCredentials? {
        // Try file first
        if let data = FileManager.default.contents(atPath: Self.credentialFilePath) {
            if let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
               creds.claudeAiOauth != nil {
                return creds
            }
        }
        // Fallback to Keychain
        return KeychainHelper.readGenericPasswordJSON(
            service: Self.keychainService,
            as: ClaudeCredentials.self
        )
    }

    // MARK: - Token Refresh

    private func refreshToken(_ refreshToken: String) async throws -> ClaudeTokenRefreshResponse {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppInfo.claudeUserAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.tokenRefreshFailed
        }

        return try JSONDecoder().decode(ClaudeTokenRefreshResponse.self, from: data)
    }

    private func updateCredentials(
        _ existing: ClaudeCredentials,
        with refreshed: ClaudeTokenRefreshResponse
    ) -> ClaudeCredentials {
        guard let oldOAuth = existing.claudeAiOauth else { return existing }
        let newExpiresAt = Int64(Date.now.timeIntervalSince1970 * 1000) + Int64(refreshed.expiresIn * 1000)
        let newOAuth = ClaudeCredentials.ClaudeOAuthInfo(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? oldOAuth.refreshToken,
            expiresAt: newExpiresAt,
            scopes: oldOAuth.scopes,
            subscriptionType: oldOAuth.subscriptionType,
            rateLimitTier: oldOAuth.rateLimitTier
        )
        return ClaudeCredentials(claudeAiOauth: newOAuth)
    }

    // MARK: - Usage Fetch

    private func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(AppInfo.claudeUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        if http?.statusCode == 429 {
            let retryAfter = http
                .flatMap { $0.value(forHTTPHeaderField: "Retry-After") }
                .flatMap { RetryAfterParser.seconds(from: $0) }
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        }

        guard http?.statusCode == 200 else {
            throw ProviderError.apiFailed(statusCode: http?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    }

    // MARK: - Snapshot Mapping

    nonisolated static func mapToSnapshot(_ response: ClaudeUsageResponse, plan: String?) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.planName = plan
        snapshot.lastRefreshed = .now

        if let fh = response.fiveHour {
            snapshot.sessionUsage = UsageWindow(
                percentUsed: Double(fh.utilization),
                resetsAt: fh.resetsAt.flatMap { parseISO8601($0) }
            )
        }

        if let sd = response.sevenDay {
            snapshot.weeklyUsage = UsageWindow(
                percentUsed: Double(sd.utilization),
                resetsAt: sd.resetsAt.flatMap { parseISO8601($0) }
            )
        }

        if let extra = response.extraUsage, extra.isEnabled == true {
            let spent = Double(extra.usedCredits ?? 0) / 100.0
            let limit = extra.monthlyLimit.map { $0 > 0 ? Double($0) / 100.0 : nil } ?? nil
            snapshot.onDemandSpend = CreditInfo(
                amount: spent,
                limit: limit,
                currency: extra.currency ?? "USD"
            )
        }

        return snapshot
    }
}

// MARK: - Helpers

private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}

enum ProviderError: LocalizedError {
    case tokenRefreshFailed
    case apiFailed(statusCode: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .tokenRefreshFailed: "Token refresh failed"
        case .apiFailed(let code): "API error (\(code))"
        case .rateLimited(let retry):
            if let retry, retry > 0 {
                "Rate limited (retry in \(Int(retry.rounded()))s)"
            } else {
                "Rate limited"
            }
        case .notConfigured: "Not configured"
        }
    }
}
