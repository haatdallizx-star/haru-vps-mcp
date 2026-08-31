import Foundation
import HealthKit

public final class SyncCoordinator {
    private let health: HealthKitManager
    private let outbox: Outbox
    private let uploader: Uploader
    private let encoder = SampleEncoder()
    private var retryAttempt = 0

    public init(config: SecureConfig, health: HealthKitManager = HealthKitManager()) throws {
        self.health = health
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HealthBridge", isDirectory: true)
        self.outbox = try Outbox(databaseURL: base.appendingPathComponent("outbox.sqlite3"))
        let defaults = UserDefaults.standard
        let deviceID: String
        if let existing = defaults.string(forKey: "healthbridge.device_id") { deviceID = existing }
        else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "healthbridge.device_id")
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.uploader = Uploader(config: config, deviceID: deviceID, appVersion: appVersion)
    }

    public func prepare() async throws {
        try await health.requestAuthorization()
        try await health.enableBackgroundDelivery()
        health.installObservers { [weak self] metric, completion in
            self?.sync(metric: metric) { _ in completion() } ?? completion()
        }
    }

    public func syncNow() async throws {
        for metric in HealthMetric.allCases {
            try await withCheckedThrowingContinuation { continuation in
                sync(metric: metric) { result in continuation.resume(with: result) }
            }
        }
        try uploadPending()
    }

    public func queueDepth() -> Int { (try? outbox.queueDepth()) ?? 0 }

    private func sync(metric: HealthMetric, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let anchorData = try outbox.anchorData(for: metric)
            let anchor = try anchorData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
            let start = SyncPolicy.startDate(hasAnchor: anchor != nil)
            guard let query = health.anchoredQuery(metric: metric, anchor: anchor, startDate: start, handler: { [weak self] samples, deletions, newAnchor, error in
                guard let self else { completion(.success(())); return }
                if let error { completion(.failure(error)); return }
                guard let newAnchor else { completion(.failure(SyncCoordinatorError.missingAnchor)); return }
                do {
                    let queuedAt = Date()
                    let wireSamples = try samples.map { try self.encoder.encode(sample: $0, metric: metric, queuedAt: queuedAt) }
                    let wireDeletions = deletions.map { self.encoder.encodeDeletion($0, metric: metric, queuedAt: queuedAt) }
                    let newAnchorData = try NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                    try self.outbox.enqueue(samples: wireSamples, deletions: wireDeletions, metric: metric, anchorData: newAnchorData)
                    try self.uploadPending()
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }) else {
                completion(.failure(SyncCoordinatorError.sampleTypeUnavailable)); return
            }
            health.store.execute(query)
        } catch { completion(.failure(error)) }
    }

    private func uploadPending() throws {
        let batch = try outbox.beginUpload(limit: 800)
        guard !batch.samples.isEmpty || !batch.deletions.isEmpty else { try outbox.finishUpload(success: false); return }
        let depth = try outbox.queueDepth()
        Task { [weak self] in
            guard let self else { return }
            let aggregate = try? await StepAggregateBuilder.query(store: self.health.store)
            do {
                try self.uploader.upload(samples: batch.samples, deletions: batch.deletions, aggregates: aggregate.map { [$0] } ?? [], queueDepth: depth) { [weak self] success in
                    guard let self else { return }
                    do { try self.outbox.finishUpload(success: success) } catch { return }
                    if success { self.retryAttempt = 0 }
                    else { self.scheduleRetry() }
                }
            } catch {
                try? self.outbox.finishUpload(success: false)
                self.scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        let delay = SyncPolicy.retryDelay(attempt: retryAttempt)
        retryAttempt += 1
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in try? self?.uploadPending() }
    }
}

public enum SyncCoordinatorError: Error { case sampleTypeUnavailable, missingAnchor }
