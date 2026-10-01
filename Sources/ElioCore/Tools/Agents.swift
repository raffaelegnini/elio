import Foundation

// MARK: - Confirmation gate

/// Holds an action until the user explicitly approves it (voice or HUD button).
/// Unanswered requests are denied after a timeout: silence never means yes.
public actor ConfirmationGate {
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]
    private var questions: [String: CheckedContinuation<String?, Never>] = [:]

    /// Asks the user a free-form question (spoken, HUD, phone). Nil if unanswered in time.
    public func ask(_ q: QuestionRequest, timeout: TimeInterval) async -> String? {
        // Spoken as Elio would ask it: "Signore, Teamwork chiede di accettare i termini: posso procedere?"
        let fromAgent = q.taskId != nil ? "\(q.from) chiede: " : ""
        broadcast?(ServerMessage(type: .event, id: q.id, text: "\(addressAs), \(fromAgent)\(q.question)", kind: "question",
                                 payload: q.jsonString(), speak: true))
        let id = q.id
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.reply(id: id, text: nil)
        }
        return await withCheckedContinuation { questions[q.id] = $0 }
    }

    public func reply(id: String, text: String?) {
        guard let c = questions.removeValue(forKey: id) else { return }
        broadcast?(ServerMessage(type: .event, id: id, text: text ?? "", kind: "questionResolved"))
        c.resume(returning: text)
    }
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    public private(set) var pending: [String: ConfirmRequest] = [:]

    public init() {}

    public func setBroadcast(_ b: @escaping @Sendable (ServerMessage) -> Void) { broadcast = b }

    private var addressAs = "Signore"
    public func setAddressAs(_ s: String) { addressAs = s }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        // Keep proper names/acronyms ("Teamwork", "PR") capitalised.
        let firstWord = s.split(separator: " ").first.map(String.init) ?? ""
        let verbs = ["Invio", "Scrivo", "Modifico", "Attivo", "Il", "Un", "L'", "La", "Lo"]
        return verbs.contains(where: { firstWord.hasPrefix($0) }) ? f.lowercased() + s.dropFirst() : s
    }

    public func request(_ req: ConfirmRequest, timeout: TimeInterval = 300) async -> Bool {
        pending[req.id] = req
        let spoken = req.risk == .dangerous
            ? "\(addressAs), \(Self.lowerFirst(req.title)). È un'azione delicata: posso procedere?"
            : "\(addressAs), \(Self.lowerFirst(req.title)): posso procedere?"
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

/// Permission prompt tool for background agents (`--permission-prompt-tool mcp__elio__approve`).
public enum ApprovalTool {
    static let approve = ElioTool(
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

    private var repeatReminders = true
    public func setRepeatReminders(_ on: Bool) { repeatReminders = on }

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
            let (attempt, root) = await memory.reminderAttempt(r.id)
            let text = attempt == 0 ? "Promemoria: \(r.text)." : "Le ricordo di nuovo: \(r.text)."
            LocalActions().notify(title: "Promemoria", body: r.text)
            broadcast?(ServerMessage(type: .event, id: "\(root)", text: text, lang: .it, kind: "reminder", speak: true))
            // Until the user says "fatto", repeat after 10 minutes (twice at most).
            if repeatReminders, attempt < 2 {
                await memory.addReminder(text: r.text, at: Date().addingTimeInterval(600), attempt: attempt + 1, parent: root)
            }
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

    private let config: ElioConfig
    private let mcpConfig: String
    private var tasks: [String: Running] = [:]
    private var finished: [TaskInfo] = []
    private var broadcast: (@Sendable (ServerMessage) -> Void)?

    private let memory: Memory?

    public init(config: ElioConfig, mcpConfig: String, memory: Memory? = nil) {
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
            "--permission-prompt-tool", "mcp__elio__approve",
            "--allowedTools", "Read", "Grep", "Glob", "TodoWrite",
        ] + (config.browserAutonomy ? ["--chrome"] : []) + [
            "--disallowedTools", "mcp__elio__start_task",
        ]
        var env = ProcessInfo.processInfo.environment
        env["ELIO_TASK_ID"] = id
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

    /// pause → SIGSTOP (the agent freezes where it is), resume → SIGCONT, stop → terminate.
    public func control(_ id: String, action: String) {
        guard let t = tasks[id] else { return }
        let pid = t.process.processIdentifier
        switch action {
        case "pause" where t.info.status == .running || t.info.status == .waitingConfirmation:
            kill(pid, SIGSTOP)
            tasks[id]?.info.status = .paused
        case "resume" where t.info.status == .paused:
            kill(pid, SIGCONT)
            tasks[id]?.info.status = .running
        case "stop":
            if t.info.status == .paused { kill(pid, SIGCONT) }
            _ = cancel(id)
        default:
            return
        }
        publish(id)
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
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { logEntry(TaskLogEntry(taskId: id, kind: .say, title: String(text.prefix(1200)))) }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    addStep(id, Self.step(name, input))
                    logEntry(Self.logEntry(taskId: id, name: name, input: input))
                default:
                    break
                }
            }
        case "user":
            // Tool results: show a short tail of command output.
            let content = ((ev["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content where block["type"] as? String == "tool_result" {
                var text = ""
                if let s = block["content"] as? String { text = s }
                if let parts = block["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, lastLogKind[id] == .command else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                let tail = lines.suffix(14).joined(separator: "\n")
                logEntry(TaskLogEntry(taskId: id, kind: .output, title: "", body: String(tail.prefix(1500))))
            }
        case "result":
            let text = ev["result"] as? String ?? ""
            tasks[id]?.info.summary = text
            if ev["is_error"] as? Bool == true { tasks[id]?.info.status = .failed }
        default:
            break
        }
    }

    private var lastLogKind: [String: TaskLogEntry.Kind] = [:]

    private func logEntry(_ entry: TaskLogEntry) {
        lastLogKind[entry.taskId] = entry.kind
        if let memory { Task { await memory.addTaskLog(entry) } }
        let entry = entry.redacted
        broadcast?(ServerMessage(type: .event, id: entry.taskId, kind: "taskLog", payload: entry.jsonString()))
    }

    static func logEntry(taskId: String, name: String, input: [String: Any]) -> TaskLogEntry {
        let file = (input["file_path"] as? String).map { $0.split(separator: "/").suffix(3).joined(separator: "/") } ?? ""
        switch name {
        case "Bash":
            return TaskLogEntry(taskId: taskId, kind: .command, title: input["command"] as? String ?? "",
                                body: input["description"] as? String ?? "")
        case "Edit":
            return TaskLogEntry(taskId: taskId, kind: .edit, title: file,
                                removed: String((input["old_string"] as? String ?? "").prefix(1500)),
                                added: String((input["new_string"] as? String ?? "").prefix(1500)))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return TaskLogEntry(taskId: taskId, kind: .edit, title: "\(file) (\(edits.count) modifiche)",
                                removed: edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n…\n").prefix(1500).description,
                                added: edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n…\n").prefix(1500).description)
        case "Write":
            return TaskLogEntry(taskId: taskId, kind: .write, title: file,
                                added: String((input["content"] as? String ?? "").prefix(1500)))
        case "Read":
            return TaskLogEntry(taskId: taskId, kind: .read, title: file)
        case "Grep", "Glob":
            return TaskLogEntry(taskId: taskId, kind: .search, title: input["pattern"] as? String ?? "")
        case "mcp__elio__ask_user":
            return TaskLogEntry(taskId: taskId, kind: .ask, title: input["question"] as? String ?? "")
        default:
            return TaskLogEntry(taskId: taskId, kind: .info, title: step(name, input))
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
        default: return name.replacingOccurrences(of: "mcp__elio__", with: "")
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
        Sei un agente di Elio, l'assistente personale di Raffaele. Lavori in background nel progetto \(cwd).

        Compito: \(title)
        Dettagli: \(prompt)

        Regole:
        - Se devi modificare codice, crea prima un branch locale `elio/<slug-breve>` e committa lì. Mai su develop/main/master.
        - Non fare mai push, merge, rebase, né aprire PR: Raffaele rivede il diff nell'app e crea lui la PR.
        - Non cancellare file e non inviare messaggi a nessuno. Se ti serve davvero, chiedi (la richiesta passa da una conferma).
        - Esegui test/lint pertinenti se esistono.
        - Se ti manca un'informazione o devi scegliere tra opzioni con impatto, chiedi a Raffaele con \
        mcp__elio__ask_user invece di indovinare (una domanda chiara, con le opzioni).
        - Termina con un riassunto in italiano di massimo due frasi, adatto a essere letto a voce, poi una sezione dettagliata.
        """
    }
}

public enum AskTools {
    static let ask = ElioTool(
        name: "ask_user",
        description: """
        Fa una domanda all'utente e aspetta la risposta (a voce, nell'app o dal telefono). \
        Usalo quando ti serve una decisione o un'informazione che non puoi ricavare. Scrivi la domanda completa e cortese, \
        come la diresti a voce, spiegando la situazione e cosa farai: es. "Teamwork chiede di accettare i nuovi termini \
        e condizioni per generare la chiave: posso procedere?". Non iniziare con "Signore": lo aggiunge Elio.
        """,
        properties: ["question": prop("La domanda, breve e chiara")],
        required: ["question"]
    ) { args, ctx in
        let question = args["question"] as? String ?? ""
        guard !question.isEmpty else { throw ToolError("Domanda vuota") }
        let from = await ctx.tasks.title(for: ctx.taskId).map { "L'agente di \"\($0)\"" } ?? "L'assistente"
        let answer = await ctx.gate.ask(QuestionRequest(id: UUID().uuidString, question: question, from: from,
                                                        taskId: ctx.taskId), timeout: 1500)
        return answer.map { "Risposta dell'utente: \($0)" } ?? "Nessuna risposta entro 25 minuti: procedi con l'opzione più prudente o fermati e spiega."
    }
}

public enum TaskTools {
    static let schedule = ElioTool(
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

    static let start = ElioTool(
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

    static let list = ElioTool(
        name: "list_tasks",
        description: "Stato dei task in background (in corso e recenti)."
    ) { _, ctx in
        let all = await ctx.tasks.all()
        guard !all.isEmpty else { return "Nessun task." }
        return all.map { t in
            "- [\(t.status.rawValue)] \(t.title) (id \(t.id), \(t.project ?? "")): \(t.summary.map { String($0.prefix(200)) } ?? t.steps.last ?? "")"
        }.joined(separator: "\n")
    }

    static let control = ElioTool(
        name: "control_task",
        description: "Mette in pausa, riprende o ferma un task in background (action: pause, resume, stop).",
        properties: ["id": prop("Id del task"), "action": prop("pause, resume o stop")],
        required: ["id", "action"]
    ) { args, ctx in
        await ctx.tasks.control(args["id"] as? String ?? "", action: args["action"] as? String ?? "")
        return "Fatto."
    }

    static let cancel = ElioTool(
        name: "cancel_task",
        description: "Ferma un task in background.",
        properties: ["id": prop("Id del task")],
        required: ["id"]
    ) { args, ctx in
        await ctx.tasks.cancel(args["id"] as? String ?? "") ? "Task fermato." : "Task non trovato."
    }
}
