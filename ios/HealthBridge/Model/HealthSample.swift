import Foundation

/// A single quantity or category HealthKit sample, mirroring the server-side
/// `healthkit_ingest` contract exactly (field names, canonical units, UTC).
///
/// `received_at` is server-assigned and is therefore never set on the phone.
struct HealthSample: Codable, Equatable {
    let uuid: String            // HealthKit sample UUID (also the idempotency key)
    let type: String            // heart_rate | hrv | steps | sleep | menstrual_flow
    let value: Double?
    let unit: String?           // absent for category samples
    let startAt: String         // ISO-8601 UTC
    let endAt: String           // ISO-8601 UTC
    let sourceName: String?
    let sourceBundle: String?
    let device: String?         // sanitized device description (never a raw identifier)
    let metadata: [String: String]?   // allow-listed metadata only
    var queuedAt: String?       // phone timestamp when durably queued
    var stage: String? = nil
    var flow: String? = nil
    var cycleStart: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case uuid, type, value, unit
        case startAt = "start_at"
        case endAt = "end_at"
        case sourceName = "source_name"
        case sourceBundle = "source_bundle"
        case device
        case metadata
        case queuedAt = "queued_at"
        case stage, flow
        case cycleStart = "cycle_start"
    }
}

struct DeletedHealthSample: Codable, Equatable {
    let uuid: String
    let type: String
}

/// The HTTPS ingest request envelope for `POST /healthkit/v1/ingest`.
struct IngestEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let deviceId: String
    let sentAt: String
    let samples: [HealthSample]
    var deletedSamples: [DeletedHealthSample]? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case deviceId = "device_id"
        case sentAt = "sent_at"
        case samples
        case deletedSamples = "deleted_samples"
    }

    static let currentSchemaVersion = 2
}
