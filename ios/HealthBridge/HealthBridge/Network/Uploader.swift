import Foundation

public final class Uploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let config: SecureConfig
    private let deviceID: String
    private let appVersion: String
    private var completions: [Int: (Bool) -> Void] = [:]
    private var files: [Int: URL] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.haru.healthbridge.background-upload")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(config: SecureConfig, deviceID: String, appVersion: String) {
        self.config = config
        self.deviceID = deviceID
        self.appVersion = appVersion
        super.init()
    }

    func upload(samples: [WireSample], deletions: [WireDeletion], aggregates: [StepAggregateSnapshot], queueDepth: Int, completion: @escaping (Bool) -> Void) throws {
        guard let url = config.ingestURL, let token = try config.token() else { throw UploaderError.notConfigured }
        let envelope = IngestEnvelope(deviceID: deviceID, appVersion: appVersion, queueDepth: queueDepth, samples: samples, deletions: deletions, aggregates: aggregates)
        let data = try HealthBridgeJSON.encoder.encode(envelope)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("healthbridge-\(UUID().uuidString).json")
        try data.write(to: file, options: .atomic)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, fromFile: file)
        completions[task.taskIdentifier] = completion
        files[task.taskIdentifier] = file
        task.resume()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let success = error == nil && UploadResultPolicy.isSuccess(statusCode: status)
        if let file = files.removeValue(forKey: task.taskIdentifier) { try? FileManager.default.removeItem(at: file) }
        completions.removeValue(forKey: task.taskIdentifier)?(success)
    }
}

public enum UploaderError: Error { case notConfigured }
