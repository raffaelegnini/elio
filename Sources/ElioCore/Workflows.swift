import Foundation
import SQLite3

// MARK: - Models

/// A unit of agent work the user can follow and get a report on: a squad, or a single background task.
public struct WorkflowRecord: Codable, Sendable, Identifiable {
    public var id: String
    /// "squad" | "task"
    public var kind: String
    public var title: String
    public var project: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// running | done | failed | cancelled
    public var status: String
    public var summary: String?

    public init(id: String, kind: String, title: String, project: String?, startedAt: Date = Date(),
                endedAt: Date? = nil, status: String = "running", summary: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.project = project
        self.startedAt = startedAt; self.endedAt = endedAt; self.status = status; self.summary = summary
    }
}

/// One moment of a workflow's timeline (what the report is made of).
public struct WorkflowEvent: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case started, agentStarted, agentDone, agentFailed, message, progress, alert
        case question, answer, autoDecision, confirm, confirmResult
        case tasteViolation, tasteCorrection, tasteOk, leadWake, finished
    }
    public var id: Int
    public var workflow: String
    public var ts: Date
    public var kind: Kind
    /// Who: agent name, "elio", "utente".
    public var actor: String
    public var text: String
    /// Extra structured data (JSON string).
    public var data: String?

    public init(id: Int = 0, workflow: String, ts: Date = Date(), kind: Kind, actor: String, text: String, data: String? = nil) {
        self.id = id; self.workflow = workflow; self.ts = ts; self.kind = kind; self.actor = actor; self.text = text; self.data = data
    }
}

/// A preference the user taught Elio ("in design niente gradienti viola"): agents get them in their
/// prompt, a reviewer checks their work against them, and Elio uses them to decide small things for the user.
public struct TasteRule: Codable, Sendable, Identifiable {
    public var id: Int
    /// design | frontend | backend | codice | testi | git | ux | generale
    public var domain: String
    public var rule: String
    public var why: String
    /// Examples of what the user doesn't want / wants.
    public var bad: String
    public var good: String
    /// "fix": Elio has the agent correct it; "note": only reported; "ask": the user decides.
    public var severity: String
    public var created: Date
    /// How many times a reviewer found this rule broken.
    public var hits: Int

    public init(id: Int = 0, domain: String, rule: String, why: String = "", bad: String = "", good: String = "",
                severity: String = "fix", created: Date = Date(), hits: Int = 0) {
        self.id = id; self.domain = domain; self.rule = rule; self.why = why; self.bad = bad; self.good = good
        self.severity = severity; self.created = created; self.hits = hits
    }
}

// MARK: - Storage

extension Memory {
    static let workflowSchema = """
        CREATE TABLE IF NOT EXISTS taste_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            domain TEXT NOT NULL,
            rule TEXT NOT NULL,
            why TEXT NOT NULL DEFAULT '',
            bad TEXT NOT NULL DEFAULT '',
            good TEXT NOT NULL DEFAULT '',
            severity TEXT NOT NULL DEFAULT 'fix',
            created REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS workflows (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            project TEXT,
            started REAL NOT NULL,
            ended REAL,
            status TEXT NOT NULL,
            summary TEXT
        );
        CREATE TABLE IF NOT EXISTS workflow_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            wf TEXT NOT NULL,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            actor TEXT NOT NULL,
            text TEXT NOT NULL,
            data TEXT
        );
        CREATE INDEX IF NOT EXISTS workflow_events_wf ON workflow_events(wf);
        CREATE TABLE IF NOT EXISTS workflow_agents (
            wf TEXT NOT NULL,
            task_id TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (wf, task_id)
        );
        """

    // Taste

