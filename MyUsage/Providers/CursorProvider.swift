import Foundation

// MARK: - Cursor Data Models

/// Cursor GetCurrentPeriodUsage response.
struct CursorUsageResponse: Codable, Sendable {
    let billingCycleStart: String?    // unix ms as string
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimit?

    struct CursorPlanUsage: Codable, Sendable {
        let totalSpend: Int?          // cents
        let includedSpend: Int?       // cents
        let remaining: Int?           // cents
        let limit: Int?               // cents
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct CursorSpendLimit: Codable, Sendable {
        let totalSpend: Int?          // cents
        let individualLimit: Int?     // cents
        let individualUsed: Int?
        let individualRemaining: Int?
        let pooledLimit: Int?
        let pooledUsed: Int?
        let limitType: String?        // "user" | "team"
    }
}

/// Cursor GetPlanInfo response.
struct CursorPlanInfoResponse: Codable, Sendable {
    let planInfo: CursorPlanInfo?

    struct CursorPlanInfo: Codable, Sendable {
        let planName: String?
        let includedAmountCents: Int?
        let price: String?
        let billingCycleEnd: String?
    }
}

/// Cursor token refresh response.
struct CursorTokenRefreshResponse: Codable, Sendable {
    let accessToken: String?
    let idToken: String?
    let shouldLogout: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case shouldLogout
    }
}

// MARK: - Cursor Provider

/// Cursor usage provider.
@Observable
@MainActor
final class CursorProvider: UsageProvider {

    let kind = ProviderKind.cursor
    private(set) var isAvailable = false
    var isEnabled = true
    private(set) var snapshot: UsageSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false

    // MARK: - Constants

    private static let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    private static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!

    // SQLite keys
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let refreshTokenKey = "cursorAuth/refreshToken"
    private static let emailKey = "cursorAuth/cachedEmail"
    private static let membershipKey = "cursorAuth/stripeMembershipType"

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
            // 1. Load tokens from SQLite
            guard let tokens = loadTokens() else {
                error = "No Cursor auth found"
                return
            }

            var accessToken = tokens.accessToken

            // 2. Refresh if JWT expired
            if isJWTExpired(accessToken), let refreshToken = tokens.refreshToken {
                if let refreshed = try await refreshToken_(refreshToken) {
                    accessToken = refreshed
                }
            }

            // 3. Fetch usage + plan in parallel
            async let usageResult = fetchUsage(accessToken: accessToken)
            async let planResult = fetchPlan(accessToken: accessToken)

            let usage = try await usageResult
            let plan = try? await planResult  // plan is optional

            // 4. Map to snapshot
            snapshot = Self.mapToSnapshot(usage: usage, plan: plan, email: tokens.email, membership: tokens.membership)

        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Detection

    private func detectAvailability() {
        isAvailable = FileManager.default.fileExists(atPath: Self.dbPath)
    }

    // MARK: - Token Loading

    struct CursorTokens {
        let accessToken: String
        let refreshToken: String?
        let email: String?
        let membership: String?
    }

    func loadTokens() -> CursorTokens? {
        let values = SQLiteHelper.readValues(
            dbPath: Self.dbPath,
            keys: [Self.accessTokenKey, Self.refreshTokenKey, Self.emailKey, Self.membershipKey]
        )
        guard let accessToken = values[Self.accessTokenKey], !accessToken.isEmpty else {
            return nil
        }
        return CursorTokens(
            accessToken: accessToken,
            refreshToken: values[Self.refreshTokenKey],
            email: values[Self.emailKey],
            membership: values[Self.membershipKey]
        )
    }

    // MARK: - JWT Expiry Check

    private func isJWTExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return true }

        var base64 = String(parts[1])
        // Pad to multiple of 4
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return true
        }

        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 60
    }

    // MARK: - Token Refresh

    private func refreshToken_(_ refreshToken: String) async throws -> String? {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.tokenRefreshFailed
        }

        let refreshResponse = try JSONDecoder().decode(CursorTokenRefreshResponse.self, from: data)
        if refreshResponse.shouldLogout == true {
            throw ProviderError.tokenRefreshFailed
        }

        return refreshResponse.accessToken
    }

    // MARK: - Usage Fetch (Connect RPC)

    private func fetchUsage(accessToken: String) async throws -> CursorUsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw ProviderError.apiFailed(statusCode: http?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }

    private func fetchPlan(accessToken: String) async throws -> CursorPlanInfoResponse {
        var request = URLRequest(url: Self.planURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw ProviderError.apiFailed(statusCode: http?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(CursorPlanInfoResponse.self, from: data)
    }

    /// Known plan included budgets (cents)
    nonisolated static let includedBudgetCents: [String: Int] = [
        "pro": 2_000, "hobby": 2_000,
        "pro_plus": 7_000,
        "ultra": 40_000,
        "team": 2_000,
    ]

    nonisolated static func mapToSnapshot(
        usage: CursorUsageResponse,
        plan: CursorPlanInfoResponse?,
        email: String?,
        membership: String?
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastRefreshed = .now
        snapshot.email = email

        // Plan name
        let rawPlan = plan?.planInfo?.planName?.lowercased() ?? membership?.lowercased() ?? ""
        snapshot.planName = plan?.planInfo?.planName ?? membership.map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        }

        // Billing cycle end
        if let endStr = usage.billingCycleEnd ?? plan?.planInfo?.billingCycleEnd,
           let endMs = Double(endStr) {
            snapshot.billingCycleEnd = Date(timeIntervalSince1970: endMs / 1000)
        }

        // Included budget: prefer API limit > plan includedAmountCents > hardcoded
        let budgetCents = usage.planUsage?.limit
            ?? plan?.planInfo?.includedAmountCents
            ?? includedBudgetCents[rawPlan]
            ?? 0

        // Included spend: prefer API includedSpend > capped totalSpend
        let includedUsedCents: Int
        if let apiIncluded = usage.planUsage?.includedSpend {
            includedUsedCents = apiIncluded
        } else {
            includedUsedCents = min(usage.planUsage?.totalSpend ?? 0, budgetCents)
        }

        if budgetCents > 0 {
            let percent = Double(includedUsedCents) / Double(budgetCents) * 100
            snapshot.spentAmount = CreditInfo(
                amount: Double(includedUsedCents) / 100.0,
                limit: Double(budgetCents) / 100.0,
                currency: "USD"
            )
            snapshot.totalUsagePercent = min(percent, 100)
        }

        // On-demand: prefer spendLimitUsage (API-reported)
        let spendLimit = usage.spendLimitUsage
        let onDemandUsedCents = spendLimit?.individualUsed
            ?? spendLimit?.totalSpend
            ?? max(0, (usage.planUsage?.totalSpend ?? 0) - budgetCents)

        if onDemandUsedCents > 0 {
            let indLimit = spendLimit?.individualLimit
            let limitDollars = indLimit.flatMap { $0 > 0 ? Double($0) / 100.0 : nil }
            snapshot.onDemandSpend = CreditInfo(
                amount: Double(onDemandUsedCents) / 100.0,
                limit: limitDollars,
                currency: "USD"
            )
        }

        // Monthly cost = included spend + on-demand spend (already in USD).
        let included = snapshot.spentAmount?.amount ?? 0
        let onDemand = snapshot.onDemandSpend?.amount ?? 0
        if included > 0 || onDemand > 0 {
            snapshot.monthlyEstimatedCost = included + onDemand
        }

        return snapshot
    }
}
