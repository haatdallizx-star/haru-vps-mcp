import Foundation
import SQLite3

struct OutboxBatch: Equatable {
    let samples: [WireSample]
    let deletions: [WireDeletion]
}

enum OutboxError: Error { case sqlite(String) }

final class Outbox {
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else { throw OutboxError.sqlite("open failed") }
        db = pointer
        try exec("PRAGMA journal_mode=WAL")
        try exec("CREATE TABLE IF NOT EXISTS queue (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, payload BLOB NOT NULL, state TEXT NOT NULL DEFAULT 'pending')")
        try exec("CREATE TABLE IF NOT EXISTS anchors (metric TEXT PRIMARY KEY, data BLOB NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    func enqueue(samples: [WireSample], deletions: [WireDeletion], metric: HealthMetric, anchorData: Data) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for sample in samples { try insert(kind: "sample", data: HealthBridgeJSON.encoder.encode(sample)) }
            for deletion in deletions { try insert(kind: "deletion", data: HealthBridgeJSON.encoder.encode(deletion)) }
            try upsertAnchor(metric: metric.rawValue, data: anchorData)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func anchorData(for metric: HealthMetric) throws -> Data? {
        var statement: OpaquePointer?
        try prepare("SELECT data FROM anchors WHERE metric = ?", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, metric.rawValue, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return blob(statement, column: 0)
    }

    func queueDepth() throws -> Int {
        var statement: OpaquePointer?
        try prepare("SELECT COUNT(*) FROM queue", &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func pendingBatch(limit: Int) throws -> OutboxBatch { try readBatch(state: "pending", limit: limit) }

    func beginUpload(limit: Int) throws -> OutboxBatch {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("UPDATE queue SET state='pending' WHERE state='inflight'")
            var ids: [Int64] = []
            var statement: OpaquePointer?
            try prepare("SELECT id FROM queue WHERE state='pending' ORDER BY id LIMIT ?", &statement)
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
            sqlite3_finalize(statement)
            for id in ids { try exec("UPDATE queue SET state='inflight' WHERE id=\(id)") }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return try readBatch(state: "inflight", limit: limit)
    }

    func finishUpload(success: Bool) throws {
        try exec(success ? "DELETE FROM queue WHERE state='inflight'" : "UPDATE queue SET state='pending' WHERE state='inflight'")
    }

    private func readBatch(state: String, limit: Int) throws -> OutboxBatch {
        var statement: OpaquePointer?
        try prepare("SELECT kind, payload FROM queue WHERE state=? ORDER BY id LIMIT ?", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, state, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var samples: [WireSample] = []
        var deletions: [WireDeletion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kindC = sqlite3_column_text(statement, 0) else { continue }
            let kind = String(cString: kindC)
            let data = blob(statement, column: 1)
            if kind == "sample" { samples.append(try HealthBridgeJSON.decoder.decode(WireSample.self, from: data)) }
            else { deletions.append(try HealthBridgeJSON.decoder.decode(WireDeletion.self, from: data)) }
        }
        return OutboxBatch(samples: samples, deletions: deletions)
    }

    private func insert(kind: String, data: Data) throws {
        var statement: OpaquePointer?
        try prepare("INSERT INTO queue(kind, payload, state) VALUES (?, ?, 'pending')", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        data.withUnsafeBytes { raw in sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func upsertAnchor(metric: String, data: Data) throws {
        var statement: OpaquePointer?
        try prepare("INSERT INTO anchors(metric, data) VALUES (?, ?) ON CONFLICT(metric) DO UPDATE SET data=excluded.data", &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, metric, -1, transient)
        data.withUnsafeBytes { raw in sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func blob(_ statement: OpaquePointer?, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> OutboxError { OutboxError.sqlite(String(cString: sqlite3_errmsg(db))) }
}
