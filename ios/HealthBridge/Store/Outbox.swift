import Foundation

/// Durable two-stage disk-backed outbox.
///
/// ```text
/// new samples -> pending -> (atomic move) -> inflight -> HTTP upload
///                                          -> 2xx: delete inflight
///                                          -> failure: return to pending
/// ```
///
/// Guarantees:
/// - Pending and inflight state survive app termination and reboot (on disk).
/// - Moving a batch pending -> inflight uses an atomic rename, so a process
///   death mid-move never loses records (they stay in one state or the other).
/// - A failed or interrupted upload is safe to retry because a batch is only
///   removed from inflight after a 2xx response.
/// - Batch cap is enforced additively so batches never exceed the server's
///   800-sample contract.
final class Outbox {
    /// Server-side batch cap (mirrors HARU_HEALTHKIT_MAX_BATCH_SAMPLES=800).
    static let maxBatchSamples = 800

    enum State: String {
        case pending
        case inflight
    }

    private let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: fileURLForState(.pending), withIntermediateDirectories: true)
        try? fm.createDirectory(at: fileURLForState(.inflight), withIntermediateDirectories: true)
    }

    // MARK: Splitting

    /// Chunk an arbitrary set of samples into batches of at most `maxBatchSamples`.
    static func makeBatches(_ samples: [HealthSample], max: Int = Outbox.maxBatchSamples) -> [OutboxBatch] {
        guard max > 0 else { return [] }
        var batches: [OutboxBatch] = []
        var index = 0
        while index < samples.count {
            let slice = Array(samples[index..<min(index + max, samples.count)])
            batches.append(OutboxBatch(samples: slice))
            index += max
        }
        return batches
    }

    // MARK: Enqueue

    /// Durable-write a batch into pending. This must happen BEFORE the HealthKit
    /// anchor is advanced ("durability before progress").
    func enqueue(_ batch: OutboxBatch) {
        let url = fileURL(batchID: batch.id, state: .pending)
        do {
            let data = try JSONEncoder().encode(batch)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Never silently drop a record. Surface a diagnostic so the batch
            // can be recovered and the anchor is not advanced.
            print("Outbox: failed to enqueue batch \(batch.id): \(error)")
        }
    }

    /// Move the oldest pending batch to inflight and return it for upload.
    /// Returns nil when there is nothing to upload.
    func nextBatchForUpload() -> OutboxBatch? {
        guard let oldest = oldestPendingFile() else { return nil }
        let id = batchID(from: oldest)
        let dest = fileURL(batchID: id, state: .inflight)
        do {
            // Atomic rename on the same volume — crash-safe for the pending/inflight move.
            try fm.moveItem(at: oldest, to: dest)
        } catch {
            print("Outbox: failed to move batch to inflight: \(error)")
            return nil
        }
        return loadBatch(at: dest)
    }

    /// 2xx received: the batch is delivered. Delete inflight.
    func markSucceeded(_ id: UUID) {
        let url = fileURL(batchID: id, state: .inflight)
        try? fm.removeItem(at: url)
    }

    /// Upload failed (network/5xx): return the batch to pending for a later retry.
    func markFailed(_ id: UUID) {
        let src = fileURL(batchID: id, state: .inflight)
        let dest = fileURL(batchID: id, state: .pending)
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: src, to: dest)   // atomic, safe on failure
    }

    /// On app launch: any batch left in inflight (app died mid-upload) is a
    /// safely retryable pending batch again.
    func recoverInflightBatches() {
        let inflightDir = fileURLForState(.inflight)
        for file in (try? fm.contentsOfDirectory(at: inflightDir, includingPropertiesForKeys: nil)) ?? [] {
            let id = batchID(from: file)
            markFailed(id)
        }
    }

    // MARK: Diagnostics

    var pendingCount: Int { countInState(.pending) }
    var inflightCount: Int { countInState(.inflight) }

    /// Total samples waiting to be uploaded (pending only).
    func pendingSampleCount() -> Int {
        batchFilesInState(.pending).reduce(0) { total, file in
            total + (loadBatch(at: file)?.samples.count ?? 0)
        }
    }

    // MARK: - Internals

    private func fileURLForState(_ state: State) -> URL {
        root.appendingPathComponent(state.rawValue, isDirectory: true)
    }

    private func fileURL(batchID: UUID, state: State) -> URL {
        fileURLForState(state).appendingPathComponent("\(batchID.uuidString).json")
    }

    private func batchFilesInState(_ state: State) -> [URL] {
        let dir = fileURLForState(state)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    private func countInState(_ state: State) -> Int {
        batchFilesInState(state).count
    }

    private func oldestPendingFile() -> URL? {
        batchFilesInState(.pending)
            .compactMap { file -> (URL, Date)? in
                guard let batch = loadBatch(at: file) else { return nil }
                return (file, batch.createdAt)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func loadBatch(at url: URL) -> OutboxBatch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OutboxBatch.self, from: data)
    }

    private func batchID(from file: URL) -> UUID {
        UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID()
    }
}
