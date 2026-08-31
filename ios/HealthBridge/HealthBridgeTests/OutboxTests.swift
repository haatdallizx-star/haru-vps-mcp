import XCTest
@testable import HealthBridgeCore

final class OutboxTests: XCTestCase {
    private func makeOutbox() throws -> Outbox {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("outbox.sqlite3")
        return try Outbox(databaseURL: url)
    }

    private func sample(_ uuid: String = UUID().uuidString) -> WireSample {
        WireSample(
            uuid: uuid, type: "heart_rate", value: 70, unit: "bpm", stage: nil, stageRaw: nil,
            startAt: Date(timeIntervalSince1970: 100), endAt: Date(timeIntervalSince1970: 101),
            queuedAt: Date(timeIntervalSince1970: 102), sourceName: nil, sourceBundle: nil,
            device: nil, metadata: [:]
        )
    }

    func testEnqueueAndAnchorCommitAreAtomicAndDurable() throws {
        let outbox = try makeOutbox()
        try outbox.enqueue(samples: [sample("one")], deletions: [], metric: .heartRate, anchorData: Data([1, 2, 3]))
        XCTAssertEqual(try outbox.queueDepth(), 1)
        XCTAssertEqual(try outbox.anchorData(for: .heartRate), Data([1, 2, 3]))
        XCTAssertEqual(try outbox.pendingBatch(limit: 10).samples.map(\.uuid), ["one"])
    }

    func testPendingMovesToInflightAndOnlySuccessDeletesIt() throws {
        let outbox = try makeOutbox()
        try outbox.enqueue(samples: [sample("one"), sample("two")], deletions: [], metric: .heartRate, anchorData: Data([9]))
        let batch = try outbox.beginUpload(limit: 10)
        XCTAssertEqual(batch.samples.count, 2)
        XCTAssertEqual(try outbox.queueDepth(), 2)
        try outbox.finishUpload(success: false)
        XCTAssertEqual(try outbox.queueDepth(), 2)
        XCTAssertEqual(try outbox.beginUpload(limit: 10).samples.count, 2)
        try outbox.finishUpload(success: true)
        XCTAssertEqual(try outbox.queueDepth(), 0)
    }

    func testDeletionSharesSameDurableQueue() throws {
        let outbox = try makeOutbox()
        let deletion = WireDeletion(uuid: "gone", metric: "sleep", queuedAt: Date())
        try outbox.enqueue(samples: [], deletions: [deletion], metric: .sleep, anchorData: Data([4]))
        XCTAssertEqual(try outbox.pendingBatch(limit: 10).deletions.map(\.uuid), ["gone"])
    }
}
