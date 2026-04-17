import Foundation

/// A single usage window (e.g., 5h session or 7d weekly).
struct UsageWindow: Sendable {
    /// Percentage used (0–100).
    let percentUsed: Double
    /// When this window resets.
    let resetsAt: Date?

    /// Percentage remaining (100 - percentUsed).
    var percentRemaining: Double { max(0, 100 - percentUsed) }

    /// Formatted time until reset.
    var resetCountdown: String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSinceNow
        guard interval > 0 else { return "Resetting…" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

/// Per-model quota info (used by Antigravity).
struct ModelQuota: Identifiable, Sendable {
    let id = UUID()
    /// Display label, e.g., "Claude Sonnet 4.5"
    let label: String
    /// Remaining fraction (0.0 = depleted, 1.0 = full)
    let remainingFraction: Double
    /// When this model's quota resets.
    let resetsAt: Date?

    /// Percentage used (0–100).
    var percentUsed: Double { (1.0 - remainingFraction) * 100 }
}

/// Credit / billing info.
struct CreditInfo: Sendable {
    /// Amount spent or remaining (in dollars).
    let amount: Double
    /// Budget limit (in dollars), nil if unlimited.
    let limit: Double?
    /// Currency code.
    let currency: String

    /// Formatted display: "$5.39" or "$232.22 / $400.00"
    var formatted: String {
        if let limit {
            return String(format: "$%.2f / $%.2f", amount, limit)
        }
        return String(format: "$%.2f", amount)
    }
}

/// Unified usage snapshot from any provider.
struct UsageSnapshot: Sendable {
    // MARK: - Rolling windows (Claude, Codex)
    var sessionUsage: UsageWindow?
    var weeklyUsage: UsageWindow?

    // MARK: - Billing cycle (Cursor)
    var totalUsagePercent: Double?
    var billingCycleEnd: Date?
    var spentAmount: CreditInfo?

    // MARK: - Per-model quotas (Antigravity)
    var modelQuotas: [ModelQuota] = []

    // MARK: - Common
    var planName: String?
    var email: String?
    var credits: CreditInfo?
    var onDemandSpend: CreditInfo?
    var lastRefreshed: Date = .now

    /// Estimated spend (USD) so far this calendar month.
    /// - Claude/Codex: computed from local JSONL logs × API pricing.
    /// - Cursor: sum of included spend + on-demand spend from the billing API.
    /// - nil when the provider doesn't compute one.
    var monthlyEstimatedCost: Double?

    // MARK: - Computed

    /// On-demand usage percentage (0–100), nil if no limit set.
    var onDemandUsagePercent: Double? {
        guard let od = onDemandSpend, let limit = od.limit, limit > 0 else { return nil }
        return od.amount / limit * 100
    }

    /// The worst-case (highest) usage percentage across all windows.
    var worstUsagePercent: Double {
        let candidates: [Double?] = [
            sessionUsage?.percentUsed,
            weeklyUsage?.percentUsed,
            totalUsagePercent,
            onDemandUsagePercent,
            modelQuotas.isEmpty ? nil : modelQuotas.map(\.percentUsed).max()
        ]
        return candidates.compactMap { $0 }.max() ?? 0
    }
}
