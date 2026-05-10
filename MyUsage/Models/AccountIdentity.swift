import Foundation

/// Identity of one provider account. Drives `LedgerEntry.accountId` (so
/// per-account aggregation works across devices) and the popover's account
/// switcher / Settings sub-rows.
///
/// We prefer the user's email because it's what they recognise — an opaque
/// org UUID would defeat the whole point of multi-account UX. The
/// `id:xxxx` fallback exists only for the rare case where the provider
/// genuinely doesn't expose email at this moment (cold-start race against
/// the CLI writing its credentials, JWT lacking the claim, etc.).
struct AccountIdentity: Sendable, Equatable, Hashable, Codable {
    /// Stable string written into `LedgerEntry.accountId`. For the email
    /// path this is the email verbatim; for the fallback it is `id:<short>`.
    let id: String

    /// Email when known, `nil` for the fallback path. The popover uses this
    /// to decide between the "real email" pill and the muted "Account id:…" pill.
    let email: String?

    /// Pre-formatted label for the UI. Email verbatim, or `Account id:abc12345`.
    let displayName: String

    /// Email path. The id is the email verbatim — same string on every
    /// device, so cross-device aggregation joins cleanly.
    static func email(_ email: String) -> AccountIdentity {
        AccountIdentity(id: email, email: email, displayName: email)
    }

    /// Fallback path. Pass any opaque string the provider can offer
    /// (account_id, stripeCustomerId, hash of the access token, …); we
    /// prefix `id:` so writers and readers agree on shape and the UI
    /// renders it as `Account id:…` rather than as a real email.
    static func opaque(_ rawID: String) -> AccountIdentity {
        let trimmed = String(rawID.prefix(12))
        return AccountIdentity(
            id: "id:\(trimmed)",
            email: nil,
            displayName: "Account id:\(trimmed)"
        )
    }
}
