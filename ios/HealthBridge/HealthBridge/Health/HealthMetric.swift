import HealthKit

enum HealthMetric: String, CaseIterable {
    case heartRate = "heart_rate"
    case hrv = "hrv"
    case steps = "steps"
    case sleep = "sleep"

    var sampleType: HKSampleType? {
        switch self {
        case .heartRate:
            return HKObjectType.quantityType(forIdentifier: .heartRate)
        case .hrv:
            return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .steps:
            return HKObjectType.quantityType(forIdentifier: .stepCount)
        case .sleep:
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        }
    }
}
