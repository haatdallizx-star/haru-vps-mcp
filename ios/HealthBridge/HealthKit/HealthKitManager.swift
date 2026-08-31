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
final class HealthKitManager: NSObject {
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
    func registerObservers(onFired: @escaping (HealthKitMetric) -> Void) {
        for metric in HealthKitMetrics.all {
            guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.healthKitTypeIdentifier)) else { continue }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // Invoked on new data and on a background relaunch.
                if error == nil {
                    onFired(metric)
                }
                completion?()
            }
            healthStore.execute(query)

            // Best supported frequency for this type.
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// Run an HKAnchoredObjectQuery for a metric starting from the stored anchor.
    /// The caller supplies the stored anchor bytes and the first-run read window,
    /// and receives encoded samples plus the new anchor. Callers must persist the
    /// anchor ONLY after the samples are durably queued.
    func readAnchoredSamples(
        metric: HealthKitMetric,
        storedAnchorData: Data?,
        firstRunWindowStart: Date?,
        onSamples: @escaping (HealthKitMetric, [HealthSample], Data) -> Void
    ) {
        guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.healthKitTypeIdentifier)),
              let unit = HKUnit(from: metric.hkUnitIdentifier) else { return }

        var predicate: NSPredicate?
        var anchor: HKQueryAnchor?
        if let data = storedAnchorData, let unarchived = Self.unarchive(data) as? HKQueryAnchor {
            anchor = unarchived
        } else if let start = firstRunWindowStart {
            predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        }

        let encoder = SampleEncoder(metric: metric)
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { _, samples, _, newAnchor, error in
            guard error == nil, let samples = samples, let newAnchor else { return }

            var encoded: [HealthSample] = []
            for case let quantitySample as HKQuantitySample in samples {
                let value = quantitySample.quantity.doubleValue(for: unit)
                let metadata = Self.allowListedMetadata(quantitySample.metadata)
                encoded.append(encoder.makeSample(
                    uuid: quantitySample.uuid.uuidString,
                    value: value,
                    startAt: quantitySample.startDate,
                    endAt: quantitySample.endDate,
                    sourceName: quantitySample.sourceRevision.source.name,
                    sourceBundle: quantitySample.sourceRevision.source.bundleIdentifier,
                    device: sanitizedDeviceDescription(quantitySample),
                    metadata: metadata
                ))
            }
            guard let anchorData = Self.archive(newAnchor) else { return }
            onSamples(metric, encoded, anchorData)
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
