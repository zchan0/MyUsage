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

    // MARK: - Private

    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let savedInterval = UserDefaults.standard.string(forKey: "refreshInterval")
        self.refreshInterval = RefreshInterval(rawValue: savedInterval ?? "") ?? .fiveMinutes
        self.iconTrackProvider = UserDefaults.standard.string(forKey: "iconTrackProvider") ?? ""
        self.providerOrder = UserDefaults.standard.stringArray(forKey: "providerOrder")
            ?? ProviderKind.allCases.map(\.rawValue)
        self.showEstimatedCost = UserDefaults.standard.object(forKey: "showEstimatedCost") as? Bool ?? true

        register(ClaudeProvider())
        register(CodexProvider())
        register(CursorProvider())
        register(AntigravityProvider())
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

        for provider in providers where provider.isEnabled {
            await provider.refresh()
        }
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
              let provider = providers.first(where: { $0.kind.rawValue == iconTrackProvider && $0.isEnabled }),
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
            return "\(Int(snapshot.worstUsagePercent))%"
        }
    }

    /// Start the auto-refresh timer.
    func startTimer() {
        restartTimer()
    }

    // MARK: - Timer

    private func restartTimer() {
        refreshTask?.cancel()
        guard let seconds = refreshInterval.seconds else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
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
