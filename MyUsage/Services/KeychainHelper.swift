import Foundation
import Security

/// Minimal helper for reading Keychain items.
enum KeychainHelper {

    /// Read a generic password from Keychain by service name.
    static func readGenericPassword(service: String, account: String? = nil) -> Data? {
        readGenericPasswordResult(service: service, account: account).data
    }

    /// Read a generic password and expose the raw `OSStatus` for diagnostics.
    /// Useful to distinguish "not found" (`errSecItemNotFound`) from "access
    /// denied" / "needs interaction" errors.
    static func readGenericPasswordResult(
        service: String,
        account: String? = nil
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
}
