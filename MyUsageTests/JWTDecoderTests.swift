import XCTest
@testable import MyUsage

final class JWTDecoderTests: XCTestCase {

    /// Build a minimal unsigned JWT (header.payload.) from a JSON payload
    /// dict, then base64url-encode the parts. Signature is empty since the
    /// decoder does not verify.
    private func makeJWT(_ payload: [String: Any]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        return [headerData, payloadData]
            .map { $0.base64URLEncodedString() }
            .joined(separator: ".") + "."
    }

    func testExtractsEmailClaim() {
        let token = makeJWT(["email": "user@company.com", "sub": "abc123"])
        XCTAssertEqual(JWTDecoder.stringClaim("email", from: token), "user@company.com")
    }

    func testReturnsNilForMissingClaim() {
        let token = makeJWT(["sub": "abc123"])
        XCTAssertNil(JWTDecoder.stringClaim("email", from: token))
    }

    func testReturnsNilForMalformedToken() {
        XCTAssertNil(JWTDecoder.stringClaim("email", from: "not-a-jwt"))
        XCTAssertNil(JWTDecoder.stringClaim("email", from: ""))
        XCTAssertNil(JWTDecoder.stringClaim("email", from: "only.one"))
    }

    func testHandlesBase64URLPaddingVariants() {
        // Payload that requires 1, 2, 3 chars of restored padding depending
        // on length. We just check a non-trivial multi-char email.
        let token = makeJWT(["email": "longer.email.address+tag@my-company.io"])
        XCTAssertEqual(
            JWTDecoder.stringClaim("email", from: token),
            "longer.email.address+tag@my-company.io"
        )
    }

    func testIgnoresSignatureSection() {
        // Add a fake signature; decoder should still find email in payload.
        let header = #"{"alg":"none"}"#.data(using: .utf8)!.base64URLEncodedString()
        let payload = #"{"email":"x@y.z"}"#.data(using: .utf8)!.base64URLEncodedString()
        let token = "\(header).\(payload).signature-bytes-go-here"
        XCTAssertEqual(JWTDecoder.stringClaim("email", from: token), "x@y.z")
    }
}

private extension Data {
    /// Base64URL: standard base64 with `-`/`_` substitutions and no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
