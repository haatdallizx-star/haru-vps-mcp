import Combine
import Foundation

/// Queue/anchor mutations and published status are serialized on the main queue.
final class SyncEngine: ObservableObject {
    struct Status {
        // HealthKit reports completion of the authorization request, not which
        // read permissions the user granted (that information is private).
        var authorized = false
        var endpointConfigured = false
        var backgroundDeliveryEnabled = false
        var pendingCount = 0
        var inflightCount = 0
        var lastUpload = "—"
        var lastError: String?
        var lastSyncError: String?
        var backgroundDeliveryError: String?

        var summary: String {
            "auth request: \(authorized ? "completed" : "pending"), pending: \(pendingCount), inflight: \(inflightCount), upload: \(lastUpload)"
        }
    }

    @Published var status = Status()
    let config: SecureConfig
    let outbox: Outbox
    let anchorStore: AnchorStore
    let uploader: Uploader
    let healthKit: HealthKitReading
    private let backgroundUploader: BackgroundUploader?
    private let send: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    private var deliveryResults: [String: Bool] = [:]
    private var deliveryGeneration = 0
    private var reading = Set<String>()
    private var waiting: [String: [() -> Void]] = [:]
    private var legacyUploading = false
    private var syncErrors: [String: String] = [:]

    init(config: SecureConfig, outbox: Outbox, anchorStore: AnchorStore, uploader: Uploader,
         healthKit: HealthKitReading = HealthKitManager.shared,
         backgroundUploader: BackgroundUploader? = nil,
         send: @escaping (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void = SyncEngine.defaultSend) {
        self.config = config
        self.outbox = outbox
        self.anchorStore = anchorStore
        self.uploader = uploader
        self.healthKit = healthKit
        self.backgroundUploader = backgroundUploader
        self.send = send
        backgroundUploader?.onOutcome = { [weak self] in self?.handleUploadOutcome($0) }
        backgroundUploader?.onChange = { [weak self] in self?.refreshStatus() }
        backgroundUploader?.onError = { [weak self] in self?.status.lastError = $0 }
        recover()
    }

    func recover() {
        if let backgroundUploader { backgroundUploader.start() }
        else { outbox.recoverInflightBatches() }
        refreshStatus()
    }

    func requestAuthorization() {
        healthKit.requestReadAuthorization { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status.authorized = success
                if let error { self.status.lastSyncError = error.localizedDescription }
                if success {
                    self.startBackgroundDelivery()
                    self.manualSync()
                }
                self.refreshStatus()
            }
        }
    }

