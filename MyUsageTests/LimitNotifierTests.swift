import Testing
import Foundation
@testable import MyUsage

/// LimitNotifier tests — focus on the pure tier calculation + the
/// idempotency state machine. We don't try to drive
/// UNUserNotificationCenter from tests; the dispatch path is asserted
/// indirectly by checking the state map mutates correctly across
/// `evaluate` calls (a fresh "should fire" reflects in state[id]).
@Suite("LimitNotifier Tests")
struct LimitNotifierTests {

    // MARK: - Pure tier mapping

    @Test("tier mapping bands percent into healthy/warn/crit")
    func tierBands() {
        #expect(LimitNotifier.tier(for:  0,  warn: 80, crit: 95) == .healthy)
        #expect(LimitNotifier.tier(for: 79,  warn: 80, crit: 95) == .healthy)
        #expect(LimitNotifier.tier(for: 80,  warn: 80, crit: 95) == .warn)
        #expect(LimitNotifier.tier(for: 94,  warn: 80, crit: 95) == .warn)
        #expect(LimitNotifier.tier(for: 95,  warn: 80, crit: 95) == .crit)
        #expect(LimitNotifier.tier(for: 100, warn: 80, crit: 95) == .crit)
    }

    @Test("tier ordering: healthy < warn < crit")
    func tierOrdering() {
        #expect(LimitNotifier.Tier.healthy < .warn)
        #expect(LimitNotifier.Tier.warn < .crit)
        #expect(LimitNotifier.Tier.healthy < .crit)
    }

    // MARK: - Idempotency / state machine

    @Test("crossing healthy → warn marks state warn")
    @MainActor
    func crossUpToWarn() async {
        let (notifier, defaults, _) = makeNotifier()
        let obs = makeObs(percent: 82)

        await notifier.evaluate(observations: [obs], warnThreshold: 80, critThreshold: 95, enabled: true)

        #expect(state(defaults)[obs.id] == "warn")
    }

    @Test("staying inside the same tier is idempotent (state stays warn)")
    @MainActor
    func sameTierIdempotent() async {
        let (notifier, defaults, _) = makeNotifier()

        await notifier.evaluate(observations: [makeObs(percent: 82)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)
        await notifier.evaluate(observations: [makeObs(percent: 88)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)

        // No upgrade across the two passes — state stays at warn.
        #expect(state(defaults)["claude.session"] == "warn")
    }

    @Test("upgrading warn → crit moves stored state to crit")
    @MainActor
    func upgradeToCrit() async {
        let (notifier, defaults, _) = makeNotifier()
        await notifier.evaluate(observations: [makeObs(percent: 82)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)
        #expect(state(defaults)["claude.session"] == "warn")

        await notifier.evaluate(observations: [makeObs(percent: 96)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)
        #expect(state(defaults)["claude.session"] == "crit")
    }

    @Test("retreating below warn resets state, allowing future fires")
    @MainActor
    func retreatResets() async {
        let (notifier, defaults, _) = makeNotifier()

        await notifier.evaluate(observations: [makeObs(percent: 96)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)
        #expect(state(defaults)["claude.session"] == "crit")

        // Window resets / usage drops back to healthy.
        await notifier.evaluate(observations: [makeObs(percent: 5)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)
        #expect(state(defaults)["claude.session"] == "healthy")

        // Now climbing again should treat it as a fresh tier-up.
        await notifier.evaluate(observations: [makeObs(percent: 82)],
                                warnThreshold: 80, critThreshold: 95, enabled: true)
        #expect(state(defaults)["claude.session"] == "warn")
    }

    @Test("disabled = no state mutation, no firing")
    @MainActor
    func disabledNoOp() async {
        let (notifier, defaults, _) = makeNotifier()
        await notifier.evaluate(observations: [makeObs(percent: 96)],
                                warnThreshold: 80, critThreshold: 95, enabled: false)
        #expect(state(defaults).isEmpty)
    }

    @Test("invalid threshold ordering (warn ≥ crit) falls back to defaults")
    @MainActor
    func badThresholdsClamp() async {
        let (notifier, defaults, _) = makeNotifier()
        // warn = crit = 90; falls back to defaults 80/95.
        // 82 is below 80? no, ≥ 80 → warn under defaults.
        await notifier.evaluate(observations: [makeObs(percent: 82)],
                                warnThreshold: 90, critThreshold: 90, enabled: true)
        #expect(state(defaults)["claude.session"] == "warn")
    }

    // MARK: - Helpers

    private func makeObs(
        id: String = "claude.session",
        percent: Double
    ) -> LimitNotifier.LimitObservation {
        .init(
            id: id,
            providerName: "Claude Code",
            limitName: "5-hour window",
            percent: percent,
            resetCountdown: "2h 14m"
        )
    }

    @MainActor
    private func makeNotifier() -> (LimitNotifier, UserDefaults, String) {
        let suite = "LimitNotifierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Noop dispatcher: UNUserNotificationCenter.current() asserts in
        // xctest contexts (no main bundle). The state-machine assertions
        // are what these tests exist to cover; whether the real macOS
        // service receives the request is integration territory.
        let notifier = LimitNotifier(
            center: NoopNotificationDispatcher(),
            defaults: defaults
        )
        return (notifier, defaults, suite)
    }

    private func state(_ defaults: UserDefaults) -> [String: String] {
        (defaults.dictionary(forKey: "MyUsage.notifierState") as? [String: String]) ?? [:]
    }
}
