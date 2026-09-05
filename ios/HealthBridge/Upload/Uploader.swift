import Foundation

/// Server response body for a 2xx ingest ("accepted" / "duplicates" / "rejected").
struct IngestResponse: Codable, Equatable {
    let accepted: Int?
    let duplicates: Int?
    let rejected: Int?
}

/// Classified result of one upload attempt, used to decide outbox actions.
enum UploadOutcome: Equatable {
    /// 2xx — the batch is delivered; it may be removed from inflight.
    case success(accepted: Int?, duplicates: Int?, rejected: Int?)
    /// Network error / 5xx — safe to retry; the batch stays queued.
    case retryable(statusCode: Int?)
    /// 401 / 403 — keep queued but stop aggressive retry; surface auth failure.
    case authFailure(statusCode: Int)
    /// Other 4xx — keep queued, retain diagnostics, do not tight-loop retries.
    case validationFailure(statusCode: Int)
}

enum UploadClassifier {
    /// Pure classification of an HTTP response into an outbox action.
    static func classify(statusCode: Int?, data: Data?) -> UploadOutcome {
        guard let code = statusCode else {
            return .retryable(statusCode: nil)   // transport error / offline
        }
        if (200..<300).contains(code) {
            if let data, let r = try? JSONDecoder().decode(IngestResponse.self, from: data) {
                return .success(accepted: r.accepted, duplicates: r.duplicates, rejected: r.rejected)
            }
            return .success(accepted: nil, duplicates: nil, rejected: nil)
        }
        switch code {
        case 401, 403:
            return .authFailure(statusCode: code)
        case 400..<500:
            return .validationFailure(statusCode: code)
        default:
            return .retryable(statusCode: code)   // 5xx / other
        }
    }
}

/// Maps a classified outcome to the required outbox mutation.
enum OutboxAction: Equatable {
    case deleteInflight   // 2xx only
    case requeue          // everything else stays queued for a safe retry
}

enum OutboxActionRouter {
    static func action(for outcome: UploadOutcome) -> OutboxAction {
        switch outcome {
        case .success:
            return .deleteInflight
        case .retryable, .authFailure, .validationFailure:
            return .requeue
        }
    }
}

/// Constructs the `POST /healthkit/v1/ingest` request. Endpoint and token are
/// supplied at call time (never built in / hardcoded). Pure + testable.
enum UploadRequestBuilder {
    static func build(endpoint: URL, envelope: IngestEnvelope, token: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(envelope)
        return request
    }
}

/// Thin orchestrator: pull a pending batch, upload it, and apply the outbox
/// mutation for the classified outcome. Network transport is injected as a
/// `send` closure so the caller can use a background URLSession (production) or
/// a stub (tests). The business rules live in `UploadClassifier` /
/// `OutboxActionRouter`, which are unit-tested.
final class Uploader {
    private let outbox: Outbox

    init(outbox: Outbox) {
        self.outbox = outbox
    }

    /// Upload the oldest queued batch if any, then apply the outbox action for
    /// whatever the transport returned.
    func uploadNext(
        endpoint: URL,
        token: String,
        onFinish: ((UploadOutcome) -> Void)? = nil,
        send: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    ) {
        guard let batch = outbox.nextBatchForUpload() else { return }
        let envelope = IngestEnvelope(
            schemaVersion: IngestEnvelope.currentSchemaVersion,
            deviceId: DeviceIdentity.current(),
            sentAt: ISO8601Codec.string(Date()),
            samples: batch.samples
        )
        let request = UploadRequestBuilder.build(endpoint: endpoint, envelope: envelope, token: token)

        send(request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let outcome = error == nil
                ? UploadClassifier.classify(statusCode: statusCode, data: data)
                : .retryable(statusCode: nil)
            self?.apply(outcome: outcome, batchID: batch.id)
            onFinish?(outcome)
        }
    }

    /// Apply a classified outcome to the outbox: delete on 2xx, otherwise requeue.
    func apply(outcome: UploadOutcome, batchID: UUID) {
        switch OutboxActionRouter.action(for: outcome) {
        case .deleteInflight:
            outbox.markSucceeded(batchID)
        case .requeue:
            outbox.markFailed(batchID)
        }
    }
}
