import Foundation
import Security

/// Minimal helper for reading Keychain items.
enum KeychainHelper {

    /// Read a generic password from Keychain by service name.
    static func readGenericPassword(service: String, account: String? = nil) -> Data? {
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

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
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
