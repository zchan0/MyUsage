import Security
import XCTest
@testable import MyUsage

@MainActor
final class ClaudeCredentialStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Valid credentials JSON expiring far in the future.
    private static func credsJSON(
        accessToken: String = "at-1",
        expiresAt: Int64 = Int64(Date.now.addingTimeInterval(8 * 3600).timeIntervalSince1970 * 1000)
    ) -> Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"rt-1",
        "expiresAt":\(expiresAt),"scopes":["user:inference"],
        "subscriptionType":"max","rateLimitTier":null}}
        """.utf8)
    }

    private static func expiredCredsJSON(accessToken: String = "at-old") -> Data {
        credsJSON(
            accessToken: accessToken,
            expiresAt: Int64(Date.now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        )
    }

    /// A recording IO harness. Each keychain "service" is a dictionary
    /// slot; reads/writes are tracked for assertions.
    @MainActor
    private final class Harness {
        var file: Data?
        var cliData: Data?
        /// Status returned by no-UI CLI reads when `cliData` is nil.
        var cliNoUIStatus: OSStatus = errSecItemNotFound
        /// Result of an interactive CLI read (data, status).
        var cliInteractive: (Data?, OSStatus) = (nil, errSecUserCanceled)
        var cache: Data?

        /// Payload returned by the `/usr/bin/security` fallback, nil = miss.
        var securityToolData: Data?

        var interactiveReadCount = 0
        var securityToolReadCount = 0
        var cacheWriteCount = 0

        let defaults: UserDefaults

        init(defaultsSuite: String) {
            defaults = UserDefaults(suiteName: defaultsSuite)!
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        func makeStore(
            filePath: String = "/nonexistent/credentials.json",
            suppressPrompts: Bool = false,
            manualPromptOverrideAllowed: Bool = true
        ) -> ClaudeCredentialStore {
            ClaudeCredentialStore(
                credentialFilePath: filePath,
                cliKeychainService: "test-cli-service",
                io: ClaudeCredentialStore.IO(
                    readFile: { [weak self] _ in
                        MainActor.assumeIsolated { self?.file }
                    },
                    readKeychain: { [weak self] service, allowUI in
                        MainActor.assumeIsolated {
                            guard let self else { return (nil, errSecItemNotFound) }
                            if service == ClaudeCredentialStore.cacheService {
                                return (self.cache, self.cache == nil ? errSecItemNotFound : errSecSuccess)
                            }
                            if allowUI {
                                self.interactiveReadCount += 1
                                return self.cliInteractive
                            }
                            if let data = self.cliData { return (data, errSecSuccess) }
                            return (nil, self.cliNoUIStatus)
                        }
                    },
                    readViaSecurityTool: { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.securityToolReadCount += 1
                            return self?.securityToolData
                        }
                    },
                    writeKeychain: { [weak self] data, _, _ in
                        MainActor.assumeIsolated {
                            self?.cache = data
                            self?.cacheWriteCount += 1
                            return errSecSuccess
                        }
                    }
                ),
                defaults: defaults,
                // Tests run inside an .xctest bundle, which the default
                // policy treats as a dev build and silences — but these
                // tests exercise the interactive path deliberately.
                suppressPrompts: suppressPrompts,
                manualPromptOverrideAllowed: manualPromptOverrideAllowed
            )
        }
    }

    // MARK: - Source precedence

    func testFileWinsAndSeedsCache() {
        let h = Harness(defaultsSuite: #function)
        h.file = Self.credsJSON()

        let result = h.makeStore().load(interactive: false)

        XCTAssertEqual(result?.origin, .file)
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-1")
        XCTAssertEqual(h.cache, h.file, "successful read must be copied into our own cache item")
    }

    func testCLIKeychainNoUIReadSeedsCache() {
        let h = Harness(defaultsSuite: #function)
        h.cliData = Self.credsJSON()

        let result = h.makeStore().load(interactive: false)

        XCTAssertEqual(result?.origin, .cliKeychain)
        XCTAssertEqual(h.cache, h.cliData)
        XCTAssertEqual(h.interactiveReadCount, 0)
    }

    // MARK: - `/usr/bin/security` fallback
    //
    // The CLI rewrites its Keychain item with `security add-generic-password
    // -U` on every token rotation, which resets the item's ACL partition list
    // to `apple-tool:` and makes the in-process no-UI read fail again. These
    // cover the step that keeps that from turning into a password prompt.

    func testSecurityToolServesWhenInProcessReadIsACLBlocked() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.securityToolData = Self.credsJSON(accessToken: "at-rotated")

        let result = h.makeStore().load(interactive: true)

        XCTAssertEqual(result?.origin, .cliSecurityTool)
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-rotated")
        XCTAssertEqual(h.cache, h.securityToolData, "must refresh our own cache copy")
        XCTAssertEqual(h.interactiveReadCount, 0, "the whole point is not prompting")
    }

    /// A successful security-tool read means the item *is* readable, so the
    /// ACL-blocked status must not survive to drive the "needs Keychain
    /// access" messaging or the interactive bootstrap.
    func testSecurityToolSuccessClearsBlockedStatus() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.securityToolData = Self.credsJSON()

        let store = h.makeStore()
        _ = store.load(interactive: true)

        XCTAssertEqual(store.lastCLIStatus, errSecSuccess)
    }

    /// An expired cached copy used to be the trigger for the daily prompt.
    /// With the security tool in the chain it is bypassed entirely.
    func testSecurityToolPreemptsInteractiveBootstrapOverExpiredCache() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cache = Self.expiredCredsJSON()
        h.securityToolData = Self.credsJSON(accessToken: "at-fresh")

        let result = h.makeStore().load(interactive: true)

        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-fresh")
        XCTAssertEqual(h.interactiveReadCount, 0)
    }

    func testSecurityToolNotConsultedWhenInProcessReadSucceeds() {
        let h = Harness(defaultsSuite: #function)
        h.cliData = Self.credsJSON()

        let result = h.makeStore().load(interactive: false)

        XCTAssertEqual(result?.origin, .cliKeychain)
        XCTAssertEqual(h.securityToolReadCount, 0, "no subprocess when the cheap path works")
    }

    /// Falling through the security tool must not change the pre-existing
    /// behaviour of the steps after it.
    func testSecurityToolMissFallsThroughToInteractiveBootstrap() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.securityToolData = nil
        h.cliInteractive = (Self.credsJSON(accessToken: "at-approved"), errSecSuccess)

        let result = h.makeStore().load(interactive: true)

        XCTAssertEqual(h.securityToolReadCount, 1)
        XCTAssertEqual(result?.origin, .cliKeychain)
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-approved")
    }

    func testOwnCacheServesWhenCLIBlocked() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cache = Self.credsJSON(accessToken: "at-cached")

        let result = h.makeStore().load(interactive: false)

        XCTAssertEqual(result?.origin, .ownCache)
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-cached")
    }

    func testExpiredCacheStillServedWithoutInteractive() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cache = Self.expiredCredsJSON()

        let result = h.makeStore().load(interactive: false)

        XCTAssertEqual(result?.origin, .ownCache)
        XCTAssertEqual(result?.credentials.isExpired, true)
        XCTAssertEqual(h.interactiveReadCount, 0)
    }

    // MARK: - Interactive bootstrap

    func testInteractiveBootstrapWhenBlockedAndNoCache() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cliInteractive = (Self.credsJSON(accessToken: "at-boot"), errSecSuccess)

        let result = h.makeStore().load(interactive: true)

        XCTAssertEqual(result?.origin, .cliKeychain)
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-boot")
        XCTAssertEqual(h.interactiveReadCount, 1)
        XCTAssertNotNil(h.cache)
    }

    func testInteractiveAllowedWhenCacheExpired() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cache = Self.expiredCredsJSON()
        h.cliInteractive = (Self.credsJSON(accessToken: "at-rotated"), errSecSuccess)

        let result = h.makeStore().load(interactive: true)

        XCTAssertEqual(result?.origin, .cliKeychain)
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-rotated")
    }

    func testNoInteractiveWhenValidCacheExists() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cache = Self.credsJSON(accessToken: "at-cached")

        let result = h.makeStore().load(interactive: true)

        XCTAssertEqual(result?.origin, .ownCache)
        XCTAssertEqual(h.interactiveReadCount, 0, "a valid cached copy must suppress the prompt")
    }

    func testNoInteractiveWhenItemMissing() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecItemNotFound

        let result = h.makeStore().load(interactive: true)

        XCTAssertNil(result)
        XCTAssertEqual(h.interactiveReadCount, 0, "no item → nothing to prompt for")
    }

    // MARK: - Cooldown & denial backoff

    func testInteractiveCooldownLimitsAttempts() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cliInteractive = (nil, errSecAuthFailed)
        let store = h.makeStore()
        let t0 = Date.now

        XCTAssertNil(store.load(interactive: true, now: t0))
        XCTAssertNil(store.load(interactive: true, now: t0.addingTimeInterval(60)))
        XCTAssertEqual(h.interactiveReadCount, 1, "second attempt within cooldown must be skipped")

        _ = store.load(
            interactive: true,
            now: t0.addingTimeInterval(ClaudeCredentialStore.interactiveCooldown + 1)
        )
        XCTAssertEqual(h.interactiveReadCount, 2, "attempt after cooldown is allowed")
    }

    func testUserDenialPersistsBackoff() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cliInteractive = (nil, errSecUserCanceled)
        let t0 = Date.now

        XCTAssertNil(h.makeStore().load(interactive: true, now: t0))
        XCTAssertEqual(h.interactiveReadCount, 1)

        // A brand-new store (fresh launch) must respect the persisted denial.
        XCTAssertNil(h.makeStore().load(interactive: true, now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(h.interactiveReadCount, 1, "denial backoff must survive across store instances")

        // After the backoff expires, prompting is allowed again.
        _ = h.makeStore().load(
            interactive: true,
            now: t0.addingTimeInterval(ClaudeCredentialStore.denialBackoff + 1)
        )
        XCTAssertEqual(h.interactiveReadCount, 2)
    }

    func testForcedManualAttemptBypassesDevSuppressionAndCooldown() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cliInteractive = (nil, errSecAuthFailed)
        let store = h.makeStore(suppressPrompts: true)
        let t0 = Date.now

        XCTAssertNil(store.load(
            interactive: true,
            forceInteractive: true,
            now: t0
        ))
        XCTAssertEqual(h.interactiveReadCount, 1)

        h.cliInteractive = (Self.credsJSON(accessToken: "at-manual"), errSecSuccess)
        let result = store.load(
            interactive: true,
            forceInteractive: true,
            now: t0.addingTimeInterval(60)
        )

        XCTAssertEqual(h.interactiveReadCount, 2, "each explicit click may retry")
        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-manual")
    }

    func testExplicitNoPromptPolicyStillBlocksForcedManualAttempt() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        h.cliInteractive = (Self.credsJSON(), errSecSuccess)
        let store = h.makeStore(
            suppressPrompts: true,
            manualPromptOverrideAllowed: false
        )

        XCTAssertNil(store.load(interactive: true, forceInteractive: true))
        XCTAssertEqual(h.interactiveReadCount, 0)
    }

    // MARK: - Cache write behavior

    func testCacheNotRewrittenWhenUnchanged() {
        let h = Harness(defaultsSuite: #function)
        h.cliData = Self.credsJSON()
        let store = h.makeStore()

        _ = store.load(interactive: false)
        _ = store.load(interactive: false)
        _ = store.load(interactive: false)

        XCTAssertEqual(h.cacheWriteCount, 1, "identical payloads must not trigger extra Keychain writes")
    }

    func testCacheRewrittenOnRotation() {
        let h = Harness(defaultsSuite: #function)
        h.cliData = Self.credsJSON(accessToken: "at-1")
        let store = h.makeStore()
        _ = store.load(interactive: false)

        h.cliData = Self.credsJSON(accessToken: "at-2")
        let result = store.load(interactive: false)

        XCTAssertEqual(result?.credentials.claudeAiOauth?.accessToken, "at-2")
        XCTAssertEqual(h.cacheWriteCount, 2)
        XCTAssertEqual(h.cache, h.cliData)
    }

    // MARK: - Diagnostics

    func testLastCLIStatusExposed() {
        let h = Harness(defaultsSuite: #function)
        h.cliNoUIStatus = errSecInteractionNotAllowed
        let store = h.makeStore()

        _ = store.load(interactive: false)

        XCTAssertEqual(store.lastCLIStatus, errSecInteractionNotAllowed)
    }

    func testGarbagePayloadYieldsNil() {
        let h = Harness(defaultsSuite: #function)
        h.cliData = Data("not json".utf8)

        XCTAssertNil(h.makeStore().load(interactive: false))
    }

    /// The CLI item can hold MCP-server OAuth state with no `claudeAiOauth`
    /// key (Claude Code 2.1.x) — must be treated as "no credentials", not
    /// crash or cache garbage.
    func testMcpOnlyPayloadYieldsNil() {
        let h = Harness(defaultsSuite: #function)
        h.cliData = Data(#"{"mcpOAuth":{"someServer":{"accessToken":"x"}}}"#.utf8)

        XCTAssertNil(h.makeStore().load(interactive: false))
        XCTAssertNil(h.cache, "non-OAuth payloads must not be cached")
    }
}
