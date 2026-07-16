import Foundation
import os
import Security

/// Loads Claude Code OAuth credentials while keeping Keychain password
/// prompts to the bare minimum (the CodexBar recipe).
///
/// Source chain, in order:
///   1. `~/.claude/.credentials.json` — plain file, never prompts.
///   2. The CLI's Keychain item (`Claude Code-credentials`) via a **no-UI**
///      query. Succeeds silently once the user has clicked "Always Allow";
///      fails with `errSecInteractionNotAllowed` instead of showing the
///      password dialog otherwise.
///   3. MyUsage's own Keychain cache — a copy of the last credentials we
///      managed to read. We created the item, so reading it never prompts.
///      Every successful read of sources 1–2 refreshes this copy.
///   4. Last resort, only when 1–3 produced nothing usable: an
///      **interactive** read of the CLI item — the one dialog where the
///      user should click "Always Allow". Attempts are rate-limited
///      (`interactiveCooldown`), and an explicit user denial backs off for
///      `denialBackoff` (persisted) so the refresh timer can never turn
///      into a prompt storm.
///
/// The store is read-only towards the CLI: it never writes the CLI's item
/// and never calls the OAuth refresh endpoint — token rotation stays owned
/// by the CLI alone (see docs/claude-token-rotation-bug.md).
@MainActor
final class ClaudeCredentialStore {

    /// Injectable I/O so unit tests never touch the real Keychain or disk.
    struct IO: Sendable {
        var readFile: @Sendable (String) -> Data?
        var readKeychain: @Sendable (_ service: String, _ allowUI: Bool) -> (data: Data?, status: OSStatus)
        var writeKeychain: @Sendable (_ data: Data, _ service: String, _ account: String?) -> OSStatus

        static let live = IO(
            readFile: { FileManager.default.contents(atPath: $0) },
            readKeychain: { service, allowUI in
                KeychainHelper.readGenericPasswordResult(service: service, allowUI: allowUI)
            },
            writeKeychain: { data, service, account in
                KeychainHelper.upsertGenericPassword(data, service: service, account: account)
            }
        )
    }

    enum Origin: String {
        case file
        case cliKeychain
        case ownCache
    }

    struct LoadResult {
        let credentials: ClaudeCredentials
        let origin: Origin
    }

    /// Service name of MyUsage's own cache item. Distinct from the CLI's
    /// `Claude Code-credentials` so we can never collide with (or be
    /// mistaken for) the CLI's item.
    static let cacheService = "MyUsage-claude-credentials"
    static let cacheAccount = "oauth.claude"

    /// Minimum spacing between interactive prompt attempts within one run.
    static let interactiveCooldown: TimeInterval = 30 * 60
    /// Backoff after the user explicitly cancels the ACL dialog. Persisted
    /// so a denial survives app restarts instead of re-prompting on launch.
    static let denialBackoff: TimeInterval = 8 * 3600
    static let denialDefaultsKey = "claude.keychainPromptDeniedUntil"

    /// CLI Keychain status from the most recent no-UI probe. Lets the
    /// provider distinguish "no item at all" (not a Claude user) from
    /// "item exists but needs user approval" (Claude user, ACL-blocked).
    private(set) var lastCLIStatus: OSStatus?

    private let credentialFilePath: String
    private let cliKeychainService: String
    private let io: IO
    private let defaults: UserDefaults

    private var lastInteractiveAttemptAt: Date?
    /// Raw bytes last persisted to the cache item — skips redundant
    /// Keychain writes when the CLI item hasn't rotated between refreshes.
    private var lastCachedPayload: Data?

    init(
        credentialFilePath: String = FileManager.default.homeDirectoryForCurrentUser.path
            + "/.claude/.credentials.json",
        cliKeychainService: String = "Claude Code-credentials",
        io: IO = .live,
        defaults: UserDefaults = .standard
    ) {
        self.credentialFilePath = credentialFilePath
        self.cliKeychainService = cliKeychainService
        self.io = io
        self.defaults = defaults
    }

