import Foundation

/// One discrete upload batch. A batch is the unit of atomicity: pending batches
/// move to inflight and are only deleted after a 2xx response.
struct OutboxBatch: Codable, Equatable {
    let id: UUID
    let samples: [HealthSample]
    let createdAt: Date

    init(id: UUID = UUID(), samples: [HealthSample], createdAt: Date = Date()) {
        self.id = id
        self.samples = samples
        self.createdAt = createdAt
    }
}
