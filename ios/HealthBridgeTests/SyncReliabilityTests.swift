import XCTest
@testable import HealthBridge

final class SyncReliabilityTests: XCTestCase {
    func testFailedEnqueueDoesNotAdvanceAnchor() throws {
        let root = makeTempDir().url
        let outbox = Outbox(root: root)
        let pending = root.appendingPathComponent("pending")
        try FileManager.default.removeItem(at: pending)
        try Data("blocked".utf8).write(to: pending)
        let anchors = AnchorStore(url: makeTempDir().url)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let engine = SyncEngine(config: SecureConfig(defaults: defaults, keychain: FakeKeychain()),
                                outbox: outbox, anchorStore: anchors, uploader: Uploader(outbox: outbox),
                                healthKit: FakeHealthKitReader())

        engine.didRead(metric: HealthKitMetrics.all[0], samples: TestSamples.makeMany(1),
                       newAnchorData: Data([1, 2, 3]))

        XCTAssertNil(anchors.anchor(for: "heart_rate"), "Unsaved samples must remain readable from the old anchor")
        XCTAssertNotNil(engine.status.lastSyncError)
    }

    func testTransportErrorWith200ResponseRetainsBatch() {
        let outbox = Outbox(root: makeTempDir().url)
        outbox.enqueue(OutboxBatch(samples: TestSamples.makeMany(1)))
        let uploader = Uploader(outbox: outbox)
        let endpoint = URL(string: "https://example.com/healthkit/v1/ingest")!
        uploader.uploadNext(endpoint: endpoint, token: "test", send: { _, complete in
            complete(nil, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil),
                     URLError(.networkConnectionLost))
        })
        XCTAssertEqual(outbox.pendingCount, 1)
        XCTAssertEqual(outbox.inflightCount, 0)
    }
}

final class FakeHealthKitReader: HealthKitReading {
    var fired: ((HealthKitMetric, @escaping () -> Void) -> Void)?
    var registration: ((HealthKitMetric, Bool, Error?) -> Void)?
    var reads: [(Data?, (Result<AnchoredSamples, Error>) -> Void)] = []
    func requestReadAuthorization(completion: @escaping (Bool, Error?) -> Void) { completion(true, nil) }
    func registerObservers(onFired: @escaping (HealthKitMetric, @escaping () -> Void) -> Void,
                           onRegistration: @escaping (HealthKitMetric, Bool, Error?) -> Void) {
        fired = onFired
        registration = onRegistration
    }
    func readAnchoredSamples(metric: HealthKitMetric, storedAnchorData: Data?, firstRunWindowStart: Date?,
                             completion: @escaping (Result<AnchoredSamples, Error>) -> Void) {
        reads.append((storedAnchorData, completion))
    }
}

extension SyncReliabilityTests {
    private func fixture() -> (SyncEngine, FakeHealthKitReader) {
        let outbox = Outbox(root: makeTempDir().url)
        let reader = FakeHealthKitReader()
        let engine = SyncEngine(config: SecureConfig(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeKeychain()),
                                outbox: outbox, anchorStore: AnchorStore(url: makeTempDir().url),
                                uploader: Uploader(outbox: outbox), healthKit: reader)
        return (engine, reader)
    }

    func testObserverAcknowledgedAfterSamplesAndAnchorAreDurable() {
        let (engine, reader) = fixture()
        engine.startBackgroundDelivery()
        let done = expectation(description: "observer acknowledged")
        var acknowledged = false
        reader.fired?(HealthKitMetrics.all[0], {
            acknowledged = true
            XCTAssertEqual(engine.outbox.pendingCount, 1)
            XCTAssertEqual(engine.anchorStore.anchor(for: "heart_rate")?.data, Data([9]))
            done.fulfill()
        })
        let readStarted = expectation(description: "read started")
        DispatchQueue.main.async {
            XCTAssertFalse(acknowledged)
            XCTAssertEqual(reader.reads.count, 1)
            reader.reads[0].1(.success(AnchoredSamples(samples: TestSamples.makeMany(1), anchorData: Data([9]))))
            readStarted.fulfill()
        }
        wait(for: [readStarted, done], timeout: 2)
    }

