import Foundation

/// Tiny JWT payload extractor. We do **not** verify signatures — these
/// tokens already authenticated us with the provider, we just want to
/// read public claims like `email` out of the unsigned middle section.
///
/// JWT structure: `<header>.<payload>.<signature>`, all three parts
/// base64url-encoded. The payload is JSON.
enum JWTDecoder {

    /// Returns the raw JSON payload as `[String: Any]`, or `nil` if the
    /// token is malformed.
    static func payload(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Convenience: extract a single string claim (`email`, `sub`, …).
    static func stringClaim(_ key: String, from token: String) -> String? {
        payload(of: token)?[key] as? String
    }

    /// Base64URL is base64 with `-`/`_` instead of `+`/`/` and no padding.
    /// JSONSerialization needs proper padding, so we restore it.
    private static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: b64)
    }
}
