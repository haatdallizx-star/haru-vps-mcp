import Foundation
import HealthKit

struct WireSample: Codable, Equatable {
    let uuid: String
    let type: String
    let value: Double?
    let unit: String?
    let stage: String?
    let stageRaw: Int?
    let startAt: Date
    let endAt: Date
    let queuedAt: Date
    let sourceName: String?
    let sourceBundle: String?
    let device: String?
    let metadata: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case uuid, type, value, unit, stage, metadata, device
        case stageRaw = "stage_raw"
        case startAt = "start_at"
        case endAt = "end_at"
        case queuedAt = "queued_at"
        case sourceName = "source_name"
        case sourceBundle = "source_bundle"
    }
}

struct WireDeletion: Codable, Equatable {
    let uuid: String
    let metric: String
    let queuedAt: Date

    enum CodingKeys: String, CodingKey {
        case uuid, metric
        case queuedAt = "queued_at"
    }
}

enum JSONValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

enum SampleEncoderError: Error {
    case typeMismatch
}

struct SampleEncoder {
    func encode(sample: HKSample, metric: HealthMetric, queuedAt: Date = Date()) throws -> WireSample {
        let common = commonFields(sample: sample, queuedAt: queuedAt)
        switch metric {
        case .heartRate, .hrv, .steps:
            guard let quantitySample = sample as? HKQuantitySample else { throw SampleEncoderError.typeMismatch }
            let (unit, label): (HKUnit, String)
            switch metric {
            case .heartRate:
                unit = HKUnit.count().unitDivided(by: .minute())
                label = "bpm"
            case .hrv:
                unit = .secondUnit(with: .milli)
                label = "ms"
            case .steps:
                unit = .count()
                label = "count"
            case .sleep:
                fatalError("unreachable")
            }
            return WireSample(
                uuid: common.uuid,
                type: metric.rawValue,
                value: quantitySample.quantity.doubleValue(for: unit),
                unit: label,
                stage: nil,
                stageRaw: nil,
                startAt: common.startAt,
                endAt: common.endAt,
                queuedAt: common.queuedAt,
                sourceName: common.sourceName,
                sourceBundle: common.sourceBundle,
                device: common.device,
                metadata: common.metadata
            )
        case .sleep:
            guard let categorySample = sample as? HKCategorySample else { throw SampleEncoderError.typeMismatch }
            return WireSample(
                uuid: common.uuid,
                type: metric.rawValue,
                value: nil,
                unit: nil,
                stage: sleepStage(categorySample.value),
                stageRaw: categorySample.value,
                startAt: common.startAt,
                endAt: common.endAt,
                queuedAt: common.queuedAt,
                sourceName: common.sourceName,
                sourceBundle: common.sourceBundle,
                device: common.device,
                metadata: common.metadata
            )
        }
    }

    func encodeDeletion(uuid: UUID, metric: HealthMetric, queuedAt: Date = Date()) -> WireDeletion {
        WireDeletion(uuid: uuid.uuidString, metric: metric.rawValue, queuedAt: queuedAt)
    }

    func encodeDeletion(_ deleted: HKDeletedObject, metric: HealthMetric, queuedAt: Date = Date()) -> WireDeletion {
        encodeDeletion(uuid: deleted.uuid, metric: metric, queuedAt: queuedAt)
    }

    private func commonFields(sample: HKSample, queuedAt: Date) -> (
        uuid: String, startAt: Date, endAt: Date, queuedAt: Date,
        sourceName: String?, sourceBundle: String?, device: String?, metadata: [String: JSONValue]
    ) {
        (
            sample.uuid.uuidString,
            sample.startDate,
            sample.endDate,
            queuedAt,
            sample.sourceRevision.source.name,
            sample.sourceRevision.source.bundleIdentifier,
            sample.device?.name,
            filteredMetadata(sample.metadata)
        )
    }

    private func filteredMetadata(_ metadata: [String: Any]?) -> [String: JSONValue] {
        let allowed = ["HKWasUserEntered", "HKMetadataKeyHeartRateMotionContext"]
        guard let metadata else { return [:] }
        var result: [String: JSONValue] = [:]
        for key in allowed {
            guard let value = metadata[key] else { continue }
            switch value {
            case let value as Bool: result[key] = .bool(value)
            case let value as Int: result[key] = .int(value)
            case let value as Double: result[key] = .double(value)
            case let value as String: result[key] = .string(value)
            case let value as NSNumber:
                result[key] = .double(value.doubleValue)
            default:
                continue
            }
        }
        return result
    }

    private func sleepStage(_ raw: Int) -> String {
        switch raw {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: return "in_bed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return "asleep"
        case HKCategoryValueSleepAnalysis.awake.rawValue: return "awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "core"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "deep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: return "rem"
        default: return "unknown"
        }
    }
}
