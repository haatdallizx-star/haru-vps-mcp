import Foundation
import HealthKit

struct StepAggregateSnapshot: Codable, Equatable {
    let metric = "steps"
    let bucketStart: Date
    let bucketEnd: Date
    let value: Double
    let unit = "count"
    let computedAt: Date
    let source = "healthkit_statistics"

    enum CodingKeys: String, CodingKey {
        case metric, value, unit, source
        case bucketStart = "bucket_start"
        case bucketEnd = "bucket_end"
        case computedAt = "computed_at"
    }

    init(bucketStart: Date, bucketEnd: Date, value: Double, computedAt: Date = Date()) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.value = value
        self.computedAt = computedAt
    }
}

struct StepAggregateBuilder {
    static func dayBucket(containing date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }

    static func query(store: HKHealthStore, date: Date = Date(), calendar: Calendar = .current) async throws -> StepAggregateSnapshot {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            throw StepAggregateError.stepTypeUnavailable
        }
        let bucket = dayBucket(containing: date, calendar: calendar)
        let predicate = HKQuery.predicateForSamples(withStart: bucket.start, end: bucket.end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) {
                _, statistics, error in
                if let error { continuation.resume(throwing: error); return }
                let value = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: StepAggregateSnapshot(
                    bucketStart: bucket.start, bucketEnd: bucket.end, value: value, computedAt: Date()
                ))
            }
            store.execute(query)
        }
    }
}

enum StepAggregateError: Error { case stepTypeUnavailable }