    func startBackgroundDelivery() {
        deliveryGeneration += 1
        let generation = deliveryGeneration
        deliveryResults.removeAll()
        status.backgroundDeliveryEnabled = false
        status.backgroundDeliveryError = nil
        healthKit.registerObservers(onFired: { [weak self] metric, completion in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                self.sync(metric: metric, completion: completion)
            }
        }, onRegistration: { [weak self] metric, success, error in
            DispatchQueue.main.async {
                guard let self, self.deliveryGeneration == generation else { return }
                self.deliveryResults[metric.typeCode] = success && error == nil
                self.status.backgroundDeliveryEnabled = HealthKitMetrics.all.allSatisfy {
                    self.deliveryResults[$0.typeCode] == true
                }
                if !success || error != nil {
                    self.status.backgroundDeliveryError = "Could not enable \(metric.typeCode): \(error?.localizedDescription ?? "not enabled")"
                }
            }
        })
    }

    /// Coalesce overlapping triggers for a metric into a follow-up read. That
    /// read obtains the anchor after the current read has durably committed it.
    func sync(metric: HealthKitMetric, completion: @escaping () -> Void = {}) {
        let key = metric.typeCode
        guard anchorStore.reloadIfNeeded() else {
            recordSyncError("Cannot read saved positions; collection paused", for: key)
            completion()
            return
        }
        if reading.contains(key) {
            waiting[key, default: []].append(completion)
            return
        }
        reading.insert(key)
        healthKit.readAnchoredSamples(metric: metric, storedAnchorData: anchorStore.anchor(for: key)?.data,
                                     firstRunWindowStart: anchorStore.readStartDate(for: key)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                switch result {
                case .success(let read):
                    self.didRead(metric: metric, samples: read.samples, newAnchorData: read.anchorData)
                case .failure(let error):
                    self.recordSyncError("\(key): \(error.localizedDescription)", for: key)
                }
                self.reading.remove(key)
                completion()
                if let callbacks = self.waiting.removeValue(forKey: key), !callbacks.isEmpty {
                    self.sync(metric: metric) { callbacks.forEach { $0() } }
                }
            }
        }
    }

    /// No progress is committed until EVERY chunk has been saved successfully.
    /// A partial write is safe to replay: sample UUIDs survive and the server
    /// deduplicates retries. Disk failures remain visible separately from HTTP.
    func didRead(metric: HealthKitMetric, samples: [HealthSample], newAnchorData: Data) {
        for batch in Outbox.makeBatches(samples) {
            guard outbox.enqueue(batch) else {
                recordSyncError("Could not save \(metric.typeCode); read position was not advanced", for: metric.typeCode)
                refreshStatus()
                return
            }
        }
        guard anchorStore.update(typeCode: metric.typeCode, anchorData: newAnchorData) else {
            recordSyncError("Could not save read position; queued data is retained", for: metric.typeCode)
            refreshStatus()
            drainQueue()
            return
        }
        recordSyncError(nil, for: metric.typeCode)
        refreshStatus()
        drainQueue()
    }

    func drainQueue() {
        guard let endpoint = config.endpoint, let token = config.token, !token.isEmpty else {
            status.lastError = "Not configured"
            return
        }
        if let backgroundUploader { backgroundUploader.drain(); return }
        // Test/foreground transport seam. The shipping app uses BackgroundUploader.
        guard !legacyUploading, outbox.pendingCount > 0 else { return }
        legacyUploading = true
        uploader.uploadNext(endpoint: endpoint, token: token, onFinish: { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.legacyUploading = false
                self.handleUploadOutcome(outcome)
                if case .success = outcome { self.drainQueue() }
            }
        }, send: send)
    }

    func manualSync() {
        drainQueue()
        for metric in HealthKitMetrics.all { sync(metric: metric) }
    }

    private func recordSyncError(_ message: String?, for type: String) {
        syncErrors[type] = message
        status.lastSyncError = syncErrors.isEmpty ? nil : syncErrors.keys.sorted().compactMap { syncErrors[$0] }.joined(separator: "; ")
    }

    func refreshStatus() {
        status.pendingCount = outbox.pendingCount
        status.inflightCount = outbox.inflightCount
        status.endpointConfigured = config.isConfigured
    }

    private func handleUploadOutcome(_ outcome: UploadOutcome) {
        switch outcome {
        case .success(let accepted, let duplicates, let rejected):
            status.lastUpload = "OK (\(accepted ?? 0) accepted, \(duplicates ?? 0) dup, \(rejected ?? 0) rejected)"
            status.lastError = (rejected ?? 0) > 0 ? "Server rejected some samples; inspect ingest diagnostics" : nil
        case .retryable(let code):
            status.lastUpload = "retry (\(code.map(String.init) ?? "network"))"
            status.lastError = "Upload retryable"
        case .authFailure(let code):
            status.lastUpload = "auth (\(code))"
            status.lastError = "Authentication failed — check token"
        case .validationFailure(let code):
            status.lastUpload = "validation (\(code))"
            status.lastError = "Server rejected batch (\(code))"
        }
        refreshStatus()
    }

    static let defaultSend: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void = { request, complete in
        URLSession.shared.dataTask(with: request) { data, response, error in complete(data, response, error) }.resume()
    }
}
