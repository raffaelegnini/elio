import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local persistent memory: conversation log and key/value state.
/// Facts, reminders and tasks get their own tables in later phases.
public actor Memory {
    public struct Message: Sendable {
        public let ts: Date
        public let role: String
        public let text: String
        public let route: String?
    }

    private var db: OpaquePointer?

    public init(path: URL = JarvisPaths.database) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK else {
            throw JarvisError.database("open failed at \(path.path)")
        }
        db = handle
        try Self.exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                route TEXT
            );
            CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    public func log(role: String, text: String, route: String? = nil) {
        run("INSERT INTO messages (ts, role, text, route) VALUES (?, ?, ?, ?)",
            [Date().timeIntervalSince1970, role, text, route])
    }

    public func recentMessages(limit: Int = 20) -> [Message] {
        var rows: [Message] = []
        query("SELECT ts, role, text, route FROM messages ORDER BY id DESC LIMIT ?", [limit]) { stmt in
            rows.append(Message(
                ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                role: String(cString: sqlite3_column_text(stmt, 1)),
                text: String(cString: sqlite3_column_text(stmt, 2)),
                route: sqlite3_column_text(stmt, 3).map { String(cString: $0) }))
        }
        return rows.reversed()
    }

    public func get(_ key: String) -> String? {
        var value: String?
        query("SELECT value FROM kv WHERE key = ?", [key]) { stmt in
            value = String(cString: sqlite3_column_text(stmt, 0))
        }
        return value
    }

    public func set(_ key: String, _ value: String) {
        run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value])
    }

    // MARK: - SQLite helpers

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw JarvisError.database(msg)
        }
    }

    private func prepare(_ sql: String, _ params: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            JarvisCore.log("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Any?]) {
        guard let stmt = prepare(sql, params) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            JarvisCore.log("sqlite step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query(_ sql: String, _ params: [Any?], row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(sql, params) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
