import Foundation

struct GatewayScope: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case user, key }
    let kind: Kind
    let id: String
    var label: String { kind == .user ? "My account" : "This API key" }
}

struct GatewayConnection: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var vendor: GatewayVendor = .litellm
    var baseURL: URL
    var credentialReference: String = UUID().uuidString
    var scope: GatewayScope?
    var explicitUserID: String?
    var providerID: ProviderID { .gateway(id) }
}

enum GatewayIssue: Error, Equatable, Sendable {
    case invalidConfiguration, missingCredential, identityUnknown, authentication, forbidden
    case keychainAccessRequired, keychainReadFailed(status: Int32), invalidStoredCredential
    case endpointUnavailable, invalidResponse, network, rateLimited(until: Date?)
    case unsupported, notChecked, cancelled

    var message: String {
        switch self {
        case .invalidConfiguration: "Enter a valid HTTPS gateway address (HTTP is allowed only on localhost)."
        case .missingCredential: "API key unavailable. Update it in Settings."
        case .keychainAccessRequired: "Saved API key needs Keychain access. Click Refresh, or Check Usage Access in Settings, to authorize it."
        case .keychainReadFailed: "Could not read the saved API key from Keychain. Unlock your Keychain and try again."
        case .invalidStoredCredential: "The saved API key could not be decoded. Update it in Settings."
        case .identityUnknown: "Could not identify your user. Enter your LiteLLM user ID to check account usage."
        case .authentication: "The gateway rejected this API key."
        case .forbidden: "This API key cannot read this data."
        case .endpointUnavailable: "Usage endpoint unavailable. Check the address and LiteLLM version."
        case .invalidResponse: "The gateway returned an incompatible usage response."
        case .network: "Could not reach the gateway. Try again."
        case .rateLimited: "The gateway is rate limiting requests. Try again later."
        case .unsupported: "Not available for this usage scope."
        case .notChecked: "Not checked yet."
        case .cancelled: "Check cancelled."
        }
    }
}

struct GatewayBlock<Value: Sendable>: Sendable {
    var value: Value?
    var updatedAt: Date?
    var issue: GatewayIssue?
    init(value: Value? = nil, updatedAt: Date? = nil, issue: GatewayIssue? = nil) {
        self.value = value; self.updatedAt = updatedAt; self.issue = issue
    }
    /// A failed refresh retains only data from the same connection/scope.
    mutating func merge(_ incoming: Self) {
        if incoming.value != nil { self = incoming }
        else { issue = incoming.issue }
    }
}

enum GatewayBudget: Equatable, Sendable {
    case finite(Decimal), unbounded, unspecified
}

struct GatewaySummary: Sendable, Equatable {
    let scope: GatewayScope
    let spend: Decimal?
    let budget: GatewayBudget
    let currency: String
    let budgetDuration: String?
    let resetsAt: Date?
    var percentUsed: Double? {
        guard case .finite(let limit) = budget, limit > 0, let spend else { return nil }
        let percent = NSDecimalNumber(decimal: spend / limit * 100).doubleValue
        return percent.isFinite ? percent : nil
    }
    var remaining: Decimal? {
        guard case .finite(let limit) = budget, let spend else { return nil }
        return max(0, limit - spend)
    }
    var periodLabel: String { budgetDuration == nil ? "Reported spend" : "Current budget period" }
}

struct GatewayMetrics: Sendable, Equatable {
    var cost: Decimal?
    var totalTokens: Int64?
    var inputTokens: Int64?
    var outputTokens: Int64?
    var cacheReadTokens: Int64?
    var cacheWriteTokens: Int64?
    var requests: Int64?

