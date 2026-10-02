import CryptoKit
import Foundation

/// Generic monitors: a trigger (schedule, Slack channel, HTTP check, command, webhook) and an action
/// (notify, or a background agent that investigates and reports). Cheap checks run without Claude;
/// an agent starts only when something actually happens. Configured by voice or in Settings.
public struct Watcher: Codable, Sendable, Identifiable {
    public enum TriggerKind: String, Codable, Sendable, CaseIterable { case schedule, slack, http, command, webhook }
    public enum ActionKind: String, Codable, Sendable { case notify, agent }

    public var id: String
    public var name: String
    public var enabled = true

    public var trigger: TriggerKind
    /// schedule/http/command: how often (minutes). schedule: alternatively fixed times.
    public var everyMinutes: Int?
    public var at: [String]?            // ["09:00", "18:30"]
    public var weekdaysOnly = false
    public var channel: String?         // slack: #channel (name or id)
    public var match: String?           // slack: regex on the text; http: text the page must contain
    public var url: String?             // http
    public var expectStatus: Int?       // http (default 2xx/3xx)
    public var command: String?         // command (zsh)
    public var fireOn: String?          // command: "failure" (default) or "change"
    public var secret: String?          // webhook

    public var action: ActionKind
    public var prompt: String?          // agent instructions (or the notification text for notify)
    public var directory: String?       // agent working folder
    public var cooldownMinutes = 30

    // State
    public var lastCheck: Date?
    public var lastFired: Date?
    public var lastResult: String?
    public var state: String?           // http up/down, command output hash, slack last ts, fired schedule slots
}

