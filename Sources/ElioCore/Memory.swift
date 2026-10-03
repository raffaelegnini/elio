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

    var db: OpaquePointer?

    public init(path: URL = ElioPaths.database) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK else {
            throw ElioError.database("open failed at \(path.path)")
        }
        db = handle
        // Columns added after the first release: ignore "duplicate column" on existing DBs.
        sqlite3_exec(handle, "ALTER TABLE reminders ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE reminders ADD COLUMN parent INTEGER", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE reminders ADD COLUMN fired REAL", nil, nil, nil)
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
            CREATE TABLE IF NOT EXISTS task_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                json TEXT NOT NULL,
                ts REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS task_logs_task ON task_logs(task_id);
            CREATE TABLE IF NOT EXISTS tool_calls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                ok INTEGER NOT NULL,
                ms INTEGER NOT NULL,
                ts REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS cache (
                source TEXT NOT NULL,
                key TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                search TEXT NOT NULL,
                data TEXT NOT NULL,
                updated REAL NOT NULL,
                PRIMARY KEY (source, key)
            );
            CREATE INDEX IF NOT EXISTS cache_kind ON cache(kind);
            CREATE TABLE IF NOT EXISTS cards (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                ts REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'generale',
                created REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS reminders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                text TEXT NOT NULL,
                done INTEGER NOT NULL DEFAULT 0
            );
            """)
        try Self.exec(handle, Self.workflowSchema)
        try Self.exec(handle, Self.todoSchema)
    }

    deinit { sqlite3_close(db) }

    public func log(role: String, text: String, route: String? = nil) {
        run("INSERT INTO messages (ts, role, text, route) VALUES (?, ?, ?, ?)",
            [Date().timeIntervalSince1970, role, SecretFilter.redact(text), route])
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

    public func addReminder(text: String, at: Date, attempt: Int = 0, parent: Int? = nil) {
        run("INSERT INTO reminders (at, text, attempt, parent) VALUES (?, ?, ?, ?)",
            [at.timeIntervalSince1970, text, attempt, parent])
    }

    public func reminderAttempt(_ id: Int) -> (attempt: Int, root: Int) {
        var result = (0, id)
        query("SELECT attempt, COALESCE(parent, id) FROM reminders WHERE id = ?", [id]) { stmt in
            result = (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return result
    }

    /// "Fatto": closes the most recently fired reminder and cancels its pending follow-ups.
    public func acknowledgeLastReminder(within seconds: TimeInterval) -> String? {
        var hit: (root: Int, text: String)?
        query("SELECT COALESCE(parent, id), text FROM reminders WHERE fired >= ? ORDER BY fired DESC LIMIT 1",
              [Date().addingTimeInterval(-seconds).timeIntervalSince1970]) { stmt in
            hit = (Int(sqlite3_column_int64(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1)))
        }
        guard let hit else { return nil }
        run("UPDATE reminders SET done = 1, fired = NULL WHERE id = ? OR parent = ?", [hit.root, hit.root])
        return hit.text
    }

    public func remindersFired(since: Date) -> [String] {
        var rows: [String] = []
        query("SELECT text FROM reminders WHERE fired >= ? AND attempt = 0 ORDER BY fired", [since.timeIntervalSince1970]) { stmt in
            rows.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return rows
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
        run("UPDATE reminders SET done = 1, fired = ? WHERE id = ?", [Date().timeIntervalSince1970, id])
    }

    // MARK: - Synced cache (directory of people, channels, projects, integration records)

    public struct CachedRecord: Codable, Sendable {
        public let source: String
        public let key: String
        public let kind: String
        public let title: String
        public let data: String
        public let updated: Date
    }

    /// Replaces everything a source holds with a fresh snapshot (one transaction).
    public func replaceCache(source: String, records: [(key: String, kind: String, title: String, search: String, data: String)]) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        run("DELETE FROM cache WHERE source = ?", [source])
        let now = Date().timeIntervalSince1970
        for r in records {
            run("INSERT OR REPLACE INTO cache (source, key, kind, title, search, data, updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [source, r.key, r.kind, r.title, Self.fold(r.search), r.data, now])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Candidates whose searchable text contains every word of the query (accents/case folded);
    /// ranking is done by the caller.
    public func searchCache(_ text: String, kind: String? = nil, limit: Int = 200) -> [CachedRecord] {
        let words = Self.fold(text).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        var sql = "SELECT source, key, kind, title, data, updated FROM cache WHERE 1=1"
        var params: [Any?] = []
        if let kind { sql += " AND kind = ?"; params.append(kind) }
        for w in words { sql += " AND search LIKE ?"; params.append("%\(w)%") }
        sql += " LIMIT ?"
        params.append(limit)
        var rows: [CachedRecord] = []
        query(sql, params) { s in
            rows.append(CachedRecord(source: String(cString: sqlite3_column_text(s, 0)), key: String(cString: sqlite3_column_text(s, 1)),
                                     kind: String(cString: sqlite3_column_text(s, 2)), title: String(cString: sqlite3_column_text(s, 3)),
                                     data: String(cString: sqlite3_column_text(s, 4)),
                                     updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
        }
        return rows
    }

    public func cacheStats() -> [(source: String, count: Int, updated: Date)] {
        var rows: [(String, Int, Date)] = []
        query("SELECT source, COUNT(*), MAX(updated) FROM cache GROUP BY source ORDER BY source", []) { s in
            rows.append((String(cString: sqlite3_column_text(s, 0)), Int(sqlite3_column_int64(s, 1)),
                         Date(timeIntervalSince1970: sqlite3_column_double(s, 2))))
        }
        return rows
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .replacingOccurrences(of: #"[^a-z0-9#@._ -]"#, with: " ", options: .regularExpression)
    }

    // MARK: - Cards (what Elio showed on screen)

    public struct SavedCard: Codable, Sendable { public let id: Int; public let title: String; public let body: String; public let ts: Date }

    @discardableResult
    public func addCard(title: String, body: String) -> Int {
        run("INSERT INTO cards (title, body, ts) VALUES (?, ?, ?)", [title, SecretFilter.redact(body), Date().timeIntervalSince1970])
        return Int(sqlite3_last_insert_rowid(db))
    }

    public func cards(limit: Int = 200) -> [SavedCard] {
        var rows: [SavedCard] = []
        query("SELECT id, title, body, ts FROM cards ORDER BY id DESC LIMIT ?", [limit]) { s in
            rows.append(SavedCard(id: Int(sqlite3_column_int64(s, 0)), title: String(cString: sqlite3_column_text(s, 1)),
                                  body: String(cString: sqlite3_column_text(s, 2)),
                                  ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 3))))
        }
        return rows
    }

    // MARK: - Archive

    /// One pass over what was stored before the secret filter existed. Returns rows changed.
    @discardableResult
    public func scrubSecrets() -> Int {
        var changed = 0
        for (table, col) in [("messages", "text"), ("task_logs", "json"), ("task_history", "summary")] {
            var rows: [(Int64, String)] = []
            query("SELECT rowid, \(col) FROM \(table) WHERE \(col) IS NOT NULL", []) { s in
                rows.append((sqlite3_column_int64(s, 0), String(cString: sqlite3_column_text(s, 1))))
            }
            for (id, value) in rows {
                let clean = table == "task_logs"
                    ? (TaskLogEntry.fromJSON(value)?.redacted.jsonString() ?? value)
                    : SecretFilter.redact(value)
                guard clean != value else { continue }
                run("UPDATE \(table) SET \(col) = ? WHERE rowid = ?", [clean, Int(id)])
                changed += 1
            }
        }
        return changed
    }

    public func addTaskLog(_ entry: TaskLogEntry) {
        run("INSERT INTO task_logs (task_id, json, ts) VALUES (?, ?, ?)",
            [entry.taskId, entry.redacted.jsonString(), entry.date.timeIntervalSince1970])
    }

    public func taskLog(_ taskId: String) -> [String] {
        var rows: [String] = []
        query("SELECT json FROM task_logs WHERE task_id = ? ORDER BY id", [taskId]) { rows.append(String(cString: sqlite3_column_text($0, 0))) }
        return rows
    }

    public func recordToolCall(name: String, ok: Bool, ms: Int) {
        run("INSERT INTO tool_calls (name, ok, ms, ts) VALUES (?, ?, ?, ?)", [name, ok ? 1 : 0, ms, Date().timeIntervalSince1970])
    }

    public struct DayCount: Codable, Sendable { public let day: String; public let messages: Int; public let tools: Int; public let tasks: Int }

    public func archiveDays(limit: Int = 60) -> [DayCount] {
        var days: [String: (Int, Int, Int)] = [:]
        let sql = { (table: String, col: String) in
            "SELECT strftime('%Y-%m-%d', \(col), 'unixepoch', 'localtime') d, COUNT(*) FROM \(table) GROUP BY d" }
        query(sql("messages", "ts"), []) { s in
            let d = String(cString: sqlite3_column_text(s, 0)); days[d, default: (0, 0, 0)].0 = Int(sqlite3_column_int64(s, 1)) }
        query(sql("tool_calls", "ts"), []) { s in
            let d = String(cString: sqlite3_column_text(s, 0)); days[d, default: (0, 0, 0)].1 = Int(sqlite3_column_int64(s, 1)) }
        query(sql("task_history", "ended"), []) { s in
            let d = String(cString: sqlite3_column_text(s, 0)); days[d, default: (0, 0, 0)].2 = Int(sqlite3_column_int64(s, 1)) }
        return days.sorted { $0.key > $1.key }.prefix(limit)
            .map { DayCount(day: $0.key, messages: $0.value.0, tools: $0.value.1, tasks: $0.value.2) }
    }

    public struct ArchivedMessage: Codable, Sendable { public let ts: Date; public let role: String; public let text: String; public let route: String? }

    public func messages(onDay day: String?, search: String?) -> [ArchivedMessage] {
        var rows: [ArchivedMessage] = []
        var sql = "SELECT ts, role, text, route FROM messages WHERE 1=1"
        var params: [Any?] = []
        if let day { sql += " AND strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = ?"; params.append(day) }
        if let search, !search.isEmpty { sql += " AND lower(text) LIKE ?"; params.append("%\(search.lowercased())%") }
        sql += " ORDER BY id LIMIT 1000"
        query(sql, params) { s in
            rows.append(ArchivedMessage(ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                                        role: String(cString: sqlite3_column_text(s, 1)),
                                        text: String(cString: sqlite3_column_text(s, 2)),
                                        route: sqlite3_column_text(s, 3).map { String(cString: $0) }))
        }
        return rows
    }

    public struct ArchivedToolCall: Codable, Sendable { public let ts: Date; public let name: String; public let ok: Bool; public let ms: Int }

    public func toolCalls(onDay day: String) -> [ArchivedToolCall] {
        var rows: [ArchivedToolCall] = []
        query("SELECT ts, name, ok, ms FROM tool_calls WHERE strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = ? ORDER BY id",
              [day]) { s in
            rows.append(ArchivedToolCall(ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                                         name: String(cString: sqlite3_column_text(s, 1)),
                                         ok: sqlite3_column_int64(s, 2) == 1, ms: Int(sqlite3_column_int64(s, 3))))
        }
        return rows
    }

    public func allTasks(limit: Int = 200) -> [TaskInfo] {
        tasksEnded(since: .distantPast).suffix(limit).reversed()
    }

    public func allReminders() -> [ArchivedReminder] {
        var rows: [ArchivedReminder] = []
        query("SELECT id, at, text, done, attempt FROM reminders WHERE attempt = 0 ORDER BY at DESC LIMIT 300", []) { s in
            rows.append(ArchivedReminder(id: Int(sqlite3_column_int64(s, 0)), at: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                         text: String(cString: sqlite3_column_text(s, 2)), done: sqlite3_column_int64(s, 3) == 1))
        }
        return rows
    }

    public struct ArchivedReminder: Codable, Sendable { public let id: Int; public let at: Date; public let text: String; public let done: Bool }

    // MARK: - Long-term facts

    public struct Fact: Sendable, Identifiable {
        public let id: Int; public let text: String; public let category: String; public let created: Date
    }

    @discardableResult
    public func addFact(_ text: String, category: String) -> Int {
        run("INSERT INTO facts (text, category, created) VALUES (?, ?, ?)", [text, category, Date().timeIntervalSince1970])
        return Int(sqlite3_last_insert_rowid(db))
    }

    public func facts(matching search: String? = nil, limit: Int = 200) -> [Fact] {
        var rows: [Fact] = []
        let words = (search ?? "").lowercased().split(separator: " ").filter { $0.count > 2 }.map(String.init)
        var sql = "SELECT id, text, category, created FROM facts"
        var params: [Any?] = []
        if !words.isEmpty {
            sql += " WHERE " + words.map { _ in "(lower(text) LIKE ? OR lower(category) LIKE ?)" }.joined(separator: " OR ")
            for w in words { params += ["%\(w)%", "%\(w)%"] }
        }
        sql += " ORDER BY created DESC LIMIT ?"
        params.append(limit)
        query(sql, params) { stmt in
            rows.append(Fact(id: Int(sqlite3_column_int64(stmt, 0)), text: String(cString: sqlite3_column_text(stmt, 1)),
                             category: String(cString: sqlite3_column_text(stmt, 2)),
                             created: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
        }
        return rows
    }

    public func deleteFact(_ id: Int) -> Bool {
        run("DELETE FROM facts WHERE id = ?", [id])
        return sqlite3_changes(db) > 0
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
            [t.id, t.title, t.project, t.status.rawValue, t.summary.map { SecretFilter.redact($0) }, (t.endedAt ?? Date()).timeIntervalSince1970])
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

    static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw ElioError.database(msg)
        }
    }

    func prepare(_ sql: String, _ params: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            ElioCore.log("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
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

    func run(_ sql: String, _ params: [Any?]) {
        guard let stmt = prepare(sql, params) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            ElioCore.log("sqlite step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func query(_ sql: String, _ params: [Any?], row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(sql, params) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
