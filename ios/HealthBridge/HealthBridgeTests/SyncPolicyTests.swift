import XCTest
@testable import HealthBridgeCore

final class SyncPolicyTests: XCTestCase {
    func testStepBucketUsesCalendarDayInProvidedTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = ISO8601DateFormatter().date(from: "2026-08-31T05:00:00Z")!
        let bucket = StepAggregateBuilder.dayBucket(containing: date, calendar: calendar)
        XCTAssertEqual(ISO8601DateFormatter().string(from: bucket.start), "2026-08-30T16:00:00Z")
        XCTAssertEqual(ISO8601DateFormatter().string(from: bucket.end), "2026-08-31T16:00:00Z")
    }

    func testRetryBackoffIsBounded() {
        XCTAssertEqual(SyncPolicy.retryDelay(attempt: 0), 5)
        XCTAssertEqual(SyncPolicy.retryDelay(attempt: 1), 10)
        XCTAssertLessThanOrEqual(SyncPolicy.retryDelay(attempt: 20), 15 * 60)
    }

    func testInitialSyncUsesTwentyFourHourWindowOnlyWithoutAnchor() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(SyncPolicy.startDate(hasAnchor: false, now: now), now.addingTimeInterval(-86_400))
        XCTAssertNil(SyncPolicy.startDate(hasAnchor: true, now: now))
    }
}
