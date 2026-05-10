import XCTest
@testable import MyUsage

@MainActor
final class AccountStoreTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MyUsage-AccountStoreTests-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("accounts.json")
    }

    private func sampleSnapshot(weeklyPercent: Double = 50) -> UsageSnapshot {
        var s = UsageSnapshot()
        s.planName = "Max"
        s.weeklyUsage = UsageWindow(percentUsed: weeklyPercent, resetsAt: nil, windowDuration: 7 * 86_400)
        s.monthlyEstimatedCost = 321.00
        return s
    }

    func testEmptyStoreHasNoCounts() {
        let store = AccountStore(fileURL: tempStoreURL())
        XCTAssertEqual(store.count(for: .claude), 0)
        XCTAssertNil(store.activeAccountID(for: .claude))
        XCTAssertEqual(store.accounts(for: .claude).count, 0)
    }

    func testRecordObservationCreatesActiveAccount() {
        let store = AccountStore(fileURL: tempStoreURL())
        store.recordObservation(
            provider: .claude,
            identity: .email("user@company.com"),
            snapshot: sampleSnapshot(weeklyPercent: 62)
        )
        XCTAssertEqual(store.count(for: .claude), 1)
        XCTAssertEqual(store.activeAccountID(for: .claude), "user@company.com")
        let record = store.record(for: .claude, accountID: "user@company.com")
        XCTAssertEqual(record?.email, "user@company.com")
        XCTAssertEqual(record?.snapshot?.weeklyPercent, 62)
    }

    func testSecondAccountFlipsActiveAndKeepsBoth() {
        let store = AccountStore(fileURL: tempStoreURL())
        store.recordObservation(
            provider: .claude,
            identity: .email("a@x.com"),
            snapshot: sampleSnapshot(),
            at: Date(timeIntervalSince1970: 1_000)
        )
        store.recordObservation(
            provider: .claude,
            identity: .email("b@x.com"),
            snapshot: sampleSnapshot(),
            at: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(store.count(for: .claude), 2)
        XCTAssertEqual(store.activeAccountID(for: .claude), "b@x.com")
        // Sorted by lastSeenAt desc — most recent first.
        XCTAssertEqual(store.accounts(for: .claude).map(\.accountID), ["b@x.com", "a@x.com"])
    }

    func testForgetDropsAccountAndClearsActiveIfMatched() {
        let store = AccountStore(fileURL: tempStoreURL())
        store.recordObservation(
            provider: .claude, identity: .email("a@x.com"), snapshot: sampleSnapshot(),
            at: Date(timeIntervalSince1970: 1_000)
        )
        store.recordObservation(
            provider: .claude, identity: .email("b@x.com"), snapshot: sampleSnapshot(),
            at: Date(timeIntervalSince1970: 2_000)
        )
        store.forget(provider: .claude, accountID: "b@x.com")
        XCTAssertEqual(store.count(for: .claude), 1)
        XCTAssertNil(store.activeAccountID(for: .claude), "active was b — now nil")

        // Forgetting an inactive account leaves active intact.
        store.recordObservation(
            provider: .claude, identity: .email("c@x.com"), snapshot: sampleSnapshot(),
            at: Date(timeIntervalSince1970: 3_000)
        )
        store.forget(provider: .claude, accountID: "a@x.com")
        XCTAssertEqual(store.activeAccountID(for: .claude), "c@x.com")
    }

    func testOpaqueIdentityRoundTrips() {
        let store = AccountStore(fileURL: tempStoreURL())
        store.recordObservation(
            provider: .codex,
            identity: .opaque("ab12cd34"),
            snapshot: sampleSnapshot()
        )
        let rec = store.record(for: .codex, accountID: "id:ab12cd34")
        XCTAssertNotNil(rec)
        XCTAssertNil(rec?.email)
        XCTAssertEqual(rec?.displayName, "Account id:ab12cd34")
        XCTAssertTrue(rec?.isOpaque ?? false)
    }

    func testPersistsAcrossInstances() {
        let url = tempStoreURL()
        do {
            let store = AccountStore(fileURL: url)
            store.recordObservation(
                provider: .claude, identity: .email("user@company.com"),
                snapshot: sampleSnapshot(weeklyPercent: 77)
            )
        }
        let reopened = AccountStore(fileURL: url)
        XCTAssertEqual(reopened.count(for: .claude), 1)
        XCTAssertEqual(reopened.activeAccountID(for: .claude), "user@company.com")
        XCTAssertEqual(
            reopened.record(for: .claude, accountID: "user@company.com")?.snapshot?.weeklyPercent,
            77
        )
    }

    func testDifferentProvidersAreIsolated() {
        let store = AccountStore(fileURL: tempStoreURL())
        store.recordObservation(
            provider: .claude, identity: .email("a@x.com"), snapshot: sampleSnapshot()
        )
        store.recordObservation(
            provider: .codex, identity: .email("b@x.com"), snapshot: sampleSnapshot()
        )
        XCTAssertEqual(store.count(for: .claude), 1)
        XCTAssertEqual(store.count(for: .codex), 1)
        XCTAssertNil(store.record(for: .claude, accountID: "b@x.com"))
        XCTAssertNil(store.record(for: .codex, accountID: "a@x.com"))
    }
}
