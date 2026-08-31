import Foundation
import XCTest
@testable import HealthBridge

/// Shared fixtures for HealthBridge unit tests.
enum TestSamples {
    /// Build a deterministic HealthSample for a given index.
    static func make(uuid: String = UUID().uuidString, type: String = "heart_rate", unit: String = "bpm",
                     value: Double = 60, startAt: Date = Date(timeIntervalSince1970: 1_000),
                     endAt: Date = Date(timeIntervalSince1970: 1_001)) -> HealthSample {
        HealthSample(
            uuid: uuid,
            type: type,
            value: value,
            unit: unit,
            startAt: ISO8601Codec.string(startAt),
            endAt: ISO8601Codec.string(endAt),
            sourceName: "TestSource",
            sourceBundle: "com.test.source",
            device: "TestDevice",
            metadata: nil,
            queuedAt: nil
        )
    }

    static func makeMany(_ count: Int, start: Int = 0) -> [HealthSample] {
        (start..<(start + count)).map { make(uuid: "uuid-\($0)", value: Double($0)) }
    }
}

/// Unique temporary directory per test, removed on teardown.
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("healthbridge-test-\(UUID().uuidString)", isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// In-memory Keychain stub so `SecureConfig` can be tested without a device.
final class FakeKeychain: KeychainStoring {
    private var storage: Data?

    func set(_ data: Data) { storage = data }
    func data() -> Data? { storage }
    func delete() { storage = nil }
}

extension XCTestCase {
    /// Create a temp dir, register cleanup in teardown, return its URL.
    func makeTempDir() -> TempDir {
        let temp = TempDir()
        addTeardownBlock { temp.remove() }
        return temp
    }

    /// True if any value written to `defaults` equals `secret`.
    func defaultsContain(_ defaults: UserDefaults, secret: String) -> Bool {
        defaults.dictionaryRepresentation().values.contains { value in
            (value as? String) == secret
        }
    }
}
