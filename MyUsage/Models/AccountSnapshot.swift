import Foundation

/// Serializable subset of `UsageSnapshot` cached per (provider, account)
/// so the popover can render an inactive account's last-known state
/// without having credentials to call the provider's API.
///
/// We deliberately persist the *projection* (already-derived percentages,
/// reset times, cost) rather than raw API responses — provider response
/// shapes change, but the popover-facing fields are stable.
struct AccountSnapshot: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var v: Int = AccountSnapshot.currentVersion

    /// Wall-clock time when the underlying refresh succeeded for this
    /// account. Drives the popover's stale banner ("Snapshot from May 8").
    var capturedAt: Date

    var planName: String?

    // Rolling windows
    var sessionPercent: Double?
    var sessionResetsAt: Date?
    var sessionWindowDuration: TimeInterval?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    var weeklyWindowDuration: TimeInterval?

    var weeklyByModel: [WeeklyModelEntry] = []
    struct WeeklyModelEntry: Codable, Sendable, Equatable {
        let label: String
        let percent: Double
    }

    // Cursor-style billing cycle
    var totalUsagePercent: Double?
    var billingCycleEnd: Date?
    var spentAmount: Double?
    var spentLimit: Double?
    var spentCurrency: String?

    // Generic credit pools
    var creditsAmount: Double?
    var creditsLimit: Double?
    var creditsCurrency: String?
    var onDemandAmount: Double?
    var onDemandLimit: Double?
    var onDemandCurrency: String?

    var monthlyEstimatedCost: Double?

    init(from snapshot: UsageSnapshot, capturedAt: Date = .now) {
        self.capturedAt = capturedAt
        self.planName = snapshot.planName
        self.sessionPercent = snapshot.sessionUsage?.percentUsed
        self.sessionResetsAt = snapshot.sessionUsage?.resetsAt
        self.sessionWindowDuration = snapshot.sessionUsage?.windowDuration
        self.weeklyPercent = snapshot.weeklyUsage?.percentUsed
        self.weeklyResetsAt = snapshot.weeklyUsage?.resetsAt
        self.weeklyWindowDuration = snapshot.weeklyUsage?.windowDuration
        self.weeklyByModel = snapshot.weeklyByModel.map {
            WeeklyModelEntry(label: $0.label, percent: $0.percent)
        }
        self.totalUsagePercent = snapshot.totalUsagePercent
        self.billingCycleEnd = snapshot.billingCycleEnd
        self.spentAmount = snapshot.spentAmount?.amount
        self.spentLimit = snapshot.spentAmount?.limit
        self.spentCurrency = snapshot.spentAmount?.currency
        self.creditsAmount = snapshot.credits?.amount
        self.creditsLimit = snapshot.credits?.limit
        self.creditsCurrency = snapshot.credits?.currency
        self.onDemandAmount = snapshot.onDemandSpend?.amount
        self.onDemandLimit = snapshot.onDemandSpend?.limit
        self.onDemandCurrency = snapshot.onDemandSpend?.currency
        self.monthlyEstimatedCost = snapshot.monthlyEstimatedCost
    }

    /// Reconstitute as a `UsageSnapshot` so the same `ProviderCard`
    /// SwiftUI components can render an inactive account's cached state.
    /// `lastRefreshed` is set to `capturedAt`, so the card surfaces the
    /// real age of the snapshot rather than pretending it's fresh.
    var asUsageSnapshot: UsageSnapshot {
        var s = UsageSnapshot()
        s.planName = planName
        s.lastRefreshed = capturedAt
        if let pct = sessionPercent {
            s.sessionUsage = UsageWindow(
                percentUsed: pct,
                resetsAt: sessionResetsAt,
                windowDuration: sessionWindowDuration
            )
        }
        if let pct = weeklyPercent {
            s.weeklyUsage = UsageWindow(
                percentUsed: pct,
                resetsAt: weeklyResetsAt,
                windowDuration: weeklyWindowDuration
            )
        }
        s.weeklyByModel = weeklyByModel.map {
            WeeklyModelUsage(label: $0.label, percent: $0.percent)
        }
        s.totalUsagePercent = totalUsagePercent
        s.billingCycleEnd = billingCycleEnd
        if let amt = spentAmount {
            s.spentAmount = CreditInfo(
                amount: amt, limit: spentLimit, currency: spentCurrency ?? "USD"
            )
        }
        if let amt = creditsAmount {
            s.credits = CreditInfo(
                amount: amt, limit: creditsLimit, currency: creditsCurrency ?? "USD"
            )
        }
        if let amt = onDemandAmount {
            s.onDemandSpend = CreditInfo(
                amount: amt, limit: onDemandLimit, currency: onDemandCurrency ?? "USD"
            )
        }
        s.monthlyEstimatedCost = monthlyEstimatedCost
        return s
    }
}
