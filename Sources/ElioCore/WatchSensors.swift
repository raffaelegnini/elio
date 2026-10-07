import AppKit
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit

/// Sensor state that only matters while the daemon runs (last OCR text, file sizes between checks…).
struct SensorScratch {
    var screenText: String?
    var shownText: String?
    var askedAt: Date?
    var askedText: String?
    var sizes: [String: Int64] = [:]
    var warned = false
}

struct SensorError: Error {
    var message: String
    var permission = false
}

// MARK: - Engine: the new triggers

extension WatcherEngine {
    func screenCheck(_ w: Watcher) async {
        let now = Date()
        let app = w.app
        let file: URL
        switch await Task.detached(operation: { ScreenSensor.capture(app: app) }).value {
        case .failure(let e):
            update(w.id) { $0.lastCheck = now; $0.lastResult = e.message }
            if e.permission { await warnPermission(w) }
            return
        case .success(let url):
            file = url
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let text = WatchRules.collapse(await Task.detached { ScreenSensor.ocr(file) }.value)
        var sc = scratch[w.id] ?? SensorScratch()
        let pattern = w.match ?? ""
        let place = app.map { "nella finestra di \($0)" } ?? "sullo schermo"

        if let question = w.ask {
            // match, when given, is a cheap prefilter before bothering Claude.
            if !pattern.isEmpty, !WatchRules.regexMatches(pattern, text) {
                update(w.id) { $0.lastCheck = now; $0.lastResult = "Non vedo ancora «\(pattern)» \(place)." }
                return
            }
            // At most once a minute, and only when the screen actually changed since the last answer.
            guard sc.askedText != text, sc.askedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else {
                update(w.id) { $0.lastCheck = now }
                return
            }
            sc.askedAt = now
            sc.askedText = text
            scratch[w.id] = sc
            guard let r = await ScreenSensor.askClaude(question, image: file, config: ElioConfig.load()) else {
                update(w.id) { $0.lastCheck = now; $0.lastResult = "Non sono riuscito a far guardare lo schermo a Claude: riprovo." }
                return
            }
            let d = WatchRules.presence(fireOn: "appear", present: r.answer, previous: w.state, debounce: false)
            update(w.id) { $0.lastCheck = now; $0.state = d.state; $0.lastResult = "«\(question)» \(r.answer ? "sì" : "non ancora"): \(r.detail)" }
            if d.fire { await fire(w, headline: r.detail.isEmpty ? "\(w.name): ci siamo." : r.detail) }
            return
        }

        if w.fireOn == "change" {
            guard let base = sc.screenText else {
                sc.screenText = text
                scratch[w.id] = sc
                update(w.id) { $0.lastCheck = now; $0.lastResult = "Ho memorizzato cosa c'è \(place): avviso quando cambia." }
                return
            }
            guard WatchRules.meaningfulChange(base, text) else { update(w.id) { $0.lastCheck = now }; return }
            sc.screenText = text
            scratch[w.id] = sc
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Cambiato alle \(Self.hhmm(now))." }
            await fire(w, headline: "Qualcosa è cambiato \(place).", detail: String(text.prefix(300)))
            return
        }

        let found = pattern.isEmpty ? nil : text.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map { String(text[$0]) }
        if let found { sc.shownText = found; scratch[w.id] = sc }
        let shown = sc.shownText ?? pattern
        let d = WatchRules.presence(fireOn: w.fireOn, present: found != nil, previous: w.state, debounce: true)
        let result: String = if found != nil {
            "Vedo «\(shown)» \(place)."
        } else if w.fireOn == "disappear", d.state == "absent" {
            "Non vedo «\(pattern)» \(place): aspetto che compaia, poi che sparisca."
        } else {
            "Non vedo «\(pattern)» \(place)."
        }
        update(w.id) { $0.lastCheck = now; $0.state = d.state; $0.lastResult = result }
        guard d.fire else { return }
        if w.fireOn == "disappear" {
            await fire(w, headline: "«\(shown)» non c'è più \(place).")
        } else {
            await fire(w, headline: "È comparso «\(shown)» \(place).")
        }
    }

    func processCheck(_ w: Watcher) async {
        let now = Date()
        let pattern = w.match ?? ""
        guard let procs = await Task.detached(operation: { ProcessSensor.matching(pattern) }).value else {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Non riesco a leggere i processi (ps)." }
            return
        }
        // state: waiting | running|<start epoch>|<name> | done
        let parts = (w.state ?? "").split(separator: "|", maxSplits: 2).map(String.init)
        if parts.first == "running", parts.count == 3, let start = Double(parts[1]) {
            let name = parts[2]
            if procs.isEmpty {
                let ran = WatchRules.duration(now.timeIntervalSince1970 - start)
                update(w.id) { $0.lastCheck = now; $0.state = w.once ? "done" : "waiting"; $0.lastResult = "\(name) è terminato dopo \(ran)." }
                await fire(w, headline: "\(name) è terminato dopo \(ran).", detail: "Processo: /\(pattern)/")
            } else {
                let earliest = min(start, procs.map { now.timeIntervalSince1970 - $0.elapsed }.min() ?? start)
                update(w.id) {
                    $0.lastCheck = now
                    $0.state = "running|\(Int(earliest))|\(name)"
                    $0.lastResult = "\(name) in esecuzione (pid \(procs.map { String($0.pid) }.joined(separator: ", "))): avviso quando termina."
                }
            }
        } else if procs.isEmpty {
            update(w.id) { $0.lastCheck = now; $0.state = "waiting"; $0.lastResult = "Non è in esecuzione nessun processo /\(pattern)/: aspetto che parta, poi che finisca." }
        } else {
            let start = procs.map { now.timeIntervalSince1970 - $0.elapsed }.min() ?? now.timeIntervalSince1970
            let name = procs.first!.name
            update(w.id) {
                $0.lastCheck = now
                $0.state = "running|\(Int(start))|\(name)"
                $0.lastResult = "\(name) in esecuzione (pid \(procs.map { String($0.pid) }.joined(separator: ", "))): avviso quando termina."
            }
        }
    }

    func fileCheck(_ w: Watcher) async {
        let now = Date()
        let pattern = expandPath(w.path ?? "")
        let files = await Task.detached { FileSensor.list(pattern) }.value
        let finals = files.filter { !WatchRules.isTempDownload($0.path) }
        let label = (pattern as NSString).lastPathComponent
        switch w.fireOn ?? "appear" {
        case "change":
            let sig = finals.map { "\($0.path)|\($0.size)|\($0.mtime)" }.sorted().joined(separator: "\n")
            let hash = String(SHA256.hash(data: Data(sig.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
            let changed = w.state != nil && w.state != hash
            update(w.id) {
                $0.lastCheck = now
                $0.state = hash
                if !changed, w.state == nil { $0.lastResult = finals.isEmpty ? "Nessun file \(label) per ora: avviso quando cambia." : "Controllo \(finals.count) file: avviso quando cambiano." }
            }
            if changed {
                let what = finals.count == 1 ? "Il file \((finals[0].path as NSString).lastPathComponent) è cambiato." : "I file \(label) sono cambiati."
                update(w.id) { $0.lastResult = "Cambiato alle \(Self.hhmm(now))." }
                await fire(w, headline: what, detail: pattern)
            }

        case "disappear":
            let d = WatchRules.presence(fireOn: "disappear", present: !finals.isEmpty, previous: w.state, debounce: false)
            update(w.id) {
                $0.lastCheck = now
                $0.state = d.state
                $0.lastResult = !finals.isEmpty ? "\(label) c'è: avviso quando sparisce." : d.fire ? "\(label) è sparito." : "\(label) non c'è: aspetto che compaia, poi che sparisca."
            }
            if d.fire { await fire(w, headline: "Il file \(label) non c'è più.", detail: pattern) }

        default:
            var sc = scratch[w.id] ?? SensorScratch()
            let (ready, seen) = WatchRules.filesAppeared(files, seen: w.seen, lastSizes: sc.sizes, hasTempSibling: FileSensor.hasTempSibling)
            sc.sizes = Dictionary(files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
            scratch[w.id] = sc
            let downloading = files.filter { WatchRules.isTempDownload($0.path) }.count
            let result: String = if w.seen == nil {
                finals.isEmpty ? "Aspetto che compaia \(label)." : "Ho preso nota dei \(finals.count) file già presenti: avviso per quelli nuovi."
            } else if downloading > 0 {
                "Download in corso: aspetto che finisca."
            } else if !ready.isEmpty {
                "Pronto: \(ready.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))."
            } else {
                w.lastResult ?? "Aspetto che compaia \(label)."
            }
            update(w.id) { $0.lastCheck = now; $0.seen = seen; $0.lastResult = result }
            guard !ready.isEmpty else { return }
            let names = ready.map { ($0.path as NSString).lastPathComponent }
            let headline = names.count == 1 ? "Il file \(names[0]) è pronto." : "Sono pronti \(names.count) file: \(names.prefix(3).joined(separator: ", "))."
            await fire(w, headline: headline, detail: ready.map(\.path).joined(separator: "\n"))
        }
    }

    func mailCheck(_ w: Watcher) async {
        let now = Date()
        guard !MailHub.accounts().isEmpty else {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Nessuna casella collegata: Impostazioni → Integrazioni → Gmail o Mail." }
            return
        }
        let msgs: [MailMessage]
        do { msgs = try await MailSensor.fetch(query: w.query, account: w.account) } catch {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Posta non leggibile: \(String(describing: error).prefix(160))" }
            return
        }
        let ids = msgs.map(\.id)
        guard let seen = w.seen else {
            update(w.id) {
                $0.lastCheck = now
                $0.seen = WatchRules.mergeSeen([], ids, limit: 200)
                $0.lastResult = "Pronto: ignoro le \(ids.count) mail già presenti, avviso per le nuove."
            }
            return
        }
        let known = Set(seen)
        // Older messages surfacing in the results (others deleted or archived) are not news.
        let fresh = msgs.filter { !known.contains($0.id) && now.timeIntervalSince($0.date) < 86400 }
        update(w.id) {
            $0.lastCheck = now
            $0.seen = WatchRules.mergeSeen(seen, ids, limit: 200)
            if !fresh.isEmpty { $0.lastResult = "\(fresh.count) mail nuove alle \(Self.hhmm(now))." }
            else if $0.lastResult == nil || $0.lastResult!.hasPrefix("Posta") { $0.lastResult = "Nessuna mail nuova." }
        }
        guard !fresh.isEmpty else { return }
        let headline: String = if fresh.count == 1 {
            "È arrivata una mail da \(WatchRules.senderName(fresh[0].from)): \(fresh[0].subject)."
        } else {
            "Sono arrivate \(fresh.count) mail: " + fresh.prefix(3).map { "da \(WatchRules.senderName($0.from))" }.joined(separator: ", ") + "."
        }
        let detail = fresh.prefix(5).map { "- \($0.from): \($0.subject) — \($0.snippet.prefix(200))" }.joined(separator: "\n")
        await fire(w, headline: headline, detail: detail)
    }

    func pipelineCheck(_ w: Watcher) async {
        let now = Date()
        guard let gh = PipelineSensor.ghPath() else {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Non trovo gh: installa gh (brew install gh) e fai gh auth login." }
            return
        }
        var repo = w.repo
        var state = w.state
        let pinned = w.url.flatMap(WatchRules.parseRunURL)
        if let pinned {
            repo = pinned.repo
            if state == nil { state = "run:\(pinned.id)" }
        }
        guard let repo else {
            update(w.id) { $0.lastCheck = now; $0.lastResult = "Manca il repository da controllare." }
            return
        }
        if state?.hasPrefix("done") == true { update(w.id) { $0.lastCheck = now }; return }

        if let s = state, s.hasPrefix("run:") {
            let id = String(s.dropFirst(4))
            switch await Task.detached(operation: { PipelineSensor.view(gh, repo: repo, id: id) }).value {
            case .failure(let e):
                update(w.id) { $0.lastCheck = now; $0.state = s; $0.lastResult = e.message }
            case .success(let run):
                await pipelineSeen(w, run, state: s)
            }
            return
        }

        let branch = w.branch
        switch await Task.detached(operation: { PipelineSensor.latest(gh, repo: repo, branch: branch) }).value {
        case .failure(let e):
            update(w.id) { $0.lastCheck = now; $0.lastResult = e.message }
        case .success(nil):
            update(w.id) { $0.lastCheck = now; $0.state = "after:0"; $0.lastResult = "Nessuna pipeline su \(repo)\(branch.map { " (\($0))" } ?? ""): aspetto la prossima." }
        case .success(let run?):
            let after = state.flatMap { $0.hasPrefix("after:") ? Int($0.dropFirst(6)) : nil }
            if state == nil, run.status == "completed" {
                // Already finished when the monitor was created: the user means the next one.
                update(w.id) {
                    $0.lastCheck = now
                    $0.state = "after:\(run.id)"
                    $0.lastResult = "L'ultima pipeline (\(run.name)) è già finita, \(WatchRules.conclusionIT(run.conclusion)): aspetto la prossima."
                }
            } else if let after, run.id <= after {
                update(w.id) { $0.lastCheck = now }
            } else {
                await pipelineSeen(w, run, state: "run:\(run.id)")
            }
        }
    }

    private func pipelineSeen(_ w: Watcher, _ run: PipelineSensor.Run, state: String) async {
        let now = Date()
        let on = run.branch.isEmpty ? "" : " su \(run.branch)"
        guard run.status == "completed" else {
            update(w.id) { $0.lastCheck = now; $0.state = state; $0.lastResult = "In corso: \(run.name)\(on) (\(run.status))." }
            return
        }
        let outcome = WatchRules.conclusionIT(run.conclusion)
        update(w.id) {
            $0.lastCheck = now
            // A watched run URL is done for good; a branch goes back to waiting for the next run.
            $0.state = w.url != nil ? "done:\(run.id)" : "after:\(run.id)"
            $0.lastResult = "\(run.name)\(on): \(outcome)."
        }
        await fire(w, headline: "La pipeline \(run.name)\(on) è finita: \(outcome).", detail: run.url)
    }

    // MARK: Audio

    /// Keeps exactly one running stream per enabled audio monitor.
    func reconcileSensors() {
        let wanted = Dictionary(watchers.filter { $0.enabled && $0.trigger == .audio }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, sensor) in audio where wanted[id]?.audioKey != sensor.key {
            sensor.stop()
            audio[id] = nil
        }
        for (id, w) in wanted where audio[id] == nil {
            let sensor = AudioSensor(w) { event in Task { await self.audioEvent(id, event) } }
            audio[id] = sensor
            sensor.start()
        }
    }

    func audioEvent(_ id: String, _ event: AudioSensor.Event) async {
        guard let w = current(id), w.enabled, w.trigger == .audio else { return }
        switch event {
        case .status(let text, let permission):
            update(id) { $0.lastCheck = Date(); $0.lastResult = text }
            if permission { await warnPermission(w) }
        case .fired(let headline):
            update(id) { $0.lastCheck = Date() }
            await fire(w, headline: headline)
        }
    }

    /// Said once per monitor: without Screen Recording the sensor is blind and the user would wait forever.
    func warnPermission(_ w: Watcher) async {
        var sc = scratch[w.id] ?? SensorScratch()
        guard !sc.warned else { return }
        sc.warned = true
        scratch[w.id] = sc
        await Alerts.shared.send("Per il monitor \(w.name) mi serve il permesso Registrazione schermo: aprilo in Impostazioni di Sistema, Privacy e sicurezza, e attiva Elio.",
                                 title: w.name, urgency: .notify, source: "monitor:\(w.id)")
    }

    static func hhmm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
}

extension Watcher {
    /// What an audio stream depends on: a change restarts it.
    var audioKey: String { "\(app ?? "")|\(fireOn ?? "")|\(silenceSeconds ?? 0)" }
}

// MARK: - Screen

enum ScreenSensor {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("elio-watch", isDirectory: true)
    nonisolated(unsafe) private static var requested = false

    static let permissionMessage = "Non posso vedere lo schermo: concedi «Registrazione schermo» a Elio in Impostazioni di Sistema → Privacy e sicurezza, poi riavvia Elio."

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Main display, or the largest window of `app` (by owner name or window title). Blocking.
    static func capture(app: String?) -> Result<URL, SensorError> {
        guard hasPermission() else {
            // Puts Elio in the Screen Recording list (and asks), once per run.
            if !requested { requested = true; CGRequestScreenCaptureAccess() }
            return .failure(SensorError(message: permissionMessage, permission: true))
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).png")
        var args = ["-x", "-t", "png"]
        if let app {
            guard let id = windowID(app: app) else { return .failure(SensorError(message: "Non trovo una finestra aperta di \(app).")) }
            args += ["-l", "\(id)", "-o"]
        } else {
            args += ["-m"]
        }
        _ = Exec.run("/usr/sbin/screencapture", args + [file.path], timeout: 20)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .failure(SensorError(message: permissionMessage, permission: true))
        }
        return .success(file)
    }

    static func windowID(app: String) -> Int? {
        let q = app.lowercased()
        func pick(_ options: CGWindowListOption) -> Int? {
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
            func area(_ w: [String: Any]) -> CGFloat {
                guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return 0 }
                return r.width * r.height
            }
            let mine = list.filter { w in
                guard (w[kCGWindowLayer as String] as? Int) == 0, area(w) > 10_000 else { return false }
                let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                let title = (w[kCGWindowName as String] as? String ?? "").lowercased()
                return owner.contains(q) || title.contains(q)
            }
            return mine.max { area($0) < area($1) }?[kCGWindowNumber as String] as? Int
        }
        return pick([.optionOnScreenOnly, .excludeDesktopElements]) ?? pick([.optionAll, .excludeDesktopElements])
    }

    static func ocr(_ file: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        return (try? MediaTools.recognizeText(image)) ?? ""
    }

    /// A yes/no look at the screenshot by a cheap model (OneShot.ask, plus Read so it can open the image).
    static func askClaude(_ question: String, image: URL, config: ElioConfig) async -> (answer: Bool, detail: String)? {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "boolean"], "detail": ["type": "string"]],
            "required": ["answer", "detail"],
        ]
        guard let schemaData = try? JSONSerialization.data(withJSONObject: schema) else { return nil }
        let prompt = """
        Apri con Read lo screenshot \(image.path) e rispondi alla domanda: answer true se la risposta è sì, false altrimenti.
        Domanda: \(question)
        detail: una frase breve in italiano su cosa vedi, adatta a essere letta ad alta voce (es. "Il render è finito.").
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudePath)
        p.currentDirectoryURL = ElioPaths.claudeWorkspace
        // Haiku: it's a glance at a screenshot, repeated; no need for a bigger model.
        p.arguments = ["-p", prompt, "--output-format", "json", "--model", "haiku",
                       "--tools", "Read", "--allowedTools", "Read", "--add-dir", dir.path,
                       "--no-session-persistence", "--setting-sources", "",
                       "--json-schema", String(decoding: schemaData, as: UTF8.self)]
        p.environment = config.claudeAccount.environment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { log("screen ask failed to start: \(error)"); return nil }
        let killer = Task.detached {
            try? await Task.sleep(for: .seconds(90))
            if p.isRunning { p.terminate() }
        }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        killer.cancel()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var json = obj["structured_output"] as? [String: Any]
        if json == nil, let text = obj["result"] as? String, let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}") {
            json = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any]
        }
        guard let json, let answer = json["answer"] as? Bool else { return nil }
        return (answer, json["detail"] as? String ?? "")
    }
}

// MARK: - Audio

/// Listens to the Mac's sound output through ScreenCaptureKit (audio only: a 2×2 px, 1 fps video
/// stream is the cheapest SCStream there is) and reports transitions itself: the engine's tick is
/// far too slow for "they're talking again".
final class AudioSensor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case status(String, permission: Bool)
        case fired(String)
    }

    /// Below this the output counts as silence: muted participants and room tone sit well under it,
    /// voices and music are around -35…-10 dBFS.
    static let silenceDBFS: Float = -50
    /// Sound must last this long to count (a notification ping is not people talking).
    static let sustainedSound: TimeInterval = 2
    /// Gaps shorter than this don't break a run of sound (pauses between words).
    static let soundGap: TimeInterval = 0.8

    let key: String
    private let app: String?
    private let waitsForSound: Bool
    private let silence: TimeInterval
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "elio.watch.audio")

    // Confined to `queue`.
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var generation = 0
    private var failures = 0
    private var since = Date()
    private var lastLoud: Date?
    private var runStart: Date?
    private var armed = false
    private var heard = false
    private var lastStatus = ""

    init(_ w: Watcher, onEvent: @escaping @Sendable (Event) -> Void) {
        key = w.audioKey
        app = w.app
        waitsForSound = w.fireOn != "silence"
        silence = TimeInterval(max(3, w.silenceSeconds ?? (w.fireOn == "silence" ? 30 : 20)))
        self.onEvent = onEvent
    }

    func start() { queue.async { self.stopped = false; self.launch() } }

    func stop() { queue.async { self.stopped = true; self.generation += 1; self.teardown() } }

    private func launch() {
        generation += 1
        let gen = generation
        guard CGPreflightScreenCaptureAccess() else {
            failed(SensorError(message: ScreenSensor.permissionMessage, permission: true), gen)
            return
        }
        let app = app
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw SensorError(message: "Nessuno schermo disponibile") }
                var note = ""
                let filter: SCContentFilter
                if let app {
                    let q = app.lowercased()
                    let apps = content.applications.filter {
                        $0.applicationName.lowercased().contains(q) || $0.bundleIdentifier.lowercased().contains(q)
                    }
                    if apps.isEmpty {
                        note = " (non trovo \(app): ascolto tutto l'audio del Mac)"
                        filter = SCContentFilter(display: display, excludingWindows: [])
                    } else {
                        filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
                    }
                } else {
                    filter = SCContentFilter(display: display, excludingWindows: [])
                }
                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                cfg.sampleRate = 48000
                cfg.channelCount = 1
                cfg.width = 2
                cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                cfg.showsCursor = false
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                // Without a screen output SCStream logs a dropped frame every second.
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                queue.async {
                    guard !self.stopped, gen == self.generation else { Task { try? await s.stopCapture() }; return }
                    self.stream = s
                    self.failures = 0
                    self.resetListening()
                    self.startTimer()
                    let n = Int(self.silence)
                    self.report(self.waitsForSound
                        ? "In ascolto\(note): aspetto \(n) secondi di silenzio, poi avviso quando torna il suono."
                        : "In ascolto\(note): avviso dopo \(n) secondi di silenzio.")
                }
            } catch {
                queue.async { self.failed(error, gen) }
            }
        }
    }

    private func failed(_ error: Error, _ gen: Int) {
        guard !stopped, gen == generation else { return }
        teardown()
        failures += 1
        let delay = min(300, 5 * (1 << min(failures - 1, 6)))
        if let e = error as? SensorError, e.permission {
            report(e.message, permission: true)
        } else if !CGPreflightScreenCaptureAccess() {
            report(ScreenSensor.permissionMessage, permission: true)
        } else {
            report("L'ascolto dell'audio si è interrotto (\(error.localizedDescription)): riprovo tra \(delay) secondi.")
        }
        queue.asyncAfter(deadline: .now() + .seconds(delay)) {
            guard !self.stopped, gen == self.generation else { return }
            self.launch()
        }
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.evaluate(Date()) }
        t.resume()
        timer = t
    }

    private func resetListening() {
        since = Date()
        lastLoud = nil
        runStart = nil
        armed = false
        heard = false
    }

    private func report(_ text: String, permission: Bool = false) {
        guard text != lastStatus else { return }
        lastStatus = text
        onEvent(.status(text, permission: permission))
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.stream else { return }
            self.failed(error, self.generation)
        }
    }

    // SCStreamOutput (called on `queue`)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !stopped, let db = Self.level(sampleBuffer) else { return }
        let now = Date()
        if db > Self.silenceDBFS {
            if runStart == nil || now.timeIntervalSince(lastLoud ?? .distantPast) > Self.soundGap { runStart = now }
            lastLoud = now
            heard = true
        }
        evaluate(now)
    }

    private func evaluate(_ now: Date) {
        guard !stopped, stream != nil else { return }
        let quietFor = now.timeIntervalSince(lastLoud ?? since)
        let soundFor = quietFor < Self.soundGap ? now.timeIntervalSince(runStart ?? now) : 0
        if waitsForSound {
            if !armed, quietFor >= silence {
                armed = true
                report("Silenzio da \(Int(silence)) secondi: avviso appena torna il suono.")
            }
            if armed, soundFor >= Self.sustainedSound {
                resetListening()
                report("Il suono è tornato alle \(WatcherEngine.hhmm(now)).")
                onEvent(.fired("L'audio è ripreso dopo la pausa: stanno parlando di nuovo."))
            }
        } else if heard, quietFor >= silence {
            resetListening()
            report("Silenzio dalle \(WatcherEngine.hhmm(now.addingTimeInterval(-quietFor))).")
            onEvent(.fired("Silenzio da \(WatchRules.duration(quietFor)): l'audio si è fermato."))
        } else if !heard, quietFor >= silence {
            report("Per ora non sento audio: avviso quando, dopo averlo sentito, torna il silenzio.")
        }
    }

    /// RMS of the buffer in dBFS (ScreenCaptureKit delivers Float32 PCM).
    static func level(_ sb: CMSampleBuffer) -> Float? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return nil }
        var sum: Float = 0
        var count = 0
        try? sb.withAudioBufferList { list, _ in
            for buf in list {
                guard let p = buf.mData else { continue }
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let f = p.bindMemory(to: Float.self, capacity: n)
                for i in 0..<n { sum += f[i] * f[i] }
                count += n
            }
        }
        guard count > 0 else { return nil }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}

// MARK: - Processes, files, mail, CI

enum Exec {
    /// Runs a program with a sane PATH (Homebrew included), off the actor. Blocking.
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 60,
                    env extra: [String: String] = [:]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "", "\(error)") }
        let errBox = ErrBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errBox.data, as: UTF8.self))
    }

    private final class ErrBox: @unchecked Sendable { var data = Data() }
}

enum ProcessSensor {
    struct Proc: Sendable { var pid: Int32; var elapsed: TimeInterval; var name: String }

    /// Processes whose name or command line matches `pattern` (not Elio itself, ps, or Claude, whose
    /// prompts may well contain the pattern). nil when ps fails.
    static func matching(_ pattern: String) -> [Proc]? {
        let full = Exec.run("/bin/ps", ["-axww", "-o", "pid=,etime=,args="], timeout: 15)
        let names = Exec.run("/bin/ps", ["-ax", "-o", "pid=,ucomm="], timeout: 15)
        guard full.code == 0 else { return nil }
        var comm: [Int32: String] = [:]
        for line in names.out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if parts.count == 2, let pid = Int32(parts[0]) { comm[pid] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let me = getpid()
        return full.out.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), pid != me, let elapsed = WatchRules.parseEtime(String(parts[1])) else { return nil }
            let args = String(parts[2])
            let name = comm[pid] ?? (args.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? args)
            guard !["ps", "claude"].contains(name.lowercased()) else { return nil }
            return WatchRules.regexMatches(pattern, "\(name) \(args)") ? Proc(pid: pid, elapsed: elapsed, name: name) : nil
        }
    }
}

enum FileSensor {
    /// Files matching a path or glob, with size and modification date.
    static func list(_ pattern: String) -> [WatchRules.FileInfo] {
        var paths: [String] = []
        if pattern.contains(where: { "*?[".contains($0) }) {
            var g = glob_t()
            defer { globfree(&g) }
            if glob(pattern, GLOB_TILDE, nil, &g) == 0 {
                for i in 0..<Int(g.gl_pathc) { if let c = g.gl_pathv[i] { paths.append(String(cString: c)) } }
            }
        } else if FileManager.default.fileExists(atPath: pattern) {
            paths = [pattern]
        }
        return paths.compactMap { p in
            guard let a = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
            return WatchRules.FileInfo(path: p, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                                       mtime: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
    }

    static func hasTempSibling(_ path: String) -> Bool {
        [".part", ".crdownload", ".download"].contains { FileManager.default.fileExists(atPath: path + $0) }
    }
}

enum MailSensor {
    /// Recent mail matching the query on every connected account (or `account`).
    static func fetch(query: String?, account: String?) async throws -> [MailMessage] {
        var all: [MailMessage] = []
        var errors: [String] = []
        for p in MailHub.providers(account) {
            do {
                if p.hasPrefix("gmail:") {
                    let q = [query ?? "in:inbox", "newer_than:2d"].joined(separator: " ")
                    all += try await Gmail.list(account: String(p.dropFirst(6)), query: q, max: 20)
                } else {
                    let q = query.map(WatchRules.appleMailQuery) ?? ""
                    all += try await Task.detached {
                        q.isEmpty ? try AppleMail.inbox(hours: 48, unreadOnly: false, max: 20) : try AppleMail.search(q, max: 20)
                    }.value
                }
            } catch { errors.append("\(p): \(error)") }
        }
        if all.isEmpty, !errors.isEmpty { throw ToolError(errors.joined(separator: "; ")) }
        return all
    }
}

enum PipelineSensor {
    struct Run: Sendable {
        var id: Int
        var status: String
        var conclusion: String?
        var name: String
        var branch: String
        var url: String
    }

    static func ghPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let fields = "databaseId,status,conclusion,name,displayTitle,url,headBranch,createdAt,updatedAt"

    static func view(_ gh: String, repo: String, id: String) -> Result<Run, SensorError> {
        let r = Exec.run(gh, ["run", "view", id, "--repo", repo, "--json", fields], timeout: 45)
        guard r.code == 0 else { return .failure(failure(r.err)) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any], let run = parse(obj) else {
            return .failure(SensorError(message: "Risposta di gh non leggibile."))
        }
        return .success(run)
    }

    static func latest(_ gh: String, repo: String, branch: String?) -> Result<Run?, SensorError> {
        var args = ["run", "list", "--repo", repo, "--limit", "1", "--json", fields]
        if let branch { args += ["--branch", branch] }
        let r = Exec.run(gh, args, timeout: 45)
        guard r.code == 0 else { return .failure(failure(r.err)) }
        guard let list = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]] else {
            return .failure(SensorError(message: "Risposta di gh non leggibile."))
        }
        return .success(list.first.flatMap(parse))
    }

    static func parse(_ o: [String: Any]) -> Run? {
        guard let id = o["databaseId"] as? Int else { return nil }
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? o["displayTitle"] as? String ?? "CI"
        return Run(id: id, status: o["status"] as? String ?? "", conclusion: (o["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                   name: name, branch: o["headBranch"] as? String ?? "", url: o["url"] as? String ?? "")
    }

    static func failure(_ err: String) -> SensorError {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.contains("auth login") || e.contains("not logged") || e.contains("authentication") {
            return SensorError(message: "gh non è autenticato: fai gh auth login.")
        }
        return SensorError(message: "gh: \(e.prefix(200))")
    }

    /// "owner/repo", a GitHub URL, or a local folder (its origin remote and current branch).
    static func resolveRepo(_ input: String) -> (repo: String?, branch: String?) {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix(".") {
            let dir = expandPath(s)
            let remote = GitSafety.run(dir, ["remote", "get-url", "origin"], timeout: 15)
            guard remote.code == 0, let repo = WatchRules.parseGitHubRemote(remote.out) else { return (nil, nil) }
            let head = GitSafety.run(dir, ["rev-parse", "--abbrev-ref", "HEAD"], timeout: 15)
            let branch = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return (repo, head.code == 0 && !branch.isEmpty && branch != "HEAD" ? branch : nil)
        }
        if s.contains("github.com") { return (WatchRules.parseGitHubRemote(s), nil) }
        if s.wholeMatch(of: #/[\w.-]+\/[\w.-]+/#) != nil { return (s, nil) }
        return (nil, nil)
    }
}
