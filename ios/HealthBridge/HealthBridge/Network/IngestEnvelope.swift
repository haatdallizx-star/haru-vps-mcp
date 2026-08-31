import Foundation

struct IngestEnvelope: Codable, Equatable {
    let schemaVersion = 1
    let deviceID: String
    let appVersion: String
    let queueDepth: Int
    let sentAt: Date
    let samples: [WireSample]
    let deletions: [WireDeletion]
    let aggregates: [StepAggregateSnapshot]

    enum CodingKeys: String, CodingKey {
        case samples, deletions, aggregates
        case schemaVersion = "schema_version"
        case deviceID = "device_id"
        case appVersion = "app_version"
        case queueDepth = "queue_depth"
        case sentAt = "sent_at"
    }

    init(deviceID: String, appVersion: String, queueDepth: Int, sentAt: Date = Date(), samples: [WireSample], deletions: [WireDeletion], aggregates: [StepAggregateSnapshot]) {
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.queueDepth = queueDepth
        self.sentAt = sentAt
        self.samples = samples
        self.deletions = deletions
        self.aggregates = aggregates
    }
}

enum HealthBridgeJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum UploadResultPolicy {
    static func isSuccess(statusCode: Int) -> Bool { (200...299).contains(statusCode) }
}
