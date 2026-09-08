import Foundation

/// One discrete upload batch. A batch is the unit of atomicity: pending batches
/// move to inflight and are only deleted after a 2xx response.
struct OutboxBatch: Codable, Equatable {
    let id: UUID
    let samples: [HealthSample]
    let createdAt: Date
    var deletedSamples: [DeletedHealthSample]? = nil

    init(id: UUID = UUID(), samples: [HealthSample], createdAt: Date = Date(), deletedSamples: [DeletedHealthSample] = []) {
        self.id = id
        self.samples = samples
        self.createdAt = createdAt
        self.deletedSamples = deletedSamples.isEmpty ? nil : deletedSamples
    }
}