public actor WatcherEngine {
    public static let shared = WatcherEngine()
    static let file = ElioPaths.support.appendingPathComponent("watchers.json")

    private var watchers: [Watcher] = []
    private var tasks: TaskRunner?
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    private var running: Set<String> = []

    public func start(tasks: TaskRunner, broadcast: @escaping @Sendable (ServerMessage) -> Void) {
        self.tasks = tasks
        self.broadcast = broadcast
        watchers = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder.iso.decode([Watcher].self, from: $0) } ?? []
        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func save() {
        try? JSONEncoder.iso.encode(watchers).write(to: Self.file, options: .atomic)
        broadcast?(ServerMessage(type: .event, kind: "watchers", payload: watchers.jsonString()))
    }

    public func all() -> [Watcher] { watchers }

    public func upsert(_ w: Watcher) {
        if let i = watchers.firstIndex(where: { $0.id == w.id }) { watchers[i] = w } else { watchers.append(w) }
        save()
    }

    public func remove(_ id: String) { watchers.removeAll { $0.id == id }; save() }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let i = watchers.firstIndex(where: { $0.id == id }) else { return }
        watchers[i].enabled = on
        save()
    }

    public func find(_ idOrName: String) -> Watcher? {
        let q = idOrName.lowercased()
        return watchers.first { $0.id == idOrName } ?? watchers.first { $0.name.lowercased().contains(q) }
    }

    // MARK: Checks

    private func tick() async {
        let now = Date()
        for w in watchers where w.enabled && !running.contains(w.id) {
            guard isDue(w, now) else { continue }
            running.insert(w.id)
            let snapshot = w
            Task { await self.check(snapshot); await self.done(snapshot.id) }
        }
    }

    private func done(_ id: String) { running.remove(id) }

    private func isDue(_ w: Watcher, _ now: Date) -> Bool {
        if w.weekdaysOnly, Calendar.current.isDateInWeekend(now) { return false }
        switch w.trigger {
        case .webhook:
            return false
        case .schedule:
            if let times = w.at, !times.isEmpty {
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                let slot = "\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)-\(f.string(from: now))"
                return times.contains(f.string(from: now)) && w.state != slot
            }
            return elapsed(w.lastCheck, now) >= Double(max(1, w.everyMinutes ?? 60)) * 60
        case .slack:
            return elapsed(w.lastCheck, now) >= 55
        case .http, .command:
            return elapsed(w.lastCheck, now) >= Double(max(1, w.everyMinutes ?? 5)) * 60
        }
    }

    private func elapsed(_ d: Date?, _ now: Date) -> TimeInterval { d.map { now.timeIntervalSince($0) } ?? .infinity }

    private func update(_ id: String, _ change: (inout Watcher) -> Void) {
        guard let i = watchers.firstIndex(where: { $0.id == id }) else { return }
        change(&watchers[i])
        save()
    }

    func check(_ w: Watcher) async {
        let now = Date()
        switch w.trigger {
        case .schedule:
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let slot = "\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)-\(f.string(from: now))"
            update(w.id) { $0.lastCheck = now; if $0.at?.isEmpty == false { $0.state = slot } }
            await fire(w, context: "Esecuzione programmata (\(f.string(from: now))).", force: true)

        case .http:
            let (ok, detail) = await httpCheck(w)
            let wasDown = w.state == "down"
            update(w.id) { $0.lastCheck = now; $0.state = ok ? "up" : "down"; $0.lastResult = detail }
            if !ok && !wasDown {
                await fire(w, context: "Il controllo di \(w.url ?? "") è fallito: \(detail).")
            } else if ok && wasDown {
                notify(w, "\(w.name): di nuovo raggiungibile (\(detail)).")
            }

        case .command:
            let (code, out) = runCommand(w.command ?? "")
            let hash = SHA256.hash(data: Data(out.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            let changed = w.state != nil && w.state != String(hash)
            update(w.id) { $0.lastCheck = now; $0.state = String(hash); $0.lastResult = "exit \(code): \(out.prefix(200))" }
            if (w.fireOn ?? "failure") == "change" ? changed : code != 0 {
                await fire(w, context: "Il comando `\(w.command ?? "")` \(code != 0 ? "è fallito (exit \(code))" : "ha cambiato output"):\n\(out.prefix(1500))")
            }

        case .slack:
            await slackCheck(w)

        case .webhook:
            break
        }
    }

    func httpCheck(_ w: Watcher) async -> (Bool, String) {
        guard let s = w.url, let url = URL(string: s) else { return (false, "URL non valido") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Elio-monitor/1.0", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let statusOK = w.expectStatus.map { $0 == code } ?? (200..<400).contains(code)
            let textOK = w.match.map { String(decoding: data.prefix(500_000), as: UTF8.self).contains($0) } ?? true
            return (statusOK && textOK, "HTTP \(code) in \(ms) ms\(textOK ? "" : ", testo atteso assente")")
        } catch {
            return (false, "nessuna risposta (\(error.localizedDescription))")
        }
    }

    func runCommand(_ cmd: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (127, "\(error)") }
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return (124, "timeout") }
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func slackCheck(_ w: Watcher) async {
        let now = Date()
        guard let raw = w.channel, let channel = try? await SlackAPI.shared.channelId(raw.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) else {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "canale non trovato" }
            return
        }
        // First run: start from now (don't replay history).
        let oldest = w.state ?? String(now.timeIntervalSince1970)
        guard let r = try? await SlackAPI.shared.call("conversations.history", ["channel": channel, "oldest": oldest, "limit": "50"]),
              r["ok"] as? Bool == true else {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Slack non leggibile" }
            return
        }
        let msgs = (r["messages"] as? [[String: Any]] ?? []).sorted { ($0["ts"] as? String ?? "") < ($1["ts"] as? String ?? "") }
        let newest = msgs.last?["ts"] as? String ?? oldest
        update(w.id) { $0.lastCheck = now; $0.state = newest; $0.lastResult = "\(msgs.count) messaggi nuovi" }
        let texts = msgs.map { m -> String in
            // Bots (Uptime Kuma, alerts) often put the content in attachments/blocks.
            var t = m["text"] as? String ?? ""
            for a in m["attachments"] as? [[String: Any]] ?? [] {
                t += " " + [a["title"], a["text"], a["fallback"]].compactMap { $0 as? String }.joined(separator: " ")
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let hits = texts.filter { t in
            guard let re = w.match, !re.isEmpty else { return true }
            return t.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard !hits.isEmpty else { return }
        await fire(w, context: "Nuovi messaggi in \(raw) che corrispondono al filtro:\n" + hits.prefix(10).map { "- \($0.prefix(500))" }.joined(separator: "\n"))
    }

    /// Webhook call (POST /hook/<id>?key=<secret>): the body is the event.
    public func webhook(id: String, key: String, body: String) async -> Bool {
        guard let w = watchers.first(where: { $0.id == id && $0.trigger == .webhook }), w.enabled,
              let secret = w.secret, !secret.isEmpty, key == secret else { return false }
        update(w.id) { $0.lastCheck = Date(); $0.lastResult = "webhook ricevuto" }
        await fire(w, context: "Webhook ricevuto:\n\(SecretFilter.redact(String(body.prefix(4000))))")
        return true
    }

    public func runNow(_ id: String) async -> String {
        guard let w = watchers.first(where: { $0.id == id }) else { return "Monitor non trovato." }
        if w.trigger == .schedule || w.trigger == .webhook {
            await fire(w, context: "Esecuzione manuale.", force: true)
            return "Avviato \(w.name)."
        }
        update(w.id) { $0.lastCheck = nil }
        await check(w)
        return "Controllato \(w.name): \(watchers.first { $0.id == id }?.lastResult ?? "")."
    }

    // MARK: Actions

    func fire(_ w: Watcher, context: String, force: Bool = false) async {
        if !force, let last = w.lastFired, Date().timeIntervalSince(last) < Double(w.cooldownMinutes) * 60 { return }
        update(w.id) { $0.lastFired = Date() }
        switch w.action {
        case .notify:
            let text = [w.prompt, context].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            notify(w, "\(w.name): \(text.prefix(300))")
        case .agent:
            guard let tasks else { return }
            let dir = expandPath(w.directory ?? "~")
            let prompt = """
            Monitor "\(w.name)".
            Evento:
            \(context)

            Cosa fare: \(w.prompt ?? "Analizza l'evento e riferisci.")

            Lavori in background: niente domande se non indispensabili. Usa le integrazioni e il browser se servono.
            Alla fine scrivi un report: prima due frasi parlate per Raffaele (cosa è successo, gravità, cosa consigli), \
            poi i dettagli. Se non c'è nulla di rilevante, dillo in una frase.
            """
            do {
                _ = try await tasks.start(title: "Monitor: \(w.name)", prompt: prompt, cwd: dir, kind: .mac)
                notify(w, "\(w.name): ho rilevato qualcosa, sto analizzando.", speak: false)
            } catch {
                notify(w, "\(w.name): non sono riuscito ad avviare l'analisi.")
            }
        }
    }

    private func notify(_ w: Watcher, _ text: String, speak: Bool = true) {
        broadcast?(ServerMessage(type: .event, text: text, lang: .it, kind: "watch", speak: speak))
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

// MARK: - Tools

public enum WatcherTools {
    static let create = ElioTool(
        name: "watch_create",
        description: """
        Crea (o aggiorna, se passi id) un monitor. trigger: schedule (every_minutes oppure at "09:00,18:00"), \
        slack (channel + match regex opzionale: nuovi messaggi, anche dai bot come Uptime Kuma), http (url, expect_status, \
        match = testo atteso, every_minutes), command (comando zsh; fire_on failure|change; every_minutes), \
        webhook (restituisce l'URL da chiamare). action: notify (avviso a voce/telefono) oppure agent (un agente in \
        background esegue prompt e fa un report). Esempio Kuma: trigger slack, channel kuma-ops, match "down|🔴", action \
        agent, prompt "analizza su Cloudflare il sito coinvolto e fammi un report".
        """,
        properties: [
            "id": prop("Id esistente da aggiornare (opzionale)"), "name": prop("Nome breve"),
            "trigger": prop("schedule, slack, http, command o webhook"),
            "every_minutes": prop("Ogni quanti minuti", type: "integer"), "at": prop("Orari fissi HH:mm separati da virgola"),
            "weekdays_only": prop("Solo giorni feriali", type: "boolean"),
            "channel": prop("Canale Slack"), "match": prop("Regex sui messaggi Slack / testo atteso nella pagina"),
            "url": prop("URL da controllare"), "expect_status": prop("Codice HTTP atteso", type: "integer"),
            "command": prop("Comando shell"), "fire_on": prop("failure o change"),
            "action": prop("notify o agent"), "prompt": prop("Istruzioni per l'agente (o testo dell'avviso)"),
            "directory": prop("Cartella di lavoro dell'agente"), "cooldown_minutes": prop("Pausa minima tra due allarmi", type: "integer"),
        ],
        required: ["name", "trigger", "action"]
    ) { args, ctx in
        guard let trigger = Watcher.TriggerKind(rawValue: args["trigger"] as? String ?? ""),
              let action = Watcher.ActionKind(rawValue: args["action"] as? String ?? "") else {
            throw ToolError("trigger o action non validi")
        }
        var existing: Watcher?
        if let id = args["id"] as? String, !id.isEmpty { existing = await WatcherEngine.shared.find(id) }
        var w = existing ?? Watcher(id: String(UUID().uuidString.prefix(8)).lowercased(), name: "", trigger: trigger, action: action)
        w.name = args["name"] as? String ?? w.name
        w.trigger = trigger
        w.action = action
        if let v = args["every_minutes"] as? Int { w.everyMinutes = v }
        if let v = args["at"] as? String { w.at = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let v = args["weekdays_only"] as? Bool { w.weekdaysOnly = v }
        if let v = args["channel"] as? String { w.channel = v }
        if let v = args["match"] as? String { w.match = v }
        if let v = args["url"] as? String { w.url = v }
        if let v = args["expect_status"] as? Int { w.expectStatus = v }
        if let v = args["command"] as? String { w.command = v }
        if let v = args["fire_on"] as? String { w.fireOn = v }
        if let v = args["prompt"] as? String { w.prompt = v }
        if let v = args["directory"] as? String { w.directory = v }
        if let v = args["cooldown_minutes"] as? Int { w.cooldownMinutes = v }
        if trigger == .webhook, w.secret == nil { w.secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        // A command runs on the Mac by itself, over and over: the user approves it once, explicitly.
        if trigger == .command, let cmd = w.command {
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: "Creo un monitor che esegue un comando ogni \(w.everyMinutes ?? 5) minuti",
                                                           detail: cmd, risk: .dangerous, taskId: nil), timeout: 180)
            guard ok else { return "Monitor non creato: l'utente non ha confermato il comando." }
        }
        await WatcherEngine.shared.upsert(w)
        var out = "Monitor \"\(w.name)\" (id \(w.id)) attivo."
        if trigger == .webhook {
            let host = PhoneSetup.hostname().map { "https://\($0)" } ?? "http://127.0.0.1:\(ctx.config.webPort)"
            out += " URL da chiamare (POST): \(host)/hook/\(w.id)?key=⟦\(w.secret!)⟧ — raggiungibile dal tailnet; per servizi esterni serve Tailscale Funnel."
        }
        return out
    }

    static let list = ElioTool(
        name: "watch_list",
        description: "Elenca i monitor con stato e ultimo risultato.",
        properties: [:]
    ) { _, _ in
        let all = await WatcherEngine.shared.all()
        guard !all.isEmpty else { return "Nessun monitor." }
        let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"
        return all.map { w in
            "- \(w.name) (id \(w.id)) [\(w.enabled ? "attivo" : "in pausa")] \(w.trigger.rawValue) → \(w.action.rawValue); " +
            "ultimo controllo \(w.lastCheck.map(f.string) ?? "mai"), ultimo allarme \(w.lastFired.map(f.string) ?? "mai"): \(w.lastResult ?? "")"
        }.joined(separator: "\n")
    }

    static let listJSON = ElioTool(
        name: "watch_list_json",
        description: "Uso interno (Impostazioni): i monitor in JSON.",
        properties: [:]
    ) { _, _ in await WatcherEngine.shared.all().jsonString() }

    static let control = ElioTool(
        name: "watch_control",
        description: "Gestisce un monitor: action = pause, resume, delete, run (esegue subito).",
        properties: ["id": prop("Id o nome del monitor"), "action": prop("pause, resume, delete o run")],
        required: ["id", "action"]
    ) { args, _ in
        guard let w = await WatcherEngine.shared.find(args["id"] as? String ?? "") else { throw ToolError("Monitor non trovato") }
        switch args["action"] as? String ?? "" {
        case "pause": await WatcherEngine.shared.setEnabled(w.id, false); return "\(w.name) in pausa."
        case "resume": await WatcherEngine.shared.setEnabled(w.id, true); return "\(w.name) riattivato."
        case "delete": await WatcherEngine.shared.remove(w.id); return "\(w.name) eliminato."
        case "run": return await WatcherEngine.shared.runNow(w.id)
        default: throw ToolError("Azione non valida")
        }
    }
}
