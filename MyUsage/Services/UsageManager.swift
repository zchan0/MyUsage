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
            defaults.set(refreshInterval.rawValue, forKey: "refreshInterval")
            restartTimer()
        }
    }

    /// Which provider to show usage for in the menu bar. Empty string = none.
    /// Merged mode only — separate mode gives every provider its own icon.
    var iconTrackProvider: String {
        didSet { defaults.set(iconTrackProvider, forKey: "iconTrackProvider.v2") }
    }

    /// How status items appear in the menu bar (CodexBar-style).
    ///
    /// - `merged` (default): one icon; the panel is Overview + provider tabs.
    /// - `separate`: one icon per enabled provider; clicking an icon opens
    ///   a panel with only that provider — no Overview, no tab strip.
    enum MenuBarMode: String, CaseIterable, Sendable {
        case merged
        case separate
    }

    var menuBarMode: MenuBarMode {
        didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }

    /// Adopt an externally written `menuBarMode` (e.g. `defaults write`)
    /// into the live property so the menu bar rebuilds without a relaunch.
    /// Called from a `UserDefaults.didChangeNotification` observer.
    func syncMenuBarModeFromDefaults() {
        guard let raw = defaults.string(forKey: "menuBarMode"),
              let mode = MenuBarMode(rawValue: raw),
              mode != menuBarMode else { return }
        menuBarMode = mode
    }

    /// Custom display order for providers.
    var providerOrder: [String] {
        didSet { defaults.set(providerOrder, forKey: "providerOrder.v2") }
    }

    /// Whether provider cards display the estimated monthly spend row.
    var showEstimatedCost: Bool {
        didSet { defaults.set(showEstimatedCost, forKey: "showEstimatedCost") }
    }

    /// Master toggle for limit-pressure notifications.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    /// Percent threshold at which a "warn"-level notification fires the
    /// first time a limit crosses up. Default 80 — intentionally above the
    /// visual `LimitSafety.warnThreshold` (75) so the bar turns amber
    /// before users get pinged.
    var notifyWarnThreshold: Double {
        didSet { defaults.set(notifyWarnThreshold, forKey: "notifyWarnThreshold") }
    }

    /// Percent threshold for the "crit" notification (default 95).
    var notifyCritThreshold: Double {
        didSet { defaults.set(notifyCritThreshold, forKey: "notifyCritThreshold") }
    }


    // MARK: - Private

    private let defaults: UserDefaults
    private let backgroundServicesEnabled: Bool
    let gatewayStore: GatewayConnectionStore
    private(set) var gatewaySettingsError: String?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    init(
        ledger: LedgerSync = LedgerSync(),
        providers initialProviders: [any UsageProvider]? = nil,
        startsLedger: Bool = true,
        defaults: UserDefaults = .standard,
        gatewayStore: GatewayConnectionStore? = nil
    ) {
        self.defaults = defaults
        self.backgroundServicesEnabled = startsLedger
        self.gatewayStore = gatewayStore ?? GatewayConnectionStore(defaults: defaults)
        let savedInterval = defaults.string(forKey: "refreshInterval")
        self.refreshInterval = RefreshInterval(rawValue: savedInterval ?? "") ?? .fiveMinutes
        let storedOrder = defaults.stringArray(forKey: "providerOrder.v2")
            ?? defaults.stringArray(forKey: "providerOrder")
        self.providerOrder = (storedOrder ?? ProviderKind.allCases.map(\.rawValue)).map { ProviderID.migrated($0).rawValue }
        self.iconTrackProvider = ProviderID.migrated(defaults.string(forKey: "iconTrackProvider.v2")
            ?? defaults.string(forKey: "iconTrackProvider") ?? storedOrder?.first ?? "claude").rawValue
        self.menuBarMode = defaults.string(forKey: "menuBarMode")
            .flatMap(MenuBarMode.init(rawValue:)) ?? .merged
        self.showEstimatedCost = defaults.object(forKey: "showEstimatedCost") as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.notifyWarnThreshold = (defaults.object(forKey: "notifyWarnThreshold") as? Double) ?? 80
        self.notifyCritThreshold = (defaults.object(forKey: "notifyCritThreshold") as? Double) ?? 95
        self.ledger = ledger

        if let initialProviders {
            for provider in initialProviders {
                register(provider)
            }
        } else {
            register(ClaudeProvider(ledger: ledger))
            register(CodexProvider(ledger: ledger))
            register(CursorProvider())
            register(AntigravityProvider())
            do {
                for connection in try self.gatewayStore.load() {
                    register(GatewayProvider(connection: connection, credentials: self.gatewayStore.credentials))
                }
            } catch { gatewaySettingsError = error.localizedDescription }
        }

        // One-time cleanup: the multi-account registry was removed.
        // Its persisted `accounts.json` is now orphaned — delete it
        // best-effort so we don't leave dead state behind. Harmless if
        // already gone. The ledger (which still carries account_id rows
        // for spec 13 cross-device sync) is untouched.
        if startsLedger { Self.removeOrphanedAccountStore() }

        // Pick up `defaults write MyUsage menuBarMode …` while running —
        // used by automated testing and handy for scripting. KVO (not
        // didChangeNotification) because only KVO sees writes made by
        // OTHER processes via cfprefsd.
        if startsLedger {
            menuBarModeObserver = DefaultsKeyObserver(key: "menuBarMode") { [weak self] in
                Task { @MainActor [weak self] in self?.syncMenuBarModeFromDefaults() }
            }
            Task { await ledger.start() }
        }
    }

    private var menuBarModeObserver: DefaultsKeyObserver?

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

    func setEnabled(_ enabled: Bool, for provider: any UsageProvider) {
        provider.isEnabled = enabled
        defaults.set(enabled, forKey: "provider.\(provider.id.rawValue).enabled")
        if !enabled, let gateway = provider as? GatewayProvider { gateway.invalidate() }
    }

    func saveGateway(_ draft: GatewayConnection, newKey: String?, initial: GatewayScopeCheck?) throws {
        let connection = try gatewayStore.save(draft, newKey: newKey)
        if let provider = providers.first(where: { $0.id == connection.providerID }) as? GatewayProvider {
            provider.update(connection, initial: initial)
        } else {
            register(GatewayProvider(connection: connection, credentials: gatewayStore.credentials, initial: initial))
        }
        gatewaySettingsError = nil
    }

    func removeGateway(_ connection: GatewayConnection) throws {
        try gatewayStore.remove(connection.id)
        (providers.first { $0.id == connection.providerID } as? GatewayProvider)?.invalidate()
        providers.removeAll { $0.id == connection.providerID }
        providerOrder.removeAll { $0 == connection.providerID.rawValue }
        defaults.removeObject(forKey: "provider.\(connection.providerID.rawValue).enabled")
        if iconTrackProvider == connection.providerID.rawValue { iconTrackProvider = "" }
    }

    /// Refresh all enabled providers.
    func refreshAll(trigger: UsageRefreshTrigger = .automatic) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshed = .now
        }

        // Keep the pricing catalog fresh (LiteLLM, ≤ once per 24h).
        // Fire-and-forget: cost estimates for THIS refresh use whatever
        // catalog is installed; the swap benefits the next one.
        if backgroundServicesEnabled {
            Task.detached(priority: .utility) { await PricingUpdater.refreshIfStale() }
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
        // visibly lag behind the first provider). Capture instance references
        // so removing/reordering settings during refresh cannot change a target.
        let enabled = providers.filter { $0.isEnabled }
        let tasks: [Task<Void, Never>] = enabled.map { provider in
            Task { @MainActor in
                await provider.refresh(trigger: trigger)
            }
        }
        for task in tasks {
            await task.value
        }

        // Evaluate limit pressure and dispatch notifications for any
        // tier upgrades observed since the previous refresh. Idempotent
        // by ID, so no duplicates within the same window.
        let observations = LimitNotifier.observations(from: providers)
        if backgroundServicesEnabled {
            await LimitNotifier.shared.evaluate(
                observations: observations,
                warnThreshold: notifyWarnThreshold,
                critThreshold: notifyCritThreshold,
                enabled: notificationsEnabled
            )
        }
    }

    /// Register a provider, restoring persisted enabled state.
    func register(_ provider: any UsageProvider) {
        let key = "provider.\(provider.id.rawValue).enabled"
        if defaults.object(forKey: key) != nil {
            provider.isEnabled = defaults.bool(forKey: key)
        }
        if let builtin = provider as? any BuiltinUsageProvider, defaults.object(forKey: key) == nil,
           let legacy = defaults.object(forKey: "provider.\(builtin.kind.rawValue).enabled") as? Bool {
            provider.isEnabled = legacy
        }
        guard !providers.contains(where: { $0.id == provider.id }) else { return }
        providers.append(provider)
        if !providerOrder.contains(provider.id.rawValue) { providerOrder.append(provider.id.rawValue) }
    }

    /// Providers sorted by user-defined order.
    var orderedProviders: [any UsageProvider] {
        providers.sorted { a, b in
            let ai = providerOrder.firstIndex(of: a.id.rawValue) ?? Int.max
            let bi = providerOrder.firstIndex(of: b.id.rawValue) ?? Int.max
            return ai < bi
        }
    }

    /// Move a provider from one position to another.
    func moveProvider(from source: IndexSet, to destination: Int) {
        providerOrder = orderedProviders.map(\.id.rawValue)
        providerOrder.move(fromOffsets: source, toOffset: destination)
    }

    /// The worst usage percent across all enabled providers.
    var worstUsagePercent: Double {
        providers
            .filter { $0.isEnabled }
            .compactMap { provider -> Double? in
                switch provider.payload {
                case .builtin(let snapshot): snapshot.worstUsagePercent
                case .gateway(let snapshot): snapshot.summary.issue == nil ? snapshot.summary.value?.percentUsed : nil
                case nil: nil
                }
            }
            .max() ?? 0
    }

    /// Short text for the menu bar label, based on tracked provider.
    var menuBarDisplayText: String? {
        guard !iconTrackProvider.isEmpty,
              let provider = providers.first(where: { $0.id.rawValue == iconTrackProvider })
        else { return nil }
        return menuBarText(for: provider.id)
    }

    /// Short menu-bar label text for one provider — used by the merged
    /// icon (via `menuBarDisplayText`) and by each per-provider status
    /// item in separate-icons mode.
    func menuBarText(for kind: ProviderKind) -> String? { menuBarText(for: .builtin(kind)) }

    func menuBarText(for id: ProviderID) -> String? {
        guard let instance = providers.first(where: { $0.id == id }) else { return nil }
        if case .gateway(let snapshot) = instance.payload {
            guard snapshot.summary.issue == nil, let summary = snapshot.summary.value else { return nil }
            if let percent = summary.percentUsed { return "\(Int(min(percent, 999)))%" }
            return summary.spend.map { GatewayFormatting.money($0, currency: summary.currency) }
        }
        guard let provider = instance as? any BuiltinUsageProvider,
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
