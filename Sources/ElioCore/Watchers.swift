import CryptoKit
import Foundation

/// Generic monitors: a trigger (schedule, Slack channel, HTTP check, command, webhook, what's on screen,
/// the Mac's audio, new mail, a process exiting, a file landing, a CI pipeline) and an action (tell the
/// user, or a background agent that investigates and reports). Cheap checks run without Claude;
/// an agent starts only when something actually happens. Configured by voice or in Settings.
public struct Watcher: Codable, Sendable, Identifiable, Equatable {
    public enum TriggerKind: String, Codable, Sendable, CaseIterable {
        case schedule, slack, http, command, webhook, screen, audio, mail, process, file, pipeline
    }
    public enum ActionKind: String, Codable, Sendable { case notify, agent }

    public var id: String
    public var name: String
    public var enabled = true

    public var trigger: TriggerKind
    /// schedule/http/command/mail: how often (minutes). schedule: alternatively fixed times.
    public var everyMinutes: Int?
    public var at: [String]?            // ["09:00", "18:30"]
    public var weekdaysOnly = false
    public var channel: String?         // slack: #channel (name or id)
    /// slack/screen/command/process: regex; http: text the page must contain (down) or regex (match).
    public var match: String?
    public var url: String?             // http; pipeline: a GitHub Actions run URL
    public var expectStatus: Int?       // http (default 2xx/3xx)
    public var command: String?         // command (zsh)
    /// command: failure (default), change, success, match · http: down (default), up, change, match ·
    /// screen/file: appear (default), disappear, change · audio: sound (default), silence.
    public var fireOn: String?
    public var secret: String?          // webhook

    /// How loudly to tell the user (message, notify, call), and whether they want it on the phone anyway.
    public var urgency: Urgency = .notify
    public var phone = false
    /// Fires once, then pauses itself ("tell me when…").
    public var once = false
    /// Fast sensors (screen, process, file, pipeline): seconds between checks; minutes are too coarse.
    public var everySeconds: Int?
    public var app: String?             // screen: whose window to read · audio: whose sound to hear
    public var ask: String?             // screen: yes/no question about the screenshot, for Claude
    public var path: String?            // file: path or glob (~/Downloads/*.zip)
    public var repo: String?            // pipeline: owner/repo
    public var branch: String?          // pipeline
    public var query: String?           // mail: Gmail search syntax
    public var account: String?         // mail
    public var silenceSeconds: Int?     // audio: how much silence counts (pause before sound / call over)

    public var action: ActionKind
    public var prompt: String?          // agent instructions (or the notification text for notify)
    public var directory: String?       // agent working folder
    public var cooldownMinutes = 30

    // State
    public var lastCheck: Date?
    public var lastFired: Date?
    public var lastResult: String?
    /// http up/down, command output hash, slack last ts, fired schedule slots, sensor phase…
    public var state: String?
    /// mail: message ids already seen · file: files already there (bounded).
    public var seen: [String]?
}

