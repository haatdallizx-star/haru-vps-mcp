import HealthKit
import XCTest
@testable import HealthBridge

final class SampleEncoderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let end = Date(timeIntervalSince1970: 1_700_000_060)
    private let queued = Date(timeIntervalSince1970: 1_700_000_120)

    func testEncodesNumericSamplesInCanonicalUnits() throws {
        let encoder = SampleEncoder()
        let cases: [(HealthMetric, HKUnit, Double, String, Double)] = [
            (.heartRate, HKUnit.count().unitDivided(by: .minute()), 72, "bpm", 72),
            (.hrv, .secondUnit(with: .milli), 48.5, "ms", 48.5),
            (.steps, .count(), 123, "count", 123),
        ]

        for (metric, unit, value, expectedUnit, expectedValue) in cases {
            guard let quantityType = metric.sampleType as? HKQuantityType else {
                return XCTFail("Expected quantity type for \(metric)")
            }
            let sample = HKQuantitySample(
                type: quantityType,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start,
                end: end
            )
            let wire = try encoder.encode(sample: sample, metric: metric, queuedAt: queued)
            XCTAssertEqual(wire.uuid, sample.uuid.uuidString)
            XCTAssertEqual(wire.type, metric.rawValue)
            XCTAssertEqual(wire.unit, expectedUnit)
            XCTAssertEqual(wire.value ?? .nan, expectedValue, accuracy: 0.0001)
            XCTAssertEqual(wire.startAt, start)
            XCTAssertEqual(wire.endAt, end)
            XCTAssertEqual(wire.queuedAt, queued)
            XCTAssertNil(wire.stage)
        }
    }

    func testEncodesSleepStagesAndPreservesRawValue() throws {
        let encoder = SampleEncoder()
        guard let sleepType = HealthMetric.sleep.sampleType as? HKCategoryType else {
            return XCTFail("Expected sleep category type")
        }
        let known: [(Int, String)] = [
            (HKCategoryValueSleepAnalysis.inBed.rawValue, "in_bed"),
            (HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, "asleep"),
            (HKCategoryValueSleepAnalysis.awake.rawValue, "awake"),
            (HKCategoryValueSleepAnalysis.asleepCore.rawValue, "core"),
            (HKCategoryValueSleepAnalysis.asleepDeep.rawValue, "deep"),
            (HKCategoryValueSleepAnalysis.asleepREM.rawValue, "rem"),
        ]

        for (raw, label) in known + [(9_999, "unknown")] {
            let sample = HKCategorySample(type: sleepType, value: raw, start: start, end: end)
            let wire = try encoder.encode(sample: sample, metric: .sleep, queuedAt: queued)
            XCTAssertEqual(wire.type, "sleep")
            XCTAssertEqual(wire.stage, label)
            XCTAssertEqual(wire.stageRaw, raw)
            XCTAssertNil(wire.value)
            XCTAssertNil(wire.unit)
        }
    }

    func testDeletionPreservesUUIDMetricAndQueueTime() {
        let uuid = UUID()
        let wire = SampleEncoder().encodeDeletion(uuid: uuid, metric: .heartRate, queuedAt: queued)
        XCTAssertEqual(wire.uuid, uuid.uuidString)
        XCTAssertEqual(wire.metric, "heart_rate")
        XCTAssertEqual(wire.queuedAt, queued)
    }
}
