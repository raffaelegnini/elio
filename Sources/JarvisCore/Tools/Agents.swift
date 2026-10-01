import Foundation

// MARK: - Confirmation gate

/// Holds an action until the user explicitly approves it (voice or HUD button).
/// Unanswered requests are denied after a timeout: silence never means yes.
public actor ConfirmationGate {
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    public private(set) var pending: [String: ConfirmRequest] = [:]

    public init() {}

    public func setBroadcast(_ b: @escaping @Sendable (ServerMessage) -> Void) { broadcast = b }

    public func request(_ req: ConfirmRequest, timeout: TimeInterval = 300) async -> Bool {
        pending[req.id] = req
        let spoken = req.risk == .dangerous
            ? "\(req.title). È un'azione delicata: per procedere di' \"confermo\"."
            : "\(req.title). Posso procedere?"
        broadcast?(ServerMessage(type: .event, id: req.id, text: spoken, kind: "confirm",
                                 payload: req.jsonString(), speak: true))
        let id = req.id
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.answer(id: id, approved: false)
        }
        return await withCheckedContinuation { waiting[req.id] = $0 }
    }

    public func answer(id: String, approved: Bool) {
        guard let c = waiting.removeValue(forKey: id) else { return }
        pending[id] = nil
        broadcast?(ServerMessage(type: .event, id: id, text: approved ? "Confermato" : "Annullato",
                                 kind: "confirmResolved", payload: "{\"approved\":\(approved)}"))
        c.resume(returning: approved)
    }
}

/// Permission prompt tool for background agents (`--permission-prompt-tool mcp__jarvis__approve`).
public enum ApprovalTool {
    static let approve = JarvisTool(
        name: "approve",
        description: "Uso interno: richiesta di permesso degli agenti in background. Non chiamarlo direttamente.",
        properties: [
            "tool_name": prop("Tool richiesto"),
            "input": ["type": "object", "description": "Input del tool"],
        ],
        required: ["tool_name", "input"]
    ) { args, ctx in
        let tool = args["tool_name"] as? String ?? ""
        let input = args["input"] as? [String: Any] ?? [:]
        let cwd = await ctx.tasks.cwd(for: ctx.taskId) ?? "/nonexistent"
        let decision = PermissionPolicy.decide(tool: tool, input: input, cwd: cwd)

        let allow: Bool
        switch decision {
        case .allow:
            allow = true
        case .confirm(let risk):
            let detail = describe(tool: tool, input: input)
            let title = await ctx.tasks.title(for: ctx.taskId).map { "Il task \"\($0)\" vuole eseguire: \(short(detail))" }
                ?? "Un agente vuole eseguire: \(short(detail))"
            await ctx.tasks.setStatus(ctx.taskId, .waitingConfirmation)
            allow = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: title, detail: detail,
                                                          risk: risk, taskId: ctx.taskId))
            await ctx.tasks.setStatus(ctx.taskId, .running)
        }
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "L'utente non ha confermato questa azione. Non riprovare; prosegui senza o fermati e spiega."]
        let data = try JSONSerialization.data(withJSONObject: response)
        return String(decoding: data, as: UTF8.self)
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash": return input["command"] as? String ?? "comando"
        case "Edit", "Write", "MultiEdit": return "\(tool) \(input["file_path"] as? String ?? "")"
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
            return "\(tool) \(String(decoding: data, as: UTF8.self).prefix(300))"
        }
    }

    static func short(_ s: String) -> String {
        s.count > 90 ? String(s.prefix(87)) + "…" : s
    }
}

// MARK: - Scheduler

