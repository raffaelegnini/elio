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
            CREATE TABLE IF NOT EXISTS scheduled_tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                title TEXT NOT NULL,
                prompt TEXT NOT NULL,
                cwd TEXT NOT NULL,
                done INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS task_history (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                project TEXT,
                status TEXT NOT NULL,
                summary TEXT,
                ended REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS reminders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                text TEXT NOT NULL,
                done INTEGER NOT NULL DEFAULT 0
            );
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

    // MARK: - Reminders

    public struct Reminder: Sendable { public let id: Int; public let text: String; public let at: Date }

    public func addReminder(text: String, at: Date) {
        run("INSERT INTO reminders (at, text) VALUES (?, ?)", [at.timeIntervalSince1970, text])
    }

    /// Pending reminders; with `dueBefore` only those already due.
    public func reminders(dueBefore: Date?) -> [Reminder] {
        var rows: [Reminder] = []
        let sql = dueBefore == nil
            ? "SELECT id, text, at FROM reminders WHERE done = 0 ORDER BY at"
            : "SELECT id, text, at FROM reminders WHERE done = 0 AND at <= ? ORDER BY at"
        query(sql, dueBefore.map { [$0.timeIntervalSince1970] } ?? []) { stmt in
            rows.append(Reminder(id: Int(sqlite3_column_int64(stmt, 0)),
                                 text: String(cString: sqlite3_column_text(stmt, 1)),
                                 at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))))
        }
        return rows
    }

    public func markReminderDone(_ id: Int) {
        run("UPDATE reminders SET done = 1 WHERE id = ?", [id])
    }

    // MARK: - Scheduled agent tasks

    public struct ScheduledTask: Sendable {
        public let id: Int; public let at: Date; public let title: String; public let prompt: String; public let cwd: String
    }

    public func addScheduledTask(at: Date, title: String, prompt: String, cwd: String) {
        run("INSERT INTO scheduled_tasks (at, title, prompt, cwd) VALUES (?, ?, ?, ?)",
            [at.timeIntervalSince1970, title, prompt, cwd])
    }

    public func scheduledTasks(dueBefore: Date?) -> [ScheduledTask] {
        var rows: [ScheduledTask] = []
        let sql = dueBefore == nil
            ? "SELECT id, at, title, prompt, cwd FROM scheduled_tasks WHERE done = 0 ORDER BY at"
            : "SELECT id, at, title, prompt, cwd FROM scheduled_tasks WHERE done = 0 AND at <= ? ORDER BY at"
        query(sql, dueBefore.map { [$0.timeIntervalSince1970] } ?? []) { stmt in
            rows.append(ScheduledTask(id: Int(sqlite3_column_int64(stmt, 0)),
                                      at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                      title: String(cString: sqlite3_column_text(stmt, 2)),
                                      prompt: String(cString: sqlite3_column_text(stmt, 3)),
                                      cwd: String(cString: sqlite3_column_text(stmt, 4))))
        }
        return rows
    }

    public func markScheduledTaskDone(_ id: Int) {
        run("UPDATE scheduled_tasks SET done = 1 WHERE id = ?", [id])
    }

    // MARK: - Task history (for the morning recap)

    public func recordTask(_ t: TaskInfo) {
        run("INSERT OR REPLACE INTO task_history (id, title, project, status, summary, ended) VALUES (?, ?, ?, ?, ?, ?)",
            [t.id, t.title, t.project, t.status.rawValue, t.summary, (t.endedAt ?? Date()).timeIntervalSince1970])
    }

    public func tasksEnded(since: Date) -> [TaskInfo] {
        var rows: [TaskInfo] = []
        query("SELECT id, title, project, status, summary, ended FROM task_history WHERE ended >= ? ORDER BY ended",
              [since.timeIntervalSince1970]) { stmt in
            let ended = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            rows.append(TaskInfo(id: String(cString: sqlite3_column_text(stmt, 0)),
                                 title: String(cString: sqlite3_column_text(stmt, 1)),
                                 project: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                                 status: TaskInfo.Status(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .done,
                                 summary: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                                 startedAt: ended, endedAt: ended))
        }
        return rows
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
