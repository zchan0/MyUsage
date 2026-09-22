import XCTest
@testable import MyUsage

@MainActor
final class MemoryGatewayCredentials: GatewayCredentialStore {
    var keys: [String: String] = [:]
    var failWrites = false
    var failDeletes = false
    func read(_ reference: String) throws -> String {
        guard let key = keys[reference] else { throw GatewayIssue.missingCredential }
        return key
    }
    func write(_ key: String, reference: String) throws {
        if failWrites { throw GatewayStoreError.keychain }
        keys[reference] = key
    }
    func delete(_ reference: String) throws {
        if failDeletes { throw GatewayStoreError.keychain }
        keys.removeValue(forKey: reference)
    }
}

private actor StateGatewayAdapter: GatewayAdapter {
    var summaryResults: [GatewayBlock<GatewaySummary>]
    var summaryCalls = 0
    var historyCalls = 0
    var suspended = false
    var pending: CheckedContinuation<GatewayBlock<GatewaySummary>, Never>?
    init(_ results: [GatewayBlock<GatewaySummary>] = [], suspended: Bool = false) {
        summaryResults = results; self.suspended = suspended
    }
    func checkConnection(_ context: GatewayRequestContext) async throws -> GatewayConnectionCheck {
        .init(checkedAt: .now, scopes: [], issues: [.identityUnknown])
    }
    func fetchSummary(_ context: GatewayRequestContext) async throws -> GatewayBlock<GatewaySummary> {
        summaryCalls += 1
        if suspended { return await withCheckedContinuation { pending = $0 } }
        return summaryResults.isEmpty ? .init(issue: .network) : summaryResults.removeFirst()
    }
    func fetchHistory(_ context: GatewayRequestContext, start: String, end: String, probe: Bool) async throws -> GatewayBlock<GatewayHistory> {
        historyCalls += 1
        return .init(issue: .forbidden)
    }
    func resume(with result: GatewayBlock<GatewaySummary>) { pending?.resume(returning: result); pending = nil }
    func isPending() -> Bool { pending != nil }
}

