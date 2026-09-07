import Foundation
import HealthKit

/// Category values are labels, never quantities. Preserve unknown future values.
enum CategorySampleEncoder {
    static func makeSample(uuid: String, typeCode: String, rawValue: Int,
                           startAt: Date, endAt: Date, sourceName: String?,
                           sourceBundle: String?, device: String?, metadata: [String: String],
                           cycleStart: Bool?) -> HealthSample {
        var sample = HealthSample(uuid: uuid, type: typeCode, value: nil, unit: nil,
            startAt: ISO8601Codec.string(startAt), endAt: ISO8601Codec.string(endAt),
            sourceName: sourceName, sourceBundle: sourceBundle, device: device,
            metadata: metadata.filter { SampleEncodingPolicy.allowedMetadataKeys.contains($0.key) }.nilIfEmpty,
            queuedAt: ISO8601Codec.string(Date()))
        if typeCode == "sleep" {
            switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
            case .inBed: sample.stage = "in_bed"
            case .awake: sample.stage = "awake"
            case .asleepUnspecified: sample.stage = "asleep"
            case .asleepCore: sample.stage = "core"
            case .asleepDeep: sample.stage = "deep"
            case .asleepREM: sample.stage = "rem"
            default: sample.stage = "unknown_\(rawValue)"
            }
        } else {
            switch HKCategoryValueMenstrualFlow(rawValue: rawValue) {
            case .unspecified: sample.flow = "unspecified"
            case .some(.none): sample.flow = "none"
            case .light: sample.flow = "light"
            case .medium: sample.flow = "medium"
            case .heavy: sample.flow = "heavy"
            default: sample.flow = "unknown"
            }
            sample.cycleStart = cycleStart
        }
        return sample
    }
}
