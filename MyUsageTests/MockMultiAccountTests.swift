import XCTest
@testable import MyUsage

@MainActor
final class MockMultiAccountTests: XCTestCase {

    private func makeManager() -> UsageManager {
        // In-memory store + unavailable sync folder so tests don't touch
        // the real ~/Library Application Support tree or any iCloud /
        // Dropbox folder. AccountStore similarly gets a throwaway temp
        // file.
        let tempStore = AccountStore(fileURL: tempURL())
        let store = try! LedgerStore(path: LedgerStore.inMemoryPath)
        let ledger = LedgerSync(store: store, syncRoot: UnavailableSyncRoot())
        return UsageManager(ledger: ledger, accountStore: tempStore)
    }

    private struct UnavailableSyncRoot: SyncRoot {
        let rootURL: URL? = nil
        let isAvailable: Bool = false
    }

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MyUsage-MockMultiAccountTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    func testEnableInjectsTwoDemoAccountsPerMultiAccountProvider() async {
        let manager = makeManager()
        await MockMultiAccount.enable(manager: manager)

        for kind in [ProviderKind.claude, .codex, .cursor] {
            let accounts = manager.accountStore.accounts(for: kind)
            let demoCount = accounts.filter { $0.accountID.hasSuffix("@\(MockMultiAccount.demoDomain)") }.count
            XCTAssertEqual(demoCount, 2, "\(kind.rawValue): expected 2 demo accounts, got \(demoCount)")
        }

        // Antigravity is intentionally skipped — no per-account billing.
        let antig = manager.accountStore.accounts(for: .antigravity)
        XCTAssertEqual(antig.count, 0, "Antigravity should not get demo accounts")
    }

    func testDisableRemovesDemoAccountsAndWipesLedgerRows() async {
        let manager = makeManager()
        await MockMultiAccount.enable(manager: manager)

        let monthKey = LedgerCalendar.monthKey(for: .now)
        for kind in [ProviderKind.claude, .codex, .cursor] {
            let totalsBefore = manager.ledger.monthlyTotalsByAccount(provider: kind, monthKey: monthKey)
            let demoBefore = totalsBefore.filter { $0.key.hasSuffix("@\(MockMultiAccount.demoDomain)") }
            XCTAssertEqual(demoBefore.count, 2, "\(kind): demo ledger rows should exist after enable")
        }

        await MockMultiAccount.disable(manager: manager)

        for kind in [ProviderKind.claude, .codex, .cursor] {
            let accounts = manager.accountStore.accounts(for: kind)
            let demoLeft = accounts.filter { $0.accountID.hasSuffix("@\(MockMultiAccount.demoDomain)") }
            XCTAssertEqual(demoLeft.count, 0, "\(kind): demo accounts should be gone after disable")

            let totals = manager.ledger.monthlyTotalsByAccount(provider: kind, monthKey: monthKey)
            let demoTotals = totals.filter { $0.key.hasSuffix("@\(MockMultiAccount.demoDomain)") }
            XCTAssertEqual(demoTotals.count, 0, "\(kind): demo ledger rows should be wiped")
        }
    }

    func testEnableDoesNotChangeActivePointer() async {
        let manager = makeManager()
        // Pre-seed a "real" active account.
        manager.accountStore.recordObservation(
            provider: .claude,
            identity: .email("real@company.com"),
            snapshot: UsageSnapshot()
        )
        XCTAssertEqual(manager.accountStore.activeAccountID(for: .claude), "real@company.com")

        await MockMultiAccount.enable(manager: manager)

        XCTAssertEqual(
            manager.accountStore.activeAccountID(for: .claude),
            "real@company.com",
            "real account should remain active after demo injection"
        )
    }
}