    @discardableResult
    public func addTasteRule(_ r: TasteRule) -> Int {
        run("INSERT INTO taste_rules (domain, rule, why, bad, good, severity, created) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [r.domain, r.rule, r.why, r.bad, r.good, r.severity, Date().timeIntervalSince1970])
        return Int(sqlite3_last_insert_rowid(db))
    }

    public func tasteRules() -> [TasteRule] {
        var rows: [TasteRule] = []
        query("SELECT id, domain, rule, why, bad, good, severity, created, hits FROM taste_rules ORDER BY domain, id", []) { s in
            rows.append(TasteRule(id: Int(sqlite3_column_int64(s, 0)), domain: Self.text(s, 1), rule: Self.text(s, 2),
                                  why: Self.text(s, 3), bad: Self.text(s, 4), good: Self.text(s, 5), severity: Self.text(s, 6),
                                  created: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                                  hits: Int(sqlite3_column_int64(s, 8))))
        }
        return rows
    }

    public func deleteTasteRule(_ id: Int) -> Bool {
        run("DELETE FROM taste_rules WHERE id = ?", [id])
        return sqlite3_changes(db) > 0
    }

    public func bumpTasteHits(_ ids: [Int]) {
        for id in Set(ids) { run("UPDATE taste_rules SET hits = hits + 1 WHERE id = ?", [id]) }
    }

    // Workflows

    public func saveWorkflow(_ w: WorkflowRecord) {
        run("""
            INSERT INTO workflows (id, kind, title, project, started, ended, status, summary) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, ended = excluded.ended, status = excluded.status,
            summary = COALESCE(excluded.summary, workflows.summary)
            """,
            [w.id, w.kind, w.title, w.project, w.startedAt.timeIntervalSince1970, w.endedAt?.timeIntervalSince1970,
             w.status, w.summary.map { SecretFilter.redact($0) }])
    }

    public func workflows(limit: Int = 50) -> [WorkflowRecord] {
        var rows: [WorkflowRecord] = []
        query("SELECT id, kind, title, project, started, ended, status, summary FROM workflows ORDER BY started DESC LIMIT ?", [limit]) { s in
            rows.append(Self.workflowRow(s))
        }
        return rows
    }

    public func workflow(_ id: String) -> WorkflowRecord? {
        var row: WorkflowRecord?
        query("SELECT id, kind, title, project, started, ended, status, summary FROM workflows WHERE id = ?", [id]) { row = Self.workflowRow($0) }
        return row
    }

    public func addWorkflowEvent(_ e: WorkflowEvent) {
        run("INSERT INTO workflow_events (wf, ts, kind, actor, text, data) VALUES (?, ?, ?, ?, ?, ?)",
            [e.workflow, e.ts.timeIntervalSince1970, e.kind.rawValue, e.actor, SecretFilter.redact(e.text), e.data])
    }

    public func workflowEvents(_ wf: String) -> [WorkflowEvent] {
        var rows: [WorkflowEvent] = []
        query("SELECT id, wf, ts, kind, actor, text, data FROM workflow_events WHERE wf = ? ORDER BY id", [wf]) { s in
            guard let kind = WorkflowEvent.Kind(rawValue: Self.text(s, 3)) else { return }
            rows.append(WorkflowEvent(id: Int(sqlite3_column_int64(s, 0)), workflow: Self.text(s, 1),
                                      ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), kind: kind,
                                      actor: Self.text(s, 4), text: Self.text(s, 5),
                                      data: sqlite3_column_text(s, 6).map { String(cString: $0) }))
        }
        return rows
    }

    /// One row per agent (`key`: its squad name, or "main" for a single task), updated at every run.
    public func saveWorkflowAgent(_ wf: String, key: String, _ info: TaskInfo) {
        var info = info
        info.summary = info.summary.map { SecretFilter.redact($0) }
        info.lastMessage = info.lastMessage.map { SecretFilter.redact($0) }
        info.steps = []
        run("INSERT OR REPLACE INTO workflow_agents (wf, task_id, json) VALUES (?, ?, ?)", [wf, key, info.jsonString()])
    }

