import XCTest
@testable import HealthBridge

final class FakeBackgroundTransfer: BackgroundTransferring {
    var onCompletion: ((UUID, UploadOutcome) -> Void)?
    var onEventsFinished: (() -> Void)?
    var reconnectCompletion: ((Set<UUID>) -> Void)?
    var submissions: [(UUID, URLRequest, URL)] = []
    func reconnect(completion: @escaping (Set<UUID>) -> Void) { reconnectCompletion = completion }
    func submit(request: URLRequest, file: URL, batchID: UUID) { submissions.append((batchID, request, file)) }
}

final class BackgroundUploadTests: XCTestCase {
    private func fixture() -> (Outbox, FakeBackgroundTransfer, BackgroundUploader, URL) {
        let root = makeTempDir().url
        let outbox = Outbox(root: root.appendingPathComponent("outbox"))
        let config = SecureConfig(defaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: FakeKeychain())
        config.save(endpoint: "https://example.com/healthkit/v1/ingest", token: "fixture-secret")
        let transport = FakeBackgroundTransfer()
        let bodies = root.appendingPathComponent("bodies")
        return (outbox, transport, BackgroundUploader(outbox: outbox, config: config, bodyDirectory: bodies, transport: transport), bodies)
    }

    func testRecoveryWaitsForSystemAndDoesNotResubmitActiveBatch() {
        let (outbox, transfer, uploader, _) = fixture()
        let active = OutboxBatch(samples: TestSamples.makeMany(1))
        outbox.enqueue(active)
        _ = outbox.nextBatchForUpload()
        uploader.start()
        uploader.drain()
        XCTAssertTrue(transfer.submissions.isEmpty)
        transfer.reconnectCompletion?([active.id])
        XCTAssertEqual(outbox.inflightCount, 1)
        XCTAssertTrue(transfer.submissions.isEmpty)
    }

    func testOrphanRecoverySubmitsFileEnvelopeWithoutTokenOnDisk() throws {
        let (outbox, transfer, uploader, _) = fixture()
        let batch = OutboxBatch(samples: TestSamples.makeMany(1))
        outbox.enqueue(batch)
        _ = outbox.nextBatchForUpload()
        uploader.start()
        transfer.reconnectCompletion?([])
        XCTAssertEqual(transfer.submissions.count, 1)
        let (_, request, file) = try XCTUnwrap(transfer.submissions.first)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        let data = try Data(contentsOf: file)
        let envelope = try JSONDecoder().decode(IngestEnvelope.self, from: data)
        XCTAssertEqual(envelope.samples, batch.samples)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
        transfer.onCompletion?(batch.id, .success(accepted: 1, duplicates: 0, rejected: 0))
        XCTAssertEqual(outbox.inflightCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFailureRetainsDataAndDoesNotTightLoop() {
        let (outbox, transfer, uploader, _) = fixture()
        let batch = OutboxBatch(samples: TestSamples.makeMany(1))
        outbox.enqueue(batch)
        uploader.start()
        transfer.reconnectCompletion?([])
        transfer.onCompletion?(batch.id, .authFailure(statusCode: 401))
        XCTAssertEqual(outbox.pendingCount, 1)
        XCTAssertEqual(transfer.submissions.count, 1)
        uploader.drain()
        XCTAssertEqual(transfer.submissions.count, 2)
    }

    func testCompletionDuringReconciliationDoesNotLeavePhantomActiveTask() {
        let (outbox, transfer, uploader, _) = fixture()
        let batch = OutboxBatch(samples: TestSamples.makeMany(1))
        outbox.enqueue(batch)
        _ = outbox.nextBatchForUpload()
        uploader.start()
        transfer.onCompletion?(batch.id, .retryable(statusCode: nil))
        transfer.reconnectCompletion?([batch.id])
        XCTAssertEqual(outbox.pendingCount, 1)
        uploader.drain()
        XCTAssertEqual(transfer.submissions.count, 1)
    }

    func testBodyWriteFailureRequeuesBatch() throws {
        let (outbox, transfer, uploader, bodies) = fixture()
        try FileManager.default.createDirectory(at: bodies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: bodies)
        outbox.enqueue(OutboxBatch(samples: TestSamples.makeMany(1)))
        uploader.start()
        transfer.reconnectCompletion?([])
        XCTAssertEqual(outbox.pendingCount, 1)
        XCTAssertEqual(outbox.inflightCount, 0)
        XCTAssertTrue(transfer.submissions.isEmpty)
    }

    func testBackgroundCompletionRunsOnceAfterReconciliation() {
        let (_, transfer, uploader, _) = fixture()
        var calls = 0
        uploader.start()
        uploader.handleBackgroundEvents { calls += 1 }
        transfer.onEventsFinished?()
        XCTAssertEqual(calls, 0)
        transfer.reconnectCompletion?([])
        XCTAssertEqual(calls, 1)
        transfer.onEventsFinished?() // unmatched old notification must not finish the next wake
        XCTAssertEqual(calls, 1)
        uploader.handleBackgroundEvents { calls += 1 }
        XCTAssertEqual(calls, 1)
        transfer.onEventsFinished?()
        XCTAssertEqual(calls, 2)
    }

    func testPendingBatchesContinueAfterSuccessfulUpload() {
        let (outbox, transfer, uploader, _) = fixture()
        for _ in 0..<6 { outbox.enqueue(OutboxBatch(samples: TestSamples.makeMany(1))) }
        uploader.start()
        transfer.reconnectCompletion?([])
        XCTAssertEqual(transfer.submissions.count, BackgroundUploader.maxConcurrentUploads)
        let id = transfer.submissions[0].0
        transfer.onCompletion?(id, .success(accepted: 1, duplicates: 0, rejected: 0))
        XCTAssertEqual(transfer.submissions.count, BackgroundUploader.maxConcurrentUploads + 1)
    }
}
