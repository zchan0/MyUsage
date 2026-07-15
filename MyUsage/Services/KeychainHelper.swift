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
            // Belt and suspenders: `kSecUseAuthenticationUI` is the modern
            // switch, but on macOS file-based keychains the LAContext flag
            // is what reliably suppresses the ACL dialog (same recipe
            // CodexBar uses for its no-UI probes).
            query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return (data, status)
        }
        return (nil, status)
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
