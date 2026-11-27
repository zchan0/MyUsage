#if DEBUG
import Foundation
import Observation

@Observable
@MainActor
final class PreviewUsageProvider: BuiltinUsageProvider {
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
    static func manager(providerCount: Int = 2, gateway: GatewayPreviewFixtures.Shape? = nil, gatewayCount: Int = 1) -> UsageManager {
        var providers = Array(allProviders.prefix(max(1, min(providerCount, allProviders.count))))
        if let gateway {
            for index in 0..<max(1, min(gatewayCount, 50)) {
                providers.append(GatewayPreviewFixtures.provider(gateway, index: index))
            }
        }
        let defaults = UserDefaults(suiteName: "MyUsage.preview.\(UUID().uuidString)")!
        defaults.set(false, forKey: "notificationsEnabled")
        let manager = UsageManager(providers: providers, backgroundServicesEnabled: false, defaults: defaults)
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
        claude.resetCredits = ResetCreditInventory(
            reportedAvailableCount: 1,
            availableCredits: [
                ResetCredit(
                    id: "opus-launch",
                    label: "Opus 5.5 launch · 5h & 7d reset",
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(17 * 86_400)
                ),
            ],
            fetchedAt: now
        )
        claude.localUsage = localUsage(for: .claude, now: now)
        claude.lastRefreshed = now.addingTimeInterval(-32)

        var codex = UsageSnapshot()
        codex.planName = "Plus"
        codex.email = "alex@example.com"
        codex.sessionUsage = UsageWindow(
            percentUsed: 12,
            resetsAt: now.addingTimeInterval(2.75 * 3_600),
            windowDuration: 5 * 3600
        )
        codex.weeklyUsage = UsageWindow(
            percentUsed: 5,
            resetsAt: now.addingTimeInterval(4.33 * 86_400),
            windowDuration: 7 * 86_400
        )
        codex.resetCredits = ResetCreditInventory(
            reportedAvailableCount: 3,
            availableCredits: [
                ResetCredit(id: "one", grantedAt: nil, expiresAt: now.addingTimeInterval(3 * 86_400)),
                ResetCredit(id: "two", grantedAt: nil, expiresAt: now.addingTimeInterval(11 * 86_400)),
                ResetCredit(id: "three", grantedAt: nil, expiresAt: now.addingTimeInterval(18 * 86_400)),
            ],
            fetchedAt: now
        )
        codex.localUsage = localUsage(for: .codex, now: now)
        codex.lastRefreshed = now.addingTimeInterval(-32)

        var cursor = UsageSnapshot()
        cursor.planName = "Pro"
        cursor.email = "alex@example.com"
        cursor.totalUsagePercent = 82
        cursor.billingCycleStart = now.addingTimeInterval(-18 * 86_400)
        cursor.billingCycleEnd = now.addingTimeInterval(12 * 86_400)
        cursor.spentAmount = CreditInfo(amount: 16.40, limit: 20, currency: "USD")
        cursor.onDemandSpend = CreditInfo(amount: 7.20, limit: 50, currency: "USD")
        cursor.lastRefreshed = now.addingTimeInterval(-32)

        var antigravity = UsageSnapshot()
        antigravity.planName = "Google AI Ultra"
        antigravity.email = "alex@example.com"
        antigravity.modelQuotas = [
            ModelQuota(
                label: "Gemini Models · 7d",
                remainingFraction: 0.99,
                resetsAt: now.addingTimeInterval(6 * 86_400),
                groupName: "Gemini Models",
                windowLabel: "7d",
                windowDuration: 7 * 86_400,
                bucketId: "gemini-weekly"
            ),
            ModelQuota(
                label: "Gemini Models · 5h",
                remainingFraction: 0.98,
                resetsAt: now.addingTimeInterval(4 * 3_600 + 50 * 60),
                groupName: "Gemini Models",
                windowLabel: "5h",
                windowDuration: 5 * 3_600,
                bucketId: "gemini-5h"
            ),
            ModelQuota(
                label: "Claude & GPT Models · 7d",
                remainingFraction: 0.97,
                resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3_600),
                groupName: "Claude & GPT Models",
                windowLabel: "7d",
                windowDuration: 7 * 86_400,
                bucketId: "3p-weekly"
            ),
            ModelQuota(
                label: "Claude & GPT Models · 5h",
                remainingFraction: 1.0,
                resetsAt: now.addingTimeInterval(4 * 3_600 + 59 * 60),
                groupName: "Claude & GPT Models",
                windowLabel: "5h",
                windowDuration: 5 * 3_600,
                bucketId: "3p-5h"
            ),
        ]
        antigravity.lastRefreshed = now.addingTimeInterval(-32)

