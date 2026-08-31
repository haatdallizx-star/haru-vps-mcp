import XCTest
@testable import HealthBridge

final class AnchorStoreTests: XCTestCase {

    func testNoAnchorMeansFirstRunWindowIsLast24h() {
        let store = AnchorStore(url: makeTempDir().url)
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertFalse(store.hasAnchor(for: "heart_rate"))
        XCTAssertEqual(
            store.readStartDate(for: "heart_rate", now: now),
            now.addingTimeInterval(-24 * 60 * 60)   // previous 24 hours only
        )
    }

    func testStoredAnchorMeansIncrementalReadNoWindow() {
        let store = AnchorStore(url: makeTempDir().url)
        store.update(typeCode: "heart_rate", anchorData: Data([1, 2, 3]), now: Date())

        XCTAssertTrue(store.hasAnchor(for: "heart_rate"))
        XCTAssertNil(store.readStartDate(for: "heart_rate", now: Date()))   // incremental
    }

    func testAnchorIsPerMetricType() {
        let store = AnchorStore(url: makeTempDir().url)
        store.update(typeCode: "heart_rate", anchorData: Data([9]), now: Date())

        XCTAssertTrue(store.hasAnchor(for: "heart_rate"))
        XCTAssertFalse(store.hasAnchor(for: "steps"))   // independent per type
        XCTAssertNotNil(store.readStartDate(for: "steps", now: Date()))
    }

    func testAnchorPersistsAcrossReload() {
        let root = makeTempDir().url

        let first = AnchorStore(url: root)
        first.update(typeCode: "hrv", anchorData: Data([7, 8, 9]), now: Date())

        let reloaded = AnchorStore(url: root)
        XCTAssertEqual(reloaded.anchor(for: "hrv")?.data, Data([7, 8, 9]))
    }

    /// Durability-before-progress: the anchor must only be advanced after samples
    /// are durably queued. This asserts the store treats update as a positive,
    /// per-type progress marker independent of the queue (the ordering is enforced
    /// by the SyncEngine which enqueues before calling update).
    func testSamplesQueuedBeforeAnchorAdvanceIsObservable() {
        let root = makeTempDir().url
        let outbox = Outbox(root: root.appendingPathComponent("outbox"))
        let anchors = AnchorStore(url: root.appendingPathComponent("anchors"))

        // Simulate the SyncEngine ordering: queue first, then advance anchor.
        let samples = TestSamples.makeMany(Outbox.maxBatchSamples)
        let beforeAnchor = anchors.anchor(for: "heart_rate")

        for batch in Outbox.makeBatches(samples) {
            outbox.enqueue(batch)
        }
        anchors.update(typeCode: "heart_rate", anchorData: Data([42]), now: Date())

        XCTAssertNil(beforeAnchor)                          // first run -> was nil
        XCTAssertEqual(outbox.pendingCount, 1)              // samples durable
        XCTAssertEqual(anchors.anchor(for: "heart_rate")?.data, Data([42]))  // then anchor advanced
    }
}
