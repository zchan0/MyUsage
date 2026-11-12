import Testing
import Foundation
import Observation
@testable import MyUsage

@Suite("AntigravityProvider Tests")
struct AntigravityProviderTests {

    // MARK: - UserStatus Response Parsing

    @Test("Parse full GetUserStatus response")
    func parseUserStatus() throws {
        let json = """
        {
            "userStatus": {
                "planStatus": {
                    "planInfo": {
                        "planName": "Pro"
                    }
                },
                "cascadeModelConfigData": {
                    "clientModelConfigs": [
                        {
                            "label": "Gemini 3 Pro (High)",
                            "quotaInfo": {
                                "remainingFraction": 0.75,
                                "resetTime": "2026-04-14T20:00:00Z"
                            }
                        },
                        {
                            "label": "Claude Sonnet 4.5",
                            "quotaInfo": {
                                "remainingFraction": 0.2,
                                "resetTime": "2026-04-14T20:00:00Z"
                            }
                        }
                    ]
                },
                "accountEmail": "user@example.com"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)

        #expect(response.userStatus?.planStatus?.planInfo?.planName == "Pro")
        #expect(response.userStatus?.cascadeModelConfigData?.clientModelConfigs?.count == 2)
        #expect(response.userStatus?.accountEmail == "user@example.com")
    }

    // MARK: - Snapshot Mapping

    @Test("Map UserStatus response to snapshot")
    func mapUserStatusSnapshot() {
        let response = AntigravityUserStatusResponse(
            userStatus: .init(
                planStatus: .init(planInfo: .init(planName: "Pro")),
                cascadeModelConfigData: .init(clientModelConfigs: [
                    .init(label: "Gemini 3 Pro", quotaInfo: .init(remainingFraction: 0.75, resetTime: "2026-04-14T20:00:00Z")),
                    .init(label: "Claude Sonnet 4.5", quotaInfo: .init(remainingFraction: 0.2, resetTime: "2026-04-14T20:00:00Z")),
                    .init(label: "GPT-OSS 120B", quotaInfo: .init(remainingFraction: 1.0, resetTime: nil)),
                ]),
                accountEmail: "user@test.com"
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(response)

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.email == "user@test.com")
        #expect(snapshot.modelQuotas.count == 3)
        #expect(snapshot.modelQuotas[0].label == "Gemini 3 Pro")
        #expect(snapshot.modelQuotas[0].remainingFraction == 0.75)
        #expect(snapshot.modelQuotas[0].percentUsed == 25.0)  // 1 - 0.75 = 0.25 → 25%
        #expect(snapshot.modelQuotas[1].percentUsed == 80.0)  // 1 - 0.2 = 0.8 → 80%
        #expect(snapshot.modelQuotas[2].percentUsed == 0.0)   // 1 - 1.0 = 0 → 0%
    }

    @Test("Map fallback model configs response")
    func mapModelConfigsFallback() {
        let response = AntigravityModelConfigsResponse(
            clientModelConfigs: [
                .init(label: "Model A", quotaInfo: .init(remainingFraction: 0.5, resetTime: nil)),
                .init(label: "Model B", quotaInfo: .init(remainingFraction: 0.9, resetTime: nil)),
            ]
        )

        let snapshot = AntigravityProvider.mapConfigsToSnapshot(response)

        #expect(snapshot.planName == nil)
        #expect(snapshot.email == nil)
        #expect(snapshot.modelQuotas.count == 2)
        #expect(snapshot.modelQuotas[0].percentUsed == 50.0)
        #expect(abs(snapshot.modelQuotas[1].percentUsed - 10.0) < 0.01)
    }

    @Test("Skip models with missing quota info")
    func skipMissingQuota() {
        let response = AntigravityUserStatusResponse(
            userStatus: .init(
                planStatus: nil,
                cascadeModelConfigData: .init(clientModelConfigs: [
                    .init(label: "Good Model", quotaInfo: .init(remainingFraction: 0.6, resetTime: nil)),
                    .init(label: nil, quotaInfo: .init(remainingFraction: 0.5, resetTime: nil)),  // missing label
                    .init(label: "No Quota", quotaInfo: nil),  // missing quota
                ]),
                accountEmail: nil
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(response)
        #expect(snapshot.modelQuotas.count == 1)
        #expect(snapshot.modelQuotas[0].label == "Good Model")
    }

    @Test("Worst usage from model quotas")
    func worstUsageFromQuotas() {
        let response = AntigravityUserStatusResponse(
            userStatus: .init(
                planStatus: nil,
                cascadeModelConfigData: .init(clientModelConfigs: [
                    .init(label: "A", quotaInfo: .init(remainingFraction: 0.1, resetTime: nil)),  // 90% used
                    .init(label: "B", quotaInfo: .init(remainingFraction: 0.5, resetTime: nil)),  // 50% used
                ]),
                accountEmail: nil
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(response)
        #expect(snapshot.worstUsagePercent == 90.0)
    }

    // MARK: - RetrieveUserQuotaSummary (Antigravity 2.0+)

    @Test("Parse envelope RetrieveUserQuotaSummary response with Gemini and 3P groups")
    func parseEnvelopeQuotaSummary() throws {
        let json = """
        {
            "response": {
                "groups": [
                    {
                        "displayName": "Gemini Models",
                        "buckets": [
                            {
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.98,
                                "resetTime": "2026-11-24T14:00:00Z"
                            },
                            {
                                "bucketId": "gemini-weekly",
                                "window": "weekly",
                                "remainingFraction": 0.99,
                                "resetTime": "2026-12-01T09:00:00Z"
                            }
                        ]
                    },
                    {
                        "displayName": "Claude and GPT models",
                        "buckets": [
                            {
                                "bucketId": "3p-weekly",
                                "window": "weekly",
                                "remainingFraction": 0.97,
                                "resetTime": "2026-11-27T14:24:00Z"
                            },
                            {
                                "bucketId": "3p-5h",
                                "window": "5h",
                                "remainingFraction": 1.0,
                                "resetTime": "2026-11-24T14:09:00Z"
                            }
                        ]
                    }
                ]
            }
        }
        """
        let summary = try JSONDecoder().decode(
            AntigravityQuotaSummaryResponse.self,
            from: Data(json.utf8)
        )
        let status = AntigravityUserStatusResponse(
            userStatus: .init(
                userTier: .init(id: "ultra", name: "Google AI Ultra"),
                email: "dev@example.com"
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(quotaSummary: summary, userStatus: status)

        #expect(snapshot.planName == "Google AI Ultra")
        #expect(snapshot.email == "dev@example.com")
        #expect(snapshot.modelQuotas.count == 4)

        // 7d is ordered above 5h within each group even when API returned 5h first.
        #expect(snapshot.modelQuotas[0].groupName == "Gemini Models")
        #expect(snapshot.modelQuotas[0].windowLabel == "7d")
        #expect(snapshot.modelQuotas[0].windowDuration == TimeInterval(7 * 86_400))
        #expect(snapshot.modelQuotas[0].bucketId == "gemini-weekly")
        #expect(abs(snapshot.modelQuotas[0].percentUsed - 1.0) < 0.01)

        #expect(snapshot.modelQuotas[1].groupName == "Gemini Models")
        #expect(snapshot.modelQuotas[1].windowLabel == "5h")
        #expect(snapshot.modelQuotas[1].windowDuration == TimeInterval(5 * 3_600))
        #expect(abs(snapshot.modelQuotas[1].percentUsed - 2.0) < 0.01)

        #expect(snapshot.modelQuotas[2].groupName == "Claude and GPT models")
        #expect(snapshot.modelQuotas[2].windowLabel == "7d")
        #expect(abs(snapshot.modelQuotas[2].percentUsed - 3.0) < 0.01)

        #expect(snapshot.modelQuotas[3].groupName == "Claude and GPT models")
        #expect(snapshot.modelQuotas[3].windowLabel == "5h")
        #expect(snapshot.modelQuotas[3].percentUsed == 0.0)

        #expect(snapshot.worstUsage.label == "7d")
        #expect(abs(snapshot.worstUsage.percent - 3.0) < 0.01)
    }

    @Test("Direct quotaGroups handles proto3 omitted zero remainingFraction and skips disabled buckets")
    func parseDirectQuotaSummaryEdgeCases() throws {
        let json = """
        {
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [
                        {
                            "bucketId": "gemini-5h",
                            "displayName": "Five Hour Limit Remaining",
                            "resetTime": "2026-11-24T18:00:00Z"
                        },
                        {
                            "bucketId": "disabled-bucket",
                            "window": "weekly",
                            "remainingFraction": 0.5,
                            "disabled": true
                        }
                    ]
                }
            ]
        }
        """
        let summary = try JSONDecoder().decode(
            AntigravityQuotaSummaryResponse.self,
            from: Data(json.utf8)
        )
        let snapshot = AntigravityProvider.mapQuotaSummaryToSnapshot(summary)

        #expect(snapshot.modelQuotas.count == 1)
        #expect(snapshot.modelQuotas[0].bucketId == "gemini-5h")
        #expect(snapshot.modelQuotas[0].windowLabel == "5h")
        #expect(snapshot.modelQuotas[0].remainingFraction == 0.0)
        #expect(snapshot.modelQuotas[0].percentUsed == 100.0)
    }

    // MARK: - Process & Port Parsing

    @Test("Parse Antigravity 2.0 and legacy IDE processes while ignoring Windsurf")
    func parseAntigravityProcesses() {
        let psOutput = """
          101 /Applications/Windsurf.app/Contents/Resources/bin/language_server_macos_arm64 --csrf_token windsurf-tok --extension_server_port 50001
          202 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token=ag2-token-abc --https_server_port 0
          303 /Users/dev/Antigravity/language_server_macos_arm64 --app_data_dir antigravity --csrf_token legacy-tok --extension_server_port 42100 --https_server_port 42101
          404 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        """

        let processes = ProcessHelper.parseAntigravityProcesses(from: psOutput)
        #expect(processes.count == 2)

        #expect(processes[0] == AntigravityProcessInfo(
            pid: 202,
            csrfToken: "ag2-token-abc",
            httpsPort: nil,
            httpPort: nil
        ))
        #expect(processes[1] == AntigravityProcessInfo(
            pid: 303,
            csrfToken: "legacy-tok",
            httpsPort: 42101,
            httpPort: 42100
        ))
    }

    @Test("Detect hardened Antigravity 2.34+ standalone server without CLI csrf_token and prioritize tokenized ones")
    func parseHardenedStandaloneAntigravityProcess() {
        let psOutput = """
          990 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.35.1 --https_server_port 0 --app_data_dir antigravity --read_host_bridge_token_from_stdin
          303 /Users/dev/Antigravity/language_server_macos_arm64 --app_data_dir antigravity --csrf_token legacy-tok --extension_server_port 42100
        """

        let processes = ProcessHelper.parseAntigravityProcesses(from: psOutput)
        #expect(processes.count == 2)

        // Tokenized process is prioritized first for live Connect-RPC probing.
        #expect(processes[0].pid == 303)
        #expect(processes[0].hasCSRFToken)

        // Hardened 2.35.1 standalone process is still detected so UI doesn't falsely say "not running".
        #expect(processes[1] == AntigravityProcessInfo(
            pid: 990,
            csrfToken: nil,
            httpsPort: nil,
            httpPort: nil,
            ideVersion: "2.35.1",
            usesStdinBridgeToken: true
        ))
        #expect(!processes[1].hasCSRFToken)
        #expect(
            AntigravityProvider.tokenlessStatusMessage(for: processes[1])
                == "Antigravity 2.35.1 is running, but uses a private stdin token; local quota API is unavailable."
        )
    }

    @Test("Parse lsof listening ports deduplicated and sorted")
    func parseListeningPorts() {
        let lsofOutput = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_s  202 dev   10u  IPv4 0x1234      0t0  TCP 127.0.0.1:53210 (LISTEN)
        language_s  202 dev   11u  IPv6 0x1235      0t0  TCP [::1]:53210 (LISTEN)
        language_s  202 dev   12u  IPv4 0x1236      0t0  TCP 127.0.0.1:51100 (LISTEN)
        language_s  202 dev   13u  IPv4 0x1237      0t0  TCP 127.0.0.1:51100->127.0.0.1:60000 (ESTABLISHED)
        """

        #expect(ProcessHelper.parseListeningPorts(from: lsofOutput) == [51100, 53210])
    }

    @Test("Menu bar text is nil when Antigravity snapshot has local usage only (no live quotas)")
    @MainActor
    func menuBarTextOmittedWithoutLiveQuotas() throws {
        final class StubAntigravityProvider: BuiltinUsageProvider {
            let kind: ProviderKind = .antigravity
            var isAvailable = true
            var isEnabled = true
            var snapshot: UsageSnapshot?
            var error: String?
            var isLoading = false
            func refresh() async {}
        }

        let suiteName = "AntigravityMenuBarText-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-menubar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = StubAntigravityProvider()
        var localOnly = UsageSnapshot()
        localOnly.planName = "Antigravity 2.35.1"
        provider.snapshot = localOnly

        let ledger = LedgerSync(
            store: try LedgerStore(path: LedgerStore.inMemoryPath),
            syncRoot: LocalSyncRoot(url: tempDir)
        )
        let manager = UsageManager(ledger: ledger, providers: [provider], startsLedger: false, defaults: defaults)
        #expect(manager.menuBarText(for: .antigravity) == nil)

        var withQuotas = UsageSnapshot()
        withQuotas.modelQuotas = [
            ModelQuota(label: "Gemini", remainingFraction: 0.26, resetsAt: nil)
        ]
        provider.snapshot = withQuotas
        #expect(manager.menuBarText(for: .antigravity) == "74%")
    }

    // MARK: - Statusline Integration

    @Test("Statusline lifecycle: notConnected → waiting → valid → disabled → invalid")
    @MainActor
    func statuslineSetupWaitingValidAndInvalid() async throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        let now = f.now
        let provider = AntigravityProvider(
            directory: f.directory,
            bridge: f.bridge,
            logRoots: [],
            now: { now },
            processFinder: { [] },
            hasLocalInstallation: { false }
        )

        #expect(provider.statuslineDataState == .notConnected)
        #expect(provider.quotaSource == .none)
        #expect(!provider.isAvailable)
        #expect(!provider.isNotificationEligible)
        #expect(!FileManager.default.fileExists(atPath: f.settings.path))

        try f.bridge.enable()
        await provider.refresh(trigger: .automatic)
        #expect(provider.statuslineDataState == .waiting)
        #expect(provider.quotaSource == .statusline)
        #expect(provider.isAvailable)
        #expect(!provider.isNotificationEligible)
        #expect(provider.snapshot?.modelQuotas.isEmpty == true)

        try f.store.write(f.input(quota: ""), now: now)
        await provider.refresh(trigger: .manual)
        #expect(provider.statuslineDataState == .waiting)
        #expect(!provider.isNotificationEligible)

        try f.store.write(f.input(), now: now)
        await provider.refresh(trigger: .manual)
        #expect(provider.statuslineDataState == .valid)
        #expect(provider.quotaSource == .statusline)
        #expect(provider.error == nil)
        #expect(provider.isNotificationEligible)

        let snap = try #require(provider.snapshot)
        #expect(snap.planName == "Google AI Ultra")
        #expect(snap.email == "synthetic@example.com")
        #expect(snap.lastRefreshed == now)
        #expect(snap.modelQuotas.count == 4)
        // Canonical ordering: Gemini Models (7d then 5h), then Claude & GPT Models (7d then 5h).
        #expect(snap.modelQuotas[0].groupName == "Gemini Models")
        #expect(snap.modelQuotas[0].windowLabel == "7d")
        #expect(snap.modelQuotas[0].windowDuration == TimeInterval(7 * 86_400))
        #expect(snap.modelQuotas[0].bucketId == "gemini-weekly")
        #expect(abs(snap.modelQuotas[0].percentUsed - 15.0) < 0.01)

        #expect(snap.modelQuotas[1].groupName == "Gemini Models")
        #expect(snap.modelQuotas[1].windowLabel == "5h")
        #expect(snap.modelQuotas[1].windowDuration == TimeInterval(5 * 3_600))
        #expect(abs(snap.modelQuotas[1].percentUsed - 23.5) < 0.01)

        #expect(snap.modelQuotas[2].groupName == "Claude & GPT Models")
        #expect(snap.modelQuotas[2].windowLabel == "7d")
        #expect(abs(snap.modelQuotas[2].percentUsed - 41.0) < 0.01)

        #expect(snap.modelQuotas[3].groupName == "Claude & GPT Models")
        #expect(snap.modelQuotas[3].windowLabel == "5h")
        #expect(snap.modelQuotas[3].percentUsed == 0.0)
        #expect(provider.statuslineSourceMessage.contains("Received locally"))

        // Disabling retains the dated snapshot while suppressing new notifications.
        try f.bridge.disable()
        await provider.refresh(trigger: .manual)
        #expect(provider.statuslineDataState == .notConnected)
        #expect(provider.quotaSource == .statusline)
        #expect(!provider.isNotificationEligible)
        #expect(provider.snapshot?.modelQuotas.count == 4)

        // Re-enabling then editing settings externally yields invalid state without touching settings.
        try f.bridge.enable()
        try f.writeSettings(["statusLine": ["type": "command", "command": "echo user-edit"]])
        let before = try Data(contentsOf: f.settings)
        await provider.refresh(trigger: .manual)
        #expect(provider.statuslineDataState == .invalid)
        #expect(!provider.isNotificationEligible)
        #expect(try Data(contentsOf: f.settings) == before)
    }

    @Test("Statusline serves as seamless fallback when Antigravity 2.35+ uses private stdin token")
    @MainActor
    func statuslineFallbackWithTokenlessProcess() async throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        let now = f.now
        let tokenless = AntigravityProcessInfo(
            pid: 990,
            csrfToken: nil,
            ideVersion: "2.35.1",
            usesStdinBridgeToken: true
        )
        let provider = AntigravityProvider(
            directory: f.directory,
            bridge: f.bridge,
            logRoots: [],
            now: { now },
            processFinder: { [tokenless] },
            hasLocalInstallation: { true }
        )

        await provider.refresh(trigger: .automatic)
        #expect(provider.quotaSource == .none)
        #expect(!provider.isNotificationEligible)
        #expect(provider.error?.contains("private stdin token") == true)
        #expect(provider.snapshot?.planName == "Antigravity 2.35.1")

        try f.bridge.enable()
        try f.store.write(f.input(planTier: nil, email: nil), now: now)
        await provider.refresh(trigger: .manual)
        #expect(provider.quotaSource == .statusline)
        #expect(provider.statuslineDataState == .valid)
        #expect(provider.error == nil)
        #expect(provider.isNotificationEligible)
        #expect(provider.snapshot?.modelQuotas.count == 4)
        #expect(provider.snapshot?.planName == "Antigravity 2.35.1")
    }

    @Test("Stale receipts, clock skew, expired buckets, and menu-bar text behavior")
    @MainActor
    func statuslineStaleExpiryAndMenuBar() async throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        try f.bridge.enable()
        try f.store.write(f.input(), now: f.now)

        // Age > 15m and future clock (< -60s) are explicitly stale.
        for date in [f.now.addingTimeInterval(901), f.now.addingTimeInterval(-120)] {
            let provider = AntigravityProvider(
                directory: f.directory,
                bridge: f.bridge,
                logRoots: [],
                now: { date },
                processFinder: { [] },
                hasLocalInstallation: { false }
            )
            #expect(provider.statuslineDataState == .stale)
            #expect(!provider.isNotificationEligible)
        }

        // After 5h buckets expire, only 7d buckets remain and menu bar still shows worst active window.
        let afterFiveHour = f.now.addingTimeInterval(3601)
        let staleProvider = AntigravityProvider(
            directory: f.directory,
            bridge: f.bridge,
            logRoots: [],
            now: { afterFiveHour },
            processFinder: { [] },
            hasLocalInstallation: { false }
        )
        #expect(staleProvider.statuslineDataState == .stale)
        #expect(staleProvider.snapshot?.modelQuotas.count == 2)
        #expect(staleProvider.snapshot?.modelQuotas.allSatisfy { $0.windowLabel == "7d" } == true)

        let suite = "antigravity-statusline-menubar-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = LedgerSync(store: try LedgerStore(path: LedgerStore.inMemoryPath), syncRoot: LocalSyncRoot(url: f.root))
        let manager = UsageManager(ledger: ledger, providers: [staleProvider], startsLedger: false, defaults: defaults)
        #expect(manager.menuBarText(for: .antigravity) == "7d · 41%")

        // After all buckets expire, snapshot has no active quotas and menu bar text is nil.
        let afterAllResets = f.now.addingTimeInterval(600_000)
        let expiredProvider = AntigravityProvider(
            directory: f.directory,
            bridge: f.bridge,
            logRoots: [],
            now: { afterAllResets },
            processFinder: { [] },
            hasLocalInstallation: { false }
        )
        let managerExpired = UsageManager(ledger: ledger, providers: [expiredProvider], startsLedger: false, defaults: defaults)
        #expect(expiredProvider.snapshot?.modelQuotas.isEmpty == true)
        #expect(managerExpired.menuBarText(for: .antigravity) == nil)
    }

    @Test("Local statusline bucket reset notifies observers without refreshing")
    @MainActor
    func statuslineLocalResetNotifiesWithoutRefreshing() async throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        try f.bridge.enable()
        let reset = Date.now.addingTimeInterval(0.5).timeIntervalSince1970
        try f.store.write(f.input(quota: "\"gemini-5h\":{\"remaining_fraction\":0.58,\"resets_at\":\(reset)}"))
        let provider = AntigravityProvider(
            directory: f.directory,
            bridge: f.bridge,
            logRoots: [],
            processFinder: { [] },
            hasLocalInstallation: { false }
        )
        let invalidations = InvalidationCounter()
        withObservationTracking {
            #expect(provider.snapshot?.modelQuotas.count == 1)
            #expect(provider.statuslineDataState == .valid)
        } onChange: {
            Task { await invalidations.record() }
        }
        let deadline = Date.now.addingTimeInterval(3)
        while await invalidations.count == 0 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await invalidations.count == 1)
        #expect(provider.snapshot?.modelQuotas.isEmpty == true)
        #expect(provider.statuslineDataState == .stale)
        #expect(!provider.isNotificationEligible)
    }

    private actor InvalidationCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

}