        return [
            PreviewUsageProvider(kind: .claude, snapshot: claude),
            PreviewUsageProvider(kind: .codex, snapshot: codex),
            PreviewUsageProvider(kind: .antigravity, snapshot: antigravity),
            PreviewUsageProvider(kind: .cursor, snapshot: cursor),
        ]
    }

    static func localUsage(for kind: ProviderKind, now: Date = .now) -> LocalUsageReport {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let isClaude = kind == .claude
        let activity = [0, 0, 2, 0, 8, 0, 0, 3, 0, 0, 16, 0, 9, 3, 0, 0, 1, 0, 22, 11, 0, 5, 7, 0, 14, 4, 17, 5, 9]
        var daily: [Date: [String: LocalUsageReport.ModelMetrics]] = [:]
        for (index, amount) in activity.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: index - 29, to: today) else { continue }
            if amount > 0 {
                daily[day] = sampleModels(isClaude: isClaude, scale: amount, seed: index)
            } else if isClaude && index == 23 {
                daily[day] = ["Opus 5.5": .init(reportedCostUSD: 1.18)]
            }
        }

        let hours = [1: 1, 8: 2, 9: 5, 11: 3, 15: 1]
        let hourly = Dictionary(uniqueKeysWithValues: hours.map { hour, amount in
            (hour, sampleModels(isClaude: isClaude, scale: amount, seed: hour, hourly: true))
        })
        daily[today] = hourly.values.reduce(into: [:]) { total, models in
            for (name, metrics) in models { total[name, default: .init()] += metrics }
        }
        return LocalUsageReport.build(daily: daily, hourlyToday: hourly, now: now, calendar: calendar)
    }

    private static func sampleModels(
        isClaude: Bool, scale: Int, seed: Int, hourly: Bool = false
    ) -> [String: LocalUsageReport.ModelMetrics] {
        let activity = scale * (hourly ? 120_000 : 1_500_000)
        if isClaude {
            var models: [String: LocalUsageReport.ModelMetrics] = [
                "Opus 5.5": .init(tokens: TokenUsage(
                    input: activity / 50, output: activity / 90, cacheWrite: activity / 70, cacheRead: activity
                ), reportedCostUSD: hourly ? 0 : Double(scale) * 0.41),
            ]
            if seed.isMultiple(of: 3) {
                models["Fable 5.2"] = .init(tokens: TokenUsage(
                    input: activity / 40, output: activity / 85, cacheRead: activity / 3
                ), reportedCostUSD: hourly ? 0 : Double(scale) * 0.23)
            }
            if !seed.isMultiple(of: 2) {
                models["Haiku 5.5"] = .init(tokens: TokenUsage(
                    input: activity / 150, output: activity / 270, cacheRead: activity / 28
                ), reportedCostUSD: hourly ? 0 : Double(scale) * 0.003)
            }
            return models
        }

        let sol = TokenUsage(input: activity / 13, output: activity / 42, cachedInput: activity)
        let other = TokenUsage(input: activity / 40, output: activity / 110, cachedInput: activity / 4)
        return seed.isMultiple(of: 2)
            ? ["GPT-6.1 Sol": .init(tokens: sol), "GPT-6.2 Sol": .init(tokens: other)]
            : ["GPT-6.2 Sol": .init(tokens: sol)]
    }
}
#endif
