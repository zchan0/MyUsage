import Foundation
import os
import CryptoKit

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
///
/// The API exposes a primary weekly cap (`sevenDay`) plus a *variable* set
/// of per-bucket sub-caps. Each sub-cap is **plan-dependent and optional**:
/// only plans that actually meter usage against that bucket return a non-
/// null value. Max 5x users typically see all sub-caps as null because
/// their usage rolls up into the unified `sevenDay` figure; some Enterprise
/// / Team tiers have separate Opus / Design / Cowork caps.
///
/// The bucket vocabulary has been evolving:
/// - `sevenDayOpus` / `sevenDaySonnet` — model-family caps (Haiku appears
///   to have been removed from the response entirely as of mid-2026).
/// - `sevenDayOmelette` — Anthropic's internal codename for **Claude Design**.
/// - `sevenDayCowork` — **Claude Cowork** (the collaborative coding product).
/// - `sevenDayOauthApps` — usage attributed to third-party OAuth apps.
///
/// Other codename fields appear in the response (`tangelo`, `iguana_necktie`,
/// `omelette_promotional`, ...) but their semantics aren't documented and
/// they're consistently null for end-user accounts; we don't decode them.
///
/// As of mid-2026 Anthropic added a structured `limits` array that reports
/// every cap in one place — the 5-hour session, the unified weekly cap, and
/// any *model-scoped* weekly caps — and stopped populating the flat
/// `seven_day_<codename>` fields (they now arrive null for end-user
/// accounts). New model caps, e.g. the **Fable** weekly cap, surface *only*
/// through `limits` (as a `weekly_scoped` entry whose `scope.model.display_name`
/// is the model name). `weeklyModelRows(from:)` prefers `limits` and falls
/// back to the flat fields for responses that predate the array. See
/// `ClaudeLimit`.
struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?

    let sevenDayOpus: ClaudeWindow?
    let sevenDaySonnet: ClaudeWindow?
    let sevenDayHaiku: ClaudeWindow?
    let sevenDayOmelette: ClaudeWindow?
    let sevenDayCowork: ClaudeWindow?
    let sevenDayOauthApps: ClaudeWindow?

    let extraUsage: ClaudeExtraUsage?

    /// Structured per-cap array (current API shape). Supersedes the flat
    /// `seven_day_<codename>` fields for model-scoped weekly caps. See
    /// `ClaudeLimit`. Optional so responses that predate it decode fine.
    let limits: [ClaudeLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayHaiku = "seven_day_haiku"
        case sevenDayOmelette = "seven_day_omelette"
        case sevenDayCowork = "seven_day_cowork"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case extraUsage = "extra_usage"
        case limits
    }

    /// Explicit memberwise init so the new `limits` field can default to
    /// `nil` — keeps existing call sites (tests, cache fixtures) compiling
    /// unchanged while the JSON decoder still populates it via the
    /// synthesized `init(from:)`. `fiveHour` / `sevenDay` stay required.
    init(
        fiveHour: ClaudeWindow?,
        sevenDay: ClaudeWindow?,
        sevenDayOpus: ClaudeWindow? = nil,
        sevenDaySonnet: ClaudeWindow? = nil,
        sevenDayHaiku: ClaudeWindow? = nil,
        sevenDayOmelette: ClaudeWindow? = nil,
        sevenDayCowork: ClaudeWindow? = nil,
        sevenDayOauthApps: ClaudeWindow? = nil,
        extraUsage: ClaudeExtraUsage? = nil,
        limits: [ClaudeLimit]? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayHaiku = sevenDayHaiku
        self.sevenDayOmelette = sevenDayOmelette
        self.sevenDayCowork = sevenDayCowork
        self.sevenDayOauthApps = sevenDayOauthApps
        self.extraUsage = extraUsage
        self.limits = limits
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

    /// One entry in the structured `limits` array.
    ///
    /// `kind` classifies the cap:
    ///   - `session`       — the 5-hour rolling window (mirrors `five_hour`)
    ///   - `weekly_all`    — the unified weekly cap (mirrors `seven_day`)
    ///   - `weekly_scoped` — a *per-model* weekly cap. The model's
    ///     user-facing name is in `scope.model.display_name` (e.g. "Fable").
    ///     This is the only place new model caps now surface.
    ///
    /// `percent` is decoded as `Double` because the API is inconsistent
    /// about integer vs. fractional utilization across fields. `severity`
    /// (`normal` / `warning` / …) is decoded for future colour-driving but
    /// not yet consumed — the bars still derive their band from `percent`.
    struct ClaudeLimit: Codable, Sendable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        struct Scope: Codable, Sendable {
            let model: Model?

            struct Model: Codable, Sendable {
                let id: String?
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                }
            }
        }
    }
}

