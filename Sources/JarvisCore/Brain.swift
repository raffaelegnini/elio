import Foundation

/// Orchestrates a request: local fast path first, otherwise the warm Claude session.
public actor Brain {
    private let config: JarvisConfig
    private let matcher = IntentMatcher()
    private let actions = LocalActions()
    private let memory: Memory
    private let claude: ClaudeBridge
    private var eventSinks: [UUID: @Sendable (ServerMessage) -> Void] = [:]

    public init(config: JarvisConfig, memory: Memory) async {
        self.config = config
        self.memory = memory
        let options = ClaudeBridge.Options(
            claudePath: config.claudePath,
            model: config.claudeModel,
            systemPrompt: Self.systemPrompt(userName: config.userName),
            workingDirectory: JarvisPaths.claudeWorkspace)
        claude = ClaudeBridge(options: options, resumeSessionId: await memory.get("claude.session_id"))
        await claude.setSessionIdHandler { id in Task { await memory.set("claude.session_id", id) } }
    }

    public func start() async {
        do { try await claude.warmUp() } catch { log("claude warm-up failed: \(error)") }
    }

    public func shutdown() async { await claude.shutdown() }

    // MARK: - Unsolicited events (timers, reminders)

    public func subscribe(id: UUID, _ sink: @escaping @Sendable (ServerMessage) -> Void) {
        eventSinks[id] = sink
    }

    public func unsubscribe(_ id: UUID) { eventSinks[id] = nil }

    private func broadcast(_ message: ServerMessage) {
        for sink in eventSinks.values { sink(message) }
    }

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
        }
    }

    private func startTimer(seconds: Int, lang: Lang) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            let text = Replies.timerFired(seconds, lang)
            actions.notify(title: "Jarvis", body: text)
            await memory.log(role: "assistant", text: text, route: "event")
            broadcast(ServerMessage(type: .event, text: text, route: .local, lang: lang))
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
        Personalità: maggiordomo britannico brillante, calmo, preciso, con un'ironia leggera e mai servile.

        Le tue risposte vengono lette ad alta voce:
        - Rispondi nella lingua dell'utente (italiano o inglese).
        - Frasi brevi e naturali, da parlato. Di norma una-tre frasi.
        - Niente markdown, elenchi puntati, emoji, codice o URL: se servono dettagli, offri di mostrarli a schermo.
        - Numeri e orari scritti come si dicono.

        Onestà:
        - Non inventare mai dati personali (calendario, mail, task, messaggi). \
        Al momento non hai ancora accesso a questi strumenti: se te li chiedono, dillo chiaramente.
        - Ogni messaggio inizia con [contesto: data e ora attuali]; usalo, non citarlo.
        """
    }
}
