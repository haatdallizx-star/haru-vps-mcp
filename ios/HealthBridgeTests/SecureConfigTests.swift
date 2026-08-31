import XCTest
@testable import HealthBridge

final class SecureConfigTests: XCTestCase {

    func testTokenIsStoredOnlyInKeychainNotInUserDefaults() {
        let suite = "SecureConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let keychain = FakeKeychain()
        let config = SecureConfig(defaults: defaults, keychain: keychain)

        let secret = "secret-bearer-token-1234567890"
        config.save(endpoint: "https://example.com/healthkit/v1/ingest", token: secret)

        XCTAssertEqual(config.endpoint?.absoluteString, "https://example.com/healthkit/v1/ingest")
        XCTAssertEqual(config.token, secret)
        XCTAssertTrue(keychain.data() != nil)
        // The secret must never be serialized into ordinary settings.
        XCTAssertFalse(defaultsContain(defaults, secret: secret))
    }

    func testEndpointMustBeHTTPSAndHaveHost() {
        let suite = "SecureConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let config = SecureConfig(defaults: defaults, keychain: FakeKeychain())

        defaults.set("http://example.com", forKey: SecureConfig.endpointKey)
        XCTAssertNil(config.endpoint)   // plain http rejected

        defaults.set("https://", forKey: SecureConfig.endpointKey)
        XCTAssertNil(config.endpoint)   // no host rejected

        defaults.set("https://example.com/healthkit/v1/ingest", forKey: SecureConfig.endpointKey)
        XCTAssertEqual(config.endpoint?.host, "example.com")
    }

    func testIsConfiguredRequiresBothEndpointAndToken() {
        let suite = "SecureConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let config = SecureConfig(defaults: defaults, keychain: FakeKeychain())

        XCTAssertFalse(config.isConfigured)
        config.save(endpoint: "https://example.com", token: "token")
        XCTAssertTrue(config.isConfigured)
    }
}
