import Foundation

/// Supported quantity/category metrics and their server-contract codes.
struct HealthKitMetric: Equatable {
    var isCategory: Bool { typeCode == "sleep" || typeCode == "menstrual_flow" }
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
        HealthKitMetric(healthKitTypeIdentifier: "HKCategoryTypeIdentifierSleepAnalysis",
                        typeCode: "sleep", canonicalUnit: "", hkUnitIdentifier: ""),
        HealthKitMetric(healthKitTypeIdentifier: "HKCategoryTypeIdentifierMenstrualFlow",
                        typeCode: "menstrual_flow", canonicalUnit: "", hkUnitIdentifier: ""),
    ]

    static func metric(typeCode: String) -> HealthKitMetric? {
        all.first { $0.typeCode == typeCode }
    }
}
