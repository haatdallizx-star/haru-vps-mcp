import Foundation

/// Encoding policy: the allow-list of HealthKit metadata keys forwarded to the
/// server (the server enforces the same allow-list). Anything outside this set
/// is dropped rather than risk sending sensitive / non-contract fields.
enum SampleEncodingPolicy {
    static let allowedMetadataKeys: Set<String> = [
        "HKWasUserEntered",
        "HKMetadataKeyHeartRateMotionContext",
    ]
}

/// Pure encoding logic: extracts an exact server-contract `HealthSample` from
/// already-read quantity values. Lives in its own type so it is fully unit
/// testable without a HealthKit store or a physical device.
struct SampleEncoder {
    let metric: HealthKitMetric
    private let now: () -> Date

    init(metric: HealthKitMetric, now: @escaping () -> Date = { Date() }) {
        self.metric = metric
        self.now = now
    }

    func makeSample(
        uuid: String,
        value: Double,
        startAt: Date,
        endAt: Date,
        sourceName: String?,
        sourceBundle: String?,
        device: String?,
        metadata: [String: String]
    ) -> HealthSample {
        HealthSample(
            uuid: uuid,
            type: metric.typeCode,
            value: value,
            unit: metric.canonicalUnit,
            startAt: ISO8601Codec.string(startAt),
            endAt: ISO8601Codec.string(endAt),
            sourceName: sourceName,
            sourceBundle: sourceBundle,
            device: device,
            metadata: metadata
                .filter { SampleEncodingPolicy.allowedMetadataKeys.contains($0.key) }
                .nilIfEmpty,
            queuedAt: ISO8601Codec.string(now())
        )
    }
}

/// UTC ISO-8601 codec used for every timestamp in the model. Kept tiny so the
/// format conversion is a single, reviewable place.
enum ISO8601Codec {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension Dictionary where Key == String, Value == String {
    var nilIfEmpty: [String: String]? {
        isEmpty ? nil : self
    }
}
