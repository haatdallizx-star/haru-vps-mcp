import XCTest
@testable import HealthBridge

final class OutboxTests: XCTestCase {

    func testPendingToInflightThenSucceed() {
        let outbox = Outbox(root: makeTempDir().url)
        let batch = OutboxBatch(samples: TestSamples.makeMany(3))

        outbox.enqueue(batch)
        XCTAssertEqual(outbox.pendingCount, 1)
        XCTAssertEqual(outbox.inflightCount, 0)

        let submitted = outbox.nextBatchForUpload()
        XCTAssertEqual(submitted?.id, batch.id)
        XCTAssertEqual(submitted?.samples.count, 3)
        XCTAssertEqual(outbox.pendingCount, 0)
        XCTAssertEqual(outbox.inflightCount, 1)

        outbox.markSucceeded(batch.id)
        XCTAssertEqual(outbox.inflightCount, 0)
        XCTAssertEqual(outbox.pendingCount, 0)
    }

    func testFailedUploadRequeuesToPending() {
        let outbox = Outbox(root: makeTempDir().url)
        let batch = OutboxBatch(samples: TestSamples.makeMany(2))

        outbox.enqueue(batch)
        _ = outbox.nextBatchForUpload()
        outbox.markFailed(batch.id)

        XCTAssertEqual(outbox.inflightCount, 0)
        XCTAssertEqual(outbox.pendingCount, 1)
    }

    func testQueuePersistsAcrossReload() {
        let root = makeTempDir().url

        let first = Outbox(root: root)
        let batch = OutboxBatch(samples: TestSamples.makeMany(4))
        first.enqueue(batch)

        // A new Outbox over the same directory sees the persisted pending batch.
        let second = Outbox(root: root)
        XCTAssertEqual(second.pendingCount, 1)
        let submitted = second.nextBatchForUpload()
        XCTAssertEqual(submitted?.id, batch.id)
    }

    func testInflightRecoveredToPendingOnLaunch() {
        let root = makeTempDir().url
        let outbox = Outbox(root: root)
        let batch = OutboxBatch(samples: TestSamples.makeMany(5))
        outbox.enqueue(batch)
        _ = outbox.nextBatchForUpload()   // leaves it in inflight (simulate app dying mid-upload)
        XCTAssertEqual(outbox.inflightCount, 1)

        let relaunched = Outbox(root: root)
        relaunched.recoverInflightBatches()

        XCTAssertEqual(relaunched.inflightCount, 0)
        XCTAssertEqual(relaunched.pendingCount, 1)
    }

    func testMakeBatchesCapsAtMaxSamples() {
        let samples = TestSamples.makeMany(Outbox.maxBatchSamples + 300)
        let batches = Outbox.makeBatches(samples)

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].samples.count, Outbox.maxBatchSamples)
        XCTAssertEqual(batches[1].samples.count, 300)
    }

    func testMakeBatchesUnderCapacityIsSingleBatch() {
        let samples = TestSamples.makeMany(10)
        let batches = Outbox.makeBatches(samples)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].samples.count, 10)
    }
}
