import Foundation
import os

// `@preconcurrency` tells Swift to treat all `UserNotifications` types
// as `Sendable` for cross-actor purposes. The framework predates the
// Swift 6 concurrency model and Apple has not yet annotated all of its
// classes as `Sendable`; without this, sending `UNUserNotificationCenter`
// or `UNNotificationRequest` across an `await` boundary errors on the
// macos-15 / Xcode 16 toolchain even though local Xcode 26 lets it pass.
@preconcurrency import UserNotifications

/// Thin abstraction over `UNUserNotificationCenter` so tests can inject
/// a no-op dispatcher. `UNUserNotificationCenter.current()` asserts when
/// called from a context without a main bundle (xctest), so we can't
/// construct the real one in unit tests.
protocol NotificationDispatcher: AnyObject, Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

// Retroactive `@unchecked Sendable` is required on Xcode 16's UserNotifications
// SDK because Apple hasn't annotated `UNUserNotificationCenter` as Sendable
// there yet. Without this, conforming to the Sendable-requiring
// `NotificationDispatcher` protocol below errors at compile time
// ("conformance to 'Sendable' must occur in the same source file as class").
// `@retroactive` silences the warning that pairs with retroactive
// conformance and is a no-op on Xcode 26 where Apple already added it.
extension UNUserNotificationCenter: @retroactive @unchecked Sendable {}

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
        /// Pre-formatted account label folded into notification copy when
        /// non-nil. nil = single-account case (today's wording preserved).
        /// Spec 15: include the email for disambiguation when ≥ 2 accounts
        /// have been observed for the same provider.
        let accountLabel: String?
        let limitName: String           // "5-hour window"
        let percent: Double
        let resetCountdown: String?     // "2h 14m" or nil

        init(
            id: String,
            providerName: String,
            accountLabel: String? = nil,
            limitName: String,
            percent: Double,
            resetCountdown: String?
        ) {
            self.id = id
            self.providerName = providerName
            self.accountLabel = accountLabel
            self.limitName = limitName
            self.percent = percent
            self.resetCountdown = resetCountdown
        }
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
    ///
    /// `accountStore` (when present) is consulted per-provider to fold
    /// the active account's display name into notifications when ≥ 2
    /// accounts have been observed. Single-account providers see no
    /// change to their notification copy.
    static func observations(
        from providers: [any UsageProvider],
        accountStore: AccountStore? = nil
    ) -> [LimitObservation] {
        providers.flatMap { observations(from: $0, accountStore: accountStore) }
    }

    static func observations(
        from provider: any UsageProvider,
        accountStore: AccountStore? = nil
    ) -> [LimitObservation] {
        guard provider.isEnabled, let snap = provider.snapshot else { return [] }
        let display = provider.kind.displayName
        let kindRaw = provider.kind.rawValue
        let accountLabel = activeAccountLabel(provider: provider, store: accountStore)
        var rows: [LimitObservation] = []

        if let session = snap.sessionUsage {
            rows.append(.init(
                id: "\(kindRaw).session",
                providerName: display,
                accountLabel: accountLabel,
                limitName: "5-hour window",
                percent: session.percentUsed,
                resetCountdown: session.resetCountdown
            ))
        }
        if let weekly = snap.weeklyUsage {
            rows.append(.init(
                id: "\(kindRaw).weekly",
                providerName: display,
                accountLabel: accountLabel,
                limitName: "Weekly limit",
                percent: weekly.percentUsed,
                resetCountdown: weekly.resetCountdown
            ))
        }
        if let pct = snap.totalUsagePercent {
            rows.append(.init(
                id: "\(kindRaw).included",
                providerName: display,
                accountLabel: accountLabel,
                limitName: "Included quota",
                percent: pct,
                resetCountdown: nil
            ))
        }
        if let odPct = snap.onDemandUsagePercent {
            rows.append(.init(
                id: "\(kindRaw).on-demand",
                providerName: display,
                accountLabel: accountLabel,
                limitName: "On-demand budget",
                percent: odPct,
                resetCountdown: nil
            ))
        }
        for quota in snap.modelQuotas {
            rows.append(.init(
                id: "\(kindRaw).model.\(quota.label)",
                providerName: display,
                accountLabel: accountLabel,
                limitName: quota.label,
                percent: quota.percentUsed,
                resetCountdown: nil
            ))
        }
        return rows
    }

    /// Returns the active account's display name for this provider when
    /// ≥ 2 accounts have been observed. Single-account providers return
    /// nil so the notification text reads as it does today.
    private static func activeAccountLabel(
        provider: any UsageProvider,
        store: AccountStore?
    ) -> String? {
        guard let store, store.count(for: provider.kind) >= 2 else { return nil }
        guard let activeID = store.activeAccountID(for: provider.kind),
              let record = store.record(for: provider.kind, accountID: activeID)
        else { return nil }
        return record.displayName
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
        // Spec 15: when the provider has ≥ 2 observed accounts, fold the
        // active account's display name into the title so notifications
        // are still useful when the user runs work + personal Claude
        // accounts on the same Mac.
        let accountSuffix = obs.accountLabel.map { " (\($0))" } ?? ""
        content.title = "\(prefix)\(obs.providerName)\(accountSuffix) · \(obs.limitName) at \(Int(obs.percent.rounded()))%"
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
