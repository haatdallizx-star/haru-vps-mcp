import Foundation
import Security

/// Minimal protocol so the token store can be stubbed in unit tests (the real
/// `KeychainStore` requires a device / is not reliably present on a simulator
/// test host).
protocol KeychainStoring {
    func set(_ data: Data)
    func data() -> Data?
    func delete()
}

/// Keychain-backed storage for the ingest bearer token.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlock` so background work can read the
/// token after the device's first unlock following a reboot — required for
/// background delivery. The token is deliberately never written to UserDefaults
/// or any ordinary settings file (see `SecureConfigTests`).
struct KeychainStore: KeychainStoring {
    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func set(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace any existing value.
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func data() -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
