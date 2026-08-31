import Foundation
import HealthKit

public final class HealthKitManager {
    public let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    var readTypes: Set<HKObjectType> { Set(HealthMetric.allCases.compactMap { $0.sampleType }) }

    public static func initialSyncStart(now: Date = Date()) -> Date { now.addingTimeInterval(-24 * 60 * 60) }

    public static func backgroundFrequency(for metric: HealthMetric) -> HKUpdateFrequency {
        metric == .steps ? .hourly : .immediate
    }

    public func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: HealthKitManagerError.authorizationNotGranted) }
            }
        }
    }

    func anchoredQuery(metric: HealthMetric, anchor: HKQueryAnchor?, startDate: Date?, handler: @escaping ([HKSample], [HKDeletedObject], HKQueryAnchor?, Error?) -> Void) -> HKAnchoredObjectQuery? {
        guard let type = metric.sampleType else { return nil }
        let predicate = startDate.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
        return HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) {
            _, samples, deletions, newAnchor, error in handler(samples ?? [], deletions ?? [], newAnchor, error)
        }
    }

    public func enableBackgroundDelivery() async throws {
        for metric in HealthMetric.allCases {
            guard let type = metric.sampleType else { continue }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.enableBackgroundDelivery(for: type, frequency: Self.backgroundFrequency(for: metric)) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: HealthKitManagerError.backgroundDeliveryNotEnabled) }
                }
            }
        }
    }

    public func installObservers(onChange: @escaping (HealthMetric, @escaping () -> Void) -> Void) {
        for metric in HealthMetric.allCases {
            guard let type = metric.sampleType else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in onChange(metric, completion) }
            store.execute(query)
        }
    }
}

public enum HealthKitManagerError: Error { case authorizationNotGranted, backgroundDeliveryNotEnabled }
