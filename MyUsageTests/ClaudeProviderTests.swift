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
                                      costCacheURL: fixture.root.appendingPathComponent("cost.json"), now: { now })
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
                                      costCacheURL: fixture.root.appendingPathComponent("cost.json"), now: { afterFiveHourReset })
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
            let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [], now: { date })
            #expect(provider.dataState == .stale)
        }
    }

    @Test @MainActor
    func managerRefreshesMissingCorruptAndChangedSettingsWithoutRecoverySideEffects() async throws {
        let fixture = try ClaudeStatuslineFixture()
        defer { fixture.cleanup() }
        let now = fixture.now
        let provider = ClaudeProvider(directory: fixture.directory, bridge: fixture.bridge, logRoots: [],
                                      costCacheURL: fixture.root.appendingPathComponent("cost.json"), now: { now })
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
        let provider = ClaudeProvider(directory: f.directory, bridge: f.bridge, logRoots: [])
        let invalidations = InvalidationCounter()
        withObservationTracking {
            #expect(provider.snapshot?.sessionUsage?.percentUsed == 42)
        } onChange: {
            Task { await invalidations.record() }
        }
        try await Task.sleep(for: .milliseconds(750))
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
        for name in ["Providers/ClaudeProvider.swift", "Services/ClaudeStatuslineSnapshot.swift", "Services/ClaudeStatuslineBridge.swift"] {
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
                                      costCacheURL: f.root.appendingPathComponent("cost.json"))
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
        #expect(provider.snapshot?.email == nil)
        #expect(provider.snapshot?.planName == nil)
        #expect(provider.sourceMessage.contains("Ambiguous legacy cost days were preserved"))
    }
}
