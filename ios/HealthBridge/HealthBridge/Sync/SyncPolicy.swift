import Foundation

struct SyncPolicy {
    static func retryDelay(attempt: Int) -> TimeInterval {
        let clamped = max(0, min(attempt, 20))
        return min(5 * pow(2, Double(clamped)), 15 * 60)
    }

    static func startDate(hasAnchor: Bool, now: Date = Date()) -> Date? {
        hasAnchor ? nil : now.addingTimeInterval(-24 * 60 * 60)
    }
}
