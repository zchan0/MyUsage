import Foundation

// MARK: - Codex Credential Models

/// Codex CLI auth.json structure.
struct CodexAuthFile: Codable, Sendable {
    let tokens: CodexTokens?
    let lastRefresh: String?  // ISO 8601

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
    }

    /// Whether token needs refresh (last_refresh > 8 days ago).
    var needsRefresh: Bool {
        guard let lastRefresh, let date = ISO8601DateFormatter().date(from: lastRefresh) else {
            return true
        }
        return date.timeIntervalSinceNow < -(8 * 24 * 3600) // > 8 days ago
    }
}

struct CodexTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountId = "account_id"
    }
}

/// Codex usage API response.
struct CodexUsageResponse: Codable, Sendable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?
    let codeReviewRateLimit: CodexCodeReviewLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case codeReviewRateLimit = "code_review_rate_limit"
    }
}

struct CodexRateLimit: Codable, Sendable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexWindow: Codable, Sendable {
    let usedPercent: Int?
    let resetAt: Int64?        // Unix seconds
    let limitWindowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

struct CodexCredits: Codable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?      // dollars

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

struct CodexCodeReviewLimit: Codable, Sendable {
    let primaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
    }
}

/// Codex token refresh response.
struct CodexTokenRefreshResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

// MARK: - Codex Provider

/// Codex (OpenAI) usage provider.
@Observable
@MainActor
final class CodexProvider: UsageProvider {

    let kind = ProviderKind.codex
    private(set) var isAvailable = false
    var isEnabled = true
    private(set) var snapshot: UsageSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false

    // MARK: - Constants

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let keychainService = "Codex Auth"

    /// Search paths for auth.json, in priority order.
    private static var authFilePaths: [String] {
        var paths: [String] = []
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            paths.append("\(codexHome)/auth.json")
        }
        paths.append("\(NSHomeDirectory())/.config/codex/auth.json")
        paths.append("\(NSHomeDirectory())/.codex/auth.json")
        return paths
    }

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
            guard let auth = loadAuth(), let tokens = auth.tokens else {
                error = "No credentials found"
                return
            }

            var accessToken = tokens.accessToken

            // Refresh if needed
            if auth.needsRefresh {
                let refreshed = try await refreshToken(tokens.refreshToken)
                accessToken = refreshed.accessToken
            }

            // Fetch usage
            let usage = try await fetchUsage(accessToken: accessToken, accountId: tokens.accountId)

            // Map to snapshot
            snapshot = Self.mapToSnapshot(usage)

        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Detection

    private func detectAvailability() {
        for path in Self.authFilePaths {
            if FileManager.default.fileExists(atPath: path) {
                isAvailable = true
                return
            }
        }
    }

    // MARK: - Auth Loading

    func loadAuth() -> CodexAuthFile? {
        for path in Self.authFilePaths {
            if let data = FileManager.default.contents(atPath: path),
               let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
               auth.tokens != nil {
                return auth
            }
        }
        // Fallback to Keychain
        return KeychainHelper.readGenericPasswordJSON(
            service: Self.keychainService,
            as: CodexAuthFile.self
        )
    }

    // MARK: - Token Refresh

    private func refreshToken(_ refreshToken: String) async throws -> CodexTokenRefreshResponse {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&client_id=\(Self.clientID)&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.tokenRefreshFailed
        }

        return try JSONDecoder().decode(CodexTokenRefreshResponse.self, from: data)
    }

    // MARK: - Usage Fetch

    private func fetchUsage(accessToken: String, accountId: String?) async throws -> CodexUsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw ProviderError.apiFailed(statusCode: http?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }

    // MARK: - Snapshot Mapping

    nonisolated static func mapToSnapshot(_ response: CodexUsageResponse) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now

        // Plan name
        snapshot.planName = response.planType.map { $0.prefix(1).uppercased() + $0.dropFirst() }

        // Session (5h)
        if let primary = response.rateLimit?.primaryWindow, let used = primary.usedPercent {
            let resetDate = primary.resetAt.map { Date(timeIntervalSince1970: Double($0)) }
            snapshot.sessionUsage = UsageWindow(percentUsed: Double(used), resetsAt: resetDate)
        }

        // Weekly (7d)
        if let secondary = response.rateLimit?.secondaryWindow, let used = secondary.usedPercent {
            let resetDate = secondary.resetAt.map { Date(timeIntervalSince1970: Double($0)) }
            snapshot.weeklyUsage = UsageWindow(percentUsed: Double(used), resetsAt: resetDate)
        }

        // Credits
        if let credits = response.credits, credits.hasCredits == true, let balance = credits.balance {
            snapshot.credits = CreditInfo(
                amount: balance,
                limit: nil,
                currency: "USD"
            )
        }

        return snapshot
    }
}
