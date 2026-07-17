import Foundation
import LocalAuthentication
import Security

/// Minimal helper for reading and writing Keychain items.
enum KeychainHelper {

    /// Read a generic password from Keychain by service name.
    static func readGenericPassword(service: String, account: String? = nil) -> Data? {
        readGenericPasswordResult(service: service, account: account).data
    }

    /// Read a generic password and expose the raw `OSStatus` for diagnostics.
    /// Useful to distinguish "not found" (`errSecItemNotFound`) from "access
    /// denied" / "needs interaction" errors.
    ///
    /// `allowUI: false` makes the query non-interactive: if the item's ACL
    /// would require the user to approve access (the "MyUsage wants to use
    /// your confidential information" password dialog), the query fails with
    /// `errSecInteractionNotAllowed` instead of showing the dialog. This is
    /// what lets background refreshes probe another app's item — like the
    /// Claude CLI's `Claude Code-credentials` — without prompt storms.
    static func readGenericPasswordResult(
        service: String,
        account: String? = nil,
        allowUI: Bool = true
    ) -> (data: Data?, status: OSStatus) {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        if !allowUI {
            // Modern, warning-free suppression for **data-protection**
            // keychain items: a no-interaction LAContext makes
            // SecItemCopyMatching fail rather than prompt. (This is the
            // replacement Apple's own `kSecUseAuthenticationUIFail`
            // deprecation message points to.) It does NOT cover the legacy
            // file-based "login" keychain — see `copyMatchingNoInteraction`.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }

        var result: CFTypeRef?
        let status = allowUI
            ? SecItemCopyMatching(query as CFDictionary, &result)
            : Self.copyMatchingNoInteraction(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return (data, status)
        }
        guard !allowUI else { return (nil, status) }

        // A no-UI read of an ACL-restricted item on the legacy login
        // keychain fails with `errSecAuthFailed` — NOT the
        // `errSecInteractionNotAllowed` that the data-protection keychain
        // returns and that the whole credential chain keys off of. Consult a
        // metadata-only existence probe (never ACL-gated, never prompts) and
        // normalize a "present but unreadable without interaction" outcome to
        // the canonical `errSecInteractionNotAllowed`, so callers can tell it
        // apart from a genuinely missing item regardless of which keychain
        // backs it.
        let normalized = Self.normalizedNoUIStatus(rawStatus: status) {
            Self.genericPasswordExists(service: service, account: account)
        }
        return (nil, normalized)
    }

    /// Canonicalize the `OSStatus` of a failed **no-UI** read. `errSecSuccess`
    /// and `errSecItemNotFound` pass through untouched; any other failure is
    /// mapped to `errSecInteractionNotAllowed` when `itemExists()` confirms
    /// the item is actually present (so the failure means "ACL-blocked", not
    /// "absent"). `itemExists` is a closure so the (real-Keychain) probe only
    /// runs when the raw status is ambiguous.
    static func normalizedNoUIStatus(rawStatus: OSStatus, itemExists: () -> Bool) -> OSStatus {
        guard rawStatus != errSecSuccess, rawStatus != errSecItemNotFound else {
            return rawStatus
        }
        return itemExists() ? errSecInteractionNotAllowed : rawStatus
    }

    /// Whether a generic-password item exists, via a **metadata-only** query
    /// (`kSecReturnAttributes`, never `kSecReturnData`). The ACL guards only
    /// an item's secret data, not its attributes, so this never prompts and
    /// needs no interaction switch — it reports presence even for items whose
    /// data is ACL-restricted to another app, the exact case of the Claude
    /// CLI's `Claude Code-credentials`.
    static func genericPasswordExists(service: String, account: String? = nil) -> Bool {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// No-UI `SecItemCopyMatching` for the legacy file-based login
    /// keychain — where the Claude CLI's `Claude Code-credentials` item
    /// lives. Its ACL dialog ("enter the login keychain password") ignores
    /// the LAContext flag and would block app launch; the process-global
    /// `SecKeychainSetUserInteractionAllowed` switch is the only thing that
    /// turns it into a silent `errSecInteractionNotAllowed`. That API is
    /// deprecated (all of SecKeychain is) but remains the sole option and
    /// is CodexBar's recipe too — isolating it in one deprecated method
    /// confines the unavoidable warning to a single, documented call.
    /// The switch is restored on every exit path so interactive reads
    /// elsewhere still prompt.
    @available(macOS, deprecated: 10.10)
    private static func copyMatchingNoInteraction(
        _ query: CFDictionary,
        _ result: inout CFTypeRef?
    ) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return SecItemCopyMatching(query, &result)
    }

    /// Read a generic password as a UTF-8 string.
    static func readGenericPasswordString(service: String, account: String? = nil) -> String? {
        guard let data = readGenericPassword(service: service, account: account) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Read a generic password as decoded JSON.
    static func readGenericPasswordJSON<T: Decodable>(
        service: String,
        account: String? = nil,
        as type: T.Type
    ) -> T? {
        guard let data = readGenericPassword(service: service, account: account) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Create or update a generic password item owned by MyUsage.
    ///
    /// Items are written with `AfterFirstUnlockThisDeviceOnly` so they never
    /// leave this Mac (no iCloud Keychain sync) — appropriate for cached
    /// OAuth tokens. Reading back an item this process created never
    /// triggers an ACL dialog, which is the whole point of keeping a local
    /// copy of credentials that originate in another app's item.
    @discardableResult
    static func upsertGenericPassword(
        _ data: Data,
        service: String,
        account: String? = nil
    ) -> OSStatus {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }

        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else { return addStatus }
        return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    /// Delete a generic password item. Missing items are not an error.
    @discardableResult
    static func deleteGenericPassword(service: String, account: String? = nil) -> OSStatus {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        return SecItemDelete(query as CFDictionary)
    }
}
