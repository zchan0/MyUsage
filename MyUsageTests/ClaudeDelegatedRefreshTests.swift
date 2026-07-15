import Foundation
import Testing
@testable import MyUsage

@Suite("ClaudeDelegatedRefresh Tests")
struct ClaudeDelegatedRefreshTests {

    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "delegated-refresh-tests-\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("First attempt is always permitted")
    func firstAttemptPermitted() {
        let defaults = scratchDefaults()
        #expect(ClaudeDelegatedRefresh.cooldownPermits(defaults: defaults))
    }

    @Test("Attempts inside the cooldown window are blocked")
    func cooldownBlocks() {
        let defaults = scratchDefaults()
        let t0 = Date.now

        ClaudeDelegatedRefresh.recordAttempt(defaults: defaults, now: t0)

        #expect(!ClaudeDelegatedRefresh.cooldownPermits(defaults: defaults, now: t0.addingTimeInterval(1)))
        #expect(!ClaudeDelegatedRefresh.cooldownPermits(
            defaults: defaults,
            now: t0.addingTimeInterval(ClaudeDelegatedRefresh.cooldown - 1)
        ))
        #expect(ClaudeDelegatedRefresh.cooldownPermits(
            defaults: defaults,
            now: t0.addingTimeInterval(ClaudeDelegatedRefresh.cooldown + 1)
        ))
    }

    @Test("Cooldown persists across instances (survives relaunch)")
    func cooldownPersists() {
        let suite = "delegated-refresh-tests-persist"
        let a = UserDefaults(suiteName: suite)!
        a.removePersistentDomain(forName: suite)
        let t0 = Date.now

        ClaudeDelegatedRefresh.recordAttempt(defaults: a, now: t0)

        let b = UserDefaults(suiteName: suite)!
        #expect(!ClaudeDelegatedRefresh.cooldownPermits(defaults: b, now: t0.addingTimeInterval(60)))
        b.removePersistentDomain(forName: suite)
    }

    @Test("Binary resolution checks well-known locations plus PATH")
    func binaryResolution() {
        // Environment-dependent by nature: assert only that resolution
        // doesn't crash and, when it finds something, it's executable.
        if let url = ClaudeDelegatedRefresh.resolveBinary() {
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
        }
    }

    /// Opt-in end-to-end check: actually spawns `claude /status` on a PTY
    /// and terminates it. Excluded from normal runs (spawns a real CLI
    /// session); run with PTY_E2E=1 when touching the runner.
    @Test(
        "PTY runner spawns and terminates the real CLI",
        .enabled(if: ProcessInfo.processInfo.environment["PTY_E2E"] == "1")
    )
    func ptyEndToEnd() async {
        let defaults = scratchDefaults()
        let outcome = await ClaudeDelegatedRefresh.attempt(
            timeout: 6,
            defaults: defaults,
            now: .now
        )
        #expect(outcome == .attempted || outcome == .cliUnavailable)

        // Second call inside the cooldown must not spawn again.
        let second = await ClaudeDelegatedRefresh.attempt(defaults: defaults, now: .now)
        #expect(second == .skippedByCooldown || second == .cliUnavailable)
    }
}
