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
        let store = try! LedgerStore(path: LedgerStore.inMemoryPath)
        seedLedger(store)
        let ledger = LedgerSync(store: store, syncRoot: PreviewSyncRoot())
        ledger.reloadForPreview()
        let manager = UsageManager(ledger: ledger, providers: providers, startsLedger: false)
        manager.providers.forEach { $0.isEnabled = true }
        return manager
    }

    static var allProviders: [any UsageProvider] {
        let now = Date.now

        var claude = UsageSnapshot()
        claude.planName = "Max"
        claude.email = "alex@example.com"
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
        claude.weeklyByModel = [
            WeeklyModelUsage(
                label: "Fable",
                percent: 37,
                resetsAt: now.addingTimeInterval(3.8 * 86_400)
            ),
            WeeklyModelUsage(
                label: "Daily Routines",
                percent: 12,
                resetsAt: now.addingTimeInterval(3.8 * 86_400),
                scope: .product
            ),
        ]
        claude.onDemandSpend = CreditInfo(amount: 2.32, limit: 100, currency: "USD")
        claude.monthlyEstimatedCost = 112.40
        claude.lastRefreshed = now.addingTimeInterval(-32)

        var codex = UsageSnapshot()
        codex.planName = "Plus"
        codex.email = "alex@example.com"
        codex.sessionUsage = UsageWindow(
            percentUsed: 33,
            resetsAt: now.addingTimeInterval(54 * 60),
            windowDuration: 5 * 3600
        )
        codex.weeklyUsage = UsageWindow(
            percentUsed: 24,
            resetsAt: now.addingTimeInterval(5.2 * 86_400),
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
        cursor.email = "alex@example.com"
        cursor.totalUsagePercent = 77
        cursor.billingCycleEnd = now.addingTimeInterval(12 * 86_400)
        cursor.spentAmount = CreditInfo(amount: 16.40, limit: 20, currency: "USD")
        cursor.onDemandSpend = CreditInfo(amount: 7.20, limit: 50, currency: "USD")
        cursor.monthlyEstimatedCost = 23.60
        cursor.lastRefreshed = now.addingTimeInterval(-32)

        var antigravity = UsageSnapshot()
        antigravity.planName = "Google account"
        antigravity.email = "alex@example.com"
        antigravity.modelQuotas = [
            ModelQuota(label: "Claude Sonnet", remainingFraction: 0.44, resetsAt: now.addingTimeInterval(6 * 3600)),
            ModelQuota(label: "Gemini Pro", remainingFraction: 0.71, resetsAt: now.addingTimeInterval(8 * 3600)),
        ]
        antigravity.lastRefreshed = now.addingTimeInterval(-32)

        return [
            PreviewUsageProvider(kind: .claude, snapshot: claude),
            PreviewUsageProvider(kind: .codex, snapshot: codex),
            PreviewUsageProvider(kind: .cursor, snapshot: cursor),
            PreviewUsageProvider(kind: .antigravity, snapshot: antigravity),
        ]
    }

    private static func seedLedger(_ store: LedgerStore) {
        let entries = (0..<30).flatMap { offset -> [LedgerEntry] in
            let date = Date.now.addingTimeInterval(Double(-offset) * 86_400)
            let day = LedgerCalendar.dayKey(for: date)
            let claudeOpus = 1.1 + abs(sin(Double(offset) * 1.27)) * 3.0
            let claudeSonnet = 0.7 + abs(cos(Double(offset) * 0.83)) * 1.8
            let codexCost = 0.8 + abs(sin(Double(offset) * 1.08 + 0.7)) * 3.5
            let codexSol = codexCost * 0.78
            let codexStandard = codexCost - codexSol
            return [
                LedgerEntry(
                    deviceId: "preview-this-mac",
                    accountId: "alex@example.com",
                    provider: .claude,
                    day: day,
                    costUSD: claudeOpus + claudeSonnet,
                    costByModel: ["Opus": claudeOpus, "Sonnet": claudeSonnet],
                    tokenUsage: TokenUsage(
                        input: 410_000 + offset * 900,
                        output: 102_000 + offset * 300,
                        cacheRead: 6_750_000 + offset * 1_100
                    )
                ),
                LedgerEntry(
                    deviceId: "preview-this-mac",
                    accountId: "alex@example.com",
                    provider: .codex,
                    day: day,
                    costUSD: codexCost,
                    costByModel: [
                        "GPT-5.6 Sol": codexSol,
                        "GPT-5.5": codexStandard,
                    ],
                    tokenUsage: TokenUsage(
                        input: 620_000 + offset * 700,
                        output: 160_000 + offset * 240,
                        cachedInput: 1_580_000 + offset * 800
                    )
                ),
            ]
        }
        _ = try? store.upsert(entries)
    }
}

private struct PreviewSyncRoot: SyncRoot {
    let rootURL: URL? = nil
    let isAvailable = false
}
#endif
