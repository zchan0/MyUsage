import Security
import XCTest
@testable import MyUsage

/// Regression coverage for the no-UI keychain read status normalization.
///
/// The Claude CLI's `Claude Code-credentials` item lives in the legacy
/// file-based login keychain. A no-UI read of it, when this process isn't in
/// the item's ACL, fails with `errSecAuthFailed` — not the
/// `errSecInteractionNotAllowed` the data-protection keychain returns. The
/// whole credential chain (detection + interactive bootstrap) keys off
/// `errSecInteractionNotAllowed`, so `KeychainHelper` normalizes the legacy
/// status back to it whenever a metadata probe confirms the item is present.
final class KeychainHelperTests: XCTestCase {

    // MARK: - normalizedNoUIStatus

    func testAuthFailedOnExistingItemBecomesInteractionNotAllowed() {
        let status = KeychainHelper.normalizedNoUIStatus(rawStatus: errSecAuthFailed) { true }
        XCTAssertEqual(
            status, errSecInteractionNotAllowed,
            "an ACL-blocked legacy read of a present item must read as interaction-not-allowed"
        )
    }

    func testAuthFailedOnMissingItemPassesThrough() {
        let status = KeychainHelper.normalizedNoUIStatus(rawStatus: errSecAuthFailed) { false }
        XCTAssertEqual(
            status, errSecAuthFailed,
            "a failure with no item behind it must not be masked as ACL-blocked"
        )
    }

    func testItemNotFoundShortCircuitsExistenceProbe() {
        var probed = false
        let status = KeychainHelper.normalizedNoUIStatus(rawStatus: errSecItemNotFound) {
            probed = true
            return true
        }
        XCTAssertEqual(status, errSecItemNotFound)
        XCTAssertFalse(probed, "errSecItemNotFound is already definitive — don't probe")
    }

    func testSuccessShortCircuitsExistenceProbe() {
        var probed = false
        let status = KeychainHelper.normalizedNoUIStatus(rawStatus: errSecSuccess) {
            probed = true
            return true
        }
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertFalse(probed, "a successful read never needs the existence probe")
    }

    func testInteractionNotAllowedIsIdempotent() {
        let status = KeychainHelper.normalizedNoUIStatus(rawStatus: errSecInteractionNotAllowed) { true }
        XCTAssertEqual(status, errSecInteractionNotAllowed)
    }

    // MARK: - genericPasswordExists (real Keychain round-trip)

    func testGenericPasswordExistsRoundTrip() throws {
        let service = "MyUsage-KeychainHelperTests-\(UUID().uuidString)"
        let account = "unit-test"
        addTeardownBlock {
            KeychainHelper.deleteGenericPassword(service: service, account: account)
        }

        XCTAssertFalse(
            KeychainHelper.genericPasswordExists(service: service, account: account),
            "a service we just minted must not exist yet"
        )

        let writeStatus = KeychainHelper.upsertGenericPassword(
            Data("token".utf8), service: service, account: account
        )
        // Headless CI without an unlocked login keychain can't write — skip
        // rather than fail there; the pure-function tests still guard the fix.
        try XCTSkipUnless(
            writeStatus == errSecSuccess,
            "Keychain not writable in this environment (status \(writeStatus))"
        )

        XCTAssertTrue(
            KeychainHelper.genericPasswordExists(service: service, account: account),
            "a metadata probe must see an item we own, without prompting"
        )

        KeychainHelper.deleteGenericPassword(service: service, account: account)
        XCTAssertFalse(
            KeychainHelper.genericPasswordExists(service: service, account: account),
            "the item must be gone after deletion"
        )
    }
}
