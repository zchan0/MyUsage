import Foundation
import os

// MARK: - Codex Credential Models

/// Codex CLI auth.json structure.
struct CodexAuthFile: Codable, Sendable {
    let openaiApiKey: String?    // May be null in auth.json
    let tokens: CodexTokens?
    let lastRefresh: String?  // ISO 8601

    enum CodingKeys: String, CodingKey {
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    /// Whether token needs refresh (last_refresh > 8 days ago).
    var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        // Try with fractional seconds first, then without
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        guard let date = fmtFrac.date(from: lastRefresh) ?? fmtBasic.date(from: lastRefresh) else {
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

struct CodexCredits: Sendable, Equatable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?
}

extension CodexCredits: Codable {
    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
        unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
        // API may return balance as Double or String
        if let d = try? container.decodeIfPresent(Double.self, forKey: .balance) {
            balance = d
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .balance) {
            balance = Double(s)
        } else {
            balance = nil
        }
    }
}

struct CodexCodeReviewLimit: Codable, Sendable {
    let primaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
    }
}

/// Codex rate-limit reset-credit API response.
struct CodexResetCreditResponse: Decodable, Sendable {
    let credits: [CodexResetCreditRecord]
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credits = try container.decodeIfPresent([CodexResetCreditRecord].self, forKey: .credits) ?? []
        availableCount = try container.decode(Int.self, forKey: .availableCount)
        guard availableCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .availableCount,
                in: container,
                debugDescription: "available_count must not be negative"
            )
        }
    }
}

