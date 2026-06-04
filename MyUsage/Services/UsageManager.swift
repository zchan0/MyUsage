import Foundation
import SwiftUI

/// Orchestrates all providers: auto-detection, refresh timer, and combined state.
@Observable
@MainActor
final class UsageManager {

    // MARK: - Published state

    private(set) var providers: [any UsageProvider] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?

    /// Multi-device usage ledger — see `specs/12a-sync-folder.md`.
    /// Lives on the manager so every provider can read/write through a single
    /// instance and the UI can observe aggregate state.
    let ledger: LedgerSync

    // MARK: - Settings

    var refreshInterval: RefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
            restartTimer()
        }
    }

    /// Which provider to show usage for in the menu bar. Empty string = none.
    var iconTrackProvider: String {
        didSet { UserDefaults.standard.set(iconTrackProvider, forKey: "iconTrackProvider") }
    }

    /// Custom display order for providers.
    var providerOrder: [String] {
        didSet { UserDefaults.standard.set(providerOrder, forKey: "providerOrder") }
    }

    /// Whether provider cards display the estimated monthly spend row.
    var showEstimatedCost: Bool {
        didSet { UserDefaults.standard.set(showEstimatedCost, forKey: "showEstimatedCost") }
    }

    /// Whether Claude's per-model bars (Opus / Sonnet / Design / …)
    /// render under the Weekly bar. Each row is one model's separate
    /// weekly cap — 0% means the cap exists on this plan but is unused
    /// this week, not "no data". Plans where Anthropic doesn't return
    /// per-bucket fields at all (Max 5x and most Pro tiers, where
    /// everything pools into the unified weekly cap) show nothing
    /// regardless of this toggle.
    var showPerModelBars: Bool {
        didSet { UserDefaults.standard.set(showPerModelBars, forKey: "showPerModelBars") }
    }

    /// Master toggle for limit-pressure notifications.
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    /// Percent threshold at which a "warn"-level notification fires the
    /// first time a limit crosses up. Default 80 — intentionally above the
    /// visual `LimitSafety.warnThreshold` (75) so the bar turns amber
    /// before users get pinged.
    var notifyWarnThreshold: Double {
        didSet { UserDefaults.standard.set(notifyWarnThreshold, forKey: "notifyWarnThreshold") }
    }

    /// Percent threshold for the "crit" notification (default 95).
    var notifyCritThreshold: Double {
        didSet { UserDefaults.standard.set(notifyCritThreshold, forKey: "notifyCritThreshold") }
    }


    // MARK: - Private

    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    init(
        ledger: LedgerSync = LedgerSync()
    ) {
        let savedInterval = UserDefaults.standard.string(forKey: "refreshInterval")
        self.refreshInterval = RefreshInterval(rawValue: savedInterval ?? "") ?? .fiveMinutes
        let storedOrder = UserDefaults.standard.stringArray(forKey: "providerOrder")
        self.providerOrder = storedOrder ?? ProviderKind.allCases.map(\.rawValue)
        self.iconTrackProvider = UserDefaults.standard.string(forKey: "iconTrackProvider")
            ?? storedOrder?.first
            ?? ProviderKind.allCases.first?.rawValue
            ?? ""
        self.showEstimatedCost = UserDefaults.standard.object(forKey: "showEstimatedCost") as? Bool ?? true
        self.showPerModelBars = UserDefaults.standard.object(forKey: "showPerModelBars") as? Bool ?? true
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.notifyWarnThreshold = (UserDefaults.standard.object(forKey: "notifyWarnThreshold") as? Double) ?? 80
        self.notifyCritThreshold = (UserDefaults.standard.object(forKey: "notifyCritThreshold") as? Double) ?? 95
        self.ledger = ledger

        register(ClaudeProvider(ledger: ledger))
        register(CodexProvider(ledger: ledger))
        register(CursorProvider())
        register(AntigravityProvider())

        // One-time cleanup: the multi-account registry was removed.
        // Its persisted `accounts.json` is now orphaned — delete it
        // best-effort so we don't leave dead state behind. Harmless if
        // already gone. The ledger (which still carries account_id rows
        // for spec 13 cross-device sync) is untouched.
        Self.removeOrphanedAccountStore()

        Task { await ledger.start() }
    }

    /// Deletes the orphaned `~/Library/Application Support/MyUsage/accounts.json`
    /// left behind by the removed multi-account feature.
    private static func removeOrphanedAccountStore() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let url = support
            .appendingPathComponent("MyUsage", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Public API

    /// Refresh all enabled providers.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshed = .now
        }

        // Refresh providers concurrently so a slow one (e.g. Claude
        // waiting on the network) doesn't hold up the others. Each
        // provider is @MainActor-isolated, but its `refresh()` suspends at
        // every network `await`, freeing the main actor for the others —
        // so the HTTP round-trips genuinely overlap. Previously this was a
        // serial `for await` loop, which made later providers (Codex,
        // Cursor) visibly lag behind the first to finish.
        // Kick each provider's refresh off as its own MainActor Task, then
        // await them all. The providers are @MainActor-isolated, but each
        // refresh() suspends at every network `await`, freeing the main
        // actor for the others — so the HTTP round-trips overlap instead of
        // running strictly one-after-another (which made Codex/Cursor
        // visibly lag behind the first provider). Capturing `self`
        // (a @MainActor class is Sendable) + an index keeps the closures
        // free of non-Sendable captures.
        let enabledIndices = providers.indices.filter { providers[$0].isEnabled }
        let tasks: [Task<Void, Never>] = enabledIndices.map { index in
            Task { @MainActor in await self.providers[index].refresh() }
        }
        for task in tasks {
            await task.value
        }

        // Evaluate limit pressure and dispatch notifications for any
        // tier upgrades observed since the previous refresh. Idempotent
        // by ID, so no duplicates within the same window.
        let observations = LimitNotifier.observations(from: providers)
        await LimitNotifier.shared.evaluate(
            observations: observations,
            warnThreshold: notifyWarnThreshold,
            critThreshold: notifyCritThreshold,
            enabled: notificationsEnabled
        )
    }

    /// Register a provider, restoring persisted enabled state.
    func register(_ provider: any UsageProvider) {
        let key = "provider.\(provider.kind.rawValue).enabled"
        if UserDefaults.standard.object(forKey: key) != nil {
            provider.isEnabled = UserDefaults.standard.bool(forKey: key)
        }
        providers.append(provider)
    }

    /// Providers sorted by user-defined order.
    var orderedProviders: [any UsageProvider] {
        providers.sorted { a, b in
            let ai = providerOrder.firstIndex(of: a.kind.rawValue) ?? Int.max
            let bi = providerOrder.firstIndex(of: b.kind.rawValue) ?? Int.max
            return ai < bi
        }
    }

    /// Move a provider from one position to another.
    func moveProvider(from source: IndexSet, to destination: Int) {
        providerOrder.move(fromOffsets: source, toOffset: destination)
    }

    /// The worst usage percent across all enabled providers.
    var worstUsagePercent: Double {
        providers
            .filter { $0.isEnabled }
            .compactMap { $0.snapshot?.worstUsagePercent }
            .max() ?? 0
    }

    /// Short text for the menu bar label, based on tracked provider.
    var menuBarDisplayText: String? {
        guard !iconTrackProvider.isEmpty,
              let provider = providers.first(where: { $0.kind.rawValue == iconTrackProvider }),
              let snapshot = provider.snapshot else { return nil }

        switch provider.kind {
        case .cursor:
            if let od = snapshot.onDemandSpend, od.amount > 0 {
                return String(format: "$%.0f", od.amount)
            }
            if let spent = snapshot.spentAmount {
                return String(format: "$%.0f", spent.amount)
            }
            return nil
        case .claude, .codex, .antigravity:
            // Prefix the worst window (5h·90% / wk·62%) so the number
            // isn't ambiguous when it jumps between windows. Antigravity's
            // quotas have no window label → bare percentage.
            let worst = snapshot.worstUsage
            let pct = "\(Int(worst.percent))%"
            // Space-dot-space matches the app's separator convention
            // (e.g. the reset countdown "2h 14m · 16:30") and gives the
            // menu-bar label breathing room — "7d·62%" read as cramped.
            return worst.label.map { "\($0) · \(pct)" } ?? pct
        }
    }

    /// Start the auto-refresh timer.
    func startTimer() {
        restartTimer()
    }

    // MARK: - Timer

    /// Hard floor for the auto-refresh interval. Even if jitter would pull
    /// the tick below this, we wait at least this long — keeps us under
    /// Anthropic / OpenAI rate-limit radar.
    nonisolated static let minRefreshIntervalFloor: TimeInterval = 60

    private func restartTimer() {
        refreshTask?.cancel()
        guard let seconds = refreshInterval.seconds else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let jittered = Self.jitteredInterval(base: seconds)
                let delay = max(Self.minRefreshIntervalFloor, jittered)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
    }

    /// Jitter the configured refresh interval by ±`jitterFraction` so multiple
    /// devices (or multiple launches of the same device) don't all hit
    /// provider APIs on the same second. Default is ±20%.
    ///
    /// This is a pure math helper. The timer applies a hard floor of
    /// `minRefreshIntervalFloor` separately.
    nonisolated static func jitteredInterval(
        base: Double,
        jitterFraction: Double = 0.2
    ) -> Double {
        let clamped = max(0, min(jitterFraction, 1))
        let spread = base * clamped
        let offset = Double.random(in: -spread...spread)
        return max(0, base + offset)
    }
}

// MARK: - Refresh Interval

enum RefreshInterval: String, CaseIterable, Identifiable {
    case oneMinute = "1m"
    case twoMinutes = "2m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .manual: "Manual"
        }
    }

    var seconds: Double? {
        switch self {
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .manual: nil
        }
    }
}
