import XCTest
@testable import HealthBridgeCore

final class BackgroundRefreshTests: XCTestCase {
    func testRefreshIdentifierMatchesInfoPlistContract() {
        XCTAssertEqual(BackgroundScheduler.identifier, "com.haru.healthbridge.refresh")
    }

    func testFallbackRetryNeverPretendsToBeMinutePrecision() {
        XCTAssertGreaterThanOrEqual(SyncPolicy.retryDelay(attempt: 0), 5)
        XCTAssertLessThanOrEqual(SyncPolicy.retryDelay(attempt: 20), 15 * 60)
    }
}
