import Security
import XCTest
@testable import MyUsage

@MainActor
final class GatewayKeychainTests: XCTestCase {
    func testReadableSavedKeyDoesNotPromptEvenForManualRead() throws {
        var requests: [Bool] = []
        let store = GatewayKeychain(readPassword: { service, reference, allowUI in
            XCTAssertEqual(service, "MyUsage.Gateway.APIKey")
            XCTAssertEqual(reference, "saved-reference")
            requests.append(allowUI)
            return (Data("fixture-key".utf8), errSecSuccess)
        }, allowsInteraction: true)

        XCTAssertEqual(try store.read("saved-reference", allowUI: true), "fixture-key")
        XCTAssertEqual(requests, [false])
    }

    func testBackgroundReadDistinguishesBlockedKeyFromMissingKey() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            var requests: [Bool] = []
            let store = GatewayKeychain(readPassword: { _, _, allowUI in
                requests.append(allowUI)
                return (nil, status)
            }, allowsInteraction: true)

            XCTAssertThrowsError(try store.read("saved-reference")) {
                XCTAssertEqual($0 as? GatewayIssue, .keychainAccessRequired)
            }
            XCTAssertEqual(requests, [false])
        }
    }

    func testExplicitReadRecoversExistingKeyAfterAccessIsAuthorized() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            var requests: [Bool] = []
            let store = GatewayKeychain(readPassword: { service, reference, allowUI in
                XCTAssertEqual(service, "MyUsage.Gateway.APIKey")
                XCTAssertEqual(reference, "saved-reference")
                requests.append(allowUI)
                return allowUI ? (Data("fixture-key".utf8), errSecSuccess) : (nil, status)
            }, allowsInteraction: true)

            XCTAssertEqual(try store.read("saved-reference", allowUI: true), "fixture-key")
            XCTAssertEqual(requests, [false, true])
        }
    }

    func testCancelStopsRecoveryAndBackgroundReadsRemainSilent() {
        var requests: [Bool] = []
        let store = GatewayKeychain(readPassword: { _, _, allowUI in
            requests.append(allowUI)
            return (nil, allowUI ? errSecUserCanceled : errSecInteractionNotAllowed)
        }, allowsInteraction: true)

        XCTAssertThrowsError(try store.read("saved-reference", allowUI: true)) {
            XCTAssertEqual($0 as? GatewayIssue, .keychainAccessRequired)
        }
        XCTAssertThrowsError(try store.read("saved-reference")) {
            XCTAssertEqual($0 as? GatewayIssue, .keychainAccessRequired)
        }
        XCTAssertEqual(requests, [false, true, false])

        // A new explicit click may retry after an earlier cancellation.
        XCTAssertThrowsError(try store.read("saved-reference", allowUI: true))
        XCTAssertEqual(requests, [false, true, false, false, true])
    }

    func testAutomationSuppressionOverridesExplicitRead() {
        var requests: [Bool] = []
        let store = GatewayKeychain(readPassword: { _, _, allowUI in
            requests.append(allowUI)
            return (nil, errSecInteractionNotAllowed)
        }, allowsInteraction: false)

        XCTAssertThrowsError(try store.read("saved-reference", allowUI: true)) {
            XCTAssertEqual($0 as? GatewayIssue, .keychainAccessRequired)
        }
        XCTAssertEqual(requests, [false])
    }

    func testMissingAndUnexpectedErrorsAreNotTreatedAsAuthorizationRequests() {
        let cases: [(OSStatus, GatewayIssue)] = [
            (errSecItemNotFound, .missingCredential),
            (errSecNotAvailable, .keychainReadFailed(status: errSecNotAvailable)),
            (errSecParam, .keychainReadFailed(status: errSecParam)),
        ]
        for (status, expected) in cases {
            var requests: [Bool] = []
            let store = GatewayKeychain(readPassword: { _, _, allowUI in
                requests.append(allowUI)
                return (nil, status)
            }, allowsInteraction: true)

            XCTAssertThrowsError(try store.read("saved-reference", allowUI: true)) {
                XCTAssertEqual($0 as? GatewayIssue, expected)
            }
            XCTAssertEqual(requests, [false])
        }
    }

    func testMalformedStoredDataIsNotReportedAsAMissingKey() {
        for data in [nil, Data(), Data([0xFF])] as [Data?] {
            let store = GatewayKeychain(readPassword: { _, _, _ in (data, errSecSuccess) })
            XCTAssertThrowsError(try store.read("saved-reference")) {
                XCTAssertEqual($0 as? GatewayIssue, .invalidStoredCredential)
            }
        }
    }
}
