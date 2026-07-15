import Darwin
import Foundation
import os

/// Runs the Claude CLI briefly so *it* rotates the OAuth tokens in the
/// Keychain — MyUsage never calls the refresh endpoint itself, because
/// Anthropic rotates refresh tokens on use and a second consumer burns
/// the CLI's copy (docs/claude-token-rotation-bug.md). This automates the
/// "Run `claude` once in Terminal" hint the popover used to show.
///
/// The CLI is spawned on a PTY because `/status` is an interactive slash
/// command (the CodexBar recipe): TUI output is drained and discarded,
/// Enter is nudged periodically to dismiss any prompt, and the process is
/// terminated after `timeout`. We deliberately do NOT parse the TUI —
/// success is the caller silently re-reading credentials and finding a
/// non-expired token.
enum ClaudeDelegatedRefresh {

    enum Outcome: Equatable, Sendable {
        /// Attempted too recently — don't hammer the CLI from the refresh timer.
        case skippedByCooldown
        /// No claude binary found on this machine.
        case cliUnavailable
        /// The CLI ran (to completion or until our timeout). Re-read
        /// credentials to find out whether rotation actually happened.
        case attempted
        case launchFailed(String)
    }

    /// Minimum spacing between CLI spawns, persisted so a relaunch doesn't
    /// reset it. One spawn per cooldown window is plenty: rotation either
    /// worked (token now valid for ~8h) or something is wrong that
    /// retrying won't fix.
    static let cooldown: TimeInterval = 5 * 60
    static let lastAttemptDefaultsKey = "claude.delegatedRefreshLastAttemptAt"

    /// Attempt a delegated refresh. Serialized (concurrent callers coalesce)
    /// and cooldown-gated. `timeout` bounds the CLI run, not the whole call.
    static func attempt(
        timeout: TimeInterval = 8,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) async -> Outcome {
        guard let binary = resolveBinary() else { return .cliUnavailable }
        guard await gate.begin() else { return .skippedByCooldown }
        defer { Task { await gate.end() } }

        guard cooldownPermits(defaults: defaults, now: now) else {
            return .skippedByCooldown
        }
        recordAttempt(defaults: defaults, now: now)

        let outcome = await runOnPTY(binary: binary, timeout: timeout)
        Logger.claude.info("Delegated refresh outcome: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// True when enough time has passed since the last CLI spawn.
    /// Extracted (and defaults-injectable) so the gate is unit-testable
    /// without actually spawning the CLI.
    static func cooldownPermits(defaults: UserDefaults, now: Date = .now) -> Bool {
        let last = defaults.double(forKey: lastAttemptDefaultsKey)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= cooldown
    }

    static func recordAttempt(defaults: UserDefaults, now: Date = .now) {
        defaults.set(now.timeIntervalSince1970, forKey: lastAttemptDefaultsKey)
    }

    // MARK: - Binary resolution

    /// Well-known install locations first (a GUI app's PATH is minimal),
    /// then PATH for dev runs from a shell.
    static func resolveBinary(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    // MARK: - PTY runner

    private static func runOnPTY(binary: URL, timeout: TimeInterval) async -> Outcome {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            return .launchFailed("openpty failed")
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["/status"]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        // Drain the PTY so the CLI never blocks on a full buffer; the TUI
        // bytes themselves are noise.
        masterHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            return .launchFailed(error.localizedDescription)
        }

        // Give the CLI time to start up and hit the auth path (which is
        // where an expired token gets rotated). Nudge Enter periodically
        // to step past trust/update prompts.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 800_000_000)
            try? masterHandle.write(contentsOf: Data("\r".utf8))
        }

        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        masterHandle.readabilityHandler = nil
        return .attempted
    }

    /// Single-flight gate — overlapping refresh ticks share one CLI spawn.
    private actor Gate {
        private var inFlight = false
        func begin() -> Bool {
            if inFlight { return false }
            inFlight = true
            return true
        }
        func end() { inFlight = false }
    }

    private static let gate = Gate()
}
