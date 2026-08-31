import XCTest
@testable import HealthBridge

final class SampleEncoderTests: XCTestCase {

    func testHeartRateUsesCanonicalUnit() {
        let metric = HealthKitMetrics.metric(typeCode: "heart_rate")!
        let encoder = SampleEncoder(metric: metric, now: { Date(timeIntervalSince1970: 0) })

        let sample = encoder.makeSample(
            uuid: "U1",
            value: 72.5,
            startAt: Date(timeIntervalSince1970: 100),
            endAt: Date(timeIntervalSince1970: 200),
            sourceName: "Watch",
            sourceBundle: "com.apple.watch",
            device: "Watch",
            metadata: [:]
        )

        XCTAssertEqual(sample.type, "heart_rate")
        XCTAssertEqual(sample.unit, "bpm")
        XCTAssertEqual(sample.value, 72.5)
        XCTAssertEqual(sample.startAt, "1970-01-01T00:01:40.000Z")
        XCTAssertEqual(sample.endAt, "1970-01-01T00:03:20.000Z")
        XCTAssertEqual(sample.queuedAt, "1970-01-01T00:00:00.000Z")
        XCTAssertNil(sample.metadata)   // empty metadata -> nil
    }

    func testHRVAndStepsUnits() {
        let hrv = SampleEncoder(metric: HealthKitMetrics.metric(typeCode: "hrv")!, now: { Date() })
        let hrvSample = hrv.makeSample(uuid: "H", value: 42, startAt: Date(), endAt: Date(), sourceName: nil, sourceBundle: nil, device: nil, metadata: [:])
        XCTAssertEqual(hrvSample.unit, "ms")

        let steps = SampleEncoder(metric: HealthKitMetrics.metric(typeCode: "steps")!, now: { Date() })
        let stepsSample = steps.makeSample(uuid: "S", value: 1500, startAt: Date(), endAt: Date(), sourceName: nil, sourceBundle: nil, device: nil, metadata: [:])
        XCTAssertEqual(stepsSample.unit, "count")
    }

    func testMetadataAllowListDropsDisallowedKeys() {
        let encoder = SampleEncoder(metric: HealthKitMetrics.metric(typeCode: "steps")!, now: { Date() })
        let sample = encoder.makeSample(
            uuid: "M",
            value: 1,
            startAt: Date(),
            endAt: Date(),
            sourceName: nil,
            sourceBundle: nil,
            device: nil,
            metadata: [
                "HKWasUserEntered": "true",            // allowed
                "HKMetadataKeyHeartRateMotionContext": "1", // allowed
                "HKObjectTypeIdentifierBloodType": "sensitive", // dropped
                "SenderName": "dropped",
            ]
        )

        XCTAssertEqual(sample.metadata, ["HKWasUserEntered": "true", "HKMetadataKeyHeartRateMotionContext": "1"])
    }
}
