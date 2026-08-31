import HealthKit
import XCTest
@testable import HealthBridgeCore

final class HealthMetricTests: XCTestCase {
    func testPhaseOneContainsExactlyFourMetrics() {
        XCTAssertEqual(
            Set(HealthMetric.allCases.map(\.rawValue)),
            Set(["heart_rate", "hrv", "steps", "sleep"])
        )
    }

    func testEveryMetricResolvesAHealthKitSampleType() {
        for metric in HealthMetric.allCases {
            XCTAssertNotNil(metric.sampleType)
        }
    }
}