extension Watcher {
    /// Every field after the first few is optional on disk: older watchers.json files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try c.decode(TriggerKind.self, forKey: .trigger)
        everyMinutes = try c.decodeIfPresent(Int.self, forKey: .everyMinutes)
        at = try c.decodeIfPresent([String].self, forKey: .at)
        weekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? false
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        match = try c.decodeIfPresent(String.self, forKey: .match)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        expectStatus = try c.decodeIfPresent(Int.self, forKey: .expectStatus)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        fireOn = try c.decodeIfPresent(String.self, forKey: .fireOn)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        urgency = (try? c.decodeIfPresent(Urgency.self, forKey: .urgency)) ?? .notify
        phone = try c.decodeIfPresent(Bool.self, forKey: .phone) ?? false
        once = try c.decodeIfPresent(Bool.self, forKey: .once) ?? false
        everySeconds = try c.decodeIfPresent(Int.self, forKey: .everySeconds)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        ask = try c.decodeIfPresent(String.self, forKey: .ask)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        silenceSeconds = try c.decodeIfPresent(Int.self, forKey: .silenceSeconds)
        action = try c.decodeIfPresent(ActionKind.self, forKey: .action) ?? .notify
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        cooldownMinutes = try c.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? 30
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        lastFired = try c.decodeIfPresent(Date.self, forKey: .lastFired)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        seen = try c.decodeIfPresent([String].self, forKey: .seen)
    }

    /// Seconds between checks; nil for event-driven triggers (webhook, audio).
    var interval: TimeInterval? {
        let minutes = everyMinutes.map { Double(max(1, $0)) * 60 }
        let seconds = everySeconds.map { Double(max(2, $0)) }
        switch trigger {
        case .webhook, .audio: return nil
        case .schedule: return minutes ?? 3600
        case .slack: return 55
        case .http, .command: return seconds ?? minutes ?? 300
        case .screen: return seconds ?? 15
        case .process, .file: return seconds ?? 5
        case .pipeline: return seconds ?? minutes ?? 30
        case .mail: return seconds.map { max(30, $0) } ?? minutes ?? 120
        }
    }

    /// One line for lists (Italian): what it watches and how often.
    public var triggerSummary: String {
        let every: String = {
            if let s = everySeconds { return "ogni \(s) s" }
            if let m = everyMinutes { return "ogni \(m) min" }
            return ""
        }()
        let on = fireOn.map { " (\($0))" } ?? ""
        let text: String = switch trigger {
        case .schedule: at?.isEmpty == false ? "alle \(at!.joined(separator: ", "))" : "ogni \(everyMinutes ?? 60) min"
        case .slack: "Slack \(channel ?? "")\(match.map { " /\($0)/" } ?? "")"
        case .http: "\(url ?? "")\(on) \(every.isEmpty ? "ogni \(everyMinutes ?? 5) min" : every)"
        case .command: "comando\(on) \(every.isEmpty ? "ogni \(everyMinutes ?? 5) min" : every)"
        case .webhook: "webhook"
        case .screen: "schermo\(app.map { " di \($0)" } ?? "")\(ask.map { " «\($0)»" } ?? match.map { " /\($0)/" } ?? "")\(on)"
        case .audio: "audio\(app.map { " di \($0)" } ?? "")\(fireOn == "silence" ? " → silenzio" : " → torna il suono")"
        case .mail: "mail\(query.map { " «\($0)»" } ?? "")\(account.map { " (\($0))" } ?? "")"
        case .process: "fine del processo /\(match ?? "")/"
        case .file: "file \(path ?? "")\(on)"
        case .pipeline: "pipeline \(repo ?? url ?? "")\(branch.map { " su \($0)" } ?? "")"
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    public var urgencyLabel: String {
        switch urgency {
        case .message: "messaggio"
        case .notify: "avviso"
        case .call: "chiamata"
        }
    }
}

public actor WatcherEngine {
    public static let shared = WatcherEngine()
    static let file = ElioPaths.support.appendingPathComponent("watchers.json")

    var watchers: [Watcher] = []
    private var tasks: TaskRunner?
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    private var running: Set<String> = []
    /// Unsaved changes that only touch lastCheck: written at most once a minute.
    private var dirty = false
    private var lastSave = Date.distantPast
    /// In-memory sensor state that doesn't need to survive a restart (last OCR text, file sizes…).
    var scratch: [String: SensorScratch] = [:]
    var audio: [String: AudioSensor] = [:]

    public func start(tasks: TaskRunner, broadcast: @escaping @Sendable (ServerMessage) -> Void) {
        self.tasks = tasks
        self.broadcast = broadcast
        watchers = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder.iso.decode([Watcher].self, from: $0) } ?? []
        reconcileSensors()
        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(nextWake()))
            }
        }
    }

    private func save() {
        try? JSONEncoder.iso.encode(watchers).write(to: Self.file, options: .atomic)
        dirty = false
        lastSave = Date()
        broadcast?(ServerMessage(type: .event, kind: "watchers", payload: watchers.jsonString()))
    }

    public func all() -> [Watcher] { watchers }

    public func upsert(_ w: Watcher) {
        if let i = watchers.firstIndex(where: { $0.id == w.id }) { watchers[i] = w } else { watchers.append(w) }
        scratch[w.id] = nil
        save()
        reconcileSensors()
    }

    public func remove(_ id: String) {
        watchers.removeAll { $0.id == id }
        scratch[id] = nil
        save()
        reconcileSensors()
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let i = watchers.firstIndex(where: { $0.id == id }) else { return }
        watchers[i].enabled = on
        // A one-shot monitor that already fired starts over when resumed.
        if on, watchers[i].once { watchers[i].state = nil; watchers[i].seen = nil; scratch[id] = nil }
        save()
        reconcileSensors()
    }

    public func find(_ idOrName: String) -> Watcher? {
        let q = idOrName.lowercased()
        return watchers.first { $0.id == idOrName } ?? watchers.first { $0.name.lowercased().contains(q) }
    }

    // MARK: Checks

    private func tick() async {
        if dirty, Date().timeIntervalSince(lastSave) > 60 { save() }
        let now = Date()
        for w in watchers where w.enabled && !running.contains(w.id) {
            guard isDue(w, now) else { continue }
            running.insert(w.id)
            let snapshot = w
            Task { await self.check(snapshot); await self.done(snapshot.id) }
        }
    }

    private func done(_ id: String) { running.remove(id) }

    /// Sleeps until the next check is due (fast sensors need seconds, not the old 30 s beat), 2–30 s.
    private func nextWake() -> Double {
        let now = Date()
        var wait = 30.0
        for w in watchers where w.enabled && !running.contains(w.id) {
            guard w.trigger != .schedule, let iv = w.interval else { continue }
            wait = min(wait, iv - elapsed(w.lastCheck, now))
        }
        return max(2, wait)
    }

    private func isDue(_ w: Watcher, _ now: Date) -> Bool {
        if w.weekdaysOnly, Calendar.current.isDateInWeekend(now) { return false }
        if w.trigger == .schedule, let times = w.at, !times.isEmpty {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let slot = "\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)-\(f.string(from: now))"
            return times.contains(f.string(from: now)) && w.state != slot
        }
        guard let iv = w.interval else { return false }
        return elapsed(w.lastCheck, now) >= iv - 0.5
    }

    private func elapsed(_ d: Date?, _ now: Date) -> TimeInterval { d.map { now.timeIntervalSince($0) } ?? .infinity }

    /// Saves right away when something meaningful changed; a bare lastCheck bump waits (fast sensors
    /// would otherwise rewrite the file and broadcast the list every few seconds).
    func update(_ id: String, _ change: (inout Watcher) -> Void) {
        guard let i = watchers.firstIndex(where: { $0.id == id }) else { return }
        var before = watchers[i]
        change(&watchers[i])
        before.lastCheck = watchers[i].lastCheck
        if before == watchers[i] { dirty = true } else { save() }
    }

    func current(_ id: String) -> Watcher? { watchers.first { $0.id == id } }

    func check(_ w: Watcher) async {
        let now = Date()
        switch w.trigger {
        case .schedule:
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let slot = "\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)-\(f.string(from: now))"
            update(w.id) { $0.lastCheck = now; if $0.at?.isEmpty == false { $0.state = slot } }
            // A reminder with its own text says just that; an agent gets the context.
            let plain = w.action == .notify && !(w.prompt ?? "").isEmpty
            await fire(w, headline: "", detail: plain ? "" : "Esecuzione programmata (\(f.string(from: now))).", force: true)

        case .http:
            let r = await httpCheck(w)
            let d = WatchRules.http(fireOn: w.fireOn, ok: r.ok, matched: r.matched, hash: r.hash, previous: w.state)
            update(w.id) { $0.lastCheck = now; $0.state = d.state; $0.lastResult = r.detail }
            let site = w.url ?? ""
            if d.recovered {
                await say(w, "\(w.name) è di nuovo raggiungibile.", detail: "\(site): \(r.detail)")
            } else if d.fire {
                switch w.fireOn ?? "down" {
                case "up": await fire(w, headline: "\(w.name) è di nuovo raggiungibile.", detail: "\(site): \(r.detail)")
                case "change": await fire(w, headline: "La pagina di \(w.name) è cambiata.", detail: site)
                case "match": await fire(w, headline: "Nella pagina di \(w.name) è comparso quello che aspettavi.", detail: site)
                default: await fire(w, headline: "\(w.name) non risponde.", detail: "Il controllo di \(site) è fallito: \(r.detail).")
                }
            }

        case .command:
            let cmd = w.command ?? ""
            let (code, out) = await Task.detached { WatcherEngine.runCommand(cmd) }.value
            let hash = SHA256.hash(data: Data(out.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            let matched = WatchRules.regexMatches(w.match, out)
            let d = WatchRules.command(fireOn: w.fireOn, code: code, hash: String(hash), matched: matched, previous: w.state)
            update(w.id) { $0.lastCheck = now; $0.state = d.state; $0.lastResult = "exit \(code): \(out.prefix(200))" }
            guard d.fire else { break }
            let headline: String = switch w.fireOn ?? "failure" {
            case "change": "L'output del comando di \(w.name) è cambiato."
            case "success": "Il comando di \(w.name) ora riesce."
            case "match": "Nell'output del comando di \(w.name) è comparso quello che aspettavi."
            default: "Il comando di \(w.name) è fallito."
            }
            await fire(w, headline: headline, detail: "`\(cmd)` exit \(code):\n\(out.prefix(1500))")

        case .slack:
            await slackCheck(w)

        case .screen: await screenCheck(w)
        case .mail: await mailCheck(w)
        case .process: await processCheck(w)
        case .file: await fileCheck(w)
        case .pipeline: await pipelineCheck(w)
        case .webhook, .audio:
            break
        }
    }

    struct HTTPResult { var ok: Bool; var matched: Bool; var hash: String?; var detail: String }

    func httpCheck(_ w: Watcher) async -> HTTPResult {
        guard let s = w.url, let url = URL(string: s) else { return HTTPResult(ok: false, matched: false, detail: "URL non valido") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Elio-monitor/1.0", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let body = String(decoding: data.prefix(500_000), as: UTF8.self)
            let statusOK = w.expectStatus.map { $0 == code } ?? (200..<400).contains(code)
            // "down" keeps the old meaning of match (literal text that must be there); "match" uses a regex.
            let mode = w.fireOn ?? "down"
            let textOK = mode == "down" ? (w.match.map { body.contains($0) } ?? true) : true
            let matched = statusOK && WatchRules.regexMatches(w.match, body)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
            var detail = "HTTP \(code) in \(ms) ms"
            if !textOK { detail += ", testo atteso assente" }
            if mode == "match" { detail += matched ? ", testo trovato" : ", testo non ancora presente" }
            return HTTPResult(ok: statusOK && textOK, matched: matched, hash: String(hash), detail: detail)
        } catch {
            return HTTPResult(ok: false, matched: false, detail: "nessuna risposta (\(error.localizedDescription))")
        }
    }

    /// Blocking: always call off the actor.
    static func runCommand(_ cmd: String, timeout: TimeInterval = 120) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (127, "\(error)") }
        // Read while it runs: a full pipe would block the command forever.
        let reader = DispatchQueue.global()
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        reader.async { box.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return (124, "timeout") }
        group.wait()
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
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
        await fire(w, headline: hits.count == 1 ? "Nuovo messaggio in \(raw)." : "\(hits.count) nuovi messaggi in \(raw).",
                   detail: hits.prefix(10).map { "- \($0.prefix(500))" }.joined(separator: "\n"))
    }

    /// Webhook call (POST /hook/<id>?key=<secret>): the body is the event.
    public func webhook(id: String, key: String, body: String) async -> Bool {
        guard let w = watchers.first(where: { $0.id == id && $0.trigger == .webhook }), w.enabled,
              let secret = w.secret, !secret.isEmpty, key == secret else { return false }
        update(w.id) { $0.lastCheck = Date(); $0.lastResult = "webhook ricevuto" }
        await fire(w, headline: "Evento ricevuto da \(w.name).", detail: SecretFilter.redact(String(body.prefix(4000))))
        return true
    }

    public func runNow(_ id: String) async -> String {
        guard let w = watchers.first(where: { $0.id == id }) else { return "Monitor non trovato." }
        switch w.trigger {
        case .schedule, .webhook:
            await fire(w, headline: "", detail: "Esecuzione manuale.", force: true)
            return "Avviato \(w.name)."
        case .audio:
            return "\(w.name) ascolta in continuo: \(w.lastResult ?? "in avvio")."
        default:
            update(w.id) { $0.lastCheck = nil }
            await check(w)
            return "Controllato \(w.name): \(watchers.first { $0.id == id }?.lastResult ?? "")."
        }
    }

    // MARK: Actions

    /// `headline`: one or two short spoken sentences; `detail`: what follows (URLs, output), not read first.
    /// Returns false when the cooldown swallowed it.
    @discardableResult
    func fire(_ w: Watcher, headline: String, detail: String = "", force: Bool = false) async -> Bool {
        let w = current(w.id) ?? w
        if !force, let last = w.lastFired, Date().timeIntervalSince(last) < Double(w.cooldownMinutes) * 60 { return false }
        update(w.id) { $0.lastFired = Date() }
        switch w.action {
        case .notify:
            let lead = [w.prompt, headline].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let first = lead.isEmpty ? "\(w.name): \(detail.prefix(300))" : lead
            let rest = lead.isEmpty || detail.isEmpty ? "" : "\n\(detail.prefix(300))"
            await say(w, first, detail: rest)
        case .agent:
            guard let tasks else { return true }
            let dir = expandPath(w.directory ?? "~")
            let prompt = """
            Monitor "\(w.name)".
            Evento:
            \([headline, detail].filter { !$0.isEmpty }.joined(separator: "\n"))

            Cosa fare: \(w.prompt ?? "Analizza l'evento e riferisci.")

            Lavori in background: niente domande se non indispensabili. Usa le integrazioni e il browser se servono.
            Alla fine scrivi un report: prima due frasi parlate per l'utente (cosa è successo, gravità, cosa consigli), \
            poi i dettagli. Se non c'è nulla di rilevante, dillo in una frase.
            """
            do {
                _ = try await tasks.start(title: "Monitor: \(w.name)", prompt: prompt, cwd: dir, kind: .mac)
                await Alerts.shared.send("\(w.name): ho rilevato qualcosa, sto analizzando.", title: w.name,
                                         urgency: w.urgency == .call ? .call : .message, source: "monitor:\(w.id)", phone: w.phone)
            } catch {
                await say(w, "\(w.name): non sono riuscito ad avviare l'analisi.")
            }
        }
        if w.once { finish(w.id, headline.isEmpty ? detail : headline) }
        return true
    }

    /// A one-shot monitor did its job: it stays in the list, paused, saying it fired.
    private func finish(_ id: String, _ what: String) {
        let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"
        update(id) {
            $0.enabled = false
            $0.lastResult = "Scattato il \(f.string(from: Date())): \(what.prefix(160)) Completato, ora in pausa."
        }
        scratch[id] = nil
        reconcileSensors()
    }

    func say(_ w: Watcher, _ text: String, detail: String = "") async {
        let body = detail.isEmpty ? text : "\(text)\n\(detail.trimmingCharacters(in: .newlines))"
        await Alerts.shared.send(body, title: w.name, urgency: w.urgency, source: "monitor:\(w.id)", phone: w.phone)
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

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
        Crea (o aggiorna, se passi id) un monitor che tiene d'occhio qualcosa e avvisa quando succede. trigger:
        - schedule: every_minutes oppure at "09:00,18:00".
        - slack: channel + match regex opzionale (nuovi messaggi, anche dai bot come Uptime Kuma).
        - http: url; fire_on down (default: smette di rispondere), up (torna raggiungibile), change (la pagina cambia), \
        match (compare il testo/regex match); expect_status; every_minutes o every_seconds.
        - command: comando zsh; fire_on failure (default), change, success (exit 0: "aspetta finché…"), match (output \
        corrisponde a match). Per GitLab: command con glab. Chiede conferma all'utente.
        - screen: legge lo schermo (o la finestra di app) con l'OCR ogni every_seconds (default 15). match = regex sul \
        testo; fire_on appear (default), disappear (es. "Rendering", "Elaborazione" sparisce), change. Se non c'è un \
        testo da cercare usa ask: domanda sì/no sullo screenshot (es. "la barra di avanzamento è completa?").
        - audio: l'audio del Mac. fire_on sound (default: dopo almeno silence_seconds di silenzio, default 20, torna il \
        suono: fine della pausa di un meeting) o silence (silenzio per silence_seconds, default 30: la chiamata è finita). \
        app opzionale; per Meet nel browser di solito non serve.
        - mail: nuove mail che corrispondono a query (sintassi Gmail, es. from:mario@x.it subject:fattura); account opzionale. \
        Le mail già presenti vengono ignorate.
        - process: match = regex sul nome o sulla riga di comando; avvisa quando il processo termina (build, export, script lunghi).
        - file: path (anche glob, ~/Downloads/*.zip); fire_on appear (default: il file c'è ed è completo, cioè un download \
        finito), change, disappear.
        - pipeline: CI su GitHub Actions via gh. url di una run, oppure repo (owner/repo o cartella locale) + branch: \
        avvisa quando la run finisce, con l'esito.
        - webhook: restituisce l'URL da chiamare.
        action: notify (avvisa) oppure agent (un agente in background esegue prompt e fa un report). prompt con notify = \
        frase da dire quando scatta (es. "La pausa del Meet è finita").
        urgency: call quando l'utente dice "chiamami", "avvisami subito" o per la fine di una pausa/meeting; message per \
        cose poco importanti (finiscono nei messaggi sul telefono); notify altrimenti (default). phone=true se chiede \
        di saperlo sul telefono. once: scatta una volta e si mette in pausa (default sì per screen, audio, mail, process, \
        file, pipeline, http up/match, command success/match).
        Esempi: "chiamami quando finisce la pausa del Meet" → audio, fire_on sound, urgency call, prompt "La pausa del Meet \
        è finita". "dimmi quando finisce la pipeline di elio" → pipeline, repo. "avvisami quando arriva la mail di Mario" → \
        mail, query from:mario. "dimmi quando finisce il render" → screen, app "Final Cut Pro", match "Rendering", fire_on \
        disappear (oppure ask). "avvisami quando finisce il download" → file, path ~/Downloads/*. "dimmi quando il sito torna \
        su" → http, fire_on up, every_seconds 30. Kuma: slack, channel kuma-ops, match "down|🔴", action agent.
        """,
        properties: [
            "id": prop("Id esistente da aggiornare (opzionale)"), "name": prop("Nome breve"),
            "trigger": prop("schedule, slack, http, command, webhook, screen, audio, mail, process, file o pipeline"),
            "every_minutes": prop("Ogni quanti minuti", type: "integer"),
            "every_seconds": prop("Ogni quanti secondi (sensori veloci: screen, process, file, pipeline, http)", type: "integer"),
            "at": prop("Orari fissi HH:mm separati da virgola"),
            "weekdays_only": prop("Solo giorni feriali", type: "boolean"),
            "channel": prop("Canale Slack"),
            "match": prop("Regex: messaggi Slack, testo sullo schermo, output del comando, nome del processo; http: testo atteso"),
            "url": prop("URL da controllare (http) o della run GitHub Actions (pipeline)"),
            "expect_status": prop("Codice HTTP atteso", type: "integer"),
            "command": prop("Comando shell"),
            "fire_on": prop("Quando scatta: failure|change|success|match (command), down|up|change|match (http), appear|disappear|change (screen, file), sound|silence (audio)"),
            "app": prop("screen: app di cui leggere la finestra; audio: app di cui ascoltare l'audio"),
            "ask": prop("screen: domanda sì/no sullo screenshot quando non c'è un testo da cercare"),
            "path": prop("file: percorso o glob, es. ~/Downloads/*.zip"),
            "repo": prop("pipeline: owner/repo o cartella locale del progetto"),
            "branch": prop("pipeline: branch (default: tutti, o quello attuale se repo è una cartella)"),
            "query": prop("mail: ricerca in sintassi Gmail, es. from:mario subject:contratto"),
            "account": prop("mail: account (indirizzo Gmail o \"mail\"); vuoto = tutti"),
            "silence_seconds": prop("audio: secondi di silenzio (default 20 per sound, 30 per silence)", type: "integer"),
            "urgency": prop("message, notify (default) o call"),
            "phone": prop("Avvisa anche sul telefono", type: "boolean"),
            "once": prop("Scatta una volta sola e poi va in pausa", type: "boolean"),
            "action": prop("notify o agent"), "prompt": prop("Istruzioni per l'agente (o frase dell'avviso)"),
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
        func str(_ key: String) -> String? {
            guard let v = args[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if let v = args["every_minutes"] as? Int { w.everyMinutes = v }
        if let v = args["every_seconds"] as? Int { w.everySeconds = v }
        if let v = str("at") { w.at = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let v = args["weekdays_only"] as? Bool { w.weekdaysOnly = v }
        if let v = str("channel") { w.channel = v }
        if let v = str("match") { w.match = v }
        if let v = str("url") { w.url = v }
        if let v = args["expect_status"] as? Int { w.expectStatus = v }
        if let v = str("command") { w.command = v }
        if let v = str("fire_on") { w.fireOn = v.lowercased() }
        if let v = str("app") { w.app = v }
        if let v = str("ask") { w.ask = v }
        if let v = str("path") { w.path = v }
        if let v = str("repo") { w.repo = v }
        if let v = str("branch") { w.branch = v }
        if let v = str("query") { w.query = v }
        if let v = str("account") { w.account = v }
        if let v = args["silence_seconds"] as? Int { w.silenceSeconds = v }
        if let v = str("urgency") {
            guard let u = Urgency(rawValue: v.lowercased()) else { throw ToolError("urgency: message, notify o call") }
            w.urgency = u
        }
        if let v = args["phone"] as? Bool { w.phone = v }
        if let v = str("prompt") { w.prompt = v }
        if let v = str("directory") { w.directory = v }
        if let v = args["cooldown_minutes"] as? Int { w.cooldownMinutes = v }
        if let v = args["once"] as? Bool { w.once = v } else if existing == nil { w.once = WatcherTools.defaultOnce(w) }
        if let r = regexError(w.match) { throw ToolError("match non è una regex valida: \(r)") }

        switch trigger {
        case .webhook:
            if w.secret == nil { w.secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        case .screen:
            guard w.match != nil || w.ask != nil else { throw ToolError("screen: manca il parametro match (testo da cercare) oppure ask (domanda sì/no sullo screenshot)") }
        case .process:
            guard w.match != nil else { throw ToolError("process: manca il parametro match (nome del processo o parte della riga di comando)") }
        case .file:
            guard w.path != nil else { throw ToolError("file: manca il parametro path (percorso o glob del file da controllare)") }
        case .pipeline:
            if let u = w.url, WatchRules.parseRunURL(u) == nil { throw ToolError("pipeline: url non è una run di GitHub Actions (…/actions/runs/<id>)") }
            if w.url == nil {
                guard let r = w.repo else { throw ToolError("pipeline: manca il parametro url (run di GitHub Actions) oppure repo (owner/repo o cartella)") }
                let (repo, branch) = await Task.detached { PipelineSensor.resolveRepo(r) }.value
                guard let repo else { throw ToolError("pipeline: non trovo un remote GitHub per \(r)") }
                w.repo = repo
                if w.branch == nil { w.branch = branch }
            }
        case .http:
            guard w.url != nil else { throw ToolError("http: manca il parametro url") }
        default:
            break
        }
        // Re-baseline an updated monitor: the old state may belong to another configuration.
        if existing != nil { w.state = nil; w.seen = nil; w.lastResult = nil }

        // A command runs on the Mac by itself, over and over: the user approves it once, explicitly.
        if trigger == .command, let cmd = w.command {
            let every = w.everySeconds.map { "\($0) secondi" } ?? "\(w.everyMinutes ?? 5) minuti"
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: "Creo un monitor che esegue un comando ogni \(every)",
                                                           detail: cmd, risk: .dangerous, taskId: nil), timeout: 180)
            guard ok else { return "Monitor non creato: l'utente non ha confermato il comando." }
        }
        await WatcherEngine.shared.upsert(w)
        var out = "Monitor \"\(w.name)\" (id \(w.id)) attivo: \(w.triggerSummary), \(w.urgencyLabel)\(w.once ? ", una volta" : "")."
        switch trigger {
        case .webhook:
            let host = PhoneSetup.hostname().map { "https://\($0)" } ?? "http://127.0.0.1:\(ctx.config.webPort)"
            out += " URL da chiamare (POST): \(host)/hook/\(w.id)?key=⟦\(w.secret!)⟧ — raggiungibile dal tailnet; per servizi esterni serve Tailscale Funnel."
        case .screen, .audio:
            if !ScreenSensor.hasPermission() {
                out += " Attenzione: serve il permesso Registrazione schermo per Elio (Impostazioni di Sistema → Privacy e sicurezza)."
            }
        default:
            break
        }
        return out
    }

    /// "Tell me when…" triggers are one-shot unless the user says otherwise.
    static func defaultOnce(_ w: Watcher) -> Bool {
        switch w.trigger {
        case .screen, .audio, .mail, .process, .file, .pipeline: true
        case .http: ["up", "match"].contains(w.fireOn ?? "")
        case .command: ["success", "match"].contains(w.fireOn ?? "")
        default: false
        }
    }

    static func regexError(_ pattern: String?) -> String? {
        guard let pattern else { return nil }
        do { _ = try NSRegularExpression(pattern: pattern); return nil } catch { return "\(error.localizedDescription)" }
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
            "- \(w.name) (id \(w.id)) [\(w.enabled ? "attivo" : "in pausa")] \(w.trigger.rawValue): \(w.triggerSummary) → " +
            "\(w.action == .agent ? "analisi" : w.urgencyLabel)\(w.phone ? " +telefono" : "")\(w.once ? ", una volta" : ""); " +
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
