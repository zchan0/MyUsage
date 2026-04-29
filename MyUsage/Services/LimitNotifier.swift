import Foundation
import UserNotifications
import os

/// Thin abstraction over `UNUserNotificationCenter` so tests can inject
/// a no-op dispatcher. `UNUserNotificationCenter.current()` asserts when
/// called from a context without a main bundle (xctest), so we can't
/// construct the real one in unit tests.
protocol NotificationDispatcher: AnyObject, Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: NotificationDispatcher {}

/// Drops every request on the floor. Used by tests so the state-machine
/// assertions can run without touching the real notification center.
final class NoopNotificationDispatcher: NotificationDispatcher, @unchecked Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
    func add(_ request: UNNotificationRequest) async throws { /* intentionally empty */ }
}

/// Dispatches macOS notifications when any tracked limit crosses up
/// into a higher pressure tier. Idempotent across refreshes — the same
/// 80% bar doesn't fire twice; only when it crosses 80→95 (warn→crit)
/// does a new notification go out.
///
/// Lives as a `@MainActor` singleton because:
/// - UNUserNotificationCenter is main-thread-bound;
/// - notification state (which tier each limit was last notified at) is
///   process-global and trivially small (UserDefaults dictionary);
/// - tests can inject a custom UserDefaults via the init for isolation.
///
/// Notification thresholds are intentionally **separate** from the
/// visual `LimitSafety` thresholds (75/90). The visual scale tells the
/// user the bar is approaching a limit; the notification scale (default
/// 80/95) gives the user explicit action moments without being noisy.
@MainActor
final class LimitNotifier {

    static let shared = LimitNotifier(center: UNUserNotificationCenter.current())

    enum Tier: String, Codable, Comparable, Sendable {
        case healthy
        case warn
        case crit

        private var rank: Int {
            switch self {
            case .healthy: 0
            case .warn:    1
            case .crit:    2
            }
        }

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rank < rhs.rank }
    }

    /// One row evaluated against the warn / crit thresholds. Must carry a
    /// stable `id` across refreshes so idempotency state can be keyed by it.
    struct LimitObservation: Sendable, Equatable {
        let id: String                  // e.g. "claude.session"
        let providerName: String        // "Claude Code"
        let limitName: String           // "5-hour window"
        let percent: Double
        let resetCountdown: String?     // "2h 14m" or nil
    }

    // MARK: - Dependencies

    private let center: NotificationDispatcher
    private let defaults: UserDefaults
    private static let stateKey = "MyUsage.notifierState"

    /// Production callers leave `center` at the default; tests pass
    /// `NoopNotificationDispatcher()` (or a custom mock) so the state
    /// machine can be exercised without a real macOS notification
    /// service connection.
    init(
        center: NotificationDispatcher,
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    // MARK: - Authorization

    /// Best-effort permission request. Failure is logged; subsequent
    /// `add(_:)` calls will silently no-op if denied, which is fine.
    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Logger.general.error(
                "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Pure helpers (testable)

    /// Map a percent value to a tier given the user's thresholds.
    nonisolated static func tier(for percent: Double, warn: Double, crit: Double) -> Tier {
        if percent >= crit { return .crit }
        if percent >= warn { return .warn }
        return .healthy
    }

    /// Compose `LimitObservation`s out of every enabled provider's snapshot.
    /// MainActor-isolated because UsageProvider properties (kind, isEnabled,
    /// snapshot) are themselves MainActor-only. Tests should construct
    /// observations by hand rather than calling this overload.
    static func observations(
        from providers: [any UsageProvider]
    ) -> [LimitObservation] {
        providers.flatMap { observations(from: $0) }
    }

    static func observations(
        from provider: any UsageProvider
    ) -> [LimitObservation] {
        guard provider.isEnabled, let snap = provider.snapshot else { return [] }
        let display = provider.kind.displayName
        let kindRaw = provider.kind.rawValue
        var rows: [LimitObservation] = []

        if let session = snap.sessionUsage {
            rows.append(.init(
                id: "\(kindRaw).session",
                providerName: display,
                limitName: "5-hour window",
                percent: session.percentUsed,
                resetCountdown: session.resetCountdown
            ))
        }
        if let weekly = snap.weeklyUsage {
            rows.append(.init(
                id: "\(kindRaw).weekly",
                providerName: display,
                limitName: "Weekly limit",
                percent: weekly.percentUsed,
                resetCountdown: weekly.resetCountdown
            ))
        }
        if let pct = snap.totalUsagePercent {
            rows.append(.init(
                id: "\(kindRaw).included",
                providerName: display,
                limitName: "Included quota",
                percent: pct,
                resetCountdown: nil
            ))
        }
        if let odPct = snap.onDemandUsagePercent {
            rows.append(.init(
                id: "\(kindRaw).on-demand",
                providerName: display,
                limitName: "On-demand budget",
                percent: odPct,
                resetCountdown: nil
            ))
        }
        for quota in snap.modelQuotas {
            rows.append(.init(
                id: "\(kindRaw).model.\(quota.label)",
                providerName: display,
                limitName: quota.label,
                percent: quota.percentUsed,
                resetCountdown: nil
            ))
        }
        return rows
    }

    // MARK: - Evaluation

    /// Decide which observations need a notification right now and dispatch.
    /// Idempotency: stores the last-notified tier per limit ID; only fires
    /// when the current tier is **strictly higher** than the stored one.
    /// When a limit drops in tier (window reset, usage dropped), the stored
    /// state is reset so a future tier-up will fire again.
    func evaluate(
        observations: [LimitObservation],
        warnThreshold: Double,
        critThreshold: Double,
        enabled: Bool
    ) async {
        guard enabled else { return }
        // Defensive: warn must be < crit; if user mis-configured, fall back
        // to defaults rather than producing duplicate notifications.
        let (warn, crit) = warnThreshold < critThreshold
            ? (warnThreshold, critThreshold)
            : (80.0, 95.0)

        var state = readState()
        var toFire: [(LimitObservation, Tier)] = []

        for obs in observations {
            let current = Self.tier(for: obs.percent, warn: warn, crit: crit)
            let lastRaw = state[obs.id] ?? Tier.healthy.rawValue
            let last = Tier(rawValue: lastRaw) ?? .healthy

            if current > last {
                toFire.append((obs, current))
                state[obs.id] = current.rawValue
            } else if current < last {
                // Window reset / usage retreated — clear so the next
                // climb fires fresh.
                state[obs.id] = current.rawValue
            }
            // current == last: no-op
        }

        writeState(state)

        for (obs, tier) in toFire {
            await dispatch(observation: obs, tier: tier)
        }
    }

    // MARK: - Private

    private func dispatch(observation obs: LimitObservation, tier: Tier) async {
        let content = UNMutableNotificationContent()
        let prefix = tier == .crit ? "⚠︎ " : ""
        content.title = "\(prefix)\(obs.providerName) · \(obs.limitName) at \(Int(obs.percent.rounded()))%"
        if let reset = obs.resetCountdown {
            content.body = "Resets in \(reset)"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "myusage.\(obs.id).\(tier.rawValue)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            Logger.general.info(
                "Notification fired: \(obs.id, privacy: .public) tier=\(tier.rawValue, privacy: .public)"
            )
        } catch {
            Logger.general.error(
                "Notification dispatch failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func readState() -> [String: String] {
        defaults.dictionary(forKey: Self.stateKey) as? [String: String] ?? [:]
    }

    private func writeState(_ state: [String: String]) {
        defaults.set(state, forKey: Self.stateKey)
    }
}
