import Foundation

/// All methods and callbacks run on the main queue, shared with SyncEngine.
protocol BackgroundTransferring: AnyObject {
    var onCompletion: ((UUID, UploadOutcome) -> Void)? { get set }
    var onEventsFinished: (() -> Void)? { get set }
    func reconnect(completion: @escaping (Set<UUID>) -> Void)
    func submit(request: URLRequest, file: URL, batchID: UUID)
}

/// Owns durable batches; URLSession owns the actual transfers. A task description
/// persists the batch UUID across process death. Never recover before inventory.
final class BackgroundUploader {
    static let maxConcurrentUploads = 4
    var onOutcome: ((UploadOutcome) -> Void)?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    private let outbox: Outbox
    private let config: SecureConfig
    private let bodyDirectory: URL
    private let transport: BackgroundTransferring
    private var activeIDs = Set<UUID>()
    private var finishedDuringRecovery = Set<UUID>()
    private var started = false
    private var recovering = true
    private var pausedAfterFailure = false
    private var eventsFinished = false
    private var backgroundCompletion: (() -> Void)?

    init(outbox: Outbox, config: SecureConfig, bodyDirectory: URL, transport: BackgroundTransferring) {
        self.outbox = outbox
        self.config = config
        self.bodyDirectory = bodyDirectory
        self.transport = transport
        transport.onCompletion = { [weak self] id, outcome in self?.completed(id, outcome: outcome) }
        transport.onEventsFinished = { [weak self] in
            guard let self, self.backgroundCompletion != nil else { return }
            self.eventsFinished = true
            self.finishBackgroundEventsIfReady()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        transport.reconnect { [weak self] systemIDs in
            guard let self else { return }
            self.activeIDs = systemIDs.subtracting(self.finishedDuringRecovery)
            self.finishedDuringRecovery.removeAll()
            self.outbox.recoverInflightBatches(excluding: self.activeIDs)
            self.removeOrphanBodies()
            self.recovering = false
            self.schedulePending()
            self.onChange?()
            self.finishBackgroundEventsIfReady()
        }
    }

    /// A new observer/manual/foreground trigger permits another retry. Failure
    /// callbacks themselves never immediately resubmit a failed batch.
    func drain() {
        pausedAfterFailure = false
        schedulePending()
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        start()
        finishBackgroundEventsIfReady()
    }

    private func schedulePending() {
        guard started, !recovering, !pausedAfterFailure,
              let endpoint = config.endpoint, let token = config.token, !token.isEmpty else { return }
        while activeIDs.count < Self.maxConcurrentUploads, let batch = outbox.nextBatchForUpload() {
            do {
                let envelope = IngestEnvelope(schemaVersion: IngestEnvelope.currentSchemaVersion,
                                              deviceId: DeviceIdentity.current(), sentAt: ISO8601Codec.string(Date()),
                                              samples: batch.samples)
                let file = bodyURL(batch.id)
                try FileManager.default.createDirectory(at: bodyDirectory, withIntermediateDirectories: true)
                // Only the envelope is stored here, never the request/Authorization header.
                try JSONEncoder().encode(envelope).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var request = UploadRequestBuilder.build(endpoint: endpoint, envelope: envelope, token: token)
                request.httpBody = nil
                activeIDs.insert(batch.id)
                transport.submit(request: request, file: file, batchID: batch.id)
            } catch {
                outbox.markFailed(batch.id)
                pausedAfterFailure = true
                onError?("Could not prepare upload file; data remains queued")
                break
            }
        }
        onChange?()
    }

    private func completed(_ id: UUID, outcome: UploadOutcome) {
        if recovering { finishedDuringRecovery.insert(id) }
        activeIDs.remove(id)
        switch outcome {
        case .success:
            outbox.markSucceeded(id)
        default:
            outbox.markFailed(id)
            pausedAfterFailure = true
        }
        // The original batch is retained on every failure; the derived envelope
        // is regenerated for the next attempt, using then-current credentials.
        try? FileManager.default.removeItem(at: bodyURL(id))
        onOutcome?(outcome)
        schedulePending()
        onChange?()
    }

    private func bodyURL(_ id: UUID) -> URL {
        bodyDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func removeOrphanBodies() {
        let files = (try? FileManager.default.contentsOfDirectory(at: bodyDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !activeIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func finishBackgroundEventsIfReady() {
        guard eventsFinished, !recovering, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        eventsFinished = false
        completion()
    }
}

/// File-based uploads with a session delegate: no dataTask or completion-handler
/// upload API is used with the background session.
final class BackgroundURLSessionTransfer: NSObject, BackgroundTransferring, URLSessionDataDelegate {
    static let identifier = "com.haru.healthbridge.background-upload.v1"
    var onCompletion: ((UUID, UploadOutcome) -> Void)?
    var onEventsFinished: (() -> Void)?
    private var responseBodies: [Int: Data] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = BackgroundUploader.maxConcurrentUploads
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func reconnect(completion: @escaping (Set<UUID>) -> Void) {
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                var ids = Set<UUID>()
                for task in tasks {
                    guard let description = task.taskDescription, let id = UUID(uuidString: description) else {
                        task.cancel()
                        continue
                    }
                    // Completed/cancelling tasks still receive delegate callbacks;
                    // retain their IDs until those callbacks settle their batches.
                    ids.insert(id)
                    if task.state == .suspended { task.resume() }
                }
                completion(ids)
            }
        }
    }

    func submit(request: URLRequest, file: URL, batchID: UUID) {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = batchID.uuidString
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The expected response is tiny. Bound memory even for a malformed server.
        var body = responseBodies[dataTask.taskIdentifier] ?? Data()
        if body.count < 64 * 1024 { body.append(contentsOf: data.prefix(64 * 1024 - body.count)) }
        responseBodies[dataTask.taskIdentifier] = body
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseBodies.removeValue(forKey: task.taskIdentifier)
        guard let description = task.taskDescription, let id = UUID(uuidString: description) else { return }
        let outcome: UploadOutcome = error == nil
            ? UploadClassifier.classify(statusCode: (task.response as? HTTPURLResponse)?.statusCode, data: body)
            : .retryable(statusCode: nil)
        onCompletion?(id, outcome)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEventsFinished?()
    }
}
