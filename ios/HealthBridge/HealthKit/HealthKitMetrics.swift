import Foundation

/// One supported quantity metric and its server-contract encoding.
///
/// Phase 2A ships quantity samples only. Category metrics (sleep / menstrual /
/// etc.) are intentionally excluded from this registry for now; add them here
/// (plus a matching server-side type) when they are in scope. Keep the registry
/// extensible: adding a metric is a single entry here plus the corresponding
/// HealthKit reading in `HealthKitManager`.
struct HealthKitMetric: Equatable {
    /// HealthKit quantity-type identifier string, e.g. "HKQuantityTypeIdentifierHeartRate".
    let healthKitTypeIdentifier: String
    /// Server-contract type code, e.g. "heart_rate".
    let typeCode: String
    /// Canonical unit label sent to the server, e.g. "bpm".
    let canonicalUnit: String
    /// HealthKit unit identifier used to read a quantity value, e.g. "count/min".
    let hkUnitIdentifier: String
}

enum HealthKitMetrics {
    static let all: [HealthKitMetric] = [
        HealthKitMetric(
            healthKitTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            typeCode: "heart_rate",
            canonicalUnit: "bpm",
            hkUnitIdentifier: "count/min"),
        HealthKitMetric(
            healthKitTypeIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            typeCode: "hrv",
            canonicalUnit: "ms",
            hkUnitIdentifier: "ms"),
        HealthKitMetric(
            healthKitTypeIdentifier: "HKQuantityTypeIdentifierStepCount",
            typeCode: "steps",
            canonicalUnit: "count",
            hkUnitIdentifier: "count"),
    ]

    static func metric(typeCode: String) -> HealthKitMetric? {
        all.first { $0.typeCode == typeCode }
    }
}
