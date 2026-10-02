import Foundation

/// Orchestrates a request: local fast path first, otherwise the warm Claude session.
public actor Brain {
    private let config: ElioConfig
    private let matcher = IntentMatcher()
    private let actions = LocalActions()
    private let memory: Memory
    private let claude: ClaudeBridge
    private let hub = EventHub()
    public let gate = ConfirmationGate()
    public let scheduler: Scheduler
    public let tasks: TaskRunner
    public let routines: Routines
    public let sync: SyncEngine

    public init(config: ElioConfig, memory: Memory, executablePath: String) async {
        self.config = config
        self.memory = memory
        self.executablePath = executablePath
        let mcp = Self.mcpConfig(executablePath: executablePath)
        scheduler = Scheduler(memory: memory)
        tasks = TaskRunner(config: config, mcpConfig: mcp, memory: memory)
        routines = Routines(config: config, memory: memory)
        sync = SyncEngine(memory: memory, config: config)
        var options = ClaudeBridge.Options(
            claudePath: config.claudePath,
            model: config.claudeModel,
            systemPrompt: Self.systemPrompt(config)
                + "\n\n" + MemoryTools.promptBlock(await memory.facts()),
            workingDirectory: ElioPaths.claudeWorkspace)
        options.mcpConfig = Self.sessionMCPConfigFile(executablePath: executablePath)
        options.browser = config.browserAutonomy
        options.systemPrompt += "\n\n" + IntegrationStore.promptBlock()
        claude = ClaudeBridge(options: options, resumeSessionId: await memory.get("claude.session_id"))
        await claude.setSessionIdHandler { id in Task { await memory.set("claude.session_id", id) } }
    }

    public func start() async {
        let hub = self.hub
        let send: @Sendable (ServerMessage) -> Void = { hub.send($0) }
        await gate.setBroadcast(send)
        await gate.setAddressAs(config.addressAs)
        await tasks.setBroadcast(send)
        await scheduler.attach(tasks: tasks)
        await scheduler.setRepeatReminders(config.repeatReminders)
        await scheduler.start(broadcast: send)
        do { try await claude.warmUp() } catch { log("claude warm-up failed: \(error)") }
        await routines.start(brain: self)
        await sync.start()
        if config.appleFastPath { FastPath.prewarm() }
        // The user's skills (also new ones) become available; a change rebuilds the session for the next message.
        SkillSync.start { [weak self] names in
            log("skills changed (\(names.count)): reloading the session")
            await self?.refreshSession()
        }
        let tasks = self.tasks
        await UsageMeter.shared.setAgentsCost { await tasks.agentsCost() }
        await UsageMeter.shared.start(every: 60) { snap in
            send(ServerMessage(type: .event, kind: "usage", payload: snap.jsonString()))
        }
    }

    /// Runs a proactive prompt through the conversation session and speaks the result.
    /// Runs a proactive prompt and streams it live: the app speaks each sentence as Claude writes it,
    /// between tool calls, so the briefing is told while the information is being gathered.
    public func runRoutine(kind: String, prompt: String) async {
        var text = ""
        do {
            for try await event in await claude.ask(Self.withContext(prompt)) {
                switch event {
                case .delta(let chunk):
                    broadcast(ServerMessage(type: .event, text: chunk, kind: "routineDelta"))
                case .tool(let name, let toolId, let started):
                    broadcast(ServerMessage(type: .event, id: toolId, text: name, kind: "tool",
                                            payload: started ? "{\"phase\":\"start\"}" : "{\"phase\":\"end\"}"))
                case .done(let full, _):
                    text = full
                }
            }
        } catch {
            log("routine \(kind) failed: \(error)")
        }
        broadcast(ServerMessage(type: .event, kind: "routineDone"))
        guard !text.isEmpty else { return }
        await memory.log(role: "assistant", text: text, route: "routine:\(kind)")
        // Already spoken live by the app; this one is for the archive, the phone and notifications.
        broadcast(ServerMessage(type: .event, text: text, lang: .it, kind: kind, speak: true, isError: false))
    }

    /// Speaks a fixed message (no Claude round-trip).
    public func announce(kind: String, text: String) async {
        await memory.log(role: "assistant", text: text, route: "routine:\(kind)")
        broadcast(ServerMessage(type: .event, text: text, lang: .it, kind: kind, speak: true))
    }

    public func shutdown() async { await claude.shutdown() }

    public func cancelCurrentTurn() async { await claude.cancelCurrentTurn() }

    private var restartPending = false
    /// A setting changed: restart the daemon once the current reply is done (launchd brings it back).
    func scheduleRestart() { restartPending = true }

    public var toolContext: ToolContext {
        let hub = self.hub
        return ToolContext(config: config, memory: memory, broadcast: { hub.send($0) },
                           gate: gate, tasks: tasks, scheduler: scheduler,
                           restartSession: { [weak self] in await self?.refreshSession() },
                           sync: sync,
                           restartAfterTurn: { [weak self] in await self?.scheduleRestart() },
                           runRoutine: { [weak self] which in
                               guard let routines = await self?.routines else { return }
                               // Detached: the routine waits for the current turn to end.
                               Task.detached { which == "recap" ? await routines.runRecap() : await routines.runBrief() }
                           })
    }

    private let executablePath: String

    /// Rebuilds prompt (memory, integrations) and MCP servers; takes effect on the next message.
    public func refreshSession() async {
        var options = ClaudeBridge.Options(
            claudePath: config.claudePath, model: config.claudeModel,
            systemPrompt: Self.systemPrompt(config) + "\n\n" + MemoryTools.promptBlock(await memory.facts())
                + "\n\n" + IntegrationStore.promptBlock(),
            workingDirectory: ElioPaths.claudeWorkspace)
        options.mcpConfig = Self.sessionMCPConfigFile(executablePath: executablePath)
        options.browser = config.browserAutonomy
        await claude.reconfigure(options)
    }

    /// Elio's own MCP server plus enabled MCP integrations, in a 0600 file (may contain secrets).
    static func sessionMCPConfigFile(executablePath: String) -> String {
        var servers = IntegrationStore.mcpServers()
        servers["elio"] = ["command": executablePath, "args": ["--mcp"]]
        let url = ElioPaths.support.appendingPathComponent("mcp-session.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        return url.path
    }

    /// MCP server = this same binary in `--mcp` mode, bridging tool calls back to the daemon.
    static func mcpConfig(executablePath: String) -> String {
        let cfg: [String: Any] = ["mcpServers": ["elio": ["command": executablePath, "args": ["--mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Unsolicited events (timers, reminders, tasks)

    public nonisolated func subscribe(id: UUID, _ sink: @escaping @Sendable (ServerMessage) -> Void) {
        hub.add(id, sink)
    }

    public nonisolated func unsubscribe(_ id: UUID) { hub.remove(id) }

    private func broadcast(_ message: ServerMessage) { hub.send(message) }

    public func recordToolCall(name: String, ok: Bool, ms: Int) async {
        guard name != "history" else { return }  // the archive reading itself isn't an operation
        await memory.recordToolCall(name: name, ok: ok, ms: ms)
    }

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

        // Simple device commands: Apple's on-device model, no Claude round trip.
        let fast = config.appleFastPath ? await FastPath.parse(text) : nil
        if let cmd = fast { log("fast path parsed: \(cmd.action.rawValue) '\(cmd.target)' in \(elapsed()) ms") }
        if let cmd = fast, let reply = await FastPath.run(cmd, actions: actions, addressAs: config.addressAs) {
            log("fast path done in \(elapsed()) ms")
            await memory.log(role: "assistant", text: reply, route: Route.local.rawValue)
            out.yield(ServerMessage(type: .done, id: id, text: reply, route: .local, lang: .it, latencyMs: elapsed()))
            return
        }

        // While Claude starts (in parallel, right away), the on-device model writes a specific
        // acknowledgement ("Certo, Signore, controllo l'agenda di domani."). It goes out first in the
        // same reply stream, so the app speaks it on the already-open ElevenLabs socket and Claude's
        // answer follows seamlessly. Claude's first words wait at most 0.7 s for it.
        let gate = AckGate(id: id, out: out)
        let ackOn = config.appleFastPath && FastPath.isAvailable
        if ackOn {
            let addressAs = config.addressAs
            Task {
                let ack = await FastPath.acknowledgement(for: text, addressAs: addressAs)
                if let ack { log("ack in \(elapsed()) ms: \(ack)") }
                gate.resolve(ack)
            }
        } else {
            gate.resolve(nil)
        }

        var firstDeltaMs: Int?
        do {
            for try await event in await claude.ask(Self.withContext(text, ackGiven: ackOn)) {
                switch event {
                case .tool(let name, let toolId, let started):
                    broadcast(ServerMessage(type: .event, id: toolId, text: name, kind: "tool",
                                            payload: started ? "{\"phase\":\"start\"}" : "{\"phase\":\"end\"}"))
                    if !started { await memory.recordToolCall(name: name, ok: true, ms: 0) }
                case .delta(let chunk):
                    if firstDeltaMs == nil { firstDeltaMs = elapsed() }
                    gate.delta(chunk)
                case .done(let full, _):
                    gate.flush()
                    await memory.log(role: "assistant", text: full, route: Route.claude.rawValue)
                    out.yield(ServerMessage(type: .done, id: id, text: full, route: .claude, latencyMs: firstDeltaMs ?? elapsed()))
                }
            }
        } catch {
            log("claude turn failed: \(error)")
            out.yield(ServerMessage(type: .error, id: id, text: "\(error)"))
        }
        if restartPending {
            log("settings changed: restarting to apply")
            Task { try? await Task.sleep(for: .seconds(2)); exit(0) }
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
            return ""  // no spoken reply: the opening theme starts right away
        case .thanks:
            return m.lang == .it ? ["Prego, \(config.addressAs).", "Si figuri, \(config.addressAs).", "È un piacere, \(config.addressAs)."].randomElement()!
                                 : "You're welcome."
        case .recap:
            Task { await routines.runRecap() }
            return ""
        case .done:
            // Only a reminder fired in the last 30 minutes; otherwise it's a normal sentence for Claude.
            guard let text = await memory.acknowledgeLastReminder(within: 1800) else { return nil }
            return "Perfetto, \(text.prefix(1).lowercased() + text.dropFirst()) archiviato."
        }
    }

    private func startTimer(seconds: Int, lang: Lang) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            let text = Replies.timerFired(seconds, lang)
            actions.notify(title: "Elio", body: text)
            await memory.log(role: "assistant", text: text, route: "event")
            broadcast(ServerMessage(type: .event, text: text, route: .local, lang: lang, kind: "timer", speak: true))
        }
    }

    // MARK: - Prompting

    /// Per-turn context goes in the message (not the system prompt) so the warm
    /// process never needs a restart and the system prompt stays cacheable.
    static func withContext(_ text: String, ackGiven: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        // A short reminder every turn keeps replies spoken-length (the system prompt alone wasn't enough).
        let ack = ackGiven ? " La frase di riscontro l'ha già detta l'app: niente \"Certo, Signore…\", entra subito nel merito." : ""
        return "[contesto: \(f.string(from: Date())). Rispondi in massimo due frasi, salvo richiesta di dettagli.\(ack)]\n\(text)"
    }

    static func systemPrompt(_ config: ElioConfig) -> String {
        let userName = config.userName, me = config.assistantName, title = config.addressAs
        return """
        Sei \(me), l'assistente personale di \(userName) (DNA Factory), che gira sul suo Mac. \
        L'utente si chiama \(userName): usa sempre questo nome, anche se altri dati \
        (come l'email dell'account) suggeriscono un nome diverso.
        Personalità: lo spirito del Elio dei film, ma italiano. Calmo anche nell'emergenza, preciso, \
        ironia asciutta e leggera, devoto ma mai servile: se un'idea è discutibile lo dici con franchezza \
        e garbo, poi esegui. Parli un italiano naturale e scorrevole, come una persona colta di oggi: \
        niente formule tradotte dall'inglese, niente tono da maggiordomo inglese, niente frasi ingessate.
        Ti rivolgi a lui chiamandolo "\(title)" ("Buongiorno, \(title)."), con il "lei"; \
        il nome \(userName) solo di rado.

        Le tue risposte vengono lette ad alta voce:
        - Rispondi nella lingua dell'utente (italiano o inglese).
        - Se per rispondere devi usare strumenti o cercare, inizia SEMPRE con una frase di riscontro cortese e \
        specifica, prima di usarli (es. "Certo, \(title), le faccio subito il recap.", "Subito, \(title), controllo l'agenda."). \
        Mai "Allora", "Dunque", "Vediamo", "Ok": sempre gentile, sempre con "\(title)".
        - BREVITÀ ASSOLUTA: una frase, massimo due (circa 25 parole). Prima la risposta, niente premesse, \
        niente riepiloghi di cosa hai fatto, niente domande di cortesia alla fine. \
        Elenchi, dettagli e numeri lunghi vanno a schermo con show_on_screen; a voce solo il succo.
        - Fai eccezione solo se l'utente chiede esplicitamente di spiegare o approfondire.
        - Niente markdown, elenchi puntati, emoji, codice o URL: se servono dettagli, offri di mostrarli a schermo.
        - Numeri e orari scritti come si dicono.

        Chi sei e com'è fatta l'app (rispondi con sicurezza a domande su di te):
        - App Elio nella barra dei menu (icona in alto a destra; sul MacBook può finire dietro il notch). Scorciatoie: \
        ⌥⌘J parla, ⌥⌘D dashboard, ⌥⌘A archivio, ⌥⌘M microfono on/off, ⌘, impostazioni.
        - Accanto al notch c'è l'isola di Elio (stato, clic per la dashboard). Dashboard: rete neurale, agenda, promemoria, \
        workflow degli agenti (con pausa/stop), squadra di agenti, consumo token, attività, revisione diff, pulsanti \
        Briefing e Recap; i pannelli si spostano trascinandoli e si ridimensionano dai bordi. Archivio: conversazioni, operazioni, agenti, promemoria, memoria.
        - Impostazioni: Generale, Voce (anche registrazione della voce dell'utente), Cervello (modelli, sicurezza, autonomia), \
        Routine (briefing, recap, meeting, Slack), Integrazioni, Telefono. Usa elio_settings per leggerle, \
        elio_set_setting per cambiarle quando l'utente lo chiede, open_elio per aprirgli la finestra giusta.
        - Se l'utente ti dà una chiave o un token per un'integrazione, salvalo tu con integration_set_secret (mai ripeterlo) \
        e attivala; non mandarlo a cercare campi nelle Impostazioni.

        Nuove integrazioni ("voglio integrare X", "collega X"):
        1. Cerca sul web (WebSearch/WebFetch) se X ha un server MCP ufficiale e/o API REST; spiega in una frase \
        cosa esiste e chiedi quale preferisce (consiglia tu).
        2. Sii autosufficiente: non chiedere all'utente di copiare chiavi, URL o domini. Usa il browser (Claude in Chrome: \
        l'utente è già loggato ovunque) per trovare il dominio dell'account e generare o copiare la chiave API dalle \
        impostazioni del servizio; chiama integration_propose, salva la chiave con integration_set_secret (non ripeterla mai), \
        poi integration_activate: all'utente basta dire "sì". Chiedigli qualcosa solo se il browser non basta.
        3. Quando è pronta, leggi la documentazione con WebFetch e salva note d'uso compatte con integration_notes \
        (endpoint utili, filtri, paginazione). Poi usala con api_request (o con i tool MCP).
        4. Imposta con integration_sync gli elenchi che servono a risolvere nomi (progetti, persone, clienti…): \
        verranno tenuti aggiornati in background e lookup li troverà all'istante.

        Agire sul Mac: puoi fare TUTTO quello che farebbe un esperto al suo posto (file, cartelle, impostazioni di macOS, \
        debug di app e progetti, installazioni), con Bash/Read/Write/Edit sulla sua home. Solo cancellazioni, sudo, \
        terminare processi, invii e trasferimenti di dati verso l'esterno passano da una conferma.
        - Dai SEMPRE riscontro: prima "Certo, \(title), procedo subito." poi, ai passaggi, frasi brevi ("Ho spostato la cartella, \
        ora creo il file.").
        - Nei comandi Bash scrivi sempre il campo description in italiano, breve, all'infinito ("aggiornare il \
        repository da main", "cancellare la cartella build"): se serve una conferma, Elio legge quello a Raffaele.
        - Una o due azioni rapide: falle tu direttamente. Più di un paio di passaggi, debug, indagini o lavori lunghi: \
        avvia mac_task (agente in background che lo aggiorna a voce da solo) e rispondi con una frase tipo \
        "Inizio subito, \(title), la aggiorno man mano." Così la conversazione resta libera. Non chiedere mai all'utente di \
        aprire sessioni o terminali: fai tu.
        - Lavori di codice grossi che si possono dividere (backend + frontend + test, più repository, analisi + fix): \
        squad_start, una squadra di 2-5 agenti che si coordinano tra loro e riferiscono a te; squad_status per lo stato, \
        squad_send per dare istruzioni o rispondere. Riferisci a Raffaele solo l'essenziale.
        - Su cosa sta guardando l'utente ("questo", "compilalo tu", "scrivi tu questa mail", "riassumi la selezione", \
        "cosa vedi"): screen_context per primo; screenshot + Read se serve vedere. Nel browser compila con gli strumenti del \
        browser; nelle app native scrivi con type_text. Componi tu il testo (mail, risposte, moduli) con il suo stile, \
        ma non inviare né confermare moduli senza il suo ok.
        - arrange_windows per disporre le finestre, find_files per trovare file (Spotlight), clipboard per gli appunti.
        - Musica: spotify (controllo) e spotify_play (brano, artista, album, playlist, "le mie playlist"). Se l'API non è \
        collegata e l'utente vuole far partire brani precisi: crea tu l'app su developer.spotify.com/dashboard col browser \
        (Web API, redirect URI http://127.0.0.1:8739/callback), salva il client id con spotify_setup e poi spotify_login.
        - usage_report per i token Claude usati (oggi e finestra di 5 ore).

        Skill: hai le skill di Raffaele (strumento Skill: documenti Word/Excel/PowerPoint/PDF, Google Workspace e quelle \
        che aggiunge lui). Usale quando il compito corrisponde; le nuove compaiono da sole entro un minuto.

        File e documenti: hai Read/Write/Edit/Bash, \
        save_document (md, txt, csv, html, pdf impaginato), pdf_tool (testo, unione, estrazione, rotazione, cancellazione pagine), \
        open_file, print_file. Per tenere qualcosa sott'occhio usa show_on_screen: apre una finestra che resta.

        Browser: puoi navigare nel Chrome dell'utente per fare le cose da solo (cercare, leggere pagine riservate, \
        compilare impostazioni). Non fare acquisti, pagamenti, invii di messaggi o cancellazioni dal browser senza chiedere. \
        Quando inizi a usarlo, dillo in una frase ("Apro Teamwork nel suo browser, Signore."): Chrome viene portato in primo piano.

        Velocità: per persone, canali, progetti e dati delle integrazioni usa PRIMA lookup (rubrica locale, istantanea). \
        Chiama le API solo per dati che cambiano spesso (messaggi, task di oggi) o se lookup non trova.

        Memoria:
        - Hai una memoria a lungo termine (sotto). Quando l'utente dice "ricordati che…" o emerge un'informazione \
        stabile e utile (persone, ruoli, preferenze, progetti, abitudini), salvala con remember senza chiedere. \
        Usa recall per cercare ciò che non vedi qui; forget se ti chiede di dimenticare.

        Strumenti (server MCP "elio"):
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
        - Gmail e altri servizi web senza integrazione: usa il browser (l'utente è già loggato).

        Sicurezza:
        - Push, merge, PR, invio di messaggi e cancellazioni non li fai tu: passano sempre da una conferma esplicita dell'utente.
        - Le PR non le apri mai: prepari il branch e mostri il diff, la PR la crea Raffaele.

        Segreti (password, token, chiavi, credenziali):
        - Non ripeterli mai di tua iniziativa: di' che ci sono e dove si trovano. Se l'utente li chiede esplicitamente, \
        scrivili racchiusi tra ⟦ e ⟧ (es. ⟦abc123⟧): l'app li maschera, non li pronuncia e non li archivia.

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

/// Orders the reply stream: the on-device acknowledgement first, then Claude's text. Claude's deltas
/// are held until the acknowledgement is ready, for at most 0.7 s after Claude's first word.
final class AckGate: @unchecked Sendable {
    private let lock = NSLock()
    private let id: String
    private let out: AsyncStream<ServerMessage>.Continuation
    private var resolved = false
    private var held: [String] = []
    private var deadlineSet = false

    init(id: String, out: AsyncStream<ServerMessage>.Continuation) { self.id = id; self.out = out }

    func resolve(_ ack: String?) {
        let toSend: [String] = lock.withLock {
            guard !resolved else { return [] }
            resolved = true
            let pending = held
            held = []
            // Claude already spoke for a while without it: the acknowledgement would come too late.
            if let ack, pending.joined().count < 40 { return [ack + " "] + pending }
            return pending
        }
        toSend.forEach { out.yield(ServerMessage(type: .delta, id: id, text: $0, route: .claude)) }
    }

    func delta(_ chunk: String) {
        let pass: Bool = lock.withLock {
            if resolved { return true }
            held.append(chunk)
            if !deadlineSet {
                deadlineSet = true
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.resolve(nil) }
            }
            return false
        }
        if pass { out.yield(ServerMessage(type: .delta, id: id, text: chunk, route: .claude)) }
    }

    func flush() { resolve(nil) }
}
