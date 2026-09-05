import Foundation

/// Persisted anchor for a single HealthKit metric type.
///
/// `data` holds the opaque `HKQueryAnchor` bytes (archive via NSKeyedArchiver).
/// HealthKit treats an anchor as an opaque token but requires it to survive
/// relaunch, so we persist it verbatim. The store is metric-agnostic: it does
/// not need HealthKit to be imported or a device to be present, which keeps it
/// unit-testable.
struct MetricAnchor: Codable, Equatable {
    let typeCode: String
    let data: Data
    let updatedAt: Date
}

/// Durable, per-metric anchor persistence, plus the first-run read-window policy.
///
/// One anchor per HealthKit type. On first use for a type — when no anchor has
/// ever been persisted — query only the previous 24 hours, so a fresh install
/// never imports an entire Health history. Historical backfill is deliberately
/// deferred (see the bridge design spec).
final class AnchorStore {
    static let firstRunWindowSeconds: TimeInterval = 24 * 60 * 60

    private let url: URL
    private var anchors: [String: MetricAnchor] = [:]
    private var loadFailed = false

    init(url: URL) {
        self.url = url
        load()
    }

    func anchor(for typeCode: String) -> MetricAnchor? {
        anchors[typeCode]
    }

    func hasAnchor(for typeCode: String) -> Bool {
        anchors[typeCode] != nil
    }

    /// Persist a freshly read anchor for a type. Call ONLY after the newly read
    /// samples have been durably written to the Outbox ("durability before
    /// progress").
    @discardableResult
    func update(typeCode: String, anchorData: Data, now: Date = Date()) -> Bool {
        guard reloadIfNeeded() else { return false }
        var updated = anchors
        updated[typeCode] = MetricAnchor(typeCode: typeCode, data: anchorData, updatedAt: now)
        guard save(updated) else { return false }
        anchors = updated
        return true
    }

    /// Read-window policy for a type.
    /// - Returns `nil` when an anchor exists (incremental read starts at the
    ///   anchor). Returns a 24-hour-ago start date on first run (no anchor).
    func readStartDate(for typeCode: String, now: Date = Date()) -> Date? {
        guard !hasAnchor(for: typeCode) else { return nil }
        return now.addingTimeInterval(-Self.firstRunWindowSeconds)
    }

    // MARK: - Persistence (JSON, atomic)

    private var storeURL: URL { url.appendingPathComponent("anchors.json") }

    /// Never replace unreadable/corrupt bookmarks with an empty first-run state.
    /// A locked-file failure may recover on unlock; corruption requires repair.
    func reloadIfNeeded() -> Bool {
        if loadFailed { load() }
        return !loadFailed
    }

    private func load() {
        do {
            let data = try Data(contentsOf: storeURL)
            anchors = try JSONDecoder().decode([String: MetricAnchor].self, from: data)
            loadFailed = false
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            loadFailed = false
        } catch {
            loadFailed = true
            print("AnchorStore: cannot read anchors; collection paused (\(error))")
        }
    }

    private func save(_ updated: [String: MetricAnchor]) -> Bool {
        let dir = url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(updated)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            print("AnchorStore: failed to persist anchors (\(error))")
            return false
        }
    }
}
