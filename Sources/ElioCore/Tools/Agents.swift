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

    /// What the user said (from any device: phone, typed, Mac) answers what Elio is waiting for: the oldest
    /// confirmation first, then a pending question. Returns what to say back, or nil if it wasn't an answer.
    /// `overheard`: it came from an always-on mic (anyone in the room could have said it), so it can't approve a
    /// dangerous action — that takes a tap on Conferma, or the owner's verified voice on the Mac.
    public func answerFromSpeech(_ text: String, overheard: Bool = false) -> String? {
        if let req = pending.values.first {
            switch ConfirmationAnswer.parse(text, risk: req.risk) {
            case .approve where overheard && req.risk == .dangerous:
                return "È un'azione delicata, \(addressAs): la confermi col pulsante Conferma, sul telefono o sul Mac."
            case .approve:
                answer(id: req.id, approved: true)
                return "Grazie, \(addressAs), procedo."
            case .deny:
                answer(id: req.id, approved: false)
                return "Va bene, \(addressAs), mi fermo."
            case .needsExplicit:
                return "È un'azione delicata, \(addressAs): mi serve un \"confermo\" esplicito."
            case .unrelated:
                break
            }
        }
        if let id = questions.keys.first {
            reply(id: id, text: text)
            return "Grazie, \(addressAs), ne tengo conto."
        }
        return nil
    }

    public func reply(id: String, text: String?) {
        guard let c = questions.removeValue(forKey: id) else { return }
        broadcast?(ServerMessage(type: .event, id: id, text: text ?? "", kind: "questionResolved"))
        c.resume(returning: text)
    }
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    public private(set) var pending: [String: ConfirmRequest] = [:]

    public init() {}

    /// A confirmation or question is waiting: the user's next words are probably the answer.
    public var awaitingAnswer: Bool { !pending.isEmpty || !questions.isEmpty }

    public func setBroadcast(_ b: @escaping @Sendable (ServerMessage) -> Void) { broadcast = b }

    private var addressAs = "Signore"
    public func setAddressAs(_ s: String) { addressAs = s }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        // Keep proper names/acronyms ("Teamwork", "PR") capitalised.
        let firstWord = s.split(separator: " ").first.map(String.init) ?? ""
        let verbs = ["Invio", "Scrivo", "Modifico", "Attivo", "Vorrei", "Il", "Un", "L'", "La", "Lo"]
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
        // Agents work in their project; the conversation's free zone is the work folder.
        let cwd = await ctx.tasks.cwd(for: ctx.taskId) ?? ElioPaths.outputDir.path
        // The conversation itself and "mac" agents act on the whole Mac for the user.
        let kind = await ctx.tasks.kind(for: ctx.taskId)
        let decision = PermissionPolicy.decide(tool: tool, input: input, cwd: cwd,
                                               onMac: ctx.taskId == nil || kind == "mac")

        let allow: Bool
        switch decision {
        case .allow:
            allow = true
        case .confirm(.normal) where ApprovalMemory.shared.covers(task: ctx.taskId, tool: tool, input: input):
            // The user already said yes to this kind of action for this agent (dangerous ones always ask again).
            allow = true
            await ctx.tasks.logEvent(taskId: ctx.taskId, .autoDecision,
                                     text: "Già approvato per questo agente: \(summary(tool: tool, input: input))", actor: "elio")
        case .confirm(let risk):
            let detail = describe(tool: tool, input: input)
            // Spoken: what it amounts to ("cancellare la cartella build"), never the raw command;
            // the full command is in `detail` (card, and read aloud if the user asks).
            let what = summary(tool: tool, input: input)
            let title = await ctx.tasks.title(for: ctx.taskId).map { "L'agente di \"\($0)\" vorrebbe \(what)" }
                ?? "Vorrei \(what)"
            await ctx.tasks.setStatus(ctx.taskId, .waitingConfirmation)
            await ctx.tasks.logEvent(taskId: ctx.taskId, .confirm, text: title, data: ["detail": String(detail.prefix(500)), "risk": risk.rawValue])
            allow = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: title, detail: detail,
                                                          risk: risk, taskId: ctx.taskId))
            await ctx.tasks.logEvent(taskId: ctx.taskId, .confirmResult, text: allow ? "Confermato" : "Negato", actor: "utente")
            if allow, risk == .normal { ApprovalMemory.shared.remember(task: ctx.taskId, tool: tool, input: input) }
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

    /// Plain-language gist of an action, for the spoken confirmation.
    static func summary(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", input["dangerouslyDisableSandbox"] as? Bool == true {
            return summary(tool: tool, input: input.filter { $0.key != "dangerouslyDisableSandbox" }) + ", fuori dalla protezione (rete e file liberi)"
        }
        switch tool {
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            // Claude's own description of the command, when it's in Italian.
            if let d = (input["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty,
               d.count < 120, !looksEnglish(d) {
                return lowerFirstWord(d)
            }
            return bashGist(cmd)
        case "Edit", "MultiEdit": return "modificare \(fileName(input["file_path"]))"
        case "Write": return "scrivere \(fileName(input["file_path"]))"
        default:
            let name = tool.components(separatedBy: "__").last ?? tool
            return "usare \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    static func bashGist(_ cmd: String) -> String {
        let c = cmd.lowercased()
        func has(_ p: String) -> Bool { c.range(of: p, options: .regularExpression) != nil }
        if has(#"\bgit\s+push\b"#) { return "fare il push su git" }
        if has(#"\bgit\s+(merge|rebase)\b"#) { return "fare un merge o un rebase" }
        if has(#"\bgit\s+(reset\s+--hard|clean|checkout\s+(--|\.)|restore)"#) { return "scartare delle modifiche su git" }
        if has(#"\b(rm|rmdir|unlink|shred)\s|\s-delete\b|xargs\s+rm"#) { return "cancellare dei file" }
        if has(#"\bsudo\b"#) { return "eseguire un comando come amministratore" }
        if has(#"\b(kill|killall|pkill)\b"#) { return "terminare dei processi" }
        if has(#"\b(curl|wget)\b.*(-d\b|--data|-f\b|-t\b|-x\s*(post|put|delete|patch))"#) { return "inviare dati a un server" }
        if has(#"\b(curl|wget|ssh|scp|rsync|sftp)\b"#) { return "collegarsi a un server esterno" }
        if has(#"\b(gh|bb)\s+pr\b"#) { return "aprire o unire una pull request" }
        if has(#"\b(drop|truncate)\s+(table|database)|delete\s+from|migrate:(fresh|reset|rollback)"#) { return "cancellare dati dal database" }
        if has(#"launchagents|crontab|\.zshrc|\.bash|\.profile"#) { return "cambiare i programmi o le impostazioni di avvio del Mac" }
        if has(#"\b(python[0-9.]*|node|perl|ruby|php)\s+-[a-z]*[ce]\b|\b(sh|bash|zsh)\s+-c\b|\beval\b"#) { return "eseguire uno script al volo" }
        if has(#"\b(mv|cp)\s"#) { return "spostare o copiare file sovrascrivendo quelli esistenti" }
        if has(#"\btee\b|>"#) { return "sovrascrivere un file" }
        if has(#"\bchmod\s+-r|\bchown\b"#) { return "cambiare i permessi di molti file" }
        if has(#"\bosascript\b"#) { return "controllare un'altra app con AppleScript" }
        let first = cmd.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? "un comando"
        return "eseguire il comando \(first)"
    }

    static func looksEnglish(_ s: String) -> Bool {
        let words = Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["the", "and", "to", "from", "of", "in", "check", "run", "list", "show", "get",
                                        "install", "remove", "delete", "create", "update", "pull", "push", "latest", "with"])
    }

    static func lowerFirstWord(_ s: String) -> String {
        let t = s.hasSuffix(".") ? String(s.dropLast()) : s
        guard let f = t.first else { return t }
        return f.lowercased() + t.dropFirst()
    }

    static func fileName(_ any: Any?) -> String {
        let p = any as? String ?? ""
        return p.isEmpty ? "un file" : "il file \((p as NSString).lastPathComponent)"
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
        let runStart = Date()
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
        // Agents orphaned by a previous daemon (crash, update) can no longer report or ask: stop them.
        _ = try? shell("/usr/bin/pkill", ["-P", "1", "-f", "claude -p Sei .*(un agente di Elio|squadra coordinata da Elio)"])
    }

    public func setBroadcast(_ b: @escaping @Sendable (ServerMessage) -> Void) { broadcast = b }

    public func cwd(for id: String?) -> String? { id.flatMap { tasks[$0]?.cwd } }
    public func title(for id: String?) -> String? { id.flatMap { tasks[$0]?.info.title } }
    public func kind(for id: String?) -> String? { id.flatMap { tasks[$0]?.info.kind } }

    public func all() -> [TaskInfo] {
        tasks.values.map(\.info).sorted { $0.startedAt < $1.startedAt } + finished.suffix(10)
    }

    public func setStatus(_ id: String?, _ status: TaskInfo.Status) {
        guard let id, tasks[id] != nil else { return }
        tasks[id]?.info.status = status
        publish(id)
    }

    public enum Kind: String, Sendable { case code, mac, squad, lead, scout }

    /// The user's taste rules, handed to every agent (kept here: prompts are built synchronously).
    private var tasteRules: [TasteRule] = []
    public func setTaste(_ rules: [TasteRule]) { tasteRules = rules }

    public func start(title: String, prompt: String, cwd: String, kind: Kind = .code,
                      squad: String? = nil, member: String? = nil, role: String? = nil,
                      resume sessionId: String? = nil, difficulty: String? = nil) throws -> TaskInfo {
        // Opus unless the job is trivial for both Elio and the router; a resumed agent keeps its model.
        let previous = sessionId.flatMap { sid in finished.last(where: { $0.sessionId == sid })?.model }
        let base = [.squad, .lead, .scout].contains(kind) ? config.squadModel : config.agentModel
        let route = [.lead, .scout].contains(kind)
            ? ModelRouter.Choice(model: base, light: false, reason: "coordina o esplora")
            : ModelRouter.pick(title: title, prompt: prompt, difficulty: difficulty, base: base, light: config.lightModel,
                               enabled: config.smartModelRouting)
        let model = previous ?? route.model
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudePath)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let fullPrompt: String
        let taste = Taste.promptBlock(tasteRules)
        if sessionId != nil {
            fullPrompt = prompt
        } else {
            switch kind {
            case .code: fullPrompt = Self.agentPrompt(title: title, prompt: prompt, cwd: cwd) + "\n\n" + taste
            case .mac: fullPrompt = Self.macPrompt(title: title, prompt: prompt)
            case .squad: fullPrompt = Self.memberPrompt(goal: squads[squad ?? ""]?.goal ?? title, name: member ?? "agente",
                                                         role: role ?? "", task: prompt, cwd: cwd,
                                                         team: members(of: squad ?? "").filter { $0.member != member && $0.kind != Kind.lead.rawValue && $0.kind != Kind.scout.rawValue },
                                                         hasLead: squads[squad ?? ""]?.hasLead == true,
                                                         brief: squads[squad ?? ""]?.brief) + "\n\n" + taste
            case .scout: fullPrompt = prompt
            case .lead: fullPrompt = Self.leadPrompt(squad: squads[squad ?? ""], user: config.displayName,
                                                      team: members(of: squad ?? "").filter { $0.kind != Kind.lead.rawValue },
                                                      maxAgents: config.maxSquadAgents, taste: taste)
            }
        }
        // Background agents never start other agents or squads (only Elio coordinates). The lead is
        // Elio's own proxy: it may direct and grow its squad, but it coordinates and reviews, it doesn't write code.
        var forbidden = ["mcp__elio__start_task", "mcp__elio__mac_task", "mcp__elio__squad_start", "mcp__elio__schedule_task"]
        var allowed = ["Read", "Grep", "Glob", "TodoWrite", "WebSearch", "WebFetch",
                       "mcp__elio__report_progress", "mcp__elio__squad_post", "mcp__elio__squad_inbox", "mcp__elio__taste_rules"]
        if kind == .lead || kind == .scout {
            forbidden += ["Edit", "Write", "MultiEdit", "NotebookEdit"]
        }
        if kind == .lead {
            allowed += ["mcp__elio__squad_send", "mcp__elio__squad_status", "mcp__elio__squad_add"]
        } else {
            forbidden += ["mcp__elio__squad_send", "mcp__elio__squad_add", "mcp__elio__squad_stop"]
        }
        p.arguments = ["-p", fullPrompt] + (sessionId.map { ["--resume", $0] } ?? []) + [
            "--output-format", "stream-json", "--verbose",
            // Squads multiply the cost: their agents run on the (cheaper) squad model.
            "--model", model,
            "--setting-sources", "project,local",
            // OS-level sandbox for Bash: the real boundary under PermissionPolicy's patterns.
            "--settings", AgentSandbox.settings(kind: kind.rawValue),
            "--strict-mcp-config", "--mcp-config", mcpConfig,
            "--permission-prompt-tool", "mcp__elio__approve",
            "--allowedTools"] + allowed
          + (kind == .mac ? ["--add-dir", FileManager.default.homeDirectoryForCurrentUser.path] : [])
          + (config.browserAutonomy && kind != .lead ? ["--chrome"] : []) + ["--disallowedTools"] + forbidden
        var env = config.claudeAccount.environment()
        env["ELIO_TASK_ID"] = id
        // Agents run read-only git freely (status/log/diff): a repo's config must not turn those into program runs
        // (fsmonitor, signature checks via gpg.program, pagers/editors). Hooks stay: commits behave as the dev expects.
        let gitOverrides = ["core.fsmonitor": "false", "log.showSignature": "false", "core.pager": "cat",
                            "core.editor": "true", "sequence.editor": "true"]
        env["GIT_CONFIG_COUNT"] = "\(gitOverrides.count)"
        for (i, kv) in gitOverrides.sorted(by: { $0.key < $1.key }).enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = kv.key
            env["GIT_CONFIG_VALUE_\(i)"] = kv.value
        }
        env["GIT_PAGER"] = "cat"
        // Sandboxed agents get their own package caches (see AgentSandbox.agentCache).
        for (k, v) in AgentSandbox.cacheEnvironment { env[k] = v }
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { await self?.exited(id, code: code) }
        }
        // Hooks/config of the repo, to check (and undo) when the agent ends: they'd run outside the sandbox later.
        GitGuards.shared.begin(agent: id, cwd: cwd)
        try p.run()

        var info = TaskInfo(id: id, title: title, project: (cwd as NSString).lastPathComponent, status: .running)
        info.kind = kind.rawValue
        info.squad = squad
        info.member = member
        info.role = role
        info.workflow = squad ?? id
        info.runIds = [id]
        info.model = model
        info.cwd = cwd
        info.task = kind == .scout ? "Mappare il codice per la squadra" : String(prompt.prefix(4000))
        let resumed = sessionId.flatMap { sid in finished.last(where: { $0.sessionId == sid }) }
        if let old = resumed {
            // A resumed agent keeps its identity, its workflow and running totals.
            info.tokensIn = old.tokensIn; info.tokensOut = old.tokensOut; info.costUSD = old.costUSD
            info.workflow = old.workflow ?? info.workflow
            info.runIds = (old.runIds ?? [old.id]) + [id]
            info.activeSeconds = old.activeSeconds
            info.plan = old.plan
            info.task = old.task
            info.startedAt = old.startedAt
            info.sessionId = old.sessionId
            finished.removeAll { $0.sessionId == sessionId }
        }
        tasks[id] = Running(info: info, cwd: cwd, process: p)
        publish(id)
        if let wf = info.workflow {
            if squad == nil && resumed == nil {
                saveWorkflow(WorkflowRecord(id: wf, kind: "task", title: title, project: info.project))
                event(wf, .started, actor: "elio", text: title, data: ["prompt": String(prompt.prefix(2000)), "kind": kind.rawValue])
            }
            event(wf, .agentStarted, actor: Self.actor(info),
                  text: resumed == nil ? (role ?? title) : "riprende: \(prompt.prefix(400))",
                  data: ["model": model, "route": route.reason])
            if resumed == nil { log("agent \(id) \(info.member ?? title): \(model) (\(route.reason))") }
            saveAgent(info)
        }

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

    // MARK: Workflow log

    private func saveWorkflow(_ w: WorkflowRecord) {
        if let memory { Task { await memory.saveWorkflow(w) } }
    }

    private func saveAgent(_ info: TaskInfo) {
        guard let memory, let wf = info.workflow else { return }
        // One row per agent across its runs.
        Task { await memory.saveWorkflowAgent(wf, key: info.member ?? "main", info) }
    }

    private func event(_ wf: String, _ kind: WorkflowEvent.Kind, actor: String, text: String, data: [String: Any]? = nil) {
        let json = data.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
        let e = WorkflowEvent(workflow: wf, kind: kind, actor: actor, text: text, data: json)
        if let memory { Task { await memory.addWorkflowEvent(e) } }
        broadcast?(ServerMessage(type: .event, id: wf, text: text, kind: "workflowEvent", payload: e.jsonString()))
    }

    /// For tools acting on behalf of an agent (questions, confirmations, decisions).
    public func logEvent(taskId: String?, _ kind: WorkflowEvent.Kind, text: String, data: [String: Any]? = nil, actor: String? = nil) {
        guard let taskId, let info = tasks[taskId]?.info ?? finished.last(where: { $0.id == taskId }), let wf = info.workflow else { return }
        var data = data ?? [:]
        if data["agent"] == nil { data["agent"] = Self.actor(info) }
        event(wf, kind, actor: actor ?? Self.actor(info), text: text, data: data)
    }

    public func workflowGoal(taskId: String?) -> String {
        guard let taskId, let info = tasks[taskId]?.info else { return "" }
        return info.squad.flatMap { squads[$0]?.goal } ?? info.title
    }

    /// Live and recently finished agents of a workflow.
    public func agents(ofWorkflow wf: String) -> [TaskInfo] {
        var byAgent: [String: TaskInfo] = [:]
        for t in finished + tasks.values.map(\.info) where t.workflow == wf {
            byAgent[t.member ?? "main"] = t
        }
        return byAgent.values.sorted { $0.startedAt < $1.startedAt }
    }

    static func actor(_ info: TaskInfo) -> String {
        info.kind == Kind.lead.rawValue ? "elio" : (info.member ?? "agente")
    }

    private func handle(_ id: String, _ line: String) {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch ev["type"] as? String {
        case "system":
            if let sid = ev["session_id"] as? String { tasks[id]?.info.sessionId = sid }
        case "assistant":
            if let message = ev["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
               let mid = message["id"] as? String {
                var calls = usageByCall[id] ?? [:]
                calls[mid] = Self.tokens(usage)
                usageByCall[id] = calls
                let base = baseUsage[id] ?? (tasks[id]?.info.tokensIn ?? 0, tasks[id]?.info.tokensOut ?? 0)
                baseUsage[id] = base
                let tokIn = base.0 + calls.values.reduce(0) { $0 + $1.0 }
                let tokOut = base.1 + calls.values.reduce(0) { $0 + $1.1 }
                tasks[id]?.info.tokensIn = tokIn
                tasks[id]?.info.tokensOut = tokOut
            }
            let content = ((ev["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        tasks[id]?.info.lastMessage = String(text.prefix(300))
                        logEntry(TaskLogEntry(taskId: id, kind: .say, title: String(text.prefix(1200))))
                        publish(id)
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if name == "TodoWrite" { updatePlan(id, input) }
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
            // Read first, then write: `tasks[id]?.x = tasks[id]?.x + …` is an exclusivity violation (crash).
            if let cost = ev["total_cost_usd"] as? Double {
                let previous = tasks[id]?.info.costUSD ?? 0
                tasks[id]?.info.costUSD = previous + cost
            }
            if let sid = ev["session_id"] as? String { tasks[id]?.info.sessionId = sid }
        default:
            break
        }
    }

    private var lastLogKind: [String: TaskLogEntry.Kind] = [:]
    private var usageByCall: [String: [String: (Int, Int)]] = [:]
    private var baseUsage: [String: (Int, Int)] = [:]

    /// (input incl. cache, output) tokens of one API call.
    static func tokens(_ u: [String: Any]) -> (Int, Int) {
        let i = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
            + (u["cache_creation_input_tokens"] as? Int ?? 0)
        return (i, u["output_tokens"] as? Int ?? 0)
    }

    public func agentsCost() -> Double {
        (tasks.values.map(\.info) + finished).compactMap(\.costUSD).reduce(0, +)
    }

    // MARK: Squads

    private var squads: [String: SquadInfo] = [:]
    private var board: [SquadMessage] = []
    private var cursors: [String: Int] = [:]   // "squad/member" → last message id read

    public func createSquad(goal: String, project: String, lead: Bool = false) -> SquadInfo {
        var s = SquadInfo(id: String(UUID().uuidString.prefix(6)).lowercased(), goal: goal, project: project)
        s.hasLead = lead
        squads[s.id] = s
        broadcast?(ServerMessage(type: .event, text: goal, kind: "squad", payload: s.jsonString()))
        saveWorkflow(WorkflowRecord(id: s.id, kind: "squad", title: goal, project: (project as NSString).lastPathComponent))
        event(s.id, .started, actor: "elio", text: goal, data: ["project": project, "lead": lead])
        return s
    }

    /// Members waiting for the scout's brief, per squad.
    public struct QueuedMember: Sendable {
        public let name: String; public let role: String; public let task: String; public let difficulty: String?
        public init(name: String, role: String, task: String, difficulty: String? = nil) {
            self.name = name; self.role = role; self.task = task; self.difficulty = difficulty
        }
    }
    private var waitingForScout: [String: (members: [QueuedMember], lead: Bool)] = [:]

    public func queueAfterScout(squad: String, members: [QueuedMember], lead: Bool) {
        waitingForScout[squad] = (members, lead)
    }

    /// The scout is done: everyone starts from its brief.
    private func launchQueued(_ squad: String, brief: String?) {
        guard let queued = waitingForScout.removeValue(forKey: squad), let s = squads[squad], s.endedAt == nil else { return }
        squads[squad]?.brief = brief
        broadcast?(ServerMessage(type: .event, text: s.goal, kind: "squad", payload: squads[squad]?.jsonString()))
        if let brief, let memory {
            let wf = squad
            Task { await memory.addWorkflowEvent(WorkflowEvent(workflow: wf, kind: .message, actor: "scout", text: brief, data: "{\"brief\":true}")) }
        }
        var started: [String] = []
        for m in queued.members {
            do {
                _ = try start(title: "\(m.name): \(m.role)", prompt: m.task, cwd: s.project, kind: .squad, squad: squad,
                              member: m.name, role: m.role, difficulty: m.difficulty)
                started.append(m.name)
            } catch {
                log("squad member \(m.name) failed to start: \(error)")
            }
        }
        post(squad: squad, from: "elio", to: "tutti",
             text: "Lo scout ha mappato il codice (brief nel vostro prompt). Al lavoro: \(started.joined(separator: ", ")).")
        if queued.lead {
            _ = try? start(title: "elio: coordinatore", prompt: s.goal, cwd: s.project, kind: .lead, squad: squad, member: "elio",
                           role: "coordinatore (fa le veci \(config.ofUser))")
        }
    }

    /// Members working now (the lead excluded).
    public func runningMembers(of squad: String) -> Int {
        tasks.values.filter { $0.info.squad == squad && $0.info.kind != Kind.lead.rawValue }.count
    }

    public func squad(_ id: String) -> SquadInfo? { squads[id] }
    public func allSquads() -> [SquadInfo] { squads.values.sorted { $0.startedAt < $1.startedAt } }

    public func members(of squad: String) -> [TaskInfo] {
        (tasks.values.map(\.info) + finished).filter { $0.squad == squad }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Squad and member name of a running agent (for squad_post / squad_inbox).
    public func identity(of taskId: String?) -> (squad: String, member: String)? {
        guard let taskId, let info = tasks[taskId]?.info, let s = info.squad, let m = info.member else { return nil }
        return (s, m)
    }

    @discardableResult
    public func post(squad: String, from: String, to: String, text: String) -> SquadMessage {
        let m = SquadMessage(id: (board.last?.id ?? 0) + 1, squad: squad, from: from, to: to, text: text)
        board.append(m)
        if board.count > 2000 { board.removeFirst(board.count - 2000) }
        broadcast?(ServerMessage(type: .event, text: text, kind: "squadMessage", payload: m.jsonString()))
        event(squad, .message, actor: from, text: text, data: ["to": to])
        // Whatever reaches Elio wakes the lead, who answers in the user's place.
        // ("tutti" doesn't wake it: each wake re-reads its whole context, it reads the board when it works anyway.)
        if from != "elio", to == "elio" { wakeLead(squad) }
        return m
    }

    /// Unread messages for a member (addressed to it or to everyone).
    public func inbox(squad: String, member: String) -> [SquadMessage] {
        let key = "\(squad)/\(member)"
        let seen = cursors[key] ?? 0
        let new = board.filter { $0.squad == squad && $0.id > seen && $0.from != member && ($0.to == member || $0.to == "tutti") }
        cursors[key] = board.last?.id ?? seen
        return new
    }

    public func messages(squad: String) -> [SquadMessage] { board.filter { $0.squad == squad } }

    public func stopSquad(_ id: String) {
        squads[id]?.endedAt = Date()
        for t in tasks.values where t.info.squad == id { _ = cancel(t.info.id) }
        saveWorkflow(WorkflowRecord(id: id, kind: "squad", title: squads[id]?.goal ?? "", project: nil,
                                    startedAt: squads[id]?.startedAt ?? Date(), endedAt: Date(), status: "cancelled"))
        event(id, .finished, actor: "utente", text: "Squadra fermata.")
    }

    // MARK: Lead (Elio's proxy inside a squad)

    private var wakes: [String: Int] = [:]
    static let maxWakes = 30

    private func leadRunning(_ squad: String) -> Bool {
        tasks.values.contains { $0.info.squad == squad && $0.info.kind == Kind.lead.rawValue }
    }

    /// Resumes the lead with what it hasn't read yet. A running lead reads its inbox by itself.
    private func wakeLead(_ squad: String) {
        guard squads[squad]?.hasLead == true, squads[squad]?.endedAt == nil, !leadRunning(squad),
              wakes[squad, default: 0] < Self.maxWakes else { return }
        let unread = inbox(squad: squad, member: "elio")
        guard !unread.isEmpty else { return }
        let team = members(of: squad).filter { $0.kind != Kind.lead.rawValue }
            .map { "- \($0.member ?? "?"): \($0.status.rawValue)" }.joined(separator: "\n")
        let text = """
            Nuovi messaggi sulla bacheca:
            \(unread.map { "\($0.from) → \($0.to): \($0.text)" }.joined(separator: "\n"))

            Stato della squadra:
            \(team)
            """
        do {
            if try resume(squad: squad, member: "elio", message: text) {
                wakes[squad, default: 0] += 1
                event(squad, .leadWake, actor: "elio", text: "Elio rivede \(unread.count) messaggi", data: ["count": unread.count])
            }
        } catch {
            log("lead wake failed: \(error)")
        }
    }

    /// Wakes a finished member with a new message (same Claude session, same memory).
    public func resume(squad: String, member: String, message: String) throws -> Bool {
        if tasks.values.contains(where: { $0.info.squad == squad && $0.info.member == member }) { return false }
        guard let old = finished.last(where: { $0.squad == squad && $0.member == member }), let sid = old.sessionId,
              let cwd = squads[squad]?.project else { return false }
        _ = try start(title: old.title, prompt: message, cwd: cwd, kind: Kind(rawValue: old.kind ?? "") ?? .squad,
                      squad: squad, member: member, role: old.role, resume: sid)
        return true
    }

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

    /// The agent rewrote its plan: keep when each step got done, log newly completed ones.
    private func updatePlan(_ id: String, _ input: [String: Any]) {
        guard let todos = input["todos"] as? [[String: Any]], tasks[id] != nil else { return }
        let old = tasks[id]?.info.plan ?? []
        var plan: [PlanStep] = []
        for t in todos {
            let text = (t["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let status = t["status"] as? String ?? "pending"
            var step = PlanStep(status: status, text: text, active: t["activeForm"] as? String)
            if status == "completed" {
                step.doneAt = old.first { $0.text == text && $0.status == "completed" }?.doneAt ?? Date()
                if step.doneAt.map({ Date().timeIntervalSince($0) < 1 }) == true, let info = tasks[id]?.info, let wf = info.workflow {
                    event(wf, .progress, actor: Self.actor(info), text: "✓ \(text)", data: ["plan": true])
                }
            }
            plan.append(step)
        }
        tasks[id]?.info.plan = plan
        publish(id)
    }

    private func addStep(_ id: String, _ step: String) {
        guard tasks[id] != nil else { return }
        tasks[id]?.info.steps.append(step)
        if tasks[id]!.info.steps.count > 40 { tasks[id]?.info.steps.removeFirst() }
        publish(id)
    }

    // MARK: Messages from the user (the agent's terminal in the IDE)

    /// Text the user typed to a running agent: it's stopped where it is and resumed with the message.
    private var interjections: [String: String] = [:]

    /// The user writes to an agent. Running: interrupted and resumed with the message (claude -p has no
    /// input while it works). Finished: woken up with it. Same session, same memory.
    public func message(agent id: String, text: String) throws -> String {
        let note = "Messaggio \(config.ofUser) (scritto nel tuo terminale): \(text)\nTienine conto e continua il lavoro."
        if let running = tasks[id] {
            interjections[id] = note
            if running.info.status == .paused { kill(running.process.processIdentifier, SIGCONT) }
            running.process.interrupt()
            if let wf = running.info.workflow {
                event(wf, .message, actor: "utente", text: text, data: ["to": Self.actor(running.info)])
            }
            return "Interrompo l'agente e gli passo il messaggio."
        }
        guard let old = finished.last(where: { $0.id == id || $0.runIds?.contains(id) == true }), let sid = old.sessionId,
              let cwd = old.cwd else { return "Agente non trovato o senza sessione da riprendere." }
        _ = try start(title: old.title, prompt: note, cwd: cwd, kind: Kind(rawValue: old.kind ?? "") ?? .code,
                      squad: old.squad, member: old.member, role: old.role, resume: sid)
        return "Ho risvegliato l'agente con il messaggio."
    }

    private func exited(_ id: String, code: Int32) {
        ApprovalMemory.shared.forget(task: id)
        let title = tasks[id]?.info.title ?? "un agente"
        Task {
            guard let undone = GitGuards.shared.end(agent: id) else { return }
            log("git guard (\(id)): \(undone)")
            await Alerts.shared.send("L'agente di \"\(title)\" ha toccato la configurazione git del progetto: \(undone). Dai un'occhiata prima del prossimo commit.",
                                     title: "Configurazione git ripristinata", urgency: .notify, source: "agent:\(id)")
        }
        if let note = interjections.removeValue(forKey: id), var t = tasks.removeValue(forKey: id) {
            // Stopped on purpose to hear the user: straight back to work, with the message.
            t.info.endedAt = Date()
            t.info.activeSeconds = (t.info.activeSeconds ?? 0) + Date().timeIntervalSince(t.runStart)
            finished.append(t.info)
            if let sid = t.info.sessionId {
                do {
                    _ = try start(title: t.info.title, prompt: note, cwd: t.cwd, kind: Kind(rawValue: t.info.kind ?? "") ?? .code,
                                  squad: t.info.squad, member: t.info.member, role: t.info.role, resume: sid)
                    return
                } catch {
                    log("resume after interjection failed: \(error)")
                }
            }
            tasks[id] = t
        }
        guard var t = tasks.removeValue(forKey: id) else { return }
        if t.info.status == .running || t.info.status == .waitingConfirmation {
            t.info.status = code == 0 ? .done : .failed
        }
        t.info.endedAt = Date()
        t.info.activeSeconds = (t.info.activeSeconds ?? 0) + Date().timeIntervalSince(t.runStart)
        finished.append(t.info)
        if finished.count > 80 { finished.removeFirst() }
        broadcastTask(t.info)
        let record = t.info
        if let memory { Task { await memory.recordTask(record) } }
        saveAgent(t.info)
        if let wf = t.info.workflow {
            event(wf, t.info.status == .done ? .agentDone : .agentFailed, actor: Self.actor(t.info),
                  text: Self.spokenSummary(t.info.summary),
                  data: ["status": t.info.status.rawValue, "summary": String((t.info.summary ?? "").prefix(3000)),
                         "costUSD": t.info.costUSD ?? 0])
        }

        // Before anyone hears "done", the work is checked against the user's taste.
        if needsReview(t.info) {
            reviewing[t.info.id] = t.info.squad ?? ""
            let info = t.info, cwd = t.cwd
            Task { await self.review(info, cwd: cwd) }
            return
        }
        afterExit(t.info, cwd: t.cwd)
    }

    // MARK: Taste review

    private var reviewing: [String: String] = [:]      // task id → squad ("" for single tasks)
    private var reviewRounds: [String: Int] = [:]      // agent session → corrections asked
    static let maxReviewRounds = 2

    private func needsReview(_ info: TaskInfo) -> Bool {
        guard config.tasteReview, memory != nil, !tasteRules.isEmpty, info.status == .done,
              info.kind == Kind.code.rawValue || info.kind == Kind.squad.rawValue else { return false }
        if let squad = info.squad, squads[squad]?.endedAt != nil { return false }
        return true
    }

    private func review(_ info: TaskInfo, cwd: String) async {
        // Only what this run wrote: earlier runs were reviewed already.
        let edits = (await memory?.taskLogEntries(info.id) ?? []).filter { $0.kind == .edit || $0.kind == .write }
        let goal = info.squad.flatMap { squads[$0]?.goal } ?? info.title
        let result = edits.isEmpty ? nil
            : await TasteReviewer.review(agent: info.member ?? info.title, goal: goal, edits: edits, rules: tasteRules, config: config)
        reviewing[info.id] = nil
        let wf = info.workflow ?? info.id
        guard let result else { return afterExit(info, cwd: cwd) }
        let key = info.sessionId ?? info.id
        let toFix = result.violations.filter { $0.severity != "note" }
        if let memory { let ids = result.violations.map(\.rule); Task { await memory.bumpTasteHits(ids) } }
        for v in result.violations {
            event(wf, .tasteViolation, actor: "revisore", text: v.problem,
                  data: ["rule": v.rule, "file": v.file, "fix": v.fix, "severity": v.severity, "agent": Self.actor(info)])
        }
        if result.violations.isEmpty {
            event(wf, .tasteOk, actor: "revisore", text: result.verdict, data: ["agent": Self.actor(info), "costUSD": result.costUSD])
        }
        let rounds = reviewRounds[key, default: 0]
        guard !toFix.isEmpty, rounds < Self.maxReviewRounds, let sid = info.sessionId,
              info.squad.map({ squads[$0]?.endedAt == nil }) ?? true else { return afterExit(info, cwd: cwd) }
        reviewRounds[key] = rounds + 1
        let message = TasteReviewer.correction(toFix, rules: tasteRules, addressee: config.toUser)
        let who = info.member ?? "l'agente"
        let what = toFix.count == 1 ? "una cosa" : "\(toFix.count) cose"
        broadcast?(ServerMessage(type: .event, text: "Ho chiesto a \(who) di correggere \(what) che non le piacerebbero: \(toFix[0].problem)",
                                 lang: .it, kind: "tasteFix", payload: "{\"workflow\":\"\(wf)\"}", speak: true))
        event(wf, .tasteCorrection, actor: "elio", text: message, data: ["agent": Self.actor(info), "round": rounds + 1])
        do {
            if let squad = info.squad, let member = info.member {
                post(squad: squad, from: "elio", to: member, text: message)
                if try resume(squad: squad, member: member, message: message) { return }
            } else {
                _ = try start(title: info.title, prompt: message, cwd: cwd, kind: Kind(rawValue: info.kind ?? "") ?? .code, resume: sid)
                return
            }
        } catch {
            log("taste correction failed: \(error)")
        }
        afterExit(info, cwd: cwd)
    }

    /// What happens once an agent's run is final: tell the squad / the user.
    private func afterExit(_ info: TaskInfo, cwd: String) {
        if let squad = info.squad {
            if info.kind == Kind.lead.rawValue {
                // Messages may have arrived while it was finishing its turn.
                wakeLead(squad)
            } else if info.kind == Kind.scout.rawValue {
                let brief = info.status == .done ? info.summary : nil
                launchQueued(squad, brief: brief)
            } else {
                post(squad: squad, from: info.member ?? "agente", to: "elio",
                     text: "Ho finito (\(info.status.rawValue)): \(String((info.summary ?? "").prefix(600)))")
                if info.status == .failed, squads[squad]?.endedAt == nil {
                    broadcast?(ServerMessage(type: .event, text: "\(info.member ?? "Un agente") si è fermato con un errore.",
                                             lang: .it, kind: "workflowAlert", payload: "{\"workflow\":\"\(squad)\"}", speak: true))
                }
            }
            let busy = tasks.values.contains { $0.info.squad == squad } || reviewing.values.contains(squad)
            if !busy, squads[squad]?.endedAt == nil { finishSquad(squad) }
            return
        }
        if let wf = info.workflow {
            saveWorkflow(WorkflowRecord(id: wf, kind: "task", title: info.title, project: info.project,
                                        startedAt: info.startedAt, endedAt: Date(), status: info.status.rawValue,
                                        summary: info.summary))
            event(wf, .finished, actor: "elio", text: Self.spokenSummary(info.summary), data: ["status": info.status.rawValue])
        }
        let summary = Self.spokenSummary(info.summary)
        let text: String
        switch info.status {
        case .done: text = "Ho finito \"\(info.title)\". \(summary)"
        case .cancelled: text = "Task \"\(info.title)\" annullato."
        default: text = "Il task \"\(info.title)\" non è andato a buon fine. \(summary)"
        }
        broadcast?(ServerMessage(type: .event, text: text, lang: .it, kind: "taskDone", payload: info.jsonString(), speak: true))

        // Changes are reviewed in the app, never pushed automatically.
        if info.kind != "mac", info.status == .done, let payload = try? ProjectTools.diff(repo: cwd, base: nil, head: nil), !payload.diff.isEmpty {
            broadcast?(ServerMessage(type: .event, text: "Diff \(payload.title)", kind: "diff", payload: payload.jsonString()))
        }
    }

    private func finishSquad(_ squad: String) {
        squads[squad]?.endedAt = Date()
        let all = members(of: squad).filter { $0.kind != Kind.lead.rawValue }
        let ok = all.filter { $0.status == .done }.count
        let lead = finished.last { $0.squad == squad && $0.kind == Kind.lead.rawValue }
        let leadSummary = Self.spokenSummary(lead?.summary)
        let goal = squads[squad]?.goal ?? ""
        let text = leadSummary.isEmpty
            ? "La squadra ha finito \"\(goal)\": \(ok) su \(all.count) agenti hanno completato il lavoro."
            : "La squadra ha finito \"\(goal)\". \(leadSummary)"
        saveWorkflow(WorkflowRecord(id: squad, kind: "squad", title: goal, project: nil,
                                    startedAt: squads[squad]?.startedAt ?? Date(), endedAt: Date(),
                                    status: ok == 0 && !all.isEmpty ? "failed" : "done", summary: lead?.summary ?? text))
        event(squad, .finished, actor: "elio", text: text, data: ["ok": ok, "total": all.count])
        broadcast?(ServerMessage(type: .event, text: text, lang: .it, kind: "squadDone",
                                 payload: squads[squad]?.jsonString(), speak: true))
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
        Sei un agente di Elio, l'assistente personale dell'utente. Lavori in background nel progetto \(cwd).

        Compito: \(title)
        Dettagli: \(prompt)

        \(workRules)
        - Se ti manca un'informazione o devi scegliere tra opzioni con impatto, chiedi all'utente con \
        mcp__elio__ask_user invece di indovinare (una domanda chiara, con le opzioni).
        - Termina con un riassunto in italiano di massimo due frasi, adatto a essere letto a voce, poi una sezione dettagliata.
        """
    }

    /// How every code agent works: visible plan, cheap on tokens, free on commands, careful on what can't be undone.
    static let workRules = """
        Come lavori:
        - PIANO VISIBILE: all'inizio scrivi con TodoWrite un piano di 3-7 passi brevi in italiano (activeForm al presente: \
        "Scrivo i test dell'export"), e aggiornalo quando inizi e finisci ogni passo. È l'unico modo in cui l'utente \
        capisce cosa stai facendo e cosa hai fatto: tienilo sempre vero.
        - ECONOMIA: ogni token costa. Niente esplorazioni larghe del repo: Grep/Glob mirati, leggi solo i file che ti servono \
        e solo una volta, comandi con output corto (`| tail -20`, `-q`, `--compact`), test del file o della cartella toccata \
        invece dell'intera suite (la suite intera una volta alla fine, se serve). Non ripetere lavoro già fatto da altri.
        - Comandi: usa liberamente la shell (catene, pipe, script, test, build, flutter, curl in lettura). Chiedono conferma \
        solo push, merge/rebase, reset --hard, cancellazioni ricorsive di codice, migrazioni distruttive, invii verso \
        l'esterno, installazioni globali e docker: evitali, non servono.
        - Codice: lavora su un branch locale `elio/<slug-breve>` e committa lì, a piccoli passi. Mai su develop/main/master, \
        mai push, merge, rebase né PR: l'utente rivede il diff e crea lui la PR.
        - Nei comandi Bash scrivi il campo description in italiano, breve, all'infinito ("eseguire i test del login"): \
        se serve una conferma è quello che l'utente sente.
        """
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
        await ctx.tasks.logEvent(taskId: ctx.taskId, .question, text: question)

        // An agent's small question: Elio answers in the user's place when their taste covers it.
        if ctx.taskId != nil, ctx.config.delegateDecisions {
            var board: [SquadMessage] = []
            if let who = await ctx.tasks.identity(of: ctx.taskId) { board = await ctx.tasks.messages(squad: who.squad) }
            let decision = await Delegate.decide(question: question, from: from, goal: await ctx.tasks.workflowGoal(taskId: ctx.taskId),
                                                 board: board, rules: await ctx.memory.tasteRules(),
                                                 facts: await ctx.memory.facts(), config: ctx.config)
            if let d = decision, d.decide, !d.answer.isEmpty {
                await ctx.tasks.logEvent(taskId: ctx.taskId, .autoDecision, text: d.answer,
                                         data: ["question": question, "reason": d.reason, "costUSD": d.costUSD], actor: "elio")
                ctx.broadcast(ServerMessage(type: .event, text: "Ho deciso io al posto suo: \(d.answer.prefix(160))", lang: .it,
                                            kind: "autoDecision", payload: ["question": question, "answer": d.answer, "reason": d.reason].jsonString(),
                                            speak: true))
                return "Risposta di Elio per conto \(ctx.config.ofUser) (conosce i suoi gusti): \(d.answer)"
            }
        }

        let answer = await ctx.gate.ask(QuestionRequest(id: UUID().uuidString, question: question, from: from,
                                                        taskId: ctx.taskId), timeout: 1500)
        await ctx.tasks.logEvent(taskId: ctx.taskId, .answer, text: answer ?? "(nessuna risposta)", actor: "utente")
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
            "difficulty": prop("trivial SOLO per micro-modifiche (un typo, un testo, un colore, una versione) in 1-2 file: gira su un modello più leggero. Nel dubbio, e per tutto il resto, ometti (Opus)."),
        ],
        required: ["title", "prompt", "project_path"]
    ) { args, ctx in
        let path = expandPath(args["project_path"] as? String ?? "")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Cartella non trovata: \(path)")
        }
        let info = try await ctx.tasks.start(title: args["title"] as? String ?? "Task",
                                             prompt: args["prompt"] as? String ?? "", cwd: path,
                                             difficulty: args["difficulty"] as? String)
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

    static let message = ElioTool(
        name: "agent_message",
        description: "Scrive a un agente in background (dal suo terminale nell'IDE o a voce): se sta lavorando lo interrompe e riparte con il messaggio, se ha finito lo risveglia.",
        properties: ["id": prop("Id del task"), "text": prop("Il messaggio")],
        required: ["id", "text"]
    ) { args, ctx in
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("Messaggio vuoto") }
        return try await ctx.tasks.message(agent: args["id"] as? String ?? "", text: text)
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


/// "Don't ask again for this" without a button: once the user approves a kind of action for an agent (osascript on
/// iTerm, running tests outside the sandbox, editing files in a folder), the same kind of action by the same agent
/// doesn't ask again until the agent ends (or for 3 hours). Only ordinary confirmations: what the rules mark as
/// dangerous (push, deletes, sends) asks every time. The kind is the programs involved (with the subcommand for
/// git/npm-style tools) — so approving `git status` never covers `git push` — or the folder for file edits.
public final class ApprovalMemory: @unchecked Sendable {
    public static let shared = ApprovalMemory()
    private let lock = NSLock()
    private var approved: [String: (kinds: Set<String>, at: Date)] = [:]

    static let withSubcommand: Set<String> = ["git", "npm", "pnpm", "yarn", "bun", "composer", "php", "docker", "herd",
                                              "valet", "brew", "swift", "cargo", "go", "pip", "pip3", "python3", "node",
                                              "kubectl", "gh", "ddev", "artisan", "bin/magento", "osascript", "defaults", "launchctl"]

    /// What kind of action this is; nil when it can't be told safely (then nothing is remembered or covered).
    static func kinds(tool: String, input: [String: Any]) -> Set<String>? {
        switch tool {
        case "Bash":
            guard let cmd = input["command"] as? String, !cmd.contains("$("), !cmd.contains("`") else { return nil }
            let outside = input["dangerouslyDisableSandbox"] as? Bool == true ? "!" : ""
            var out: Set<String> = []
            for part in cmd.splitOutsideQuotes(";|&\n") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
                    .drop { $0.contains("=") && !$0.hasPrefix("-") }
                guard let first = words.first else { continue }
                let prog = (first as NSString).lastPathComponent
                if prog == "cd" { continue }
                let sub = words.dropFirst().first { !$0.hasPrefix("-") } ?? ""
                out.insert(outside + (withSubcommand.contains(prog) ? "\(prog) \(sub)" : prog))
            }
            return out.isEmpty ? nil : out
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            guard let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), !path.isEmpty else { return nil }
            return ["write:" + (path as NSString).deletingLastPathComponent]
        default:
            return [tool]
        }
    }

    public func remember(task: String?, tool: String, input: [String: Any]) {
        guard let task, let k = Self.kinds(tool: tool, input: input) else { return }
        lock.withLock {
            var entry = approved[task] ?? ([], Date())
            entry.kinds.formUnion(k)
            entry.at = Date()
            approved[task] = entry
        }
    }

    public func covers(task: String?, tool: String, input: [String: Any]) -> Bool {
        guard let task, let k = Self.kinds(tool: tool, input: input) else { return false }
        return lock.withLock {
            guard let entry = approved[task], Date().timeIntervalSince(entry.at) < 3 * 3600 else { return false }
            return k.isSubset(of: entry.kinds)
        }
    }

    public func forget(task: String) { lock.withLock { approved[task] = nil } }
}
