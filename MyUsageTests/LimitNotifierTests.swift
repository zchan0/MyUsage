import Testing
import Foundation
import UserNotifications
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

    enum ClaudeSnapshotScenario: CaseIterable {
        case valid, stale, disconnected, waiting, invalid, disabled
    }

    @Test("Only valid, enabled Claude snapshots can generate new notifications",
          arguments: ClaudeSnapshotScenario.allCases)
    @MainActor
    func claudeNotificationEligibility(scenario: ClaudeSnapshotScenario) async throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        try fixture.bridge.enable()
        let now = fixture.now
        let limits = """
        "five_hour":{"used_percentage":97,"resets_at":\(now.timeIntervalSince1970 + 3600)},
        "seven_day":{"used_percentage":97,"resets_at":\(now.timeIntervalSince1970 + 7 * 86400)}
        """
        try fixture.store.write(
            fixture.input(limits: scenario == .waiting ? "" : limits),
            now: scenario == .stale ? now.addingTimeInterval(-86400) : now
        )
        if scenario == .disconnected { try fixture.bridge.disable() }
        if scenario == .invalid {
            try ClaudePrivateFiles.atomicWrite(Data("broken".utf8),
                to: fixture.store.snapshotsDirectory.appendingPathComponent("damaged.json"))
        }
        let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge,
                                      logRoots: [], now: { now })
        provider.isEnabled = scenario != .disabled
        let expectedState: ClaudeProvider.DataState = switch scenario {
        case .valid, .disabled: .valid
        case .stale: .stale
        case .disconnected: .notConnected
        case .waiting: .waiting
        case .invalid: .invalid
        }
        #expect(provider.dataState == expectedState)
        if scenario != .waiting {
            // Suppress new alerts without discarding the dated snapshot the UI can still display.
            #expect(provider.snapshot?.weeklyUsage?.percentUsed == 97)
            #expect(provider.snapshot?.sessionUsage?.percentUsed == 97)
        }
        let observations = LimitNotifier.observations(from: provider)
        #expect(LimitNotifier.observations(from: [provider]) == observations)
        #expect(observations.count == (scenario == .valid ? 2 : 0))

        let suite = "LimitNotifierTests.ClaudeSnapshot.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["claude.weekly": "warn"], forKey: "MyUsage.notifierState")
        let dispatcher = RecordingNotificationDispatcher()
        let notifier = LimitNotifier(center: dispatcher, defaults: defaults)
        await notifier.evaluate(observations: observations, warnThreshold: 80, critThreshold: 95, enabled: true)
        #expect(state(defaults)["claude.weekly"] == (scenario == .valid ? "crit" : "warn"))
        #expect((await dispatcher.firstTitle() != nil) == (scenario == .valid))
    }

    @Test("Claude requires verified source state; other built-in notification inputs are preserved")
    @MainActor
    func sourceStateRequirementIsSpecificToClaude() {
        for kind in ProviderKind.allCases {
            let provider = SnapshotProvider(kind: kind)
            let observations = LimitNotifier.observations(from: provider)
            #expect(observations.count == (kind == .claude ? 0 : 1))
        }
    }

    @MainActor
    private final class SnapshotProvider: BuiltinUsageProvider {
        let kind: ProviderKind
        let isAvailable = true
        var isEnabled = true
        let error: String? = nil
        let isLoading = false
        let snapshot: UsageSnapshot?

        init(kind: ProviderKind) {
            self.kind = kind
            var snapshot = UsageSnapshot()
            snapshot.sessionUsage = .init(percentUsed: 97, resetsAt: nil)
            self.snapshot = snapshot
        }

        func refresh() async {}
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
        accountLabel: String? = nil,
        percent: Double
    ) -> LimitNotifier.LimitObservation {
        .init(
            id: id,
            providerName: "Claude Code",
            accountLabel: accountLabel,
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

    @MainActor
    private func makeNotifierRecording() -> (LimitNotifier, RecordingNotificationDispatcher, UserDefaults) {
        let suite = "LimitNotifierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let dispatcher = RecordingNotificationDispatcher()
        let notifier = LimitNotifier(center: dispatcher, defaults: defaults)
        return (notifier, dispatcher, defaults)
    }

    // MARK: - Notification text

    @Test("Notification title without accountLabel matches today's wording")
    @MainActor
    func titleWithoutAccount() async {
        let (notifier, dispatcher, _) = makeNotifierRecording()
        await notifier.evaluate(
            observations: [makeObs(percent: 82)],
            warnThreshold: 80, critThreshold: 95, enabled: true
        )
        let title = await dispatcher.firstTitle()
        #expect(title == "Claude Code · 5-hour window at 82%")
    }

    @Test("Notification title with accountLabel folds in the email parenthetically")
    @MainActor
    func titleWithAccount() async {
        let (notifier, dispatcher, _) = makeNotifierRecording()
        await notifier.evaluate(
            observations: [makeObs(accountLabel: "user@company.com", percent: 82)],
            warnThreshold: 80, critThreshold: 95, enabled: true
        )
        let title = await dispatcher.firstTitle()
        #expect(title == "Claude Code (user@company.com) · 5-hour window at 82%")
    }

    @Test("Critical-tier title is prefixed with the warning glyph")
    @MainActor
    func critPrefix() async {
        let (notifier, dispatcher, _) = makeNotifierRecording()
        await notifier.evaluate(
            observations: [makeObs(accountLabel: "user@company.com", percent: 96)],
            warnThreshold: 80, critThreshold: 95, enabled: true
        )
        let title = await dispatcher.firstTitle()
        #expect(title == "⚠︎ Claude Code (user@company.com) · 5-hour window at 96%")
    }

    private func state(_ defaults: UserDefaults) -> [String: String] {
        (defaults.dictionary(forKey: "MyUsage.notifierState") as? [String: String]) ?? [:]
    }
}

/// Dispatcher that captures every UNNotificationRequest for assertion
/// in tests. Backed by an actor for thread-safe access.
final class RecordingNotificationDispatcher: NotificationDispatcher, @unchecked Sendable {
    private let store = TitleStore()

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        await store.append(request.content.title)
    }

    func firstTitle() async -> String? {
        await store.first()
    }

    private actor TitleStore {
        var titles: [String] = []
        func append(_ s: String) { titles.append(s) }
        func first() -> String? { titles.first }
    }
}
