import Foundation
import HealthKit

/// Thin HealthKit layer. Owns nothing policy-wise; it reads HealthKit and hands
/// encoded samples + a new anchor back to the caller (the `SyncEngine`), which is
/// responsible for durability-before-progress and uploading.
///
/// The HealthKit store is only fully functional on a real device; this file is
/// not unit-tested. Its correctness is covered by the entitlement gate in CI
/// (build must contain healthkit + background-delivery) and the later real-device
/// acceptance run.
struct AnchoredSamples {
    let samples: [HealthSample]
    let anchorData: Data
}

protocol HealthKitReading: AnyObject {
    func requestReadAuthorization(completion: @escaping (Bool, Error?) -> Void)
    func registerObservers(onFired: @escaping (HealthKitMetric, @escaping () -> Void) -> Void,
                           onRegistration: @escaping (HealthKitMetric, Bool, Error?) -> Void)
    func readAnchoredSamples(metric: HealthKitMetric, storedAnchorData: Data?, firstRunWindowStart: Date?,
                             completion: @escaping (Result<AnchoredSamples, Error>) -> Void)
}

final class HealthKitManager: NSObject, HealthKitReading {
    static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()

    func supportedQuantityTypes() -> [HKQuantityType] {
        HealthKitMetrics.all.compactMap { metric in
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.healthKitTypeIdentifier))
        }
    }

    func requestReadAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        let read = Set(supportedQuantityTypes().map { $0 as HKObjectType })
        healthStore.requestAuthorization(toShare: [], read: read) { success, error in
            completion(success, error)
        }
    }

    /// Register one observer per supported type and enable background delivery.
    /// MUST be called at launch (didFinishLaunching) so iOS can relaunch the app
    /// for HealthKit events without the UI being opened.
    ///
    /// On fire it hands the metric back to the caller (`onFired`), which owns the
    /// AnchorStore and decides how to run the anchored read (see `SyncEngine`).
    private var observerQueries: [String: HKObserverQuery] = [:]

    func registerObservers(
        onFired: @escaping (HealthKitMetric, @escaping () -> Void) -> Void,
        onRegistration: @escaping (HealthKitMetric, Bool, Error?) -> Void
    ) {
        for metric in HealthKitMetrics.all {
            guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.healthKitTypeIdentifier)) else {
                onRegistration(metric, false, ReadError.unsupportedType)
                continue
            }
            if observerQueries[metric.typeCode] == nil {
                let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
                    // Let the anchored read surface any error, and complete only
                    // after that read and its durable queue write have settled.
                    onFired(metric, completion)
                }
                observerQueries[metric.typeCode] = query
                healthStore.execute(query)
            }
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
                onRegistration(metric, success, error)
            }
        }
    }

    enum ReadError: Error {
        case unsupportedType, invalidAnchor, missingResult
    }

    func readAnchoredSamples(
        metric: HealthKitMetric,
        storedAnchorData: Data?,
        firstRunWindowStart: Date?,
        completion: @escaping (Result<AnchoredSamples, Error>) -> Void
    ) {
        guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.healthKitTypeIdentifier)) else {
            completion(.failure(ReadError.unsupportedType))
            return
        }
        let unit = HKUnit(from: metric.hkUnitIdentifier)
        var predicate: NSPredicate?
        var anchor: HKQueryAnchor?
        if let data = storedAnchorData {
            guard let decoded = Self.unarchive(data) as? HKQueryAnchor else {
                completion(.failure(ReadError.invalidAnchor))
                return
            }
            anchor = decoded
        } else {
            let start = firstRunWindowStart ?? Date().addingTimeInterval(-AnchorStore.firstRunWindowSeconds)
            predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        }

        let encoder = SampleEncoder(metric: metric)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, samples, _, newAnchor, error in
            if let error { completion(.failure(error)); return }
            guard let samples, let newAnchor, let anchorData = Self.archive(newAnchor) else {
                completion(.failure(ReadError.missingResult))
                return
            }
            var encoded: [HealthSample] = []
            for case let quantitySample as HKQuantitySample in samples {
                encoded.append(encoder.makeSample(
                    uuid: quantitySample.uuid.uuidString,
                    value: quantitySample.quantity.doubleValue(for: unit),
                    startAt: quantitySample.startDate,
                    endAt: quantitySample.endDate,
                    sourceName: quantitySample.sourceRevision.source.name,
                    sourceBundle: quantitySample.sourceRevision.source.bundleIdentifier,
                    device: self.sanitizedDeviceDescription(quantitySample),
                    metadata: Self.allowListedMetadata(quantitySample.metadata)
                ))
            }
            completion(.success(AnchoredSamples(samples: encoded, anchorData: anchorData)))
        }
        healthStore.execute(query)
    }

    // MARK: - Encoding helpers

    private static func allowListedMetadata(_ metadata: [String: Any]?) -> [String: String] {
        guard let metadata else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in metadata where SampleEncodingPolicy.allowedMetadataKeys.contains(key) {
            result[key] = "\(value)"
        }
        return result
    }

    private func sanitizedDeviceDescription(_ sample: HKQuantitySample) -> String? {
        // HealthKit device descriptions can contain identifiers we do not want to
        // forward; keep only the human-readable name/make/model tokens.
        guard let device = sample.device else { return nil }
        let parts = [
            device.name,
            device.manufacturer,
            device.model,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> Any? {
        try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
    }
}
