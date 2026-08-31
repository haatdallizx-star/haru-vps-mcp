import XCTest
@testable import HealthBridgeCore

final class SecureConfigTests: XCTestCase {
    final class MemorySecrets: SecretStore {
        var values: [String: String] = [:]
        func set(_ value: String, for key: String) throws { values[key] = value }
        func get(_ key: String) throws -> String? { values[key] }
        func remove(_ key: String) throws { values.removeValue(forKey: key) }
    }

    func testAcceptsHTTPSServerAndStoresTokenOutsidePreferences() throws {
        let secrets = MemorySecrets()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = SecureConfig(defaults: defaults, secrets: secrets)
        try config.save(serverURL: URL(string: "https://health.example.com")!, token: "secret-token")
        XCTAssertEqual(config.serverURL?.absoluteString, "https://health.example.com")
        XCTAssertEqual(try config.token(), "secret-token")
        XCTAssertNil(defaults.string(forKey: "healthbridge.token"))
    }

    func testRejectsInsecureOrCredentialedServerURLs() {
        let config = SecureConfig(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: MemorySecrets())
        XCTAssertThrowsError(try config.save(serverURL: URL(string: "http://health.example.com")!, token: "secret"))
        XCTAssertThrowsError(try config.save(serverURL: URL(string: "https://user:pass@health.example.com")!, token: "secret"))
        XCTAssertThrowsError(try config.save(serverURL: URL(string: "https://health.example.com")!, token: ""))
    }

    func testIngestAndStatusURLsAreDerivedFromServerRoot() throws {
        let config = SecureConfig(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: MemorySecrets())
        try config.save(serverURL: URL(string: "https://health.example.com/base")!, token: "secret")
        XCTAssertEqual(config.ingestURL?.absoluteString, "https://health.example.com/healthkit/v1/ingest")
        XCTAssertEqual(config.statusURL?.absoluteString, "https://health.example.com/healthkit/v1/status")
    }
}
