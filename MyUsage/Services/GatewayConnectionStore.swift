import Foundation
import Security

@MainActor
protocol GatewayCredentialStore {
    func read(_ reference: String, allowUI: Bool) throws -> String
    func write(_ key: String, reference: String) throws
    func delete(_ reference: String) throws
}

extension GatewayCredentialStore {
    /// Launch, timer and history reads must never open an authorization dialog.
    func read(_ reference: String) throws -> String { try read(reference, allowUI: false) }
}

struct GatewayKeychain: GatewayCredentialStore {
    private let service = "MyUsage.Gateway.APIKey"
    private let readPassword: (String, String, Bool) -> (data: Data?, status: OSStatus)
    private let allowsInteraction: Bool

    init(
        readPassword: @escaping (String, String, Bool) -> (data: Data?, status: OSStatus) = {
            KeychainHelper.readGenericPasswordResult(service: $0, account: $1, allowUI: $2)
        },
        allowsInteraction: Bool = ProcessInfo.processInfo.environment["MYUSAGE_NO_PROMPT"] != "1"
            && ProcessInfo.processInfo.environment["MYUSAGE_AUTOPILOT"] == nil
    ) {
        self.readPassword = readPassword
        self.allowsInteraction = allowsInteraction
    }

    func read(_ reference: String, allowUI: Bool) throws -> String {
        var result = readPassword(service, reference, false)
        // An updated ad-hoc build can lose access to an existing item's ACL.
        // Recover only after an explicit user action, without replacing the key.
        if allowUI, allowsInteraction,
           result.status == errSecInteractionNotAllowed || result.status == errSecAuthFailed {
            result = readPassword(service, reference, true)
        }
        switch result.status {
        case errSecSuccess: break
        case errSecItemNotFound: throw GatewayIssue.missingCredential
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw GatewayIssue.keychainAccessRequired
        default: throw GatewayIssue.keychainReadFailed(status: result.status)
        }
        guard let data = result.data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw GatewayIssue.invalidStoredCredential
        }
        return key
    }
    func write(_ key: String, reference: String) throws {
        guard KeychainHelper.upsertGenericPassword(Data(key.utf8), service: service, account: reference) == errSecSuccess else {
            throw GatewayStoreError.keychain
        }
    }
    func delete(_ reference: String) throws {
        let status = KeychainHelper.deleteGenericPassword(service: service, account: reference)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GatewayStoreError.keychain }
    }
}

enum GatewayStoreError: LocalizedError {
    case invalidConfiguration, unreadableConfiguration, keychain, newKeyRequired
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a name and a valid gateway address."
        case .unreadableConfiguration: "Saved gateway settings could not be read. They have been preserved."
        case .keychain: "Could not update this gateway's Keychain item."
        case .newKeyRequired: "Enter an API key for the new gateway address."
        }
    }
}

@MainActor
final class GatewayConnectionStore {
    private struct Document: Codable { var version = 1; var connections: [GatewayConnection] }
    private let defaults: UserDefaults
    let credentials: any GatewayCredentialStore
    private let storageKey = "gateway.connections.v1"

    init(defaults: UserDefaults = .standard, credentials: any GatewayCredentialStore = GatewayKeychain()) {
        self.defaults = defaults; self.credentials = credentials
    }
    func load() throws -> [GatewayConnection] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let doc = try? JSONDecoder().decode(Document.self, from: data), doc.version == 1,
              Set(doc.connections.map(\.id)).count == doc.connections.count else { throw GatewayStoreError.unreadableConfiguration }
        return doc.connections
    }
    @discardableResult
    func save(_ draft: GatewayConnection, newKey: String?) throws -> GatewayConnection {
        var items = try load()
        let old = items.first { $0.id == draft.id }
        var connection = draft
        connection.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connection.name.isEmpty else { throw GatewayStoreError.invalidConfiguration }
        connection.baseURL = try GatewayAddress.normalize(draft.baseURL.absoluteString)
        if old?.baseURL != connection.baseURL, old != nil, newKey == nil { throw GatewayStoreError.newKeyRequired }
        if let newKey {
            guard !newKey.isEmpty else { throw GatewayIssue.missingCredential }
            // Stage a new credential before swapping the config reference.
            connection.credentialReference = UUID().uuidString
            try credentials.write(newKey, reference: connection.credentialReference)
        } else if let old {
            connection.credentialReference = old.credentialReference
        } else { throw GatewayIssue.missingCredential }
        items.removeAll { $0.id == connection.id }; items.append(connection)
        do { defaults.set(try JSONEncoder().encode(Document(connections: items)), forKey: storageKey) }
        catch {
            if newKey != nil { try? credentials.delete(connection.credentialReference) }
            throw error
        }
        if let old, old.credentialReference != connection.credentialReference { try? credentials.delete(old.credentialReference) }
        return connection
    }
    func remove(_ id: UUID) throws {
        var items = try load()
        guard let old = items.first(where: { $0.id == id }) else { return }
        try credentials.delete(old.credentialReference)
        items.removeAll { $0.id == id }
        defaults.set(try JSONEncoder().encode(Document(connections: items)), forKey: storageKey)
    }
}
