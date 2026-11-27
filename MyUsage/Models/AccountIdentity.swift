import Foundation

/// Identity of one provider account (email when available, otherwise an opaque fallback ID).
struct AccountIdentity: Sendable, Equatable, Hashable, Codable {
    let id: String

    /// Email when known, `nil` for the fallback path.
    let email: String?

    /// Pre-formatted label for the UI. Email verbatim, or `Account id:abc12345`.
    let displayName: String

    static func email(_ email: String) -> AccountIdentity {
        AccountIdentity(id: email, email: email, displayName: email)
    }

    static func opaque(_ rawID: String) -> AccountIdentity {
        let trimmed = String(rawID.prefix(12))
        return AccountIdentity(
            id: "id:\(trimmed)",
            email: nil,
            displayName: "Account id:\(trimmed)"
        )
    }
}
