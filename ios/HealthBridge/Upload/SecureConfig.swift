import Foundation

/// Holds the two pieces of user-supplied configuration for the bridge:
/// - the HTTPS server endpoint (not secret, stored in UserDefaults)
/// - the bearer token (secret, stored in Keychain only)
///
/// The token is NOT serialized into settings or logs. The endpoint is not
/// secret but the token is kept separate so a settings export never leaks it.
final class SecureConfig {
    static let endpointKey = "healthbridge_endpoint"
    static let tokenAccount = "healthbridge_ingest_token"
    static let tokenService = "com.haru.healthbridge"

    private let defaults: UserDefaults
    private let keychain: KeychainStoring

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore(service: SecureConfig.tokenService, account: SecureConfig.tokenAccount)
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var endpoint: URL? {
        guard let string = defaults.string(forKey: Self.endpointKey) else { return nil }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https", url.host != nil else { return nil }
        return url
    }

    var token: String? {
        guard let data = keychain.data(), let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    var isConfigured: Bool {
        endpoint != nil && token != nil
    }

    /// Persist config. `token` goes only to Keychain, never to UserDefaults.
    func save(endpoint: String, token: String) {
        defaults.set(endpoint, forKey: Self.endpointKey)
        keychain.set(Data(token.utf8))
    }

    func clear() {
        defaults.removeObject(forKey: Self.endpointKey)
        keychain.delete()
    }
}