    func testQueryFailureCompletesObserverAndPreservesAnchor() {
        let (engine, reader) = fixture()
        let old = Data([7])
        engine.anchorStore.update(typeCode: "heart_rate", anchorData: old)
        let done = expectation(description: "failed read settled")
        engine.sync(metric: HealthKitMetrics.all[0]) { done.fulfill() }
        reader.reads[0].1(.failure(URLError(.cannotLoadFromNetwork)))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(engine.anchorStore.anchor(for: "heart_rate")?.data, old)
        XCTAssertNotNil(engine.status.lastSyncError)
    }

    func testOverlappingReadsUseNewAnchorAndCompleteEachTriggerOnce() {
        let (engine, reader) = fixture()
        let first = expectation(description: "first read")
        let next = expectation(description: "follow-up read")
        let metric = HealthKitMetrics.all[0]
        engine.sync(metric: metric) { first.fulfill() }
        engine.sync(metric: metric) { next.fulfill() }
        XCTAssertEqual(reader.reads.count, 1)
        reader.reads[0].1(.success(AnchoredSamples(samples: [], anchorData: Data([1]))))
        wait(for: [first], timeout: 2)
        XCTAssertEqual(reader.reads.count, 2)
        XCTAssertEqual(reader.reads[1].0, Data([1]))
        reader.reads[1].1(.success(AnchoredSamples(samples: [], anchorData: Data([2]))))
        wait(for: [next], timeout: 2)
        XCTAssertEqual(engine.anchorStore.anchor(for: "heart_rate")?.data, Data([2]))
    }

    func testBackgroundStatusRequiresEveryRegistrationToSucceed() {
        let (engine, reader) = fixture()
        engine.startBackgroundDelivery()
        XCTAssertFalse(engine.status.backgroundDeliveryEnabled)
        for metric in HealthKitMetrics.all { reader.registration?(metric, metric.typeCode != "steps", nil) }
        let applied = expectation(description: "registration applied")
        DispatchQueue.main.async { applied.fulfill() }
        wait(for: [applied], timeout: 2)
        XCTAssertFalse(engine.status.backgroundDeliveryEnabled)
        XCTAssertNotNil(engine.status.backgroundDeliveryError)
    }

    func testSuccessfulMetricDoesNotHideOtherMetricReadFailure() {
        let (engine, reader) = fixture()
        let done = expectation(description: "failed heart rate read")
        engine.sync(metric: HealthKitMetrics.all[0]) { done.fulfill() }
        reader.reads[0].1(.failure(URLError(.cannotLoadFromNetwork)))
        wait(for: [done], timeout: 2)
        engine.didRead(metric: HealthKitMetrics.all[1], samples: [], newAnchorData: Data([8]))
        XCTAssertNotNil(engine.status.lastSyncError)
        XCTAssertTrue(engine.status.lastSyncError?.contains("heart_rate") == true)
    }

    func testFailedAnchorWriteKeepsOldMemoryValue() throws {
        let root = makeTempDir().url
        let anchors = AnchorStore(url: root)
        let old = Data([1])
        anchors.update(typeCode: "heart_rate", anchorData: old)
        let file = root.appendingPathComponent("anchors.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(anchors.update(typeCode: "heart_rate", anchorData: Data([2])))
        XCTAssertEqual(anchors.anchor(for: "heart_rate")?.data, old)
    }

    func testCorruptAnchorFileIsNotOverwrittenAsFreshHistory() throws {
        let root = makeTempDir().url
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("anchors.json")
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: file)
        let anchors = AnchorStore(url: root)
        XCTAssertFalse(anchors.reloadIfNeeded())
        XCTAssertFalse(anchors.update(typeCode: "heart_rate", anchorData: Data([2])))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
