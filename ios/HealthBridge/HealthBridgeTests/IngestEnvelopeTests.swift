import XCTest
@testable import HealthBridgeCore

final class IngestEnvelopeTests: XCTestCase {
    func testEnvelopeMatchesHardenedServerContract() throws {
        let sample = WireSample(
            uuid: "sample", type: "steps", value: 10, unit: "count", stage: nil, stageRaw: nil,
            startAt: Date(timeIntervalSince1970: 100), endAt: Date(timeIntervalSince1970: 101),
            queuedAt: Date(timeIntervalSince1970: 102), sourceName: nil, sourceBundle: nil, device: nil, metadata: [:]
        )
        let deletion = WireDeletion(uuid: "gone", metric: "steps", queuedAt: Date(timeIntervalSince1970: 103))
        let aggregate = StepAggregateSnapshot(
            bucketStart: Date(timeIntervalSince1970: 0), bucketEnd: Date(timeIntervalSince1970: 86_400),
            value: 4321, computedAt: Date(timeIntervalSince1970: 104)
        )
        let envelope = IngestEnvelope(
            deviceID: "installation", appVersion: "1.0", queueDepth: 2,
            sentAt: Date(timeIntervalSince1970: 105), samples: [sample], deletions: [deletion], aggregates: [aggregate]
        )
        let data = try HealthBridgeJSON.encoder.encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["device_id"] as? String, "installation")
        XCTAssertEqual(object["app_version"] as? String, "1.0")
        XCTAssertEqual(object["queue_depth"] as? Int, 2)
        XCTAssertEqual((object["samples"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["deletions"] as? [[String: Any]])?.count, 1)
        let aggregateJSON = try XCTUnwrap((object["aggregates"] as? [[String: Any]])?.first)
        XCTAssertEqual(aggregateJSON["metric"] as? String, "steps")
        XCTAssertEqual(aggregateJSON["unit"] as? String, "count")
        XCTAssertEqual(aggregateJSON["source"] as? String, "healthkit_statistics")
    }

    func testOnlyHTTP2xxCountsAsUploadSuccess() {
        XCTAssertTrue(UploadResultPolicy.isSuccess(statusCode: 200))
        XCTAssertTrue(UploadResultPolicy.isSuccess(statusCode: 204))
        XCTAssertFalse(UploadResultPolicy.isSuccess(statusCode: 199))
        XCTAssertFalse(UploadResultPolicy.isSuccess(statusCode: 400))
        XCTAssertFalse(UploadResultPolicy.isSuccess(statusCode: 500))
    }
}
