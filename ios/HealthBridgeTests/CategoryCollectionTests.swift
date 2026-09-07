import XCTest
@testable import HealthBridge

final class CategoryCollectionTests: XCTestCase {
    func testSleepAndMenstrualTypesAreCollected() {
        XCTAssertNotNil(HealthKitMetrics.metric(typeCode: "sleep"))
        XCTAssertNotNil(HealthKitMetrics.metric(typeCode: "menstrual_flow"))
    }

    func testFirstImportIncludesRecentSleepAndCycles() {
        let anchors = AnchorStore(url: makeTempDir().url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(anchors.readStartDate(for: "sleep", now: now), now.addingTimeInterval(-30 * 86400))
        XCTAssertEqual(anchors.readStartDate(for: "menstrual_flow", now: now), now.addingTimeInterval(-90 * 86400))
        XCTAssertEqual(anchors.readStartDate(for: "heart_rate", now: now), now.addingTimeInterval(-86400))
    }
}
