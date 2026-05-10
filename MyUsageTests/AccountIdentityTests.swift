import XCTest
@testable import MyUsage

final class AccountIdentityTests: XCTestCase {

    func testEmailPathRoundTrip() {
        let id = AccountIdentity.email("user@company.com")
        XCTAssertEqual(id.id, "user@company.com")
        XCTAssertEqual(id.email, "user@company.com")
        XCTAssertEqual(id.displayName, "user@company.com")
    }

    func testOpaquePathPrefixesIDAndDisplay() {
        let id = AccountIdentity.opaque("ab12cd34ef56")
        XCTAssertEqual(id.id, "id:ab12cd34ef56")
        XCTAssertNil(id.email)
        XCTAssertEqual(id.displayName, "Account id:ab12cd34ef56")
    }

    func testOpaqueTruncatesOverlyLongInput() {
        let id = AccountIdentity.opaque("0123456789abcdefghijk")
        XCTAssertEqual(id.id, "id:0123456789ab")
        XCTAssertEqual(id.displayName, "Account id:0123456789ab")
    }

    func testEqualityIsByID() {
        let a = AccountIdentity.email("user@company.com")
        let b = AccountIdentity.email("user@company.com")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, AccountIdentity.email("other@company.com"))
    }
}
