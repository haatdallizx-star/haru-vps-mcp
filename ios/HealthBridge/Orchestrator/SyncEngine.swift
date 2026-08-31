import Combine
import Foundation

/// Observable diagnostics surface for the UI: authorization, config, queue depth,
/// and last upload result.
final class SyncEngine: ObservableObject {
    struct Status {
        var authorized = false
        var endpointConfigured = false
        var backgroundDeliveryEnabled = false
        var pendingCount = 0
        var inflightCount = 0
        var lastUpload = "—"
        var lastError: String?

        var summary: String {
            var parts: [String] = []
            parts.append(authorized ? "auth: granted" : "auth: pending")
            parts.append("pending: \(pendingCount)")
            parts.append("inflight: \(inflightCount)")
            parts.append("upload: \(lastUpload)")
            return parts.joined(separator: ", ")
        }
    }

    @Published var status = Status()

    let config: SecureConfig
    let outbox: Outbox
    let anchorStore: AnchorStore
    let uploader: Uploader
    let healthKit: HealthKitManager
    /// Network transport seam — replaced by a real background URLSession in the app.
    private let send: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    init(
        config: SecureConfig,
        outbox: Outbox,
        anchorStore: AnchorStore,
        uploader: Uploader,
        healthKit: HealthKitManager = .shared,
        send: @escaping (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void = SyncEngine.defaultSend
    ) {
        self.config = config
        self.outbox = outbox
        self.anchorStore = anchorStore
        self.uploader = uploader
        self.healthKit = healthKit
        self.send = send
        recover()
    }

    /// Recover any in-flight batches to a safely retryable state on launch.
    func recover() {
        outbox.recoverInflightBatches()
        refreshStatus()
    }

    func requestAuthorization() {
        healthKit.requestReadAuthorization { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.status.authorized = success
                self?.refreshStatus()
            }
        }
    }

    /// Register HealthKit observers (called at launch so background relaunch works).
    func startBackgroundDelivery() {
        healthKit.registerObservers { [weak self] metric in
            self?.sync(metric: metric)
        }
        status.backgroundDeliveryEnabled = true
    }

    /// Handle an observer fire: read from the stored anchor (or the 24 h first-run
    /// window when no anchor exists) and route the returned samples through
    /// durability-before-progress.
    private func sync(metric: HealthKitMetric) {
        let anchorData = anchorStore.anchor(for: metric.typeCode)?.data
        let windowStart = anchorStore.readStartDate(for: metric.typeCode)
        healthKit.readAnchoredSamples(
            metric: metric,
            storedAnchorData: anchorData,
            firstRunWindowStart: windowStart
        ) { [weak self] metric, samples, newAnchorData in
            self?.didRead(metric: metric, samples: samples, newAnchorData: newAnchorData)
        }
    }

    /// Durability-before-progress: persist samples to the outbox, then advance the
    /// anchor, then drain the queue.
    func didRead(metric: HealthKitMetric, samples: [HealthSample], newAnchorData: Data) {
        for batch in Outbox.makeBatches(samples) {
            outbox.enqueue(batch)
        }
        anchorStore.update(typeCode: metric.typeCode, anchorData: newAnchorData)
        refreshStatus()
        drainQueue()
    }

    /// Push the oldest queued batch if the endpoint + token are configured.
    func drainQueue() {
        guard let endpoint = config.endpoint, let token = config.token, !token.isEmpty else {
            status.lastError = "Not configured"
            return
        }

        uploader.uploadNext(endpoint: endpoint, token: token, onFinish: { [weak self] outcome in
            DispatchQueue.main.async {
                self?.handleUploadOutcome(outcome)
            }
        }, send: send)
    }

    /// Manual sync: run an anchored read for every metric (diagnostic boundary that
    /// distinguishes HealthKit/query failures from background-wake / network failures).
    func manualSync() {
        for metric in HealthKitMetrics.all {
            let anchorData = anchorStore.anchor(for: metric.typeCode)?.data
            let windowStart = anchorStore.readStartDate(for: metric.typeCode)
            healthKit.readAnchoredSamples(
                metric: metric,
                storedAnchorData: anchorData,
                firstRunWindowStart: windowStart,
                onSamples: { [weak self] m, samples, anchorData in
                    self?.didRead(metric: m, samples: samples, newAnchorData: anchorData)
                }
            )
        }
    }

    func refreshStatus() {
        status.pendingCount = outbox.pendingCount
        status.inflightCount = outbox.inflightCount
        status.endpointConfigured = config.isConfigured
    }

    private func handleUploadOutcome(_ outcome: UploadOutcome) {
        switch outcome {
        case .success(let accepted, let duplicates, let rejected):
            status.lastUpload = "OK (\(accepted ?? 0) accepted, \(duplicates ?? 0) dup)"
            status.lastError = nil
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
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            complete(data, response, error)
        }
        task.resume()
    }
}
