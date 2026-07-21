#if DEBUG
import Foundation
import Observation

@Observable
@MainActor
final class PreviewUsageProvider: UsageProvider {
    let kind: ProviderKind
    let isAvailable = true
    var isEnabled = true
    var snapshot: UsageSnapshot?
    var error: String?
    var isLoading = false

    init(kind: ProviderKind, snapshot: UsageSnapshot?, error: String? = nil) {
        self.kind = kind
        self.snapshot = snapshot
        self.error = error
    }

    func refresh() async {}
}

@MainActor
enum PreviewFixtures {
    static func manager(providerCount: Int = 2) -> UsageManager {
        let providers = Array(allProviders.prefix(max(1, min(providerCount, allProviders.count))))
        let manager = UsageManager(providers: providers, startsLedger: false)
        manager.providers.forEach { $0.isEnabled = true }
        return manager
    }

    static var allProviders: [any UsageProvider] {
        let now = Date.now

        var claude = UsageSnapshot()
        claude.planName = "Max"
        claude.sessionUsage = UsageWindow(
            percentUsed: 42,
            resetsAt: now.addingTimeInterval(2.3 * 3600),
            windowDuration: 5 * 3600
        )
        claude.weeklyUsage = UsageWindow(
            percentUsed: 68,
            resetsAt: now.addingTimeInterval(3.8 * 86_400),
            windowDuration: 7 * 86_400
        )
        claude.monthlyEstimatedCost = 112.40
        claude.lastRefreshed = now.addingTimeInterval(-32)

        var codex = UsageSnapshot()
        codex.planName = "Plus"
        codex.sessionUsage = UsageWindow(
            percentUsed: 33,
            resetsAt: now.addingTimeInterval(54 * 60),
            windowDuration: 5 * 3600
        )
        codex.weeklyUsage = UsageWindow(
            percentUsed: 24,
            resetsAt: now.addingTimeInterval(5.4 * 86_400),
            windowDuration: 7 * 86_400
        )
        codex.resetCredits = ResetCreditInventory(
            reportedAvailableCount: 3,
            availableCredits: [
                ResetCredit(id: "one", grantedAt: nil, expiresAt: now.addingTimeInterval(4 * 86_400)),
                ResetCredit(id: "two", grantedAt: nil, expiresAt: now.addingTimeInterval(11 * 86_400)),
                ResetCredit(id: "three", grantedAt: nil, expiresAt: now.addingTimeInterval(18 * 86_400)),
            ],
            fetchedAt: now
        )
        codex.monthlyEstimatedCost = 43.62
        codex.lastRefreshed = now.addingTimeInterval(-32)

        var cursor = UsageSnapshot()
        cursor.planName = "Pro"
        cursor.totalUsagePercent = 77
        cursor.billingCycleEnd = now.addingTimeInterval(12 * 86_400)
        cursor.spentAmount = CreditInfo(amount: 16.40, limit: 20, currency: "USD")
        cursor.onDemandSpend = CreditInfo(amount: 7.20, limit: 50, currency: "USD")
        cursor.monthlyEstimatedCost = 23.60

        var antigravity = UsageSnapshot()
        antigravity.modelQuotas = [
            ModelQuota(label: "Claude Sonnet", remainingFraction: 0.44, resetsAt: now.addingTimeInterval(6 * 3600)),
            ModelQuota(label: "Gemini Pro", remainingFraction: 0.71, resetsAt: now.addingTimeInterval(8 * 3600)),
        ]

        return [
            PreviewUsageProvider(kind: .claude, snapshot: claude),
            PreviewUsageProvider(kind: .codex, snapshot: codex),
            PreviewUsageProvider(kind: .cursor, snapshot: cursor),
            PreviewUsageProvider(kind: .antigravity, snapshot: antigravity),
        ]
    }
}
#endif