    public func workflowAgents(_ wf: String) -> [TaskInfo] {
        var rows: [TaskInfo] = []
        query("SELECT json FROM workflow_agents WHERE wf = ?", [wf]) { s in
            if let t = TaskInfo.fromJSON(Self.text(s, 0)) { rows.append(t) }
        }
        return rows.sorted { $0.startedAt < $1.startedAt }
    }

    public func taskLogEntries(_ taskId: String) -> [TaskLogEntry] {
        taskLog(taskId).compactMap { TaskLogEntry.fromJSON($0) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private static func workflowRow(_ s: OpaquePointer) -> WorkflowRecord {
        WorkflowRecord(id: text(s, 0), kind: text(s, 1), title: text(s, 2),
                       project: sqlite3_column_text(s, 3).map { String(cString: $0) },
                       startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                       endedAt: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
                       status: text(s, 6), summary: sqlite3_column_text(s, 7).map { String(cString: $0) })
    }
}

// MARK: - Talking / silent mode

/// How much Elio speaks while agents work. Talking: narrates progress and the decisions it takes for
/// the user. Silent: stays quiet and speaks only for what needs the user (questions, confirmations,
/// problems) and when a workflow ends. Applied to every event on its way out, so no producer has to care.
public enum Attention {
    public enum Mode: String, Codable, Sendable { case talking, silent }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Mode = Mode(rawValue: ElioConfig.load().workflowVoice) ?? .talking

    public static var mode: Mode { lock.withLock { current } }

    /// Changes the mode now and keeps it across restarts.
    public static func set(_ mode: Mode, persist: Bool = true) {
        lock.withLock { current = mode }
        guard persist else { return }
        var cfg = ElioConfig.load()
        cfg.workflowVoice = mode.rawValue
        cfg.save()
    }

    /// Workflow chatter that silent mode keeps off the speakers (still shown on screen and in the report).
    static let chatter: Set<String> = ["progress", "autoDecision", "tasteFix", "workflowNote"]

    public static func shape(_ message: ServerMessage) -> ServerMessage {
        guard message.type == .event, message.speak == true, let kind = message.kind,
              chatter.contains(kind), mode == .silent else { return message }
        var m = message
        m.speak = false
        return m
    }
}

// MARK: - One-shot Claude calls (reviews, delegated decisions)

/// A single Claude call with no tools and no session: in → structured JSON out.
public enum OneShot {
    public struct Result: @unchecked Sendable { public let json: [String: Any]; public let costUSD: Double }

    public static func ask(_ prompt: String, schema: [String: Any], model: String, config: ElioConfig,
                           timeout: TimeInterval = 150) async -> Result? {
        guard let schemaData = try? JSONSerialization.data(withJSONObject: schema) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudePath)
        // A neutral folder: no project CLAUDE.md, no hooks.
        p.currentDirectoryURL = ElioPaths.claudeWorkspace
        p.arguments = ["-p", prompt, "--output-format", "json", "--model", model, "--tools", "",
                       "--no-session-persistence", "--setting-sources", "",
                       "--json-schema", String(decoding: schemaData, as: UTF8.self)]
        p.environment = config.claudeAccount.environment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { log("one-shot failed to start: \(error)"); return nil }
        let killer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            if p.isRunning { p.terminate() }
        }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        killer.cancel()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let cost = obj["total_cost_usd"] as? Double ?? 0
        if let structured = obj["structured_output"] as? [String: Any] {
            return Result(json: structured, costUSD: cost)
        }
        // Older CLIs: the JSON is the text of the result.
        if let text = obj["result"] as? String, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let inner = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] {
            return Result(json: inner, costUSD: cost)
        }
        return nil
    }
}

// MARK: - Report data

