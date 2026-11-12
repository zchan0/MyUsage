import Foundation
import Observation
import Testing
@testable import MyUsage

@Suite("Claude local statusline provider")
struct ClaudeProviderTests {
    @Test @MainActor
    func setupWaitingValidAndPartial() async throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        let now = fixture.now
        let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [],
                                      costCacheURL: fixture.root.appendingPathComponent("cost.json"),
                                      accountURL: fixture.accountURL, now: { now })
        #expect(provider.dataState == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: fixture.settings.path))
        try fixture.bridge.enable()
        await provider.refresh(trigger: .automatic)
        #expect(provider.dataState == .waiting)
        try fixture.store.write(fixture.input(limits: ""), now: now)
        await provider.refresh(trigger: .manual)
        #expect(provider.dataState == .waiting)
        #expect(provider.snapshot?.sessionUsage == nil)
        try fixture.store.write(fixture.input(limits: "\"seven_day\":{\"used_percentage\":0,\"resets_at\":1800500000}"), now: now)
        await provider.refresh(trigger: .manual)
        #expect(provider.dataState == .valid)
        #expect(provider.snapshot?.sessionUsage == nil)
        #expect(provider.snapshot?.weeklyUsage?.percentUsed == 0)
        #expect(provider.snapshot?.email == nil)
        #expect(provider.snapshot?.planName == nil)
        #expect(provider.snapshot?.monthlyEstimatedCost == 0)
        #expect(provider.snapshot?.weeklyByModel.isEmpty == true)
        #expect(provider.snapshot?.lastRefreshed == now)
        #expect(provider.sourceMessage.contains("Received locally"))
    }

    @Test("Claude menu-bar labels omit snapshot state", arguments: [false, true])
    @MainActor
    func menuBarOmitsSnapshotState(stale: Bool) throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        let now = fixture.now
        try fixture.bridge.enable()
        try fixture.store.write(fixture.input(), now: stale ? now.addingTimeInterval(-901) : now)
        let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [],
                                      accountURL: fixture.accountURL, now: { now })
        let suite = "claude-menu-bar-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = LedgerSync(store: try LedgerStore(path: LedgerStore.inMemoryPath),
                                syncRoot: LocalSyncRoot(url: fixture.root))
        let manager = UsageManager(ledger: ledger, providers: [provider], startsLedger: false, defaults: defaults)
        manager.iconTrackProvider = provider.id.rawValue
        #expect(provider.dataState == (stale ? .stale : .valid))
        #expect(manager.menuBarText(for: .claude) == "7d · 41%")
        #expect(manager.menuBarText(for: provider.id) == "7d · 41%")
        #expect(manager.menuBarDisplayText == "7d · 41%")
    }

    @Test @MainActor
    func staleAndExpiredWindowsNeverBecomeCurrent() async throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        try fixture.bridge.enable()
        let receipt = try ClaudeStatuslineSnapshot.capture(fixture.input(), receivedAt: fixture.now)
        let afterFiveHourReset = fixture.now.addingTimeInterval(3601)
        let mapped = ClaudeProvider.mapToSnapshot(receipt, now: afterFiveHourReset)
        #expect(mapped.sessionUsage == nil)
        #expect(mapped.weeklyUsage?.percentUsed == 41.2)
        try fixture.store.write(fixture.input(), now: fixture.now)
        let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [],
                                      costCacheURL: fixture.root.appendingPathComponent("cost.json"),
                                      accountURL: fixture.accountURL, now: { afterFiveHourReset })
        #expect(provider.dataState == .stale)
        #expect(provider.snapshot?.lastRefreshed == fixture.now)
        #expect(provider.snapshot?.sessionUsage == nil)
        await provider.refresh(trigger: .manual)
        #expect(provider.snapshot?.lastRefreshed == fixture.now)
        try fixture.bridge.disable()
        await provider.refresh()
        #expect(provider.dataState == .notConnected)
        #expect(provider.sourceMessage.contains("Received locally"))
        let afterAllResets = ClaudeProvider.mapToSnapshot(receipt, now: fixture.now.addingTimeInterval(600_000))
        #expect(afterAllResets.weeklyUsage == nil)
        #expect(afterAllResets.sessionUsage == nil)
    }

    @Test @MainActor
    func receiptAgeAndFutureClockAreExplicitlyStale() throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        try fixture.bridge.enable()
        try fixture.store.write(fixture.input(), now: fixture.now)
        for date in [fixture.now.addingTimeInterval(901), fixture.now.addingTimeInterval(-120)] {
            let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [], accountURL: fixture.accountURL, now: { date })
            #expect(provider.dataState == .stale)
        }
    }

    @Test func mapsOnlyActiveResetCreditsAndSortsByExpiryThenID() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let receivedAt = now.addingTimeInterval(-60)
        let input = Data("""
        {"session_id":"synthetic-session","version":"2.1.synthetic","cedar_ember":{"grants":[
            {"id":"no-expiry","resets_left":1,"label":"Anytime"},
            {"id":"later","resets_left":2,"ends_at":1800000600},
            {"id":"early-b","resets_left":1,"ends_at":1800000300},
            {"id":"early-a","resets_left":3,"ends_at":1800000300,"label":"  Weekly boost  "},
            {"id":"zero","resets_left":0,"ends_at":1800000100},
            {"id":"unusable","resets_left":2,"usable_now":false},
            {"id":"expired","resets_left":5,"ends_at":1800000000}
        ]}}
        """.utf8)
        let receipt = try ClaudeStatuslineSnapshot.capture(input, receivedAt: receivedAt)
        let inventory = try #require(ClaudeProvider.mapToSnapshot(receipt, now: now).resetCredits)
        #expect(inventory.reportedAvailableCount == 7)
        #expect(inventory.availableCredits.map(\.id) == ["early-a", "early-b", "later", "no-expiry"])
        #expect(inventory.availableCredits.map(\.label) == ["Weekly boost", nil, nil, "Anytime"])
        let grants = try #require(receipt.resetCredits)
        let countsByID = Dictionary(uniqueKeysWithValues: grants.map { ($0.id, $0.resetsLeft) })
        #expect(inventory.availableCredits.allSatisfy { $0.count == countsByID[$0.id] })
        #expect(inventory.availableCredits.allSatisfy { $0.grantedAt == nil })
        #expect(inventory.availableCredits.last?.expiresAt == nil)
        #expect(inventory.earliestExpiration == now.addingTimeInterval(300))
        #expect(inventory.fetchedAt == receivedAt)
    }

    @Test func omitsInventoryWithoutActiveGrants() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let variants: [[ClaudeStatuslineSnapshot.ResetCreditGrant]?] = [
            nil,
            [.init(id: "expired", label: nil, resetsLeft: 1, endsAt: now.timeIntervalSince1970, usableNow: true)]
        ]
        for grants in variants {
            let receipt = ClaudeStatuslineSnapshot(schemaVersion: 1, receivedAt: now.timeIntervalSince1970,
                sessionID: "synthetic-session", claudeCodeVersion: "2.1.synthetic",
                rateLimits: .init(fiveHour: nil, sevenDay: nil), resetCredits: grants)
            #expect(ClaudeProvider.mapToSnapshot(receipt, now: now).resetCredits == nil)
        }
    }

    @Test @MainActor
    func managerRefreshesMissingCorruptAndChangedSettingsWithoutRecoverySideEffects() async throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        let now = fixture.now
        let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [],
                                      costCacheURL: fixture.root.appendingPathComponent("cost.json"),
                                      accountURL: fixture.accountURL, now: { now })
        let suite = "claude-manager-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = LedgerSync(store: try LedgerStore(path: LedgerStore.inMemoryPath), syncRoot: LocalSyncRoot(url: fixture.root))
        let manager = UsageManager(ledger: ledger, providers: [provider], startsLedger: false, defaults: defaults)
        provider.isEnabled = true
        for trigger in [UsageRefreshTrigger.automatic, .manual] {
            await manager.refreshAll(trigger: trigger)
            #expect(provider.dataState == .notConnected)
            #expect(manager.menuBarText(for: .claude) == nil)
        }
        try fixture.bridge.enable()
        try fixture.store.write(fixture.input(), now: now)
        let file = try #require(FileManager.default.contentsOfDirectory(at: fixture.store.snapshotsDirectory,
                           includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        try ClaudePrivateFiles.atomicWrite(Data("broken".utf8), to: file)
        for trigger in [UsageRefreshTrigger.automatic, .manual] {
            await manager.refreshAll(trigger: trigger)
            #expect(provider.dataState == .invalid)
            #expect(provider.snapshot?.sessionUsage == nil)
        }
        let edited = ["statusLine": ["type": "command", "command": "echo user-edit"]]
        try fixture.writeSettings(edited)
        let settingsBefore = try Data(contentsOf: fixture.settings)
        await manager.refreshAll(trigger: .manual)
        #expect(provider.dataState == .invalid)
        #expect(try Data(contentsOf: fixture.settings) == settingsBefore)
    }

    @Test @MainActor
    func localResetNotifiesMenuBarWithoutRefreshing() async throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        try f.bridge.enable()
        let reset = Date.now.addingTimeInterval(0.5).timeIntervalSince1970
        try f.store.write(f.input(limits: "\"five_hour\":{\"used_percentage\":42,\"resets_at\":\(reset)}"))
        let provider = ClaudeProvider(directory: f.directory, bridge: f.bridge, logRoots: [], accountURL: f.accountURL)
        let invalidations = InvalidationCounter()
        withObservationTracking {
            #expect(provider.snapshot?.sessionUsage?.percentUsed == 42)
        } onChange: {
            Task { await invalidations.record() }
        }
        // Wait for observation delivery as well as the reset; both tasks can be delayed under load.
        let deadline = Date.now.addingTimeInterval(3)
        while await invalidations.count == 0 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await invalidations.count == 1)
        #expect(provider.snapshot?.sessionUsage == nil)
        #expect(provider.dataState == .stale)
    }

    private actor InvalidationCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test("Claude runtime has no credential, HTTP or CLI recovery dependencies")
    func retiredPathsStayRemoved() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Providers/ClaudeProvider.swift", "Services/ClaudeStatuslineSnapshot.swift", "Services/ClaudeStatuslineBridge.swift", "Services/ClaudeLocalAccount.swift"] {
            let text = try String(contentsOf: repo.appendingPathComponent("MyUsage/" + name), encoding: .utf8)
            for forbidden in ["URLSession", "URLRequest", "KeychainHelper", "SecItem", "Process()", "ClaudeCredentialStore", "ClaudeDelegatedRefresh", "/api/oauth/", "auth status", "[\"/status\"]"] {
                #expect(!text.contains(forbidden), "\(name) contains retired dependency: \(forbidden)")
            }
        }
        for name in ["ClaudeCredentialStore", "ClaudeDelegatedRefresh", "ClaudeUsageCache"] {
            #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("MyUsage/Services/\(name).swift").path))
        }
    }

    @Test @MainActor
    func costsKeepDailyStorageKeysWithoutReusingAccountIdentityOrDuplicatingHistory() async throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        let date = Date.now
        let days = (0..<3).map { LedgerCalendar.dayKey(for: date.addingTimeInterval(Double(-86400 * $0))) }
        let logs = f.root.appendingPathComponent("synthetic-logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let rows = (0..<3).map { i in
            let timestamp = ISO8601DateFormatter().string(from: date.addingTimeInterval(Double(-86400 * i)))
            return """
            {"type":"assistant","timestamp":"\(timestamp)","costUSD":2,"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":1}}}
            """
        }.joined(separator: "\n")
        try Data(rows.utf8).write(to: logs.appendingPathComponent("session.jsonl"))
        let store = try LedgerStore(path: LedgerStore.inMemoryPath)
        let ledger = LedgerSync(store: store, syncRoot: LocalSyncRoot(url: f.root.appendingPathComponent("sync")))
        let oldDate = date.addingTimeInterval(-100)
        _ = try store.upsert([
            LedgerEntry(deviceId: ledger.selfDeviceID, accountId: "legacy-storage-key", provider: .claude,
                        day: days[0], costUSD: 0.5, recordedAt: oldDate),
            LedgerEntry(deviceId: ledger.selfDeviceID, accountId: "legacy-a", provider: .claude,
                        day: days[2], costUSD: 1, recordedAt: oldDate),
            LedgerEntry(deviceId: ledger.selfDeviceID, accountId: "legacy-b", provider: .claude,
                        day: days[2], costUSD: 2, recordedAt: oldDate),
            LedgerEntry(deviceId: ledger.selfDeviceID, accountId: "other-provider", provider: .codex,
                        day: days[0], costUSD: 9, recordedAt: oldDate)
        ])
        let provider = ClaudeProvider(ledger: ledger, directory: f.directory, bridge: f.bridge, logRoots: [logs],
                                      costCacheURL: f.root.appendingPathComponent("cost.json"), accountURL: f.accountURL)
        await provider.refresh(trigger: .manual)
        await provider.refresh(trigger: .automatic)
        let entries = try store.entries(forDevice: ledger.selfDeviceID)
        let claude = entries.filter { $0.provider == "claude" }
        #expect(claude.count == 4)
        #expect(claude.first { $0.day == days[0] }?.accountId == "legacy-storage-key")
        #expect(claude.first { $0.day == days[0] }?.costUSD == 2)
        #expect(claude.first { $0.day == days[0] }?.tokenUsage?.input == 10)
        #expect(claude.first { $0.day == days[1] }?.accountId == "default")
        #expect(claude.filter { $0.day == days[2] }.map(\.costUSD).sorted() == [1, 2])
        #expect(entries.first { $0.provider == "codex" }?.costUSD == 9)
        #expect(provider.snapshot?.localUsage?.summary30d.reportedCostUSD == 6)
        #expect(provider.snapshot?.localUsage?.summary30d.totalTokens == 33)
        #expect(provider.snapshot?.email == nil)
        #expect(provider.snapshot?.planName == nil)
        #expect(provider.sourceMessage.contains("Ambiguous legacy cost days were preserved"))
    }
}
