import XCTest
@testable import HealthBridge

final class UploadTests: XCTestCase {

    // MARK: UploadClassifier

    func test2xxIsSuccess() {
        let body = Data(#"{"accepted":10,"duplicates":2,"rejected":0}"#.utf8)
        XCTAssertEqual(UploadClassifier.classify(statusCode: 200, data: body),
                       .success(accepted: 10, duplicates: 2, rejected: 0))
    }

    func test2xxWithoutBodyIsStillSuccess() {
        XCTAssertEqual(UploadClassifier.classify(statusCode: 204, data: nil),
                       .success(accepted: nil, duplicates: nil, rejected: nil))
    }

    func test401And403AreAuthFailure() {
        XCTAssertEqual(UploadClassifier.classify(statusCode: 401, data: nil), .authFailure(statusCode: 401))
        XCTAssertEqual(UploadClassifier.classify(statusCode: 403, data: nil), .authFailure(statusCode: 403))
    }

    func testOther4xxIsValidationFailure() {
        XCTAssertEqual(UploadClassifier.classify(statusCode: 400, data: nil), .validationFailure(statusCode: 400))
        XCTAssertEqual(UploadClassifier.classify(statusCode: 413, data: nil), .validationFailure(statusCode: 413))
    }

    func test5xxAndNilAreRetryable() {
        XCTAssertEqual(UploadClassifier.classify(statusCode: 500, data: nil), .retryable(statusCode: 500))
        XCTAssertEqual(UploadClassifier.classify(statusCode: 502, data: nil), .retryable(statusCode: 502))
        XCTAssertEqual(UploadClassifier.classify(statusCode: nil, data: nil), .retryable(statusCode: nil))
    }

    // MARK: OutboxActionRouter (only 2xx deletes inflight)

    func testOnlySuccessDeletesInflight() {
        XCTAssertEqual(OutboxActionRouter.action(for: .success(accepted: 1, duplicates: 0, rejected: 0)), .deleteInflight)
        XCTAssertEqual(OutboxActionRouter.action(for: .retryable(statusCode: 500)), .requeue)
        XCTAssertEqual(OutboxActionRouter.action(for: .authFailure(statusCode: 401)), .requeue)
        XCTAssertEqual(OutboxActionRouter.action(for: .validationFailure(statusCode: 400)), .requeue)
    }

    // MARK: UploadRequestBuilder

    func testRequestBuilderSetsBearerAuthAndJSON() {
        let endpoint = URL(string: "https://example.com/healthkit/v1/ingest")!
        let envelope = IngestEnvelope(schemaVersion: 1, deviceId: "dev-1", sentAt: "2026-01-01T00:00:00.000Z", samples: [])
        let request = UploadRequestBuilder.build(endpoint: endpoint, envelope: envelope, token: "tok")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNotNil(request.httpBody)
    }
}