/// Everything the workflow report shows, as one JSON document (rendered by web/report.html).
public struct WorkflowReport: Codable, Sendable {
    public struct AgentStats: Codable, Sendable {
        public var info: TaskInfo
        /// Log entries per kind (command, edit, read…).
        public var activity: [String: Int]
        public var files: [String]
        public var commands: [String]
        /// Minute-by-minute activity (offset from the workflow start, in minutes → actions).
        public var timeline: [Int: Int]
    }
    public var workflow: WorkflowRecord
    public var agents: [AgentStats]
    public var events: [WorkflowEvent]
    public var messages: [SquadMessage]
    public var taste: [TasteRule]
    public var mode: String
    public var generatedAt: Date

    public static func build(id: String, memory: Memory, tasks: TaskRunner) async -> WorkflowReport? {
        guard var wf = await memory.workflow(id) else { return nil }
        // Live state wins over what's stored (tokens and status move while agents run).
        var agents: [String: TaskInfo] = [:]
        for a in await memory.workflowAgents(id) { agents[a.member ?? "main"] = a }
        for a in await tasks.agents(ofWorkflow: id) { agents[a.member ?? "main"] = a }
        if let live = await tasks.squad(id) { wf.endedAt = live.endedAt ?? wf.endedAt }
        var stats: [AgentStats] = []
        for a in agents.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            var log: [TaskLogEntry] = []
            for run in a.runIds ?? [a.id] { log += await memory.taskLogEntries(run) }
            var activity: [String: Int] = [:]
            var files: [String] = []
            var commands: [String] = []
            var timeline: [Int: Int] = [:]
            for e in log {
                activity[e.kind.rawValue, default: 0] += 1
                if [.edit, .write].contains(e.kind), !e.title.isEmpty, !files.contains(e.title) { files.append(e.title) }
                if e.kind == .command, commands.count < 40 { commands.append(String(e.title.prefix(160))) }
                if e.kind != .output && e.kind != .say {
                    timeline[max(0, Int(e.date.timeIntervalSince(wf.startedAt) / 60)), default: 0] += 1
                }
            }
            stats.append(AgentStats(info: a, activity: activity, files: files, commands: commands, timeline: timeline))
        }
        return WorkflowReport(workflow: wf, agents: stats, events: await memory.workflowEvents(id),
                              messages: await tasks.messages(squad: id), taste: await memory.tasteRules(),
                              mode: Attention.mode.rawValue, generatedAt: Date())
    }

    /// The report as a self-contained HTML file (template from the web folder, data inlined).
    public func html() -> String? {
        let template = ElioPaths.support.appendingPathComponent("web/report.html")
        guard var page = try? String(contentsOf: template, encoding: .utf8) else { return nil }
        // `</` can't appear inside an inline script.
        let json = jsonString().replacingOccurrences(of: "</", with: "<\\/")
        page = page.replacingOccurrences(of: "/*__ELIO_REPORT__*/null", with: json)
        return page
    }
}

// MARK: - Tools

public enum WorkflowTools {
    static let mode = ElioTool(
        name: "workflow_mode",
        description: """
        Modalità di Elio mentre gli agenti lavorano: "talking" (racconta i progressi e le decisioni che prende per Raffaele) \
        o "silent" (sta zitto e parla solo per domande, conferme, problemi e alla fine). Senza mode restituisce quella attuale.
        """,
        properties: ["mode": prop("talking o silent (opzionale)")]
    ) { args, ctx in
        if let raw = (args["mode"] as? String)?.lowercased() {
            let mode: Attention.Mode = ["silent", "silenziosa", "muto", "zitto"].contains(raw) ? .silent : .talking
            Attention.set(mode)
            ctx.broadcast(ServerMessage(type: .event, text: mode.rawValue, kind: "mode"))
            return mode == .silent ? "Modalità silenziosa: parlo solo per domande, problemi e fine lavori."
                                   : "Modalità parlante: racconto i progressi."
        }
        return "Modalità attuale: \(Attention.mode.rawValue)."
    }

