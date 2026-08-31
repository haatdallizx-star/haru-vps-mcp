import Foundation
import Security

protocol SecretStore {
    func set(_ value: String, for key: String) throws
    func get(_ key: String) throws -> String?
    func remove(_ key: String) throws
}

final class KeychainSecretStore: SecretStore {
    private let service = "com.haru.healthbridge"

    func set(_ value: String, for key: String) throws {
        try remove(key)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureConfigError.keychain(status) }
    }

    func get(_ key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecureConfigError.keychain(status)
        }
        return value
    }

    func remove(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureConfigError.keychain(status) }
    }
}

public final class SecureConfig {
    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let urlKey = "healthbridge.server_url"
    private let tokenKey = "healthbridge.token"

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public convenience init() { self.init(defaults: .standard, secrets: KeychainSecretStore()) }

    public var serverURL: URL? {
        defaults.string(forKey: urlKey).flatMap(URL.init(string:))
    }

    public var ingestURL: URL? { endpoint("/healthkit/v1/ingest") }
    public var statusURL: URL? { endpoint("/healthkit/v1/status") }

    public func save(serverURL: URL, token: String) throws {
        guard serverURL.scheme?.lowercased() == "https", serverURL.host != nil,
              serverURL.user == nil, serverURL.password == nil else {
            throw SecureConfigError.invalidServerURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SecureConfigError.emptyToken }
        var components = URLComponents()
        components.scheme = "https"
        components.host = serverURL.host
        components.port = serverURL.port
        guard let root = components.url else { throw SecureConfigError.invalidServerURL }
        try secrets.set(token, for: tokenKey)
        defaults.set(root.absoluteString, forKey: urlKey)
    }

    public func token() throws -> String? { try secrets.get(tokenKey) }

    private func endpoint(_ path: String) -> URL? {
        guard let serverURL else { return nil }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

public enum SecureConfigError: Error {
    case invalidServerURL
    case emptyToken
    case keychain(OSStatus)
}
