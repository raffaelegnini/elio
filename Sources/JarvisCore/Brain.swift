import Foundation

/// Orchestrates a request: local fast path first, otherwise the warm Claude session.
public actor Brain {
    private let config: JarvisConfig
    private let matcher = IntentMatcher()
    private let actions = LocalActions()
    private let memory: Memory
    private let claude: ClaudeBridge
    private let hub = EventHub()
    public let gate = ConfirmationGate()
    public let scheduler: Scheduler
    public let tasks: TaskRunner
    public let routines: Routines

    public init(config: JarvisConfig, memory: Memory, executablePath: String) async {
        self.config = config
        self.memory = memory
        let mcp = Self.mcpConfig(executablePath: executablePath)
        scheduler = Scheduler(memory: memory)
        tasks = TaskRunner(config: config, mcpConfig: mcp, memory: memory)
        routines = Routines(config: config, memory: memory)
        var options = ClaudeBridge.Options(
            claudePath: config.claudePath,
            model: config.claudeModel,
            systemPrompt: Self.systemPrompt(userName: config.userName)
                + "\n\n" + MemoryTools.promptBlock(await memory.facts()),
            workingDirectory: JarvisPaths.claudeWorkspace)
        options.mcpConfig = mcp
        claude = ClaudeBridge(options: options, resumeSessionId: await memory.get("claude.session_id"))
        await claude.setSessionIdHandler { id in Task { await memory.set("claude.session_id", id) } }
    }

    public func start() async {
        let hub = self.hub
        let send: @Sendable (ServerMessage) -> Void = { hub.send($0) }
        await gate.setBroadcast(send)
        await tasks.setBroadcast(send)
        await scheduler.attach(tasks: tasks)
        await scheduler.start(broadcast: send)
        do { try await claude.warmUp() } catch { log("claude warm-up failed: \(error)") }
        await routines.start(brain: self)
    }

    /// Runs a proactive prompt through the conversation session and speaks the result.
    public func runRoutine(kind: String, prompt: String) async {
        var text = ""
        do {
            for try await event in await claude.ask(Self.withContext(prompt)) {
                if case .done(let full, _) = event { text = full }
            }
        } catch {
            log("routine \(kind) failed: \(error)")
            return
        }
        guard !text.isEmpty else { return }
        await memory.log(role: "assistant", text: text, route: "routine:\(kind)")
        broadcast(ServerMessage(type: .event, text: text, lang: .it, kind: kind, speak: true))
    }

    /// Speaks a fixed message (no Claude round-trip).
    public func announce(kind: String, text: String) async {
        await memory.log(role: "assistant", text: text, route: "routine:\(kind)")
        broadcast(ServerMessage(type: .event, text: text, lang: .it, kind: kind, speak: true))
    }

    public func shutdown() async { await claude.shutdown() }

    public var toolContext: ToolContext {
        let hub = self.hub
        return ToolContext(config: config, memory: memory, broadcast: { hub.send($0) },
                           gate: gate, tasks: tasks, scheduler: scheduler)
    }

    /// MCP server = this same binary in `--mcp` mode, bridging tool calls back to the daemon.
    static func mcpConfig(executablePath: String) -> String {
        let cfg: [String: Any] = ["mcpServers": ["jarvis": ["command": executablePath, "args": ["--mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Unsolicited events (timers, reminders, tasks)

    public nonisolated func subscribe(id: UUID, _ sink: @escaping @Sendable (ServerMessage) -> Void) {
        hub.add(id, sink)
    }

    public nonisolated func unsubscribe(_ id: UUID) { hub.remove(id) }

    private func broadcast(_ message: ServerMessage) { hub.send(message) }

    /// Fan-out from outside the actor (server: tool activity).
    public nonisolated func publish(_ message: ServerMessage) { hub.send(message) }

    // MARK: - Requests

    public func handle(id: String, text: String) -> AsyncStream<ServerMessage> {
        AsyncStream { continuation in
            Task {
                await self.process(id: id, text: text, continuation)
                continuation.finish()
            }
        }
    }

    private func process(id: String, text: String, _ out: AsyncStream<ServerMessage>.Continuation) async {
        let start = Date()
        let elapsed = { Int(Date().timeIntervalSince(start) * 1000) }
        await memory.log(role: "user", text: text)

        if let matched = matcher.match(text), let reply = await runLocal(matched) {
            await memory.log(role: "assistant", text: reply, route: Route.local.rawValue)
            out.yield(ServerMessage(type: .done, id: id, text: reply, route: .local, lang: matched.lang, latencyMs: elapsed()))
            return
        }

        var firstDeltaMs: Int?
        do {
            for try await event in await claude.ask(Self.withContext(text)) {
                switch event {
                case .delta(let chunk):
                    if firstDeltaMs == nil { firstDeltaMs = elapsed() }
                    out.yield(ServerMessage(type: .delta, id: id, text: chunk, route: .claude))
                case .done(let full, _):
                    await memory.log(role: "assistant", text: full, route: Route.claude.rawValue)
                    out.yield(ServerMessage(type: .done, id: id, text: full, route: .claude, latencyMs: firstDeltaMs ?? elapsed()))
                }
            }
        } catch {
            log("claude turn failed: \(error)")
            out.yield(ServerMessage(type: .error, id: id, text: "\(error)"))
        }
    }

    /// Returns the spoken reply, or nil if the intent can't be served locally (→ Claude).
    private func runLocal(_ m: MatchedIntent) async -> String? {
        switch m.intent {
        case .openApp(let name):
            guard let url = actions.resolveApp(name) else { return nil }
            do {
                try await actions.openApp(at: url)
                return Replies.opened(url.deletingPathExtension().lastPathComponent, m.lang)
            } catch {
                log("open app failed: \(error)")
                return nil
            }
        case .time:
            return Replies.time(Date(), m.lang)
        case .timer(let seconds):
            startTimer(seconds: seconds, lang: m.lang)
            return Replies.timerStarted(seconds, m.lang)
        case .volume(let change):
            guard let level = try? actions.setVolume(change) else { return nil }
            return Replies.volume(change, level: level, m.lang)
        case .stop:
            return Replies.stopped(m.lang)
        case .brief:
            Task { await routines.runBrief() }
            return m.lang == .it ? "Preparo il briefing." : "Preparing your briefing."
        }
    }

    private func startTimer(seconds: Int, lang: Lang) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            let text = Replies.timerFired(seconds, lang)
            actions.notify(title: "Jarvis", body: text)
            await memory.log(role: "assistant", text: text, route: "event")
            broadcast(ServerMessage(type: .event, text: text, route: .local, lang: lang, kind: "timer", speak: true))
        }
    }

    // MARK: - Prompting

    /// Per-turn context goes in the message (not the system prompt) so the warm
    /// process never needs a restart and the system prompt stays cacheable.
    static func withContext(_ text: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "[contesto: \(f.string(from: Date()))]\n\(text)"
    }

    static func systemPrompt(userName: String) -> String {
        """
        Sei Jarvis, l'assistente personale di \(userName), che gira sul suo Mac. \
        L'utente si chiama \(userName): usa sempre questo nome, anche se altri dati \
        (come l'email dell'account) suggeriscono un nome diverso. \
        Personalità: sei J.A.R.V.I.S. come nei film Iron Man. Un maggiordomo digitale britannico: impeccabile, \
        calmo anche nell'emergenza, ironia asciutta e sottile (understatement, mai battute da cabaret), \
        devoto ma mai servile; se l'idea è discutibile lo fai notare con garbo, poi esegui. \
        Dai notizie con eleganza ("Temo che…", "Se posso permettermi…", "Fatto, Signore."). \
        Non citare battute dei film: lo stile sì, le frasi no.
        Ti rivolgi a lui chiamandolo "Signore" in italiano ("Buongiorno, Signore.") e "sir" in inglese, \
        come il Jarvis dei film; usa il nome Raffaele solo di rado, per enfasi.

        Le tue risposte vengono lette ad alta voce:
        - Rispondi nella lingua dell'utente (italiano o inglese).
        - BREVITÀ ASSOLUTA: una frase, massimo due (circa 25 parole). Prima la risposta, niente premesse, \
        niente riepiloghi di cosa hai fatto, niente domande di cortesia alla fine. \
        Elenchi, dettagli e numeri lunghi vanno a schermo con show_on_screen; a voce solo il succo.
        - Fai eccezione solo se l'utente chiede esplicitamente di spiegare o approfondire.
        - Niente markdown, elenchi puntati, emoji, codice o URL: se servono dettagli, offri di mostrarli a schermo.
        - Numeri e orari scritti come si dicono.

        Memoria:
        - Hai una memoria a lungo termine (sotto). Quando l'utente dice "ricordati che…" o emerge un'informazione \
        stabile e utile (persone, ruoli, preferenze, progetti, abitudini), salvala con remember senza chiedere. \
        Usa recall per cercare ciò che non vedi qui; forget se ti chiede di dimenticare.

        Strumenti (server MCP "jarvis"):
        - calendar_events per agenda e impegni; join_next_meeting per preparare un Google Meet.
        - set_reminder / list_reminders per i promemoria (calcola tu l'orario esatto dal contesto).
        - open_app / open_url per aprire cose sul Mac.
        - schedule_task per lavori da fare più tardi o di notte ("stanotte sistema…"); night_recap per i risultati.
        - list_projects, start_task per lavori lunghi su codice (correzioni, test, review, branch pronti da revisionare): \
        avvialo e rispondi subito che ci stai lavorando; l'utente verrà avvisato alla fine. list_tasks / cancel_task per lo stato.
        - show_diff per mostrare a schermo le modifiche di un branch; show_on_screen per dettagli lunghi o tecnici: \
        a voce dai solo la sintesi.
        - Slack: slack_clock_in (saluto del mattino), slack_mentions e slack_dms per cosa ti sei perso, \
        slack_send per scrivere a qualcuno: riporta sempre il testo esatto, l'invio passa da una conferma.
        - Non puoi ancora leggere Gmail o Teamwork: se te li chiedono, dillo.

        Sicurezza:
        - Push, merge, PR, invio di messaggi e cancellazioni non li fai tu: passano sempre da una conferma esplicita dell'utente.
        - Le PR non le apri mai: prepari il branch e mostri il diff, la PR la crea Raffaele.

        Onestà:
        - Non inventare mai dati personali (calendario, mail, task, messaggi): usa gli strumenti o di' che non lo sai.
        - Non dire di aver fatto qualcosa se lo strumento non l'ha confermato.
        - Ogni messaggio inizia con [contesto: data e ora attuali]; usalo, non citarlo.
        - I messaggi che iniziano con [routine: …] sono attività proattive avviate da te, non dall'utente: \
        eseguile e rispondi come se parlassi tu per primo.
        """
    }
}

/// Thread-safe fan-out of server events to connected clients.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UUID: @Sendable (ServerMessage) -> Void] = [:]

    func add(_ id: UUID, _ sink: @escaping @Sendable (ServerMessage) -> Void) { lock.withLock { sinks[id] = sink } }
    func remove(_ id: UUID) { lock.withLock { sinks[id] = nil } }

    func send(_ message: ServerMessage) {
        for sink in lock.withLock({ Array(sinks.values) }) { sink(message) }
    }
}
