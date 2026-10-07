import Foundation

/// Short Italian lines saying what Elio is doing with a tool ("Cerco su Slack «deploy»"), for the live
/// feed in the dashboard, the HUD and the phone. Always one line, clipped, secrets redacted.
public enum ActivityText {
    public static let maxLength = 72

    public static func describe(tool: String, inputJSON: String) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any]
        return describe(tool: tool, input: obj ?? [:])
    }

    public static func describe(tool: String, input: [String: Any]) -> String {
        func s(_ key: String) -> String? {
            guard let v = input[key] else { return nil }
            let text = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
            // Redacted before any cut: a clipped secret could slip past the filter.
            let t = SecretFilter.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func quoted(_ v: String?) -> String { v.map { " «\(oneLine($0, 40))»" } ?? "" }
        let name = tool.hasPrefix("mcp__elio__") ? String(tool.dropFirst("mcp__elio__".count)) : tool

        let line: String
        switch name {
        // Claude Code's own tools.
        case "Bash":
            if let d = s("description") {
                line = d.prefix(1).uppercased() + d.dropFirst()
            } else {
                line = "Eseguo " + commandGist(s("command") ?? "un comando")
            }
        case "Read": line = "Leggo " + file(s("file_path"))
        case "Write": line = "Scrivo " + file(s("file_path"))
        case "Edit", "MultiEdit", "NotebookEdit": line = "Modifico " + file(s("file_path") ?? s("notebook_path"))
        case "Grep": line = "Cerco" + quoted(s("pattern")) + (s("path").map { " in " + file($0) } ?? "")
        case "Glob": line = "Cerco file" + quoted(s("pattern"))
        case "WebSearch": line = "Cerco sul web" + quoted(s("query"))
        case "WebFetch": line = "Apro " + domain(s("url"))
        case "Skill": line = "Uso la skill " + (s("skill") ?? s("command") ?? "")
        case "Task", "Agent": line = "Avvio un sotto-agente" + (s("description").map { ": \($0)" } ?? "")
        case "TodoWrite": line = "Aggiorno i passi da fare"
        // Elio's tools.
        case "calendar_events": line = "Leggo l'agenda" + (s("from").map { " (\(oneLine($0, 16)))" } ?? "")
        case "join_next_meeting": line = "Preparo il prossimo Meet"
        case "slack_send": line = "Scrivo su Slack" + (s("to").map { " a \($0)" } ?? "")
        case "slack_mentions": line = "Cerco le menzioni su Slack"
        case "slack_dms": line = "Leggo i messaggi diretti su Slack"
        case "slack_clock_in": line = "Saluto su Slack"
        case "mail_search": line = "Cerco nella posta" + quoted(s("query"))
        case "mail_inbox": line = "Controllo la posta" + (input["unread_only"] as? Bool == true ? " non letta" : "")
        case "mail_read": line = "Leggo una mail"
        case "mail_send": line = "Preparo una mail" + (s("to").map { " a \($0)" } ?? "")
        case "lookup": line = "Cerco in rubrica" + quoted(s("query"))
        case "recall": line = s("query") == nil ? "Rileggo la memoria" : "Cerco nella memoria" + quoted(s("query"))
        case "remember": line = "Memorizzo" + quoted(s("fact"))
        case "forget": line = "Dimentico un ricordo"
        case "history": line = "Rileggo l'archivio"
        case "set_reminder": line = "Imposto un promemoria" + quoted(s("text"))
        case "list_reminders": line = "Leggo i promemoria"
        case "open_app": line = "Apro " + (s("name") ?? "un'app")
        case "open_url": line = "Apro " + domain(s("url"))
        case "open_file": line = "Apro " + file(s("path"))
        case "print_file": line = "Stampo " + file(s("path"))
        case "find_files": line = "Cerco file" + quoted(s("query"))
        case "screen_context": line = "Guardo lo schermo"
        case "screenshot": line = "Faccio uno screenshot"
        case "clipboard": line = "Uso gli appunti"
        case "type_text": line = "Scrivo nel campo attivo"
        case "arrange_windows": line = "Dispongo le finestre"
        case "start_task", "mac_task": line = "Avvio un agente" + (s("title").map { ": \($0)" } ?? "")
        case "schedule_task": line = "Programmo un agente" + (s("title").map { ": \($0)" } ?? "")
        case "list_tasks", "control_task": line = "Controllo gli agenti"
        case "cancel_task": line = "Fermo un agente"
        case let t where t.hasPrefix("squad_"): line = t == "squad_start" ? "Avvio una squadra di agenti" : "Coordino la squadra"
        case "show_on_screen": line = "Mostro a schermo" + (s("title").map { ": \($0)" } ?? "")
        case "show_diff": line = "Preparo il diff"
        case "list_projects", "project_tree": line = "Cerco tra i progetti"
        case "save_document": line = "Salvo il documento" + (s("name").map { " \($0)" } ?? "")
        case "spotify_play": line = "Metto" + quoted(s("query")) + " su Spotify"
        case let t where t.hasPrefix("spotify"): line = "Controllo Spotify"
        case "db_query": line = "Interrogo il database" + (s("connection").map { " \($0)" } ?? "")
        case "ssh_run": line = "Eseguo su \(s("host") ?? "server"): " + commandGist(s("command") ?? "")
        case "api_request":
            line = "Chiamo \(s("integration") ?? "un'API")" + (s("path").map { ": \(s("method") ?? "GET") \($0)" } ?? "")
        case "todo_add": line = "Aggiungo alla lista" + quoted(s("text") ?? s("title"))
        case "todo_done": line = "Spunto dalla lista" + quoted(s("query"))
        case let t where t.hasPrefix("todo_"): line = "Aggiorno la to-do list"
        case let t where t.hasPrefix("taste_"): line = "Aggiorno i suoi gusti"
        case let t where t.hasPrefix("watch_"): line = "Imposto un monitor"
        case let t where t.hasPrefix("workflow_"): line = "Preparo il report del workflow"
        case let t where t.hasPrefix("integration") || t == "integrations_native": line = "Configuro un'integrazione"
        case let t where t.hasPrefix("connection_"): line = "Apro una connessione"
        case "notify_user": line = "Mando un avviso"
        case "message_send": line = "Lascio un messaggio" + (s("title").map { ": \($0)" } ?? "")
        case "call_user": line = "La chiamo"
        case "ask_user": line = "Le faccio una domanda"
        case "approve": line = "Chiedo il permesso"
        case "usage_report": line = "Controllo i consumi"
        case "elio_settings": line = "Leggo le impostazioni"
        case "elio_set_setting": line = "Cambio un'impostazione"
        case "open_elio": line = "Apro una finestra di Elio"
        case "open_ide": line = "Apro l'IDE"
        case "pdf_tool": line = "Lavoro sul PDF"
        case "image_tool": line = "Lavoro sull'immagine"
        case "media_tool": line = "Lavoro su audio e video"
        case "quick_note": line = "Prendo un appunto"
        case "self_update": line = "Mi aggiorno"
        case let t where t.hasPrefix("mcp__claude-in-chrome__"):
            line = "Browser: " + browserAction(String(t.dropFirst("mcp__claude-in-chrome__".count)), input: input)
        case let t where t.hasPrefix("mcp__"):
            // mcp__<integration>__<action>
            let parts = t.dropFirst(5).components(separatedBy: "__")
            let service = (parts.first ?? "").replacingOccurrences(of: "_", with: " ").capitalized
            let action = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            line = action.isEmpty ? "Uso \(service)" : "\(service): \(action)"
        default:
            line = "Uso " + name.replacingOccurrences(of: "_", with: " ")
        }
        return clip(line)
    }

    /// A short outcome of a finished tool, when it's cheap to tell ("3 risultati", "errore: …"); nil otherwise.
    public static func outcome(tool: String, result: String, isError: Bool) -> String? {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if isError {
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let cleaned = first.replacingOccurrences(of: #"^(Error|Errore|error)\s*:\s*"#, with: "", options: .regularExpression)
            return cleaned.isEmpty ? "errore" : "errore: " + oneLine(SecretFilter.redact(cleaned), 60)
        }
        let name = tool.hasPrefix("mcp__elio__") ? String(tool.dropFirst("mcp__elio__".count)) : tool
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        switch name {
        case "Grep", "Glob", "find_files":
            if text.isEmpty || text.hasPrefix("No files found") || text.hasPrefix("No matches") || text.hasPrefix("Nessun") {
                return "nessun risultato"
            }
            if let m = text.range(of: #"^Found (\d+)"#, options: .regularExpression) {
                let n = text[m].split(separator: " ").last.map(String.init) ?? ""
                return n == "1" ? "1 risultato" : "\(n) risultati"
            }
            return lines.count == 1 ? "1 risultato" : "\(lines.count) risultati"
        case "Read":
            return lines.isEmpty ? nil : "\(lines.count) righe"
        default:
            return nil
        }
    }

    /// One line, at most `max` characters (an ellipsis marks the cut), secrets redacted.
    public static func clip(_ s: String, _ max: Int = maxLength) -> String {
        oneLine(SecretFilter.redact(s), max)
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    static func file(_ path: String?) -> String {
        guard let p = path, !p.isEmpty else { return "un file" }
        let name = (p as NSString).lastPathComponent
        return name.isEmpty ? p : name
    }

    static func domain(_ url: String?) -> String {
        guard let u = url, !u.isEmpty else { return "una pagina" }
        if let host = URL(string: u)?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return oneLine(u, 40)
    }

    /// First words of a command, without paths that would fill the line ("git status", "npm run build").
    static func commandGist(_ cmd: String) -> String {
        let firstLine = cmd.split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd
        // `cd somewhere && real command`: the real command is what matters.
        let parts = firstLine.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        let main = parts.first(where: { !$0.hasPrefix("cd ") }) ?? parts.first ?? firstLine
        let words = main.split(separator: " ").prefix(3).map { w -> String in
            w.contains("/") && w.count > 20 ? (String(w) as NSString).lastPathComponent : String(w)
        }
        return oneLine(words.joined(separator: " "), 40)
    }

    static func browserAction(_ action: String, input: [String: Any]) -> String {
        switch action {
        case "navigate": return "apro " + domain((input["url"] as? String).map { SecretFilter.redact($0) })
        case "computer": return "clic e digitazione"
        case "read_page", "get_page_text": return "leggo la pagina"
        case "find": return "cerco" + ((input["query"] as? String).map { " «\(oneLine(SecretFilter.redact($0), 40))»" } ?? " nella pagina")
        case "form_input": return "compilo un modulo"
        case "tabs_create_mcp": return "nuova scheda"
        case "tabs_context_mcp": return "guardo le schede aperte"
        case "javascript_tool": return "eseguo uno script nella pagina"
        default: return action.replacingOccurrences(of: "_mcp", with: "").replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Thinking text arrives in many tiny deltas: the feed sends it at most every `interval`, as the redacted tail
/// of everything thought so far (a secret split across deltas is still caught, since the whole text is filtered).
public struct ThinkingThrottle: Sendable {
    public let interval: TimeInterval
    public let tailLength: Int
    public private(set) var text = ""
    private var lastSent: Date?
    private var dirty = false

    public init(interval: TimeInterval = 0.3, tailLength: Int = 600) {
        self.interval = interval
        self.tailLength = tailLength
    }

    /// Adds a delta; returns what to send now, or nil while inside the interval (or nothing new).
    public mutating func push(_ delta: String, now: Date = Date()) -> String? {
        guard !delta.isEmpty else { return nil }
        text += delta
        // Only the recent part matters (and is filtered): keeps redaction cheap on long thoughts.
        if text.count > 4000 { text = String(text.suffix(3000)) }
        dirty = true
        if let last = lastSent, now.timeIntervalSince(last) < interval { return nil }
        return take(now)
    }

    /// Whatever is still pending (thinking block over).
    public mutating func flush(now: Date = Date()) -> String? {
        dirty ? take(now) : nil
    }

    public mutating func reset() {
        text = ""
        dirty = false
        lastSent = nil
    }

    private mutating func take(_ now: Date) -> String {
        lastSent = now
        dirty = false
        let clean = SecretFilter.redact(text)
        return clean.count > tailLength ? "…" + String(clean.suffix(tailLength)) : clean
    }
}

/// The live feed of one conversation turn: phases ("capisco" → "penso" → "strumenti" → "rispondo" → "fine"),
/// a line per Claude Code tool (Elio's own tools are reported by the server, which sees their arguments),
/// and the thinking text when the session shows it.
struct TurnFeed {
    let requestId: String
    let send: (ServerMessage) -> Void
    let start = Date()
    private(set) var phase: String?
    private var thinking = ThinkingThrottle()
    private var tools: [String: (name: String, at: Date)] = [:]

    init(requestId: String, send: @escaping (ServerMessage) -> Void) {
        self.requestId = requestId
        self.send = send
    }

    private var elapsed: Int { Int(Date().timeIntervalSince(start) * 1000) }

    mutating func setPhase(_ p: String) {
        guard p != phase else { return }
        phase = p
        send(ServerMessage(type: .event, id: requestId, text: p, latencyMs: elapsed, kind: "phase"))
    }

    mutating func handle(_ event: ClaudeEvent) {
        switch event {
        case .thinking(let delta):
            setPhase("penso")
            if let tail = thinking.push(delta) { sendThinking(tail) }
        case .delta:
            flushThinking()
            setPhase("rispondo")
        case .toolCall(let name, let id, let input):
            flushThinking()
            setPhase("strumenti")
            guard !name.hasPrefix("mcp__elio__") else { return }
            if tools[id] == nil { tools[id] = (name, Date()) }
            // Start: a provisional line while Claude writes the input; then the precise one.
            let text = input.map { ActivityText.describe(tool: name, inputJSON: $0) }
                ?? ActivityText.describe(tool: name, input: [:])
            send(Self.activity(id: id, tool: name, text: text, phase: "start"))
        case .toolResult(let id, let text, let isError):
            if let t = tools.removeValue(forKey: id) {
                let ms = Int(Date().timeIntervalSince(t.at) * 1000)
                send(Self.activity(id: id, tool: t.name, text: ActivityText.outcome(tool: t.name, result: text, isError: isError) ?? "",
                                   phase: "end", ok: !isError, ms: ms))
            }
            // Results are back: Claude reads them and decides what to do next.
            if tools.isEmpty { setPhase("penso") }
        case .tool, .done:
            break
        }
    }

    mutating func finish() {
        flushThinking()
        for (id, t) in tools {
            send(Self.activity(id: id, tool: t.name, text: "", phase: "end", ok: true, ms: Int(Date().timeIntervalSince(t.at) * 1000)))
        }
        tools = [:]
        setPhase("fine")
    }

    private mutating func flushThinking() {
        if let tail = thinking.flush() { sendThinking(tail) }
    }

    private func sendThinking(_ tail: String) {
        send(ServerMessage(type: .event, id: requestId, text: tail, kind: "thinking"))
    }

    /// `text` is the action on start, the outcome (may be empty) on end.
    static func activity(id: String, tool: String, text: String, phase: String, ok: Bool = true, ms: Int? = nil) -> ServerMessage {
        var payload: [String: Any] = ["id": id, "tool": tool, "text": text, "phase": phase, "ok": ok]
        if let ms { payload["ms"] = ms }
        let json = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) }
        return ServerMessage(type: .event, id: id, text: text, latencyMs: ms, kind: "activity", payload: json, isError: !ok)
    }
}

extension ServerMessage {
    /// Live activity line of one tool call (Elio's own tools, sent by the server).
    public static func activity(id: String, tool: String, text: String, phase: String, ok: Bool = true, ms: Int? = nil) -> ServerMessage {
        TurnFeed.activity(id: id, tool: tool, text: text, phase: phase, ok: ok, ms: ms)
    }
}