    /// Missing fields remain unknown across an aggregate, not implicitly zero.
    static func sum(_ values: [Self]) -> Self {
        func counts(_ key: KeyPath<Self, Int64?>) -> Int64? {
            let counts = values.compactMap { $0[keyPath: key] }
            guard !counts.isEmpty, counts.count == values.count else { return nil }
            var total: Int64 = 0
            for count in counts {
                let next = total.addingReportingOverflow(count)
                guard !next.overflow else { return nil }; total = next.partialValue
            }
            return total
        }
        let costs = values.compactMap(\.cost)
        return Self(cost: costs.isEmpty || costs.count != values.count ? nil : costs.reduce(0, +),
                    totalTokens: counts(\.totalTokens), inputTokens: counts(\.inputTokens),
                    outputTokens: counts(\.outputTokens), cacheReadTokens: counts(\.cacheReadTokens),
                    cacheWriteTokens: counts(\.cacheWriteTokens), requests: counts(\.requests))
    }
}

struct GatewayHistory: Sendable {
    struct Day: Identifiable, Sendable {
        let date: String
        let metrics: GatewayMetrics
        let models: [String: GatewayMetrics]
        var modelsReported: Bool = true
        var id: String { date }
    }
    let scope: GatewayScope
    let startDate: String
    let endDate: String
    let days: [Day]
    let complete: Bool
    var hasCompleteModelBreakdown: Bool { complete && days.allSatisfy(\.modelsReported) }
    var totals: GatewayMetrics { .sum(days.map(\.metrics)) }
    var models: [(name: String, metrics: GatewayMetrics)] {
        var grouped: [String: [GatewayMetrics]] = [:]
        for day in days { for (model, metrics) in day.models { grouped[model, default: []].append(metrics) } }
        return grouped.map { (name: $0.key, metrics: GatewayMetrics.sum($0.value)) }
            // Hide zero-cost model rows without dropping their tokens from the totals.
            .filter { $0.metrics.cost != 0 }
            .sorted {
                if $0.metrics.cost != $1.metrics.cost { return ($0.metrics.cost ?? -1) > ($1.metrics.cost ?? -1) }
                if $0.metrics.totalTokens != $1.metrics.totalTokens { return ($0.metrics.totalTokens ?? -1) > ($1.metrics.totalTokens ?? -1) }
                return $0.name < $1.name
            }
    }
}

struct GatewaySnapshot: Sendable {
    var summary = GatewayBlock<GatewaySummary>(issue: .notChecked)
    var history = GatewayBlock<GatewayHistory>(issue: .notChecked)

    /// One conservative timestamp for all data currently displayed in this detail.
    /// A failed refresh never makes a retained value look newly fetched.
    var displayUpdatedAt: Date? {
        [summary.value == nil ? nil : summary.updatedAt,
         history.value == nil ? nil : history.updatedAt].compactMap { $0 }.min()
    }
    var hasDisplayIssue: Bool {
        (summary.value != nil && summary.issue != nil) || (history.value != nil && history.issue != nil)
    }
}

struct GatewayScopeCheck: Sendable {
    let scope: GatewayScope
    var summary: GatewayBlock<GatewaySummary>
    var history: GatewayBlock<GatewayHistory>
    var isUsable: Bool { summary.value != nil }
}

struct GatewayConnectionCheck: Sendable {
    let checkedAt: Date
    var scopes: [GatewayScopeCheck]
    var issues: [GatewayIssue]
    var usableScopes: [GatewayScopeCheck] { scopes.filter(\.isUsable) }
    var preferredScope: GatewayScope? {
        usableScopes.first { $0.scope.kind == .user }?.scope ?? usableScopes.first?.scope
    }
}

enum GatewayFormatting {
    static func money(_ value: Decimal?, currency: String = "USD") -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(currency)"
    }
    static func modelCost(_ value: Decimal) -> String {
        let cent = Decimal(string: "0.01")!
        return value > 0 && value < cent ? "<" + money(cent) : money(value)
    }
    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

/// Dates for the normalized gateway history use UTC, independent of the vendor adapter.
enum GatewayCalendar {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func parseDay(_ day: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        guard day.count == 10, let date = formatter.date(from: day), self.day(date) == day else { return nil }
        return date
    }
}
