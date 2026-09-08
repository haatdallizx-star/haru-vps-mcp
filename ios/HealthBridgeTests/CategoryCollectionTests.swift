import XCTest
import HealthKit
@testable import HealthBridge

final class CategoryCollectionTests: XCTestCase {
    func testSleepAndMenstrualTypesAreCollected() {
        XCTAssertNotNil(HealthKitMetrics.metric(typeCode: "sleep"))
        XCTAssertNotNil(HealthKitMetrics.metric(typeCode: "menstrual_flow"))
    }

    func testFirstImportIncludesRecentSleepAndCycles() {
        let anchors = AnchorStore(url: makeTempDir().url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(anchors.readStartDate(for: "sleep", now: now), now.addingTimeInterval(-30 * 86400))
        XCTAssertEqual(anchors.readStartDate(for: "menstrual_flow", now: now), now.addingTimeInterval(-90 * 86400))
        XCTAssertEqual(anchors.readStartDate(for: "heart_rate", now: now), now.addingTimeInterval(-86400))
    }

    func testCategoryEncodingOmitsNumericFieldsAndPreservesCycleStart() throws {
        let sleep = CategorySampleEncoder.makeSample(uuid: "sleep", typeCode: "sleep",
            rawValue: HKCategoryValueSleepAnalysis.asleepREM.rawValue, startAt: Date(), endAt: Date(),
            sourceName: "Watch", sourceBundle: "test", device: nil, metadata: [:], cycleStart: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sleep)) as? [String: Any])
        XCTAssertEqual(object["stage"] as? String, "rem")
        XCTAssertNil(object["value"])
        XCTAssertNil(object["unit"])
        let period = CategorySampleEncoder.makeSample(uuid: "period", typeCode: "menstrual_flow",
            rawValue: HKCategoryValueMenstrualFlow.medium.rawValue, startAt: Date(), endAt: Date(),
            sourceName: nil, sourceBundle: nil, device: nil, metadata: [:], cycleStart: true)
        let periodObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(period)) as? [String: Any])
        XCTAssertEqual(periodObject["flow"] as? String, "medium")
        XCTAssertEqual(periodObject["cycle_start"] as? Bool, true)
    }

    func testDeletedOnlyBatchesSurviveDiskAndProduceVersionTwoEnvelope() throws {
        let outbox = Outbox(root: makeTempDir().url)
        let deletion = DeletedHealthSample(uuid: "gone", type: "sleep")
        let batches = Outbox.makeDeletionBatches([deletion])
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(outbox.enqueue(batches[0]))
        let loaded = try XCTUnwrap(outbox.nextBatchForUpload())
        XCTAssertEqual(loaded.deletedSamples, [deletion])
        let uploader = Uploader(outbox: outbox)
        outbox.markFailed(loaded.id)
        uploader.uploadNext(endpoint: URL(string: "https://example.com/healthkit/v1/ingest")!, token: "fixture", send: { request, complete in
            let root = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(root["schema_version"] as? Int, 2)
            XCTAssertEqual((root["deleted_samples"] as? [[String: String]])?.first?["uuid"], "gone")
            complete(nil, nil, URLError(.notConnectedToInternet))
        })
        XCTAssertEqual(outbox.pendingCount, 1)
    }

    func testLegacyQueueWithoutCategoryOrDeletionFieldsStillDecodes() throws {
        let original = OutboxBatch(samples: TestSamples.makeMany(1))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "deletedSamples")
        let decoded = try JSONDecoder().decode(OutboxBatch.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.samples, original.samples)
        XCTAssertTrue((decoded.deletedSamples ?? []).isEmpty)
    }

    func testCategoryImportPredicateSurvivesAnchorReload() {
        let root = makeTempDir().url
        let store = AnchorStore(url: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(store.update(typeCode: "sleep", anchorData: Data([1]), queryStartAt: start))
        XCTAssertEqual(AnchorStore(url: root).readStartDate(for: "sleep"), start)
    }

    func testEmptyInitialCategoryReadDoesNotConsumeHistoryBeforeAuthorization() throws {
        let outbox = Outbox(root: makeTempDir().url)
        let anchors = AnchorStore(url: makeTempDir().url)
        let engine = SyncEngine(config: SecureConfig(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeKeychain()),
            outbox: outbox, anchorStore: anchors, uploader: Uploader(outbox: outbox), healthKit: FakeHealthKitReader())
        let metric = try XCTUnwrap(HealthKitMetrics.metric(typeCode: "sleep"))
        engine.didRead(metric: metric, samples: [], newAnchorData: Data([1]))
        XCTAssertNil(anchors.anchor(for: "sleep"))
    }

    func testFailedDeletionWriteDoesNotAdvanceExistingAnchor() throws {
        let root = makeTempDir().url
        let outbox = Outbox(root: root)
        let anchors = AnchorStore(url: makeTempDir().url)
        anchors.update(typeCode: "sleep", anchorData: Data([1]))
        let pending = root.appendingPathComponent("pending")
        try FileManager.default.removeItem(at: pending)
        try Data("blocked".utf8).write(to: pending)
        let engine = SyncEngine(config: SecureConfig(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeKeychain()),
            outbox: outbox, anchorStore: anchors, uploader: Uploader(outbox: outbox), healthKit: FakeHealthKitReader())
        engine.didRead(metric: try XCTUnwrap(HealthKitMetrics.metric(typeCode: "sleep")), samples: [],
            newAnchorData: Data([2]), deletedSamples: [DeletedHealthSample(uuid: "gone", type: "sleep")])
        XCTAssertEqual(anchors.anchor(for: "sleep")?.data, Data([1]))
        XCTAssertNotNil(engine.status.lastSyncError)
    }
}
