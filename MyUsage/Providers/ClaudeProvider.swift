import Foundation

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

    // MARK: - Init

    init() {
        detectAvailability()
    }

    // MARK: - UsageProvider

    func refresh() async {
        guard isAvailable else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            // 1. Load credentials
            guard var creds = loadCredentials(), let oauth = creds.claudeAiOauth else {
                error = "No credentials found"
                return
            }

            // 2. Refresh token if expired
            var accessToken = oauth.accessToken
            if creds.isExpired {
                let refreshed = try await refreshToken(oauth.refreshToken)
                accessToken = refreshed.accessToken
                // Update stored credentials
                creds = updateCredentials(creds, with: refreshed)
            }

            // 3. Fetch usage
            let usage = try await fetchUsage(accessToken: accessToken)

            // 4. Map to snapshot + monthly cost (computed off-main)
            var mapped = Self.mapToSnapshot(usage, plan: creds.planName)
            mapped.monthlyEstimatedCost = await Self.computeMonthlyCost()
            snapshot = mapped

        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Scan `~/.claude/projects/**/*.jsonl` modified since the first of the
    /// current calendar month and compute estimated spend.
    nonisolated static func computeMonthlyCost() async -> Double {
        await Task.detached(priority: .utility) {
            let since = Date.startOfCurrentMonth()
            let byModel = ClaudeLogParser.scan(since: since)
            return CostCalculator.totalCost(of: byModel, catalog: PricingCatalog.shared)
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
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
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .tokenRefreshFailed: "Token refresh failed"
        case .apiFailed(let code): "API error (\(code))"
        case .notConfigured: "Not configured"
        }
    }
}