/// Persistent reminders: fire on time with voice + notification, survive restarts.
public actor Scheduler {
    public struct Item: Sendable { public let id: Int; public let text: String; public let at: Date }

    private let memory: Memory
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    private var loop: Task<Void, Never>?
    private var tasks: TaskRunner?

    public init(memory: Memory) { self.memory = memory }

    public func attach(tasks: TaskRunner) { self.tasks = tasks }

    public func start(broadcast: @escaping @Sendable (ServerMessage) -> Void) {
        self.broadcast = broadcast
        loop = Task {
            while !Task.isCancelled {
                await self.fireDue()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func add(text: String, at: Date) async {
        await memory.addReminder(text: text, at: at)
    }

    public func upcoming() async -> [Item] {
        await memory.reminders(dueBefore: nil).map { Item(id: $0.id, text: $0.text, at: $0.at) }
    }

    private func fireDue() async {
        for job in await memory.scheduledTasks(dueBefore: Date()) {
            await memory.markScheduledTaskDone(job.id)
            do {
                _ = try await tasks?.start(title: job.title, prompt: job.prompt, cwd: job.cwd)
            } catch {
                log("scheduled task failed to start: \(error)")
            }
        }
        for r in await memory.reminders(dueBefore: Date()) {
            await memory.markReminderDone(r.id)
            let text = "Promemoria: \(r.text)."
            LocalActions().notify(title: "Jarvis", body: r.text)
            broadcast?(ServerMessage(type: .event, text: text, lang: .it, kind: "reminder", speak: true))
        }
    }
}

// MARK: - Background agents

/// Long jobs (code, tests, reviews) run as separate Claude Code agents with full tools
/// in a project directory. Every non-trivial action goes through `approve` → PermissionPolicy → gate.
public actor TaskRunner {
    private struct Running {
        var info: TaskInfo
        let cwd: String
        let process: Process
    }

    private let config: JarvisConfig
    private let mcpConfig: String
    private var tasks: [String: Running] = [:]
    private var finished: [TaskInfo] = []
    private var broadcast: (@Sendable (ServerMessage) -> Void)?

    private let memory: Memory?

    public init(config: JarvisConfig, mcpConfig: String, memory: Memory? = nil) {
        self.config = config
        self.mcpConfig = mcpConfig
        self.memory = memory
    }

    public func setBroadcast(_ b: @escaping @Sendable (ServerMessage) -> Void) { broadcast = b }

    public func cwd(for id: String?) -> String? { id.flatMap { tasks[$0]?.cwd } }
    public func title(for id: String?) -> String? { id.flatMap { tasks[$0]?.info.title } }

    public func all() -> [TaskInfo] {
        tasks.values.map(\.info).sorted { $0.startedAt < $1.startedAt } + finished.suffix(10)
    }

    public func setStatus(_ id: String?, _ status: TaskInfo.Status) {
        guard let id, tasks[id] != nil else { return }
        tasks[id]?.info.status = status
        publish(id)
    }

    public func start(title: String, prompt: String, cwd: String) throws -> TaskInfo {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudePath)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = [
            "-p", Self.agentPrompt(title: title, prompt: prompt, cwd: cwd),
            "--output-format", "stream-json", "--verbose",
            "--model", config.agentModel,
            "--setting-sources", "project,local",
            "--strict-mcp-config", "--mcp-config", mcpConfig,
            "--permission-prompt-tool", "mcp__jarvis__approve",
            "--allowedTools", "Read", "Grep", "Glob", "TodoWrite",
            "--disallowedTools", "mcp__jarvis__start_task",
        ]
        var env = ProcessInfo.processInfo.environment
        env["JARVIS_TASK_ID"] = id
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { await self?.exited(id, code: code) }
        }
        try p.run()

        let info = TaskInfo(id: id, title: title, project: (cwd as NSString).lastPathComponent, status: .running)
        tasks[id] = Running(info: info, cwd: cwd, process: p)
        publish(id)

        let lines = LineReader.stream(out.fileHandleForReading)
        Task { [weak self] in
            for await line in lines { await self?.handle(id, line) }
        }
        return info
    }

    public func cancel(_ id: String) -> Bool {
        guard let t = tasks[id] else { return false }
        tasks[id]?.info.status = .cancelled
        t.process.terminate()
        return true
    }

    private func handle(_ id: String, _ line: String) {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch ev["type"] as? String {
        case "assistant":
            let content = ((ev["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                addStep(id, Self.step(name, input))
            }
        case "result":
            let text = ev["result"] as? String ?? ""
            tasks[id]?.info.summary = text
            if ev["is_error"] as? Bool == true { tasks[id]?.info.status = .failed }
        default:
            break
        }
    }

    private func addStep(_ id: String, _ step: String) {
        guard tasks[id] != nil else { return }
        tasks[id]?.info.steps.append(step)
        if tasks[id]!.info.steps.count > 40 { tasks[id]?.info.steps.removeFirst() }
        publish(id)
    }

    private func exited(_ id: String, code: Int32) {
        guard var t = tasks.removeValue(forKey: id) else { return }
        if t.info.status == .running || t.info.status == .waitingConfirmation {
            t.info.status = code == 0 ? .done : .failed
        }
        t.info.endedAt = Date()
        finished.append(t.info)
        if finished.count > 20 { finished.removeFirst() }
        broadcastTask(t.info)
        let record = t.info
        if let memory { Task { await memory.recordTask(record) } }

        let summary = Self.spokenSummary(t.info.summary)
        let text: String
        switch t.info.status {
        case .done: text = "Ho finito \"\(t.info.title)\". \(summary)"
        case .cancelled: text = "Task \"\(t.info.title)\" annullato."
        default: text = "Il task \"\(t.info.title)\" non è andato a buon fine. \(summary)"
        }
        broadcast?(ServerMessage(type: .event, text: text, lang: .it, kind: "taskDone", payload: t.info.jsonString(), speak: true))

        // Changes are reviewed in the app, never pushed automatically.
        if t.info.status == .done, let payload = try? ProjectTools.diff(repo: t.cwd, base: nil, head: nil), !payload.diff.isEmpty {
            broadcast?(ServerMessage(type: .event, text: "Diff \(payload.title)", kind: "diff", payload: payload.jsonString()))
        }
    }

    private func publish(_ id: String) {
        if let info = tasks[id]?.info { broadcastTask(info) }
    }

    private func broadcastTask(_ info: TaskInfo) {
        broadcast?(ServerMessage(type: .event, text: info.title, kind: "task", payload: info.jsonString()))
    }

    static func step(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "Bash": return "$ \((input["command"] as? String ?? "").prefix(120))"
        case "Read": return "Legge \(((input["file_path"] as? String) ?? "") .split(separator: "/").suffix(2).joined(separator: "/"))"
        case "Edit", "MultiEdit", "Write": return "Modifica \(((input["file_path"] as? String) ?? "").split(separator: "/").suffix(2).joined(separator: "/"))"
        case "Grep": return "Cerca \"\((input["pattern"] as? String ?? "").prefix(60))\""
        case "Glob": return "Trova \(input["pattern"] as? String ?? "")"
        case "TodoWrite": return "Pianifica"
        default: return name.replacingOccurrences(of: "mcp__jarvis__", with: "")
        }
    }

    static func spokenSummary(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        // The agent ends with a short spoken summary; keep the first ~2 sentences.
        let clean = Speakable.clean(text)
        var splitter = SentenceSplitter()
        var sentences = splitter.push(clean + " ")
        if let rest = splitter.flush() { sentences.append(rest) }
        return sentences.prefix(2).joined(separator: " ")
    }

    static func agentPrompt(title: String, prompt: String, cwd: String) -> String {
        """
        Sei un agente di Jarvis, l'assistente personale di Raffaele. Lavori in background nel progetto \(cwd).

        Compito: \(title)
        Dettagli: \(prompt)

        Regole:
        - Se devi modificare codice, crea prima un branch locale `jarvis/<slug-breve>` e committa lì. Mai su develop/main/master.
        - Non fare mai push, merge, rebase, né aprire PR: Raffaele rivede il diff nell'app e crea lui la PR.
        - Non cancellare file e non inviare messaggi a nessuno. Se ti serve davvero, chiedi (la richiesta passa da una conferma).
        - Esegui test/lint pertinenti se esistono.
        - Termina con un riassunto in italiano di massimo due frasi, adatto a essere letto a voce, poi una sezione dettagliata.
        """
    }
}

public enum TaskTools {
    static let schedule = JarvisTool(
        name: "schedule_task",
        description: "Programma un task in background per più tardi (es. 'stanotte'): parte all'orario indicato e il risultato finisce nel recap del mattino.",
        properties: [
            "title": prop("Titolo breve del task"),
            "prompt": prop("Istruzioni complete per l'agente"),
            "project_path": prop("Percorso assoluto del repository"),
            "at": prop("Quando avviarlo, ISO8601 con fuso orario"),
        ],
        required: ["title", "prompt", "project_path", "at"]
    ) { args, ctx in
        let path = expandPath(args["project_path"] as? String ?? "")
        guard FileManager.default.fileExists(atPath: path) else { throw ToolError("Cartella non trovata: \(path)") }
        guard let at = (args["at"] as? String).flatMap(parseDate) else { throw ToolError("Orario non valido") }
        await ctx.memory.addScheduledTask(at: at, title: args["title"] as? String ?? "Task",
                                          prompt: args["prompt"] as? String ?? "", cwd: path)
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE 'alle' HH:mm"
        return "Task programmato per \(f.string(from: at))."
    }

    static let start = JarvisTool(
        name: "start_task",
        description: """
        Avvia un agente Claude in background per lavori lunghi in un progetto: scrivere/correggere codice, eseguire test, \
        fare una code review, preparare un branch da revisionare, analizzare un repository. Restituisce subito; \
        l'utente viene avvisato a voce alla fine e vede il diff nell'app. Usa list_projects per trovare il percorso.
        """,
        properties: [
            "title": prop("Titolo breve del task, in italiano"),
            "prompt": prop("Istruzioni complete e autosufficienti per l'agente"),
            "project_path": prop("Percorso assoluto del repository"),
        ],
        required: ["title", "prompt", "project_path"]
    ) { args, ctx in
        let path = expandPath(args["project_path"] as? String ?? "")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Cartella non trovata: \(path)")
        }
        let info = try await ctx.tasks.start(title: args["title"] as? String ?? "Task",
                                             prompt: args["prompt"] as? String ?? "", cwd: path)
        return "Task avviato (id \(info.id)) in \(info.project ?? path)."
    }

    static let list = JarvisTool(
        name: "list_tasks",
        description: "Stato dei task in background (in corso e recenti)."
    ) { _, ctx in
        let all = await ctx.tasks.all()
        guard !all.isEmpty else { return "Nessun task." }
        return all.map { t in
            "- [\(t.status.rawValue)] \(t.title) (id \(t.id), \(t.project ?? "")): \(t.summary.map { String($0.prefix(200)) } ?? t.steps.last ?? "")"
        }.joined(separator: "\n")
    }

    static let cancel = JarvisTool(
        name: "cancel_task",
        description: "Ferma un task in background.",
        properties: ["id": prop("Id del task")],
        required: ["id"]
    ) { args, ctx in
        await ctx.tasks.cancel(args["id"] as? String ?? "") ? "Task fermato." : "Task non trovato."
    }
}
