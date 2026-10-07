import Foundation

/// Thinks ahead while the user is still talking. The app streams the partial transcript of a long request;
/// a small, read-only Claude session works on it in parallel — finds the person, the channel, the repo,
/// the files, how the change could be done — and when the user stops, its notes go into the real turn.
/// "Manda un messaggio su Slack ad Antonio Vitale…" → Antonio is already resolved; "nel repo X fai Y e Z…"
/// → the repo is found and Y explored while Z is still being described.
///
/// It never acts: only lookups and reads (anything else is denied, there is no permission prompt).
public actor SpeechPrep {
    private let config: ElioConfig
    private let mcpConfig: String
    private var bridge: ClaudeBridge?
    private var key: String?
    /// Text already handed to the session, the newest text waiting, and its notes so far.
    private var sentText = ""
    private var latestText = ""
    private var notes = ""
    private var running: Task<Void, Never>?
    private var startedAt = Date()

    public init(config: ElioConfig, mcpConfig: String) {
        self.config = config
        self.mcpConfig = mcpConfig
    }

    /// Opens the session ahead of time (the user started talking to Elio): no cold start on the critical path.
    public func warm() {
        guard bridge == nil else { return }
        let b = makeBridge()
        bridge = b
        Task { try? await b.warmUp() }
    }

    /// New partial transcript for the utterance `key`.
    public func update(key: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(separator: " ").count >= 6 else { return }
        if key != self.key {
            // A session that already worked on another request starts over; a warm, unused one is kept.
            reset(keepWarm: sentText.isEmpty)
            self.key = key
            startedAt = Date()
        }
        latestText = text
        pump()
    }

    /// The user finished: the notes so far (waiting a moment for a step that is about to end), then a fresh
    /// session is prepared for the next request.
    public func take(key: String) async -> String? {
        guard key == self.key else { return nil }
        if running != nil {
            let deadline = Date().addingTimeInterval(1.2)
            while running != nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(80)) }
        }
        let result = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        log("speech prep: \(result.count) chars of notes after \(Int(Date().timeIntervalSince(startedAt)))s")
        reset()
        // Ready for the next request: the cold start happens now, not while the user talks.
        warm()
        return result.isEmpty ? nil : result
    }

    private func reset(keepWarm: Bool = false) {
        running?.cancel()
        running = nil
        key = nil
        sentText = ""
        latestText = ""
        notes = ""
        if !keepWarm, let old = bridge {
            Task { await old.shutdown() }
            bridge = nil
        }
    }

    /// One step at a time; when it ends, the next one gets whatever was said meanwhile.
    private func pump() {
        guard running == nil, let key else { return }
        let newWords = latestText.split(separator: " ").count - sentText.split(separator: " ").count
        // Wait for a few new words: one step per clause, not per syllable.
        guard sentText.isEmpty || newWords >= 5 else { return }
        let prompt = sentText.isEmpty
            ? "\(config.displayName.capitalizedFirst) sta parlando (trascrizione parziale, continua):\n\"\(latestText)\""
            : "Ha continuato. Ora la trascrizione è:\n\"\(latestText)\""
        sentText = latestText
        if bridge == nil { warm() }
        guard let bridge else { return }
        running = Task {
            var text = ""
            do {
                for try await event in await bridge.ask(prompt) {
                    if Task.isCancelled { break }
                    if case .done(let full, _) = event { text = full }
                }
            } catch {
                log("speech prep step failed: \(error)")
            }
            self.stepDone(key: key, notes: text)
        }
    }

    private func stepDone(key: String, notes text: String) {
        guard key == self.key else { return }
        running = nil
        if !text.isEmpty { notes = text }
        pump()
    }

    private func makeBridge() -> ClaudeBridge {
        var options = ClaudeBridge.Options(claudePath: config.claudePath, model: config.prepModel,
                                           systemPrompt: Self.prompt(config), workingDirectory: ElioPaths.claudeWorkspace)
        options.mcpConfig = mcpConfig
        options.account = config.claudeAccount
        options.turnTimeout = 60
        options.tools = ["Read", "Grep", "Glob"]
        options.allowedTools = ["Read", "Grep", "Glob"] + Self.readOnlyElioTools.map { "mcp__elio__\($0)" }
        options.addDirs = config.projectRoots.map { ($0 as NSString).expandingTildeInPath }
        return ClaudeBridge(options: options)
    }

    /// Lookups only: nothing that sends, writes, starts agents or asks the user.
    static let readOnlyElioTools = ["lookup", "list_projects", "project_tree", "project_info", "recall", "taste_rules",
                                    "todo_list", "calendar_events", "list_reminders", "list_tasks", "integration_list"]

    static func prompt(_ config: ElioConfig) -> String {
        """
        Sei il "pensiero veloce" di \(config.assistantName), l'assistente \(config.ofUser). \(config.displayName.capitalizedFirst) sta ancora \
        parlando: ricevi la trascrizione parziale (può essere incompleta o con errori di riconoscimento) e prepari il terreno \
        perché, appena finisce, \(config.assistantName) possa agire subito.

        Cosa fai, in silenzio e in fretta:
        - Risolvi i riferimenti: persone e canali (lookup), progetti e repository (list_projects, project_tree, \
        project_info), impegni (calendar_events), cose ricordate (recall), la to-do list (todo_list).
        - Se si parla di modifiche al codice, trova i file giusti (Glob, Grep, Read di poche righe) e annota dove e come \
        intervenire per ciascuna modifica man mano che viene descritta.
        - Non agisci mai: niente invii, modifiche, agenti o domande. Solo letture rapide (al massimo 4-5 strumenti per passo).
        - Lavora anche su frasi a metà: se si capisce di che progetto, persona o argomento si tratta, cercalo subito, \
        non aspettare che la richiesta sia completa. Usa almeno uno strumento appena c'è un nome o un progetto.
        - Solo se è chiaramente una chiacchiera o una domanda banale (che ore sono, metti musica) rispondi "-".

        Ogni risposta sostituisce la precedente: scrivi SEMPRE gli appunti completi aggiornati, compatti, in elenco:
        - Richiesta (in una riga, la tua miglior interpretazione)
        - Riferimenti risolti (nome → id/percorso)
        - Piano / file e punti da toccare
        - Dubbi o cose da chiedere
        Niente preamboli, niente saluti: solo gli appunti.
        """
    }
}
