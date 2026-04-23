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

    private static let claudeDirectory: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
    }()
    private static let credentialFilePath: String = {
        claudeDirectory + "/.credentials.json"
    }()
    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // MARK: - State

    private var credentials: ClaudeCredentials?

    /// After a 429, skip API calls until this time. `refresh()` becomes a no-op
    /// and we keep showing the last good snapshot and error message.
    private var nextAllowedRefreshAt: Date?

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
        // Re-detect once per refresh so a user who ran `claude login`
        // after the app launched doesn't need to relaunch.
        if !isAvailable { detectAvailability() }
        guard isAvailable else { return }

        // Respect cooldown from a prior 429 — keep stale data + error intact.
        if let until = nextAllowedRefreshAt, until > .now {
            return
        }

        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            guard let creds = loadCredentials(), let oauth = creds.claudeAiOauth else {
                error = "No credentials found"
                return
            }

            // Cache-first: seed the snapshot from disk before any slow path runs
            // so a cold start (or a run that will fail below) never shows a
            // blank card. See `specs/11-claude-data-sources.md`.
            let fingerprint = ClaudeUsageCache.fingerprint(refreshToken: oauth.refreshToken)
            if snapshot == nil,
               let cached = ClaudeUsageCache.read(matching: fingerprint) {
                snapshot = Self.mapToSnapshot(
                    cached.response,
                    plan: creds.planName,
                    fetchedAt: cached.fetchedAt
                )
                Logger.claude.info("Seeded Claude snapshot from disk cache")
            }

            // MyUsage is a passive reader: we never call Anthropic's OAuth refresh
            // endpoint ourselves, because Anthropic rotates refresh tokens on each
            // use and we would race the Claude Code CLI, invalidating whichever
            // side cached the old token. Instead we surface a clear hint and wait
            // for the CLI to rotate the Keychain entry on its own schedule.
            if creds.isExpired {
                error = Self.tokenExpiredErrorMessage()
                Logger.claude.info("Access token expired; waiting for Claude CLI to refresh Keychain")
                return
            }

            let usage = try await fetchUsage(accessToken: oauth.accessToken)

            do {
                try ClaudeUsageCache.write(
                    response: usage,
                    fingerprint: fingerprint,
                    at: .now
                )
            } catch {
                Logger.claude.error(
                    "Failed to write usage cache: \(error.localizedDescription, privacy: .public)"
                )
            }

            var mapped = Self.mapToSnapshot(usage, plan: creds.planName, fetchedAt: .now)
            mapped.monthlyEstimatedCost = await Self.computeMonthlyCost()
            snapshot = mapped
            nextAllowedRefreshAt = nil
            consecutiveFailures = 0

        } catch ProviderError.rateLimited(let retryAfter) {
            let delay = retryAfter ?? Self.defaultRateLimitCooldown
            nextAllowedRefreshAt = Date.now.addingTimeInterval(delay)
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

    /// Shown when the cached access token has expired and we're waiting for the
    /// Claude Code CLI to rotate the Keychain entry. MyUsage deliberately does
    /// not call `/v1/oauth/token` itself — see the commit removing that path.
    nonisolated static func tokenExpiredErrorMessage() -> String {
        "Claude access token expired. Run `claude` once in Terminal so the CLI refreshes the Keychain entry."
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
    /// Cache-gated: the per-file mtime walk is cheap; a full parse only
    /// happens when a JSONL has been appended to since the last scan or the
    /// calendar month has rolled over. See `specs/11-claude-data-sources.md`.
    nonisolated static func computeMonthlyCost() async -> Double {
        await Task.detached(priority: .utility) {
            Self.computeMonthlyCostSync(
                roots: ClaudeLogParser.defaultRoots(),
                now: .now,
                cacheURL: ClaudeCostCache.defaultFileURL
            )
        }.value
    }

    /// Testable synchronous core of `computeMonthlyCost`. Accepts injectable
    /// roots / now / cache URL so unit tests can use temp fixtures without
    /// touching the real `~/.claude/projects` or `~/Library/Caches`.
    nonisolated static func computeMonthlyCostSync(
        roots: [URL],
        now: Date,
        cacheURL: URL
    ) -> Double {
        let since = Date.startOfCurrentMonth(now: now)
        let month = ClaudeCostCache.monthKey(for: now)

        // 1) Stat pass — cheap, no parse. `nil` means no in-scope files.
        let maxMtime = ClaudeLogParser.maxMtime(roots: roots, since: since)

        // 2) Cache hit? Require matching month AND matching max mtime.
        if let cached = ClaudeCostCache.read(from: cacheURL),
           cached.month == month,
           let mtime = maxMtime,
           abs(cached.maxSourceMtime.timeIntervalSinceReferenceDate
               - mtime.timeIntervalSinceReferenceDate) < 1e-6 {
            return cached.totalUSD
        }

        // 3) Miss — full scan.
        let breakdown = ClaudeLogParser.scanBreakdown(roots: roots, since: since)
        let tokenCost = CostCalculator.totalCost(
            of: breakdown.tokensByModel,
            catalog: PricingCatalog.shared
        )
        let total = breakdown.preComputedCost + tokenCost

        // 4) Persist (best-effort). Skip when no in-scope files, since we
        //    have nothing to pin the cache to for invalidation.
        if let mtime = maxMtime {
            let counts = breakdown.tokensByModel.mapValues(ClaudeCostCache.CachedTokenCounts.init)
            let payload = ClaudeCostCache.Payload(
                v: ClaudeCostCache.currentVersion,
                month: month,
                totalUSD: total,
                preComputedCost: breakdown.preComputedCost,
                tokensByModel: counts,
                maxSourceMtime: mtime,
                computedAt: now
            )
            do {
                try ClaudeCostCache.write(payload, to: cacheURL)
            } catch {
                Logger.claude.error(
                    "Failed to write cost cache: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return total
    }

    // MARK: - Detection

    /// Claude is "available" when we can read credentials from *either* source:
    /// the legacy `~/.claude/.credentials.json` file or the macOS Keychain item
    /// `Claude Code-credentials`. Newer Claude Code CLIs on macOS store only in
    /// Keychain, so a file-only check hides the provider for most users.
    ///
    /// When credentials cannot be read but `~/.claude/` exists, we assume the
    /// user *is* a Claude user whose Keychain item is ACL-restricted to the
    /// CLI itself, and surface a helpful error instead of "Not configured".
    private func detectAvailability() {
        // 1) File path first.
        if let data = FileManager.default.contents(atPath: Self.credentialFilePath),
           let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
           creds.claudeAiOauth != nil {
            isAvailable = true
            error = nil
            return
        }

        // 2) Keychain (with status for diagnostics).
        let result = KeychainHelper.readGenericPasswordResult(service: Self.keychainService)
        if let data = result.data,
           let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
           creds.claudeAiOauth != nil {
            isAvailable = true
            error = nil
            Logger.claude.info("Claude credentials loaded from Keychain")
            return
        }

        isAvailable = false

        // 3) Distinguish "user never installed Claude" from "installed but we
        //    cannot read the Keychain item".
        let claudeDirExists = FileManager.default.fileExists(atPath: Self.claudeDirectory)
        if !claudeDirExists {
            // Genuinely not a Claude user. Leave error nil → "Not configured".
            Logger.claude.info("Claude not detected (no ~/.claude directory)")
            return
        }

        Logger.claude.error(
            "Claude credentials unreadable (keychain status=\(result.status, privacy: .public))"
        )
        error = Self.credentialAccessErrorMessage(status: result.status)
    }

    /// User-facing message shown when `~/.claude/` exists but credentials
    /// cannot be read from either source. Visible via the provider card's
    /// error row.
    nonisolated static func credentialAccessErrorMessage(status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound:
            return "Claude Code is installed but no credentials were found. Run `claude login` in a terminal."
        default:
            return "Cannot read Claude credentials from Keychain (status \(status)). Open Keychain Access, find “Claude Code-credentials”, and allow MyUsage to access it."
        }
    }

    // MARK: - Credentials

    func loadCredentials() -> ClaudeCredentials? {
        if let data = FileManager.default.contents(atPath: Self.credentialFilePath) {
            if let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
               creds.claudeAiOauth != nil {
                return creds
            }
        }
        return KeychainHelper.readGenericPasswordJSON(
            service: Self.keychainService,
            as: ClaudeCredentials.self
        )
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

    /// `fetchedAt` is the wall-clock time the `response` came off the wire,
    /// typically `.now` for a fresh fetch or the cached value for a
    /// replayed snapshot. It drives the "Last refreshed N min ago" label.
    nonisolated static func mapToSnapshot(
        _ response: ClaudeUsageResponse,
        plan: String?,
        fetchedAt: Date = .now
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.planName = plan
        snapshot.lastRefreshed = fetchedAt

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
