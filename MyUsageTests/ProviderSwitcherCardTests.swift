import XCTest
@testable import MyUsage

/// Regression coverage for the "all providers disappeared" crash: an
/// empty / shrinking accounts array must never produce an out-of-bounds
/// index. The crash happened when Mock multi-account was disabled and a
/// provider's demo-only account set dropped to zero while the switcher
/// was still mounted — `accounts[min(selectedIndex, count-1)]` trapped on
/// `accounts[-1]` and took the whole app down.
final class ProviderSwitcherCardTests: XCTestCase {

    func testEmptyAccountsReturnsNilNotNegativeIndex() {
        XCTAssertNil(ProviderSwitcherCard.safeIndex(selected: 0, count: 0))
        XCTAssertNil(ProviderSwitcherCard.safeIndex(selected: 3, count: 0))
        XCTAssertNil(ProviderSwitcherCard.safeIndex(selected: -1, count: 0))
    }

    func testSelectionClampedIntoBounds() {
        // Within range — unchanged.
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: 0, count: 3), 0)
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: 2, count: 3), 2)
        // Past the end (array shrank under us) — clamps to last.
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: 2, count: 1), 0)
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: 5, count: 2), 1)
        // Negative — clamps to first.
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: -1, count: 2), 0)
    }

    func testSingleAccountAlwaysIndexZero() {
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: 0, count: 1), 0)
        XCTAssertEqual(ProviderSwitcherCard.safeIndex(selected: 99, count: 1), 0)
    }
}