final class GatewayStateTests: XCTestCase, @unchecked Sendable {
    @MainActor private func isolatedDefaults() -> UserDefaults {
        let name = "MyUsageTests.gateway.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func connection(_ name: String = "Company") -> GatewayConnection {
        .init(name: name, baseURL: URL(string: "https://gateway.example.test")!, scope: .init(kind: .user, id: "fixture-user"))
    }
    private func summary(spend: Decimal = 42) -> GatewayBlock<GatewaySummary> {
        .init(value: .init(scope: .init(kind: .user, id: "fixture-user"), spend: spend, budget: .finite(100),
                           currency: "USD", budgetDuration: "30d", resetsAt: nil), updatedAt: Date(timeIntervalSince1970: 1234))
    }
    @MainActor
    func testConfigurationContainsOnlyCredentialReferenceAndInstancesAreIndependent() throws {
        let defaults = isolatedDefaults(), keys = MemoryGatewayCredentials()
        let store = GatewayConnectionStore(defaults: defaults, credentials: keys)
        let first = try store.save(connection(), newKey: "fixture-key-one")
        let second = try store.save(connection(), newKey: "fixture-key-two")
        XCTAssertNotEqual(first.providerID, second.providerID)
        XCTAssertNotEqual(first.credentialReference, second.credentialReference)
        let encoded = String(data: try XCTUnwrap(defaults.data(forKey: "gateway.connections.v1")), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("fixture-key"))
        var renamed = first; renamed.name = "Renamed"
        let saved = try store.save(renamed, newKey: nil)
        XCTAssertEqual(saved.id, first.id)
        XCTAssertEqual(saved.credentialReference, first.credentialReference)
        try store.remove(first.id)
        XCTAssertEqual(try store.load(), [second])
        XCTAssertEqual(keys.keys, [second.credentialReference: "fixture-key-two"])
    }
    @MainActor
    func testHostChangeRequiresNewKeyAndFailedWritePreservesOriginal() throws {
        let keys = MemoryGatewayCredentials(), store = GatewayConnectionStore(defaults: isolatedDefaults(), credentials: keys)
        let original = try store.save(connection(), newKey: "fixture-original")
        var edited = original; edited.baseURL = URL(string: "https://other.example.test")!
        XCTAssertThrowsError(try store.save(edited, newKey: nil))
        keys.failWrites = true
        XCTAssertThrowsError(try store.save(edited, newKey: "fixture-replacement"))
        XCTAssertEqual(try store.load(), [original])
        XCTAssertEqual(keys.keys, [original.credentialReference: "fixture-original"])
        keys.failWrites = false
        let saved = try store.save(edited, newKey: "fixture-replacement")
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(keys.keys, [saved.credentialReference: "fixture-replacement"])
    }
    @MainActor
    func testUnreadableConfigurationAndFailedDeletionArePreserved() throws {
        let defaults = isolatedDefaults(), keys = MemoryGatewayCredentials()
        let store = GatewayConnectionStore(defaults: defaults, credentials: keys)
        let original = try store.save(connection(), newKey: "fixture-key")
        keys.failDeletes = true
        XCTAssertThrowsError(try store.remove(original.id))
        XCTAssertEqual(try store.load(), [original])
        let invalid = Data("{\"version\":99,\"connections\":[]}".utf8)
        defaults.set(invalid, forKey: "gateway.connections.v1")
        XCTAssertThrowsError(try store.save(connection(), newKey: "fixture-another"))
        XCTAssertEqual(defaults.data(forKey: "gateway.connections.v1"), invalid)
        XCTAssertEqual(keys.keys.count, 1)
    }
    @MainActor
    func testRefreshFailureRetainsPreviousValueAndHistoryFailureIsIndependent() async {
        let keys = MemoryGatewayCredentials(), connection = connection()
        keys.keys[connection.credentialReference] = "fixture-key"
        let adapter = StateGatewayAdapter([summary(), .init(issue: .network)])
        let provider = GatewayProvider(connection: connection, credentials: keys, adapter: adapter)
        await provider.refresh()
        await provider.loadHistory()
        XCTAssertEqual(provider.snapshot.summary.value?.spend, 42)
        XCTAssertNil(provider.snapshot.summary.issue)
        XCTAssertEqual(provider.snapshot.history.issue, .forbidden)
        await provider.refresh()
        XCTAssertEqual(provider.snapshot.summary.value?.spend, 42)
        XCTAssertEqual(provider.snapshot.summary.updatedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(provider.snapshot.summary.issue, .network)
        await provider.loadHistory()
        let calls = await adapter.historyCalls
        XCTAssertEqual(calls, 1, "Forbidden history uses the same cache TTL instead of repeatedly probing")
    }
    @MainActor
    func testCancelledOldCredentialResponseCannotRestoreData() async {
        let keys = MemoryGatewayCredentials()
        var connection = connection()
        keys.keys[connection.credentialReference] = "fixture-key"
        let adapter = StateGatewayAdapter(suspended: true)
        let provider = GatewayProvider(connection: connection, credentials: keys, adapter: adapter)
        let refresh = Task { await provider.refresh() }
        for _ in 0..<1000 {
            if await adapter.isPending() { break }
            await Task.yield()
        }
        let pending = await adapter.isPending()
        XCTAssertTrue(pending)
        connection.credentialReference = "new-reference"
        keys.keys[connection.credentialReference] = "fixture-new-key"
        provider.update(connection)
        await adapter.resume(with: summary()) // Simulate a transport that ignores cancellation.
        await refresh.value
        XCTAssertNil(provider.snapshot.summary.value)
        XCTAssertFalse(provider.isLoading)
        XCTAssertEqual(provider.snapshot.summary.issue, .notChecked)
    }
    @MainActor
    func testRenameKeepsDataButExplicitIdentityChangeInvalidatesDraft() async {
        let keys = MemoryGatewayCredentials()
        var connection = connection(); connection.scope = nil
        let initial = GatewayScopeCheck(scope: .init(kind: .user, id: "fixture-user"), summary: summary(), history: .init())
        connection.scope = initial.scope
        let provider = GatewayProvider(connection: connection, credentials: keys, initial: initial)
        connection.name = "Personal"; provider.update(connection)
        XCTAssertEqual(provider.snapshot.summary.value?.spend, 42)
        XCTAssertEqual(provider.displayName, "Personal")
        connection.scope = nil; provider.update(connection)
        XCTAssertNil(provider.snapshot.summary.value)
    }
    @MainActor
    func testRateLimitPreventsManualAndAutomaticRetries() async {
        let keys = MemoryGatewayCredentials(), connection = connection()
        keys.keys[connection.credentialReference] = "fixture-key"
        let adapter = StateGatewayAdapter([.init(issue: .rateLimited(until: .now.addingTimeInterval(60)))])
        let provider = GatewayProvider(connection: connection, credentials: keys, adapter: adapter)
        await provider.refresh(); await provider.refresh(trigger: .manual); await provider.loadHistory(force: true)
        let summaryCalls = await adapter.summaryCalls, historyCalls = await adapter.historyCalls
        XCTAssertEqual(summaryCalls, 1); XCTAssertEqual(historyCalls, 0)
    }
    @MainActor
    func testManagerMigratesBuiltinsAndKeepsGatewayOrderingAndEnablementSeparate() throws {
        let defaults = isolatedDefaults(), keys = MemoryGatewayCredentials()
        defaults.set(["codex", "claude"], forKey: "providerOrder")
        defaults.set("codex", forKey: "iconTrackProvider")
        defaults.set(false, forKey: "provider.claude.enabled")
        let store = GatewayConnectionStore(defaults: defaults, credentials: keys)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledger = LedgerSync(store: try LedgerStore(path: LedgerStore.inMemoryPath), syncRoot: LocalSyncRoot(url: temp))
        let manager = UsageManager(ledger: ledger, providers: PreviewFixtures.allProviders, startsLedger: false, defaults: defaults, gatewayStore: store)
        XCTAssertEqual(manager.iconTrackProvider, "builtin:codex")
        XCTAssertEqual(manager.orderedProviders.first?.id, .builtin(.codex))
        XCTAssertEqual(manager.providers.first { $0.id == .builtin(.claude) }?.isEnabled, false)
        let first = connection(), second = connection()
        try manager.saveGateway(first, newKey: "fixture-one", initial: nil)
        try manager.saveGateway(second, newKey: "fixture-two", initial: nil)
        let p1 = try XCTUnwrap(manager.providers.first { $0.id == first.providerID })
        let p2 = try XCTUnwrap(manager.providers.first { $0.id == second.providerID })
        manager.setEnabled(false, for: p1)
        XCTAssertTrue(p2.isEnabled)
        manager.iconTrackProvider = second.providerID.rawValue
        manager.moveProvider(from: IndexSet(integer: 5), to: 0)
        XCTAssertEqual(manager.orderedProviders.first?.id, second.providerID)
        var renamed = second; renamed.name = "Renamed"
        try manager.saveGateway(renamed, newKey: nil, initial: nil)
        XCTAssertEqual(manager.iconTrackProvider, second.providerID.rawValue)
        try manager.removeGateway(first)
        XCTAssertNotNil(manager.providers.first { $0.id == second.providerID })
        XCTAssertEqual(manager.iconTrackProvider, second.providerID.rawValue)
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "providerOrder.v2")?.first, second.providerID.rawValue)
    }

    @MainActor
    func testNotificationIDsBelongToInstancesAndStaleUsageCannotTrigger() {
        let keys = MemoryGatewayCredentials()
        let first = connection(), second = connection()
        let initial = GatewayScopeCheck(scope: first.scope!, summary: summary(spend: 96), history: .init())
        let p1 = GatewayProvider(connection: first, credentials: keys, initial: initial)
        let p2 = GatewayProvider(connection: second, credentials: keys, initial: initial)
        let observations = LimitNotifier.observations(from: [p1, p2])
        XCTAssertEqual(observations.count, 2)
        XCTAssertNotEqual(observations[0].id, observations[1].id)
        var stale = initial; stale.summary.issue = .network
        let p3 = GatewayProvider(connection: connection(), credentials: keys, initial: stale)
        XCTAssertTrue(LimitNotifier.observations(from: [p3]).isEmpty)
    }

    func testHostLimiterCancellationDoesNotOccupyAnotherPermit() async throws {
        let limiter = GatewayRequestLimiter()
        try await limiter.acquire("one")
        try await limiter.acquire("one")
        let entered = XCTestExpectation(description: "Waiting for a saturated host")
        let queued = Task {
            entered.fulfill()
            try await limiter.acquire("one")
        }
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()
        do { try await queued.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await limiter.acquire("two") // Other hosts remain independent.
        await limiter.release("one")
        try await limiter.acquire("one")
        await limiter.release("one"); await limiter.release("one"); await limiter.release("two")
    }
}