struct CodexResetCreditRecord: Decodable, Sendable {
    let id: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        grantedAt = try Self.decodeDateIfPresent(forKey: .grantedAt, from: container)
        expiresAt = try Self.decodeDateIfPresent(forKey: .expiresAt, from: container)
    }

    private static func decodeDateIfPresent(
        forKey key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        guard let date = fractional.date(from: raw) ?? basic.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Invalid ISO 8601 date"
            )
        }
        return date
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
    nonisolated private static let resetCreditsURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    )!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let keychainService = "Codex Auth"

    /// Search paths for auth.json, in priority order.
    private static var authFilePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            paths.append("\(codexHome)/auth.json")
        }
        paths.append("\(home)/.config/codex/auth.json")
        paths.append("\(home)/.codex/auth.json")
        return paths
    }

    // MARK: - State

    /// Optional multi-device ledger (spec 12). Written after each successful
    /// `computeMonthlyCost`.
    private weak var ledger: LedgerSync?

    // MARK: - Init

    init(ledger: LedgerSync? = nil) {
        self.ledger = ledger
        detectAvailability()
    }

    // MARK: - UsageProvider

    func refresh() async {
        // Re-detect once per refresh so a user who ran `codex login`
        // after MyUsage launched (or restored credentials after a
        // logout) doesn't need to relaunch the app. Mirrors the
        // pattern in ClaudeProvider.
        if !isAvailable { detectAvailability() }
        guard isAvailable else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            guard let loaded = loadAuthWithSource(), let tokens = loaded.auth.tokens else {
                error = "No credentials found"
                return
            }
            let auth = loaded.auth
            let sourcePath = loaded.sourcePath

            var accessToken = tokens.accessToken
            var usageBundle: (usage: CodexUsageResponse, resetCredits: ResetCreditInventory?)?

            // Strategy 1: Try API with existing token first
            do {
                usageBundle = try await fetchUsageBundle(
                    accessToken: accessToken,
                    accountId: tokens.accountId
                )
            } catch ProviderError.apiFailed(let code) where code == 401 || code == 403 {
                // Token expired — try refresh below
            } catch {
                guard auth.needsRefresh else { throw error }
            }

            // Strategy 2: Refresh token and retry. OpenAI rotates the
            // refresh_token on every refresh, so we MUST persist the new
            // pair back to auth.json — otherwise next cycle reuses the
            // now-revoked old refresh_token and the user starts seeing
            // "No credentials" until they re-run `codex` manually.
            if usageBundle == nil {
                let refreshed = try await refreshToken(tokens.refreshToken)
                accessToken = refreshed.accessToken

                if let path = sourcePath {
                    let updatedTokens = CodexTokens(
                        accessToken: refreshed.accessToken,
                        refreshToken: refreshed.refreshToken ?? tokens.refreshToken,
                        idToken: refreshed.idToken ?? tokens.idToken,
                        accountId: tokens.accountId
                    )
                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let updatedAuth = CodexAuthFile(
                        openaiApiKey: auth.openaiApiKey,
                        tokens: updatedTokens,
                        lastRefresh: isoFormatter.string(from: Date.now)
                    )
                    do {
                        try saveAuth(updatedAuth, to: path)
                    } catch {
                        // Non-fatal: refresh still worked for THIS request;
                        // we just won't have persisted the rotation.
                        Logger.codex.error(
                            "Failed to persist refreshed Codex tokens: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                usageBundle = try await fetchUsageBundle(
                    accessToken: accessToken,
                    accountId: tokens.accountId
                )
            }

            // Derive the account identity from auth.json — it does NOT
            // depend on the usage API, so we resolve + record it even when
            // the usage fetch failed. Previously this lived after the
            // `guard let usage else { return }` early-return below, so a
            // free account whose first refreshes hit a token-timing usage
            // failure showed a card with no account info until usage
            // happened to succeed several refreshes later.
            let identity = currentAccount()

            if let usageBundle {
                var mapped = Self.mapToSnapshot(usageBundle.usage)
                mapped.resetCredits = usageBundle.resetCredits
                mapped.monthlyEstimatedCost = await Self.computeMonthlyCost()
                snapshot = mapped
            }

            // Tag ledger writes with the current account identity so
            // cross-device aggregates stay attributable (spec 13).
            await recordDailyCostsToLedger(accountID: identity?.id ?? "default")

            // If usage never came back this cycle, keep showing whatever we
            // had — but don't pretend success.
            guard usageBundle != nil else { return }

        } catch {
            self.error = error.localizedDescription
        }
    }

    private func recordDailyCostsToLedger(accountID: String) async {
        guard let ledger else { return }
        let breakdown = await Task.detached(priority: .utility) {
            CodexLogParser.scanDailyBreakdown(
                roots: CodexLogParser.defaultRoots(),
                since: Date.ledgerBackfillStart()
            )
        }.value
        guard !breakdown.total.isEmpty else { return }
        await ledger.recordDailyCosts(
            provider: .codex,
            byDay: breakdown.total,
            perModelByDay: breakdown.byModel.isEmpty ? nil : breakdown.byModel,
            accountID: accountID
        )
    }

    /// Scan `~/.codex/sessions` + `archived_sessions` modified since the first
    /// of the current calendar month and compute estimated spend.
    nonisolated static func computeMonthlyCost() async -> Double {
        await Task.detached(priority: .utility) {
            let since = Date.startOfCurrentMonth()
            let byModel = CodexLogParser.scan(since: since)
            return CostCalculator.totalCost(of: byModel, catalog: PricingCatalog.shared)
        }.value
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
        loadAuthWithSource()?.auth
    }

    /// Loads the auth payload AND remembers which on-disk file produced it,
    /// so a subsequent `persistRefreshedTokens` can write back to the same
    /// path (rather than guessing — Keychain-sourced auth has no path and
    /// is left untouched on refresh).
    func loadAuthWithSource() -> (auth: CodexAuthFile, sourcePath: String?)? {
        for path in Self.authFilePaths {
            if let data = FileManager.default.contents(atPath: path),
               let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
               auth.tokens != nil {
                return (auth, path)
            }
        }
        // Fallback to Keychain. nil path = "no on-disk file to write back to".
        if let auth = KeychainHelper.readGenericPasswordJSON(
            service: Self.keychainService,
            as: CodexAuthFile.self
        ) {
            return (auth, nil)
        }
        return nil
    }

    // MARK: - Account identity

    /// Identity of the currently signed-in Codex account. Email is decoded
    /// from the OIDC `id_token` (`email` claim); falls back to the opaque
    /// `account_id` when the token is missing the claim or absent.
    func currentAccount() -> AccountIdentity? {
        guard let auth = loadAuth(), let tokens = auth.tokens else { return nil }
        if let idToken = tokens.idToken,
           let email = JWTDecoder.stringClaim("email", from: idToken),
           !email.isEmpty {
            return .email(email)
        }
        if let accountID = tokens.accountId, !accountID.isEmpty {
            return .opaque(accountID)
        }
        return nil
    }

    /// Atomically write the supplied auth back to `path`. We hand-encode
    /// instead of using JSONEncoder because OpenAI's auth.json uses an
    /// uppercase `OPENAI_API_KEY` key while the rest of the file is
    /// snake_case — round-tripping that exactly with Codable + a custom
    /// encoder strategy is fiddlier than just emitting the JSON literally.
    /// The atomic-write `(.atomic)` option goes through a temp file +
    /// rename so the Codex CLI can never observe a half-written file.
    func saveAuth(_ auth: CodexAuthFile, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(auth)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

    /// Fetch usage and reset credits together. Usage remains authoritative:
    /// reset-credit failure is represented as nil and never fails the refresh.
    private func fetchUsageBundle(
        accessToken: String,
        accountId: String?
    ) async throws -> (usage: CodexUsageResponse, resetCredits: ResetCreditInventory?) {
        async let resetCredits = fetchResetCredits(accessToken: accessToken, accountId: accountId)
        let usage = try await fetchUsage(accessToken: accessToken, accountId: accountId)
        do {
            return (usage, try await resetCredits)
        } catch {
            Logger.codex.info(
                "Reset-credit inventory unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return (usage, nil)
        }
    }

    private func fetchResetCredits(
        accessToken: String,
        accountId: String?
    ) async throws -> ResetCreditInventory {
        let request = Self.makeResetCreditsRequest(accessToken: accessToken, accountId: accountId)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw ProviderError.apiFailed(statusCode: http?.statusCode ?? -1)
        }
        return try Self.decodeResetCredits(data, now: .now)
    }

    nonisolated static func makeResetCreditsRequest(
        accessToken: String,
        accountId: String?
    ) -> URLRequest {
        var request = URLRequest(url: resetCreditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    nonisolated static func decodeResetCredits(
        _ data: Data,
        now: Date
    ) throws -> ResetCreditInventory {
        let response = try JSONDecoder().decode(CodexResetCreditResponse.self, from: data)
        let credits = response.credits
            .filter { record in
                guard record.status.lowercased() == "available" else { return false }
                return record.expiresAt.map { $0 > now } ?? true
            }
            .map { ResetCredit(id: $0.id, grantedAt: $0.grantedAt, expiresAt: $0.expiresAt) }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?):
                    if left != right { return left < right }
                    return lhs.id < rhs.id
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.id < rhs.id
                }
            }

        guard credits.count <= response.availableCount else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "available_count is smaller than the available credit records"
                )
            )
        }

        return ResetCreditInventory(
            reportedAvailableCount: response.availableCount,
            availableCredits: credits,
            fetchedAt: now
        )
    }

    // MARK: - Snapshot Mapping

    nonisolated static func mapToSnapshot(_ response: CodexUsageResponse) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now

        // Plan name
        snapshot.planName = response.planType.map { $0.prefix(1).uppercased() + $0.dropFirst() }

        // Windows are classified by their actual `limit_window_seconds`, not
        // by primary/secondary position. OpenAI has dropped the 5h window for
        // some plans — those accounts now return a single weekly window as
        // `primary_window`, and the old position-based mapping rendered it as
        // a bogus "5-hour" bar. ≤6h → session; anything longer → weekly.
        // Windows without `limit_window_seconds` (older CLI proxies) fall
        // back to the legacy positional rule.
        let rateLimit = response.rateLimit
        for (window, isPrimary) in [(rateLimit?.primaryWindow, true), (rateLimit?.secondaryWindow, false)] {
            guard let window, let used = window.usedPercent else { continue }
            let resetDate = window.resetAt.map { Date(timeIntervalSince1970: Double($0)) }

            let isSession: Bool
            if let seconds = window.limitWindowSeconds {
                isSession = seconds <= 6 * 3600
            } else {
                // Legacy responses without the field: positional semantics.
                isSession = isPrimary
            }

            if isSession, snapshot.sessionUsage == nil {
                snapshot.sessionUsage = UsageWindow(
                    percentUsed: Double(used),
                    resetsAt: resetDate,
                    windowDuration: window.limitWindowSeconds.map(Double.init) ?? 5 * 3600
                )
            } else if !isSession, snapshot.weeklyUsage == nil {
                snapshot.weeklyUsage = UsageWindow(
                    percentUsed: Double(used),
                    resetsAt: resetDate,
                    windowDuration: window.limitWindowSeconds.map(Double.init) ?? 7 * 24 * 3600
                )
            }
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
