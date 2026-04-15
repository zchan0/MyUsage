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

    // MARK: - Private

    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let savedInterval = UserDefaults.standard.string(forKey: "refreshInterval")
        self.refreshInterval = RefreshInterval(rawValue: savedInterval ?? "") ?? .fiveMinutes

        // Register providers — each auto-detects availability
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

    /// The worst usage percent across all enabled providers.
    var worstUsagePercent: Double {
        providers
            .filter { $0.isEnabled }
            .compactMap { $0.snapshot?.worstUsagePercent }
            .max() ?? 0
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