    static let report = ElioTool(
        name: "workflow_report",
        description: """
        Genera il report di un workflow (squadra o task in background): grafici di tempi, token e costi per agente, \
        attività, decisioni prese per Raffaele, correzioni di gusto, domande, bacheca. Lo apre nel browser del Mac \
        (open: false per solo generarlo). Senza id usa l'ultimo workflow.
        """,
        properties: ["id": prop("Id del workflow (squadra o task, opzionale)"),
                     "open": prop("Aprirlo nel browser (default true)", type: "boolean")]
    ) { args, ctx in
        var id = (args["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if id == nil { id = await ctx.memory.workflows(limit: 1).first?.id }
        guard let id, let report = await WorkflowReport.build(id: id, memory: ctx.memory, tasks: ctx.tasks),
              let html = report.html() else { throw ToolError("Workflow non trovato") }
        let dir = ElioPaths.outputDir.appendingPathComponent("Report", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let file = dir.appendingPathComponent("workflow-\(f.string(from: report.workflow.startedAt))-\(id).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        if args["open"] as? Bool ?? true { _ = try? shell("/usr/bin/open", [file.path]) }
        let agents = report.agents.count
        let cost = report.agents.compactMap(\.info.costUSD).reduce(0, +)
        return "Report pronto (\(agents) agenti, $\(String(format: "%.2f", cost))): \(file.path). Sul telefono è nella sezione Workflow."
    }

    static let list = ElioTool(
        name: "workflow_list",
        description: "Elenco dei workflow recenti (squadre e task), con stato e id per workflow_report.",
        properties: [:]
    ) { _, ctx in
        let all = await ctx.memory.workflows(limit: 15)
        guard !all.isEmpty else { return "Nessun workflow." }
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return all.map { "- [\($0.status)] \($0.title) (id \($0.id), \($0.kind), \(f.string(from: $0.startedAt)))" }.joined(separator: "\n")
    }

    /// For the app's mission view: the full report data as JSON (same as the HTML report).
    static let reportJSON = ElioTool(
        name: "workflow_report_json",
        description: "Uso interno dell'app.",
        properties: ["id": prop("Id del workflow")],
        required: ["id"]
    ) { args, ctx in
        guard let r = await WorkflowReport.build(id: args["id"] as? String ?? "", memory: ctx.memory, tasks: ctx.tasks) else {
            throw ToolError("Workflow non trovato")
        }
        return r.jsonString()
    }

    /// For the app and the phone: recent workflows with live agents, as JSON.
    static let listJSON = ElioTool(
        name: "workflow_list_json",
        description: "Uso interno dell'app.",
        properties: [:]
    ) { _, ctx in
        try await WorkflowFeed.json(memory: ctx.memory, tasks: ctx.tasks)
    }
}

/// The phone's and dashboard's workflow overview.
public enum WorkflowFeed {
    struct Item: Codable {
        var workflow: WorkflowRecord
        var agents: [TaskInfo]
        var pending: Int
    }
    struct Feed: Codable {
        var mode: String
        var workflows: [Item]
    }

    public static func json(memory: Memory, tasks: TaskRunner) async throws -> String {
        var items: [Item] = []
        for w in await memory.workflows(limit: 20) {
            var agents: [String: TaskInfo] = [:]
            for a in await memory.workflowAgents(w.id) { agents[a.member ?? "main"] = a }
            for a in await tasks.agents(ofWorkflow: w.id) { agents[a.member ?? "main"] = a }
            var list = Array(agents.values).sorted { $0.startedAt < $1.startedAt }
            for i in list.indices { list[i].steps = Array(list[i].steps.suffix(1)) }
            let pending = list.filter { $0.status == .waitingConfirmation }.count
            items.append(Item(workflow: w, agents: list, pending: pending))
        }
        return Feed(mode: Attention.mode.rawValue, workflows: items).jsonString()
    }
}