/// `/api/oauth/profile` response — canonical source for the user's plan
/// label since recent Claude CLI builds stopped writing `subscriptionType`
/// / `rateLimitTier` into `~/.claude/.credentials.json`. Both fields now
/// arrive as `null`, so the previous credentials-only path collapsed to
/// a missing plan badge in the popover.
struct ClaudeProfile: Codable, Sendable {
    let account: Account?
    let organization: Organization?

    struct Account: Codable, Sendable {
        let hasClaudeMax: Bool?
        let hasClaudePro: Bool?
        let email: String?

        enum CodingKeys: String, CodingKey {
            case hasClaudeMax = "has_claude_max"
            case hasClaudePro = "has_claude_pro"
            case email
        }
    }

    struct Organization: Codable, Sendable {
        let organizationType: String?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case organizationType = "organization_type"
            case rateLimitTier = "rate_limit_tier"
        }
    }

    /// Display label used by the popover provider card. Account-level
    /// `has_claude_max` / `has_claude_pro` are checked first because
    /// they're the most direct signals; organization type is a fallback
    /// for team/enterprise tiers.
    var planName: String? {
        if account?.hasClaudeMax == true { return "Max" }
        if account?.hasClaudePro == true { return "Pro" }
        if let orgType = organization?.organizationType?.lowercased() {
            if orgType.contains("max") { return "Max" }
            if orgType.contains("pro") { return "Pro" }
            if orgType.contains("team") { return "Team" }
            if orgType.contains("enterprise") { return "Enterprise" }
        }
        return nil
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
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    // MARK: - State

    private var credentials: ClaudeCredentials?

    /// Cached profile (email + plan). Keyed by the credential fingerprint
    /// (`cachedProfileFingerprint`) so that when the Claude Code CLI
    /// switches accounts — a different OAuth token, hence a different
    /// fingerprint — we re-fetch instead of serving the previous account's
    /// email + plan. Without this the popover mislabels the active account
    /// (wrong email) and shows the first account's plan ("Max") for every
    /// account — the original account-switch mislabeling bug.
    private var cachedProfile: ClaudeProfile?
    private var cachedProfileFingerprint: String?

    /// Optional multi-device ledger. When present, each successful cost
    /// calculation writes per-day totals into the ledger (spec 12).
    private weak var ledger: LedgerSync?

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

    init(ledger: LedgerSync? = nil) {
        self.ledger = ledger
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
                    plan: planLabel(creds: creds),
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

            // Fetch the profile (email + plan) when we don't have one yet,
            // OR when the credential fingerprint changed since we last
            // fetched — i.e. the CLI switched accounts. Re-fetching on the
            // switch is what keeps the popover's email + plan attributed to
            // the account that's actually signed in. Failures are logged
            // but never stop the usage refresh — without the profile we
            // fall back to creds.planName, strictly worse but not broken.
            if cachedProfile == nil || cachedProfileFingerprint != fingerprint {
                do {
                    cachedProfile = try await fetchProfile(accessToken: oauth.accessToken)
                    cachedProfileFingerprint = fingerprint
                } catch {
                    Logger.claude.error(
                        "Profile fetch failed; falling back to credentials.planName: \(error.localizedDescription, privacy: .public)"
                    )
                }
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

            var mapped = Self.mapToSnapshot(usage, plan: planLabel(creds: creds), fetchedAt: .now)
            mapped.monthlyEstimatedCost = await Self.computeMonthlyCost()
            snapshot = mapped
            nextAllowedRefreshAt = nil
            consecutiveFailures = 0

            // Tag ledger writes with the current account identity so
            // cross-device aggregates stay attributable (spec 13). The
            // account_id is invisible in the UI — the cost row sums across
            // all of them — but it keeps each device's rows distinct.
            let identity = currentAccount()

            // Write per-day totals into the multi-device ledger (spec 12).
            // Off the hot path of the user-visible snapshot so a slow scan
            // never blocks the card update.
            await recordDailyCostsToLedger(accountID: identity?.id ?? "default")

            // NOTE: A previous build (commit 6ce6fba) overlaid `weeklyByModel`
            // with cost-share percentages derived from the ledger so Max 5x
            // users (where the API bundles everything into the unified
            // `sevenDay` and never populates per-bucket fields) would see
            // *something* under the Weekly bar. That conflated two different
            // semantics: per-bucket utilization (% of THIS cap used) vs.
            // share of total cost (% of THIS month's spend on this model).
            // Side-by-side they read like a quota table, so 99.99% Opus +
            // 0.01% Haiku displayed as "Opus 100% / Haiku 0%" looked like
            // a cap state — but it was just rounded cost share. Removed.
            // `weeklyByModel` is now the API path only: per-cap utilization
            // when the plan exposes sub-buckets, empty otherwise. Cost-by-
            // model data is still in the ledger for a future cost history
            // view; it just doesn't masquerade as a quota row here.

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

    // MARK: - Ledger

    private func recordDailyCostsToLedger(accountID: String) async {
        guard let ledger else { return }
        let breakdown = await Task.detached(priority: .utility) {
            ClaudeLogParser.scanDailyBreakdown(
                roots: ClaudeLogParser.defaultRoots(),
                since: Date.startOfCurrentMonth()
            )
        }.value
        guard !breakdown.total.isEmpty else { return }
        await ledger.recordDailyCosts(
            provider: .claude,
            byDay: breakdown.total,
            perModelByDay: breakdown.byModel.isEmpty ? nil : breakdown.byModel,
            accountID: accountID
        )
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

    // MARK: - Plan label

    /// Profile-first, credentials-fallback. Profile reflects the user's
    /// real subscription (Max / Pro / Team / …) even when the local
    /// credentials file no longer carries `subscriptionType`.
    private func planLabel(creds: ClaudeCredentials) -> String? {
        cachedProfile?.planName ?? creds.planName
    }

    // MARK: - Account identity

    /// Identity of the currently signed-in Claude account. `nil` when we
    /// haven't fetched the profile yet AND can't derive a fallback (e.g.
    /// no credentials at all). Once profile is cached, returns the email
    /// path; on the rare path where profile lookup failed but we still
    /// have credentials, returns an opaque hash so ledger writes don't
    /// silently merge into the legacy `"default"` bucket.
    func currentAccount() -> AccountIdentity? {
        if let email = cachedProfile?.account?.email, !email.isEmpty {
            return .email(email)
        }
        guard let creds = loadCredentials(), let oauth = creds.claudeAiOauth else {
            return nil
        }
        let digest = SHA256.hash(data: Data(oauth.refreshToken.utf8))
        let short = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return .opaque(short)
    }

    // MARK: - Profile Fetch

    private func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
        var request = URLRequest(url: Self.profileURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(AppInfo.claudeUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw ProviderError.apiFailed(statusCode: http?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(ClaudeProfile.self, from: data)
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
                resetsAt: fh.resetsAt.flatMap { parseISO8601($0) },
                windowDuration: 5 * 3600
            )
        }

        if let sd = response.sevenDay {
            snapshot.weeklyUsage = UsageWindow(
                percentUsed: Double(sd.utilization),
                resetsAt: sd.resetsAt.flatMap { parseISO8601($0) },
                windowDuration: 7 * 24 * 3600
            )
        }

        snapshot.weeklyByModel = weeklyModelRows(from: response)

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

    /// Per-model weekly caps for the popover's breakdown rows, sorted by
    /// utilization desc so the heaviest cap reads first.
    ///
    /// Source precedence:
    ///  1. The structured `limits` array (current API). Every
    ///     `weekly_scoped` entry is one model's separate weekly cap; the
    ///     label is `scope.model.display_name`. This is how new model caps
    ///     (e.g. **Fable**) arrive — the flat `seven_day_*` fields stopped
    ///     carrying them. When `limits` is present we trust it exclusively:
    ///     no scoped entries means "no per-model caps on this plan", which
    ///     is a real (empty) answer, not a reason to fall back.
    ///  2. Legacy flat `seven_day_<codename>` fields — used only when the
    ///     response predates the `limits` array (`limits == nil`).
    ///
    /// 0% rows are kept on purpose: a returned cap at 0% means "this cap
    /// exists on your plan but is unused this week" — information the user
    /// wants (and exactly the current Fable state). Only absent caps drop.
    nonisolated static func weeklyModelRows(
        from response: ClaudeUsageResponse
    ) -> [WeeklyModelUsage] {
        if let limits = response.limits {
            return limits.compactMap { limit -> WeeklyModelUsage? in
                guard limit.kind == "weekly_scoped",
                      let name = limit.scope?.model?.displayName,
                      !name.isEmpty else { return nil }
                return WeeklyModelUsage(label: name, percent: limit.percent ?? 0)
            }
            .sorted { $0.percent > $1.percent }
        }

        // Legacy fallback — flat codename fields. Model families
        // (Opus/Sonnet/Haiku) plus product lines (Design/Cowork/OAuth apps),
        // each plan-dependent and optional. Missing/nil window means the cap
        // doesn't exist on this plan and is dropped.
        return [
            ("Opus",       response.sevenDayOpus),
            ("Sonnet",     response.sevenDaySonnet),
            ("Haiku",      response.sevenDayHaiku),
            ("Design",     response.sevenDayOmelette),
            ("Cowork",     response.sevenDayCowork),
            ("OAuth apps", response.sevenDayOauthApps)
        ].compactMap { (label, window) -> WeeklyModelUsage? in
            guard let window else { return nil }
            return WeeklyModelUsage(label: label, percent: Double(window.utilization))
        }
        .sorted { $0.percent > $1.percent }
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