    /// Hard kill-switch for the interactive Keychain prompt. Dev/test runs
    /// (`swift run`, autopilot, CI) rebuild the ad-hoc binary constantly —
    /// every rebuild is a new signing identity, every prior "Always Allow"
    /// is void, and each run would throw the password dialog at whoever is
    /// sitting at the machine. Set either env var to keep those runs
    /// strictly silent; a stale cached token is fine for development.
    private var promptSuppressed: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MYUSAGE_NO_PROMPT"] == "1" || env["MYUSAGE_AUTOPILOT"] != nil { return true }
        // Any non-.app invocation IS a dev build — its ad-hoc signature
        // changes on every rebuild, so it could never hold a durable
        // Keychain approval anyway. Only real bundled builds may prompt.
        return Bundle.main.bundleURL.pathExtension != "app"
    }

    /// Walk the source chain. `interactive` gates step 4 only — steps 1–3
    /// are always silent. Returns nil when no source yields credentials
    /// with an OAuth payload.
    func load(interactive: Bool, now: Date = .now) -> LoadResult? {
        let interactive = interactive && !promptSuppressed
        // 1) Credentials file — free to read, authoritative when present.
        if let data = io.readFile(credentialFilePath),
           let creds = Self.decode(data) {
            cacheIfChanged(data)
            return LoadResult(credentials: creds, origin: .file)
        }

        // 2) CLI Keychain item, silently.
        let probe = io.readKeychain(cliKeychainService, false)
        lastCLIStatus = probe.status
        if let data = probe.data, let creds = Self.decode(data) {
            cacheIfChanged(data)
            return LoadResult(credentials: creds, origin: .cliKeychain)
        }

        // 3) Our own cached copy. Served even when expired — the provider
        //    turns an expired token into the "run `claude`" hint, which
        //    beats prompting.
        let cached = io.readKeychain(Self.cacheService, false).data.flatMap(Self.decode)

        // 4) Interactive bootstrap: only when the silent probe said the CLI
        //    item exists but needs approval, AND we hold no usable copy
        //    (none at all, or only an expired one that the silent path can't
        //    replace precisely because the ACL blocks us).
        if probe.status == errSecInteractionNotAllowed,
           interactive,
           cached == nil || cached?.isExpired == true,
           canAttemptInteractive(now: now) {
            lastInteractiveAttemptAt = now
            let result = io.readKeychain(cliKeychainService, true)
            lastCLIStatus = result.status
            if let data = result.data, let creds = Self.decode(data) {
                cacheIfChanged(data)
                return LoadResult(credentials: creds, origin: .cliKeychain)
            }
            if result.status == errSecUserCanceled {
                defaults.set(
                    now.addingTimeInterval(Self.denialBackoff).timeIntervalSince1970,
                    forKey: Self.denialDefaultsKey
                )
                Logger.claude.info("Keychain prompt denied; backing off for 8h")
            }
        }

        return cached.map { LoadResult(credentials: $0, origin: .ownCache) }
    }

    // MARK: - Internals

    private func canAttemptInteractive(now: Date) -> Bool {
        if let last = lastInteractiveAttemptAt,
           now.timeIntervalSince(last) < Self.interactiveCooldown {
            return false
        }
        let deniedUntil = defaults.double(forKey: Self.denialDefaultsKey)
        if deniedUntil > 0, now.timeIntervalSince1970 < deniedUntil {
            return false
        }
        return true
    }

    private func cacheIfChanged(_ data: Data) {
        if lastCachedPayload == data { return }
        let existing = io.readKeychain(Self.cacheService, false).data
        if existing != data {
            let status = io.writeKeychain(data, Self.cacheService, Self.cacheAccount)
            if status != errSecSuccess {
                Logger.claude.error("Failed to write credential cache (status \(status, privacy: .public))")
                return
            }
        }
        lastCachedPayload = data
    }

    /// nonisolated: pure function, and the CI toolchain (older Swift than
    /// local) rejects passing a MainActor-isolated method as a function
    /// value to `flatMap` from a nonisolated context.
    nonisolated private static func decode(_ data: Data) -> ClaudeCredentials? {
        guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
              creds.claudeAiOauth != nil else { return nil }
        return creds
    }
}
