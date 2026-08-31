import HealthKit
import XCTest
@testable import HealthBridgeCore

final class HealthKitManagerTests: XCTestCase {
    func testReadTypesContainExactlyPhaseOneMetrics() {
        let manager = HealthKitManager()
        XCTAssertEqual(manager.readTypes.count, 4)
        XCTAssertEqual(Set(manager.readTypes), Set(HealthMetric.allCases.compactMap(\.sampleType)))
    }

    func testFirstSyncStartsExactlyTwentyFourHoursBack() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(HealthKitManager.initialSyncStart(now: now), now.addingTimeInterval(-24 * 60 * 60))
    }

    func testBackgroundDeliveryUsesConservativeStepFrequency() {
        XCTAssertEqual(HealthKitManager.backgroundFrequency(for: .steps), .hourly)
        XCTAssertEqual(HealthKitManager.backgroundFrequency(for: .heartRate), .immediate)
        XCTAssertEqual(HealthKitManager.backgroundFrequency(for: .hrv), .immediate)
        XCTAssertEqual(HealthKitManager.backgroundFrequency(for: .sleep), .immediate)
    }
}
