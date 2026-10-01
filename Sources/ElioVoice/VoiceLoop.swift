import AppKit
import AVFoundation
import Foundation
import ElioCore
import Observation

/// The conversation loop: mic → VAD → on-device STT → wake word → eliod → TTS.
/// Also owns barge-in and the follow-up window (reply without saying "Elio" again).
@MainActor
@Observable
public final class VoiceLoop {
    public enum State: String { case idle, listening, hearing, thinking, speaking, muted, off }

    public struct ToolActivity: Identifiable {
        public let id: String
        public let name: String
        public var running: Bool
        public var ok: Bool
        public var ms: Int?
        public let date = Date()
    }

    public struct Turn: Identifiable {
        public let id = UUID()
        public let role: String   // "user" | "elio" | "event"
        public var text: String
        public var route: Route?
        public var latencyMs: Int?
        public let date = Date()
    }

    public private(set) var state: State = .off
    public private(set) var level: Float = 0          // 0…1, for the orb
    public private(set) var partial = ""
    public private(set) var turns: [Turn] = []
    public private(set) var connected = false
    public private(set) var charactersThisSession = 0
    public private(set) var lastError: String?
    public private(set) var inputDevice = ""
    public private(set) var muted = false
    /// Live tool calls (newest last) and the tools currently running.
    public private(set) var activity: [ToolActivity] = []
    public private(set) var activeTools: Set<String> = []
    /// Brief / recap in progress: the network starts dark and lights up tool by tool.
    public private(set) var routineMode = false
    /// When each tool first fired during the current routine.
    public private(set) var litTools: [String: Date] = [:]
    private var routineSpeaking = false
    public var alwaysListening = true
    /// Background agents, newest last.
    public private(set) var tasks: [TaskInfo] = []
    /// Actions waiting for the user's explicit OK.
    public private(set) var confirmations: [ConfirmRequest] = []
    public private(set) var diffs: [DiffPayload] = []
    public private(set) var cards: [CardPayload] = []
    /// Live activity of each agent (newest last).
    public private(set) var taskLogs: [String: [TaskLogEntry]] = [:]
    /// Questions waiting for the user's answer.
    public private(set) var questions: [QuestionRequest] = []
    /// Bumped when a new diff arrives, so the UI can open the review panel.
    public private(set) var diffSignal = 0

    private let config: ElioConfig
    private let audio = AudioIO()
    private let pipeline: InputPipeline
    private let speaker: Speaker
    private let client: DaemonClient
    /// Always-on on-device recognizer; the VAD decides where utterances end.
    private var stt: ContinuousTranscriber?
    private var inUtterance = false
    /// When Elio last stopped talking (its voice may still echo in the room).
    private var lastSpeechEnd = Date.distantPast
    private var emptyWithAEC = 0
    private var browserShownFor: String?
    private var utteranceArmed = false
    /// Utterance captured while Elio was speaking through the speakers.
    private var bargeCandidate = false
    /// What Elio is saying right now (to tell its own echo from the user's stop words).
    private var spokenText = ""
    /// Spoken sentences left for the current reply; the rest is only shown on screen.
    private var sentenceBudget = 2

    static func wantsDetail(_ text: String) -> Bool {
        text.lowercased().range(of: #"spiega|approfondisc|nel dettaglio|dimmi tutto|leggi|elenca|recap|riepilog|resoconto|briefing|explain|in detail|read"#,
                                options: .regularExpression) != nil
    }

    /// Speaks the half-sentence still in the splitter (an acknowledgement without final punctuation).
    private func splitterFlushForAck() {
        guard let rest = splitter.flush() else { return }
        replySentences += 1
        if localAckSpoken, replySentences == 1, Acknowledgement.isAcknowledgement(rest) { return }
        speaker.enqueue(rest)
        speaker.endUtterance()
    }

    private func speakReply(_ sentence: String) {
        replySentences += 1
        // We already acknowledged locally: skip Claude's own "Certo, Signore, controllo…".
        if localAckSpoken, replySentences == 1, Acknowledgement.isAcknowledgement(sentence) { return }
        guard sentenceBudget > 0 else { return }
        sentenceBudget -= 1
        if replyStreaming {
            speaker.streamSentence(sentence)
            // All that will be spoken is in: close now so it's generated in one fluid take.
            if sentenceBudget == 0 {
                speaker.endStream()
                replyStreaming = false
            }
        } else {
            speaker.enqueue(sentence)
        }
    }
    private var wakeSeen = false
    private var abandoned = false
    private var armedUntil: Date?
    private var currentRequestId: String?
    private var splitter = SentenceSplitter()
    private var requestStart = Date()
    private var replyStreaming = false
    private var firstDeltaLogged = false
    private var firstAudioLogged = false
    private var addressAs = "Signore"
    private var fillers: [String] { ["Un momento, \(addressAs).", "Subito, \(addressAs)."] }

    static let followUpWindow: TimeInterval = 8
    static let wakeWindow: TimeInterval = 10
    static let acks = ["Sì?", "Dimmi."]

    public init(config: ElioConfig, token: String) {
        self.config = config
        pipeline = InputPipeline()
        speaker = Speaker(audio: audio, voiceId: config.elevenLabsVoiceId, model: config.elevenLabsModel)
        client = DaemonClient(port: config.port, token: token)
    }

    public func start() async {
        client.onMessage = { [weak self] msg in Task { @MainActor in self?.handle(msg) } }
        client.onConnectionChange = { [weak self] up in Task { @MainActor in self?.connected = up } }
        client.start()

        speaker.onSpeakingChange = { [weak self] speaking in self?.speakingChanged(speaking) }
        speaker.onCharactersSent = { [weak self] n in self?.charactersThisSession += n }
        speaker.onFirstAudio = { [weak self] in
            guard let self, !self.firstAudioLogged else { return }
            self.firstAudioLogged = true
            VoiceLog.write(String(format: "timing: first audio %.2fs after request", Date().timeIntervalSince(self.requestStart)))
        }

        pipeline.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        pipeline.onLevel = { [weak self] db in Task { @MainActor in self?.updateLevel(db) } }
        let stt = ContinuousTranscriber(locale: Locale(identifier: "it_IT"),
                                        contextWords: [config.assistantName] + config.wakeAliases + ["Slack", "Teamwork", "Bitbucket", "Meet"])
        stt.onVolatile = { [weak self] text in Task { @MainActor in self?.heard(text) } }
        self.stt = stt
        audio.onInput = { [pipeline, stt] buffer, db in
            stt.feed(buffer)
            pipeline.process(buffer, levelDb: db)
        }

        muted = UserDefaults.standard.bool(forKey: "elio.muted")
        voiceId = config.elevenLabsVoiceId
        applySettings(config)
        do {
            try await UtteranceTranscriber.ensureModel(locale: Locale(identifier: "it_IT"))
            try audio.start()
            if muted { try audio.setInputEnabled(false) }
            pipeline.inputFormat = audio.inputFormat
            if !muted, let format = audio.inputFormat { try await stt.start(inputFormat: format) }
            inputDevice = audio.inputDeviceName
            VoiceLog.write("audio started (aec \(audio.aecActive)): in '\(inputDevice)' out '\(audio.outputDeviceName)' bt-out \(AudioDevices.defaultOutputIsBluetooth()) builtin-mic \(AudioDevices.builtInMicrophone().map { AudioDevices.name(of: $0) } ?? "-"), format: \(String(describing: audio.inputFormat))")
            audio.onRouteChange = { [weak self] format in
                guard let self else { return }
                self.inputDevice = self.audio.inputDeviceName
                VoiceLog.write("audio route changed → '\(self.inputDevice)', format: \(String(describing: format))")
                // New device, new format: restart recognition on it.
                self.inUtterance = false
                self.pipeline.inputFormat = format
                self.pipeline.resetVAD()
                if let format, !self.muted { Task { try? await self.stt?.start(inputFormat: format) } }
            }
            state = muted ? .muted : .listening
            speaker.warmCache(Self.acks + Acknowledgement.all(addressAs: addressAs))
        } catch {
            lastError = "Audio: \(error.localizedDescription)"
            state = .off
        }
    }

    /// Hotkey / click on the orb: talk now without the wake word, or interrupt Elio.
    public func activate() {
        if speaker.isSpeaking {
            interrupt()
            return
        }
        // ⌥⌘J while muted: unmute (explicit user action).
        if muted { setMuted(false) }
        // A short chime, not speech: speaking would raise the mic threshold
        // right when the user starts the command.
        armedUntil = Date().addingTimeInterval(Self.wakeWindow)
        NSSound(named: "Tink")?.play()
        if state != .thinking { state = .hearing }
    }

    /// Stops listening entirely (mic released). Typed input and spoken replies still work.
    public func setMuted(_ on: Bool) {
        guard on != muted else { return }
        do {
            try audio.setInputEnabled(!on)
        } catch {
            lastError = "Microfono: \(error.localizedDescription)"
            return
        }
        muted = on
        UserDefaults.standard.set(on, forKey: "elio.muted")
        if on {
            inUtterance = false
            pipeline.resetVAD()
            partial = ""
            state = .muted
            Task { await stt?.stop() }
        } else {
            if state == .muted || state == .off { state = .listening }
            if let format = audio.inputFormat { Task { try? await stt?.start(inputFormat: format) } }
        }
        VoiceLog.write("mic \(on ? "muted" : "unmuted")")
    }

    /// Called when the assistant prepared an integration that needs a secret in Settings.
    public var onIntegrationSetup: ((String) -> Void)?
    /// Brief/recap started: the app shows the network lighting up.
    public var onRoutineStart: (() -> Void)?
    private var spokenSentences = 3
    private var briefOpeningEnabled = true

    /// Settings saved: apply what the app owns right away (the daemon restarts on its own).
    public func applySettings(_ config: ElioConfig) {
        spokenSentences = config.spokenSentences
        addressAs = config.addressAs
        briefOpeningEnabled = config.briefOpening
        audio.preferBuiltInMicWithBluetooth = config.builtInMicWithBluetooth
        if audio.echoCancellation != config.echoCancellation {
            audio.echoCancellation = config.echoCancellation
            if state != .off { audio.reconfigureInput() }
        }
        if config.elevenLabsVoiceId != voiceId {
            voiceId = config.elevenLabsVoiceId
            speaker.setVoice(voiceId)
        }
    }

    public func requestDaemonReload() { client.send(.reload) }

    public static let voices: [(name: String, id: String)] = [
        ("MarcoTrox (italiano)", "W71zT1VwIFFx3mMGH2uZ"), ("Fabi (italiano)", "Ha21jUwaMwdgQvqNslSM"),
        ("Marco (italiano)", "GcAgjAjkhWsmUd4GlPiv"), ("Andy (italiano)", "DLMxnwJE0a28JQLTMJPJ"),
        ("George (inglese)", "JBFqnCBsd6RMkjVDRZzb"), ("Daniel (inglese)", "onwK4e9ZLuTAKqWW03F9"),
    ]
    public private(set) var voiceId: String = ""

    public func setVoice(_ id: String) {
        var cfg = ElioConfig.load()
        cfg.elevenLabsVoiceId = id
        cfg.save()
        voiceId = id
        speaker.setVoice(id)
        speaker.enqueue("Così suono adesso, Signore.")
        speaker.endUtterance()
    }

    /// Runs a tool on the daemon (dashboard data: agenda, reminders…).
    public func callTool(_ name: String, _ args: [String: Any] = [:]) async -> (String, Bool) {
        var quiet = args
        quiet["_quiet"] = true
        return await client.callTool(name, quiet)
    }

    public func interrupt() {
        speaker.stop()
        currentRequestId = nil
        armedUntil = Date().addingTimeInterval(Self.followUpWindow)
        state = .listening
    }

    /// Typed input from the HUD: same path as voice, skips the wake word.
    public func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(trimmed)
    }

    // MARK: - Mic events

    private func handle(_ event: InputPipeline.Event) {
        switch event {
        case .speechStart:
            // With echo cancellation or headphones, interrupt as soon as real words are recognized
            // (see heard()): a cough or a keystroke must not cut Elio off.
            inUtterance = true
            utteranceArmed = isArmed
            wakeSeen = false
            // Drop what the recognizer heard before (background, Elio's own voice).
            stt?.resetSegment()
            partial = ""
            if utteranceArmed, state != .thinking { state = .hearing }
        case .speechEnd:
            guard inUtterance else { return }
            inUtterance = false
            Task { await endUtterance() }
        }
    }

    private var isArmed: Bool { armedUntil.map { $0 > Date() } ?? false }

    /// Live text from the recognizer: wake word → show we're listening; while Elio talks
    /// through the speakers, a stop word it isn't saying itself interrupts it.
    private func heard(_ text: String) {
        guard inUtterance else { return }
        if speaker.isSpeaking, audio.aecActive || AudioDevices.defaultOutputIsHeadphones() {
            let words = Echo.remove(from: text, spoken: speaker.recentlySpoken())
                .split(separator: " ").filter { $0.count >= 2 }
            if !words.isEmpty {
                VoiceLog.write("barge-in on words: '\(text)'")
                interrupt()
                utteranceArmed = true
                state = .hearing
                partial = text
            }
            return
        }
        if speaker.isSpeaking, !audio.aecActive {
            // No echo cancellation: tell the user's words from Elio's own by content.
            // Answering a confirmation/question while Elio is still asking it.
            let answering = (confirmations.first.map { ConfirmationAnswer.parse(Echo.remove(from: text, spoken: speaker.recentlySpoken()), risk: $0.risk) != .unrelated } ?? false)
                || (!questions.isEmpty && !Echo.remove(from: text, spoken: speaker.recentlySpoken()).isEmpty && !utteranceArmed)
            if answering || BargeIn.detect(text, whileSaying: speaker.recentlySpoken()) {
                VoiceLog.write("barge-in on '\(text)'")
                interrupt()
                utteranceArmed = true   // what follows "Elio, aspetta…" is a command
                state = .hearing
                partial = text
            }
            return
        }
        if utteranceArmed || wakeSeen {
            partial = text
        } else if WakeWord.strip(text) != nil {
            wakeSeen = true
            partial = text
            if state != .thinking { state = .hearing }
        }
    }

    private func endUtterance() async {
        guard let stt else { return }
        var text = await stt.finalizeSegment()
        let spokeRecently = speaker.isSpeaking || Date().timeIntervalSince(lastSpeechEnd) < 3
        VoiceLog.write("heard: '\(text)'\(spokeRecently ? " (Elio spoke recently)" : "")\(audio.aecActive ? " [aec]" : "")")
        // Safety net: if echo cancellation swallows the user's voice, turn it off by itself.
        if audio.aecActive {
            emptyWithAEC = text.isEmpty ? emptyWithAEC + 1 : 0
            if emptyWithAEC >= 6 {
                emptyWithAEC = 0
                VoiceLog.write("aec: 6 empty utterances in a row, disabling echo cancellation")
                audio.echoCancellation = false
                audio.reconfigureInput()
                lastError = "Cancellazione eco disattivata: non sentivo bene la tua voce."
            }
        }
        partial = ""
        // Elio's own voice picked up by the mic is never a command.
        if spokeRecently { text = Echo.remove(from: text, spoken: speaker.recentlySpoken()) }
        if state == .hearing, !isArmed { state = .listening }
        guard !text.isEmpty else { return }
        if speaker.isSpeaking { return }  // still talking and no stop word: ignore

        let command: String
        if isArmed || utteranceArmed {
            command = WakeWord.strip(text) ?? text
        } else if let afterWake = WakeWord.strip(text) {
            command = afterWake
        } else {
            return  // background speech, not for Elio
        }
        if command.isEmpty {
            activate()
            return
        }
        if answerByVoice(command) { return }
        if let q = questions.first {
            // A pending question takes the next thing the user says as its answer.
            answer(q, text: command)
            let reply: String
            switch ConfirmationAnswer.parse(command, risk: .normal) {
            case .approve: reply = "Grazie, \(addressAs), procedo."
            case .deny: reply = "Va bene, \(addressAs), mi fermo."
            default: reply = "Grazie, \(addressAs), ne tengo conto."
            }
            speaker.enqueue(reply)
            speaker.endUtterance()
            return
        }
        send(command)
    }

    // MARK: - Daemon

    private func send(_ text: String) {
        if speaker.isSpeaking { speaker.stop() }
        armedUntil = nil
        splitter = SentenceSplitter()
        requestStart = Date()
        turns.append(Turn(role: "user", text: text))
        turns.append(Turn(role: "elio", text: ""))
        spokenText = ""
        sentenceBudget = Self.wantsDetail(text) ? 50 : spokenSentences
        currentRequestId = client.say(text)
        VoiceLog.write("→ daemon: '\(text)'")
        firstDeltaLogged = false
        firstAudioLogged = false
        // Open the TTS socket while Claude is thinking: saves the ~0.4s handshake.
        replyStreaming = speaker.beginStream()
        localAckSpoken = false
        replySentences = 0
        scheduleFiller(for: currentRequestId, request: text)
        state = .thinking
    }

    private func handle(_ msg: ServerMessage) {
        if msg.type == .event {
            handleEvent(msg)
            return
        }
        guard msg.id != nil, msg.id == currentRequestId else { return }
        switch msg.type {
        case .delta:
            appendToReply(msg.text ?? "")
            if !firstDeltaLogged {
                firstDeltaLogged = true
                VoiceLog.write(String(format: "timing: first claude text %.2fs", Date().timeIntervalSince(requestStart)))
            }
            for sentence in splitter.push(msg.text ?? "") { speakReply(sentence) }
        case .done:
            if msg.route == .local {
                appendToReply(msg.text ?? "")
                // Local replies are short and cached: drop the pre-opened stream.
                if replyStreaming { speaker.cancelStream(); replyStreaming = false }
                speaker.enqueue(msg.text ?? "", lang: msg.lang)
            } else if let rest = splitter.flush() {
                speakReply(rest)
            }
            if replyStreaming { speaker.endStream() }
            if let i = turns.lastIndex(where: { $0.role == "elio" }) {
                turns[i].route = msg.route
                turns[i].latencyMs = msg.latencyMs
            }
            speaker.endUtterance()
            currentRequestId = nil
            if !speaker.isSpeaking { state = .listening }
        case .error:
            if replyStreaming { speaker.cancelStream(); replyStreaming = false }
            appendToReply("⚠️ \(msg.text ?? "errore")")
            speaker.enqueue("Ho avuto un problema a rispondere.")
            speaker.endUtterance()
            currentRequestId = nil
        default:
            break
        }
        trimTurns()
    }

    private func handleEvent(_ msg: ServerMessage) {
        switch msg.kind {
        case "briefStart", "recapStart":
            if briefOpeningEnabled, msg.kind == "briefStart" { playOpening() }
            routineMode = true
            litTools = [:]
            onRoutineStart?()
            routineSpeaking = false
        case "brief", "recap":
            routineSpeaking = true
        case "taskLog":
            if let entry = TaskLogEntry.fromJSON(msg.payload) {
                var log = taskLogs[entry.taskId] ?? []
                log.append(entry)
                if log.count > 300 { log.removeFirst(log.count - 300) }
                taskLogs[entry.taskId] = log
            }
        case "question":
            if let q = QuestionRequest.fromJSON(msg.payload), !questions.contains(where: { $0.id == q.id }) {
                questions.append(q)
                armedUntil = Date().addingTimeInterval(20)
            }
        case "questionResolved":
            questions.removeAll { $0.id == msg.id }
        case "integrationUpdated":
            break  // Elio configures integrations itself; Settings just shows the result
        case "task", "taskDone":
            if let info = TaskInfo.fromJSON(msg.payload) {
                if let i = tasks.firstIndex(where: { $0.id == info.id }) { tasks[i] = info } else { tasks.append(info) }
                if tasks.count > 30 { tasks.removeFirst(tasks.count - 30) }
            }
        case "confirm":
            if let req = ConfirmRequest.fromJSON(msg.payload), !confirmations.contains(where: { $0.id == req.id }) {
                confirmations.append(req)
                armedUntil = Date().addingTimeInterval(30)  // the answer needs no wake word
            }
        case "confirmResolved":
            confirmations.removeAll { $0.id == msg.id }
        case "diff":
            if let d = DiffPayload.fromJSON(msg.payload) {
                diffs.insert(d, at: 0)
                if diffs.count > 10 { diffs.removeLast() }
                diffSignal += 1
            }
        case "tool":
            guard let id = msg.id, let name = msg.text else { break }
            if msg.payload?.contains("start") == true {
                activeTools.insert(name)
                // Show the user where Elio is working: bring Chrome forward once per request.
                if name.hasPrefix("mcp__claude-in-chrome__"), browserShownFor != currentRequestId {
                    browserShownFor = currentRequestId
                    if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                        NSWorkspace.shared.openApplication(at: chrome, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                if currentRequestId != nil, firstDeltaLogged {
                    // Text so far was the acknowledgement ("Certo, Signore, controllo…"): say it now,
                    // and give the real answer its own sentence budget.
                    if replyStreaming { speaker.endStream(); replyStreaming = false }
                    sentenceBudget = max(sentenceBudget, spokenSentences)
                    splitterFlushForAck()
                }
                if routineMode, litTools[name] == nil { litTools[name] = Date() }
                activity.append(ToolActivity(id: id, name: name, running: true, ok: true))
                if activity.count > 40 { activity.removeFirst(activity.count - 40) }
            } else {
                activeTools.remove(name)
                if let i = activity.firstIndex(where: { $0.id == id }) {
                    activity[i].running = false
                    activity[i].ok = msg.isError != true
                    activity[i].ms = msg.latencyMs
                }
            }
        case "card":
            if let c = CardPayload.fromJSON(msg.payload) {
                cards.insert(c, at: 0)
                if cards.count > 10 { cards.removeLast() }
                turns.append(Turn(role: "card", text: "\(c.title)\n\(c.body)"))
            }
        default:
            break
        }
        guard msg.speak == true, let text = msg.text else { return }
        turns.append(Turn(role: "event", text: text, route: msg.route))
        spokenText = text
        // Split long proactive messages (briefing) so the voice starts on the first sentence.
        var splitter = SentenceSplitter()
        for sentence in splitter.push(text + " ") { speaker.enqueue(sentence, lang: msg.lang) }
        if let rest = splitter.flush() { speaker.enqueue(rest, lang: msg.lang) }
        speaker.endUtterance()
        trimTurns()
    }

    /// Answers an agent's or the assistant's question (typed in the HUD or spoken).
    public func answer(_ q: QuestionRequest, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        questions.removeAll { $0.id == q.id }
        client.send(.answer(id: q.id, text: t))
        turns.append(Turn(role: "user", text: "↳ \(t)"))
    }

    /// Answers a confirmation from the HUD buttons.
    public func answer(_ req: ConfirmRequest, approved: Bool) {
        confirmations.removeAll { $0.id == req.id }
        client.send(.confirm(id: req.id, approved: approved))
        turns.append(Turn(role: "user", text: approved ? "✓ Confermato: \(req.detail)" : "✕ Annullato"))
    }

    /// Spoken answer to the oldest pending confirmation. Dangerous actions accept only
    /// an explicit "confermo"; a plain "sì" is not enough. Returns true if consumed.
    private func answerByVoice(_ text: String) -> Bool {
        guard let req = confirmations.first else { return false }
        switch ConfirmationAnswer.parse(text, risk: req.risk) {
        case .approve:
            answer(req, approved: true)
            speaker.enqueue("Grazie, \(addressAs), procedo.")
            speaker.endUtterance()
        case .deny:
            answer(req, approved: false)
            speaker.enqueue("Va bene, \(addressAs), mi fermo.")
            speaker.endUtterance()
        case .needsExplicit:
            speaker.enqueue("Mi conferma che posso procedere, \(addressAs)? Mi basta un sì.")
            speaker.endUtterance()
            armedUntil = Date().addingTimeInterval(20)
        case .unrelated:
            speaker.enqueue("Mi scusi, \(addressAs): procedo? Sì o no.")
            speaker.endUtterance()
            armedUntil = Date().addingTimeInterval(20)
        }
        return true
    }

    /// If Claude is slow to start, say a short cached filler so the silence doesn't feel dead.
    /// If Claude hasn't said anything after 0.9s, acknowledge right away with a cached,
    /// request-specific phrase ("Certo, Signore, controllo l'agenda.").
    private func scheduleFiller(for id: String?, request: String) {
        guard let id, let phrase = Acknowledgement.phrase(for: request, addressAs: addressAs) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard self.currentRequestId == id, !self.firstDeltaLogged, !self.speaker.isSpeaking else { return }
            self.localAckSpoken = true
            self.speaker.enqueue(phrase)
            self.speaker.endUtterance()
        }
    }

    private var localAckSpoken = false
    private var replySentences = 0

    private func appendToReply(_ text: String) {
        spokenText += text
        if let i = turns.lastIndex(where: { $0.role == "elio" }) { turns[i].text += text }
    }

    private func trimTurns() {
        if turns.count > 60 { turns.removeFirst(turns.count - 60) }
    }

    // MARK: - Brief opening theme

    private var opening: AVAudioPlayer?

    /// ~/Library/Application Support/Elio/sounds/brief-opening.m4a, if present.
    private func playOpening() {
        let url = ElioPaths.support.appendingPathComponent("sounds/brief-opening.m4a")
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 0.8
        player.play()
        opening = player
    }

    /// Elio starts talking: the theme fades out under the voice.
    private func fadeOpening() {
        guard let player = opening, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: 2.0)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.1))
            player.stop()
            if self.opening === player { self.opening = nil }
        }
    }

    private func speakingChanged(_ speaking: Bool) {
        if speaking { fadeOpening() } else { lastSpeechEnd = Date() }
        if speaking {
            state = .speaking
            pipeline.speaking = true
        } else {
            pipeline.speaking = false
            if routineSpeaking {
                // Keep the lit network on screen a moment after the recap, then back to normal.
                routineSpeaking = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    self.routineMode = false
                }
            }
            if state == .speaking { state = muted ? .muted : .listening }
            // Follow-up window: answer without repeating the wake word (never shorten a longer one).
            let followUp = Date().addingTimeInterval(Self.followUpWindow)
            armedUntil = max(armedUntil ?? followUp, followUp)
        }
    }

    private func updateLevel(_ db: Float) {
        let normalized = max(0, min(1, (db + 60) / 50))
        level = level * 0.6 + normalized * 0.4
    }
}

/// Runs on the audio thread: VAD, pre-roll ring buffer, routing buffers to the transcriber.
public final class InputPipeline: @unchecked Sendable {
    public enum Event { case speechStart, speechEnd }

    public var onEvent: ((Event) -> Void)?
    var onLevel: ((Float) -> Void)?
    var inputFormat: AVAudioFormat?
    var speaking: Bool {
        get { lock.withLock { vad.extraMarginDb > 0 } }
        set { lock.withLock { vad.extraMarginDb = newValue ? 6 : 0 } }
    }

    private let lock = NSLock()
    private var vad = VoiceActivityDetector()
    private var preRoll: [AVAudioPCMBuffer] = []
    /// Audio since speech start, held until the transcriber is ready.
    private var pending: [AVAudioPCMBuffer] = []
    private var capturing = false
    private var target: UtteranceTranscriber?
    private var levelTick = 0

    public init() {}

    public func process(_ buffer: AVAudioPCMBuffer, levelDb: Float) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let event = lock.withLock { () -> VoiceActivityDetector.Event? in
            let event = vad.process(levelDb: levelDb, duration: duration)
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return event }
            if let target {
                target.feed(copy)
            } else if event == .speechStart {
                // ~0.5s before the trigger so the first syllable isn't clipped.
                pending = preRoll + [copy]
                capturing = true
            } else if capturing {
                pending.append(copy)
            }
            preRoll.append(copy)
            let keep = Int(0.5 / max(duration, 0.005))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            return event
        }
        levelTick += 1
        if levelTick % 3 == 0 { onLevel?(levelDb) }
        if levelTick % 50 == 0 {
            let (floor, inSpeech) = lock.withLock { (vad.noiseFloorDb, vad.inSpeech) }
            VoiceLog.write(String(format: "level %.1f dB floor %.1f inSpeech %@ frames %d @ %.0f Hz ch %d",
                                  levelDb, floor, inSpeech ? "Y" : "N", buffer.frameLength,
                                  buffer.format.sampleRate, buffer.format.channelCount))
        }
        if let event { onEvent?(event == .speechStart ? .speechStart : .speechEnd) }
    }

    public func attach(_ transcriber: UtteranceTranscriber) {
        lock.withLock {
            for b in pending { transcriber.feed(b) }
            pending = []
            capturing = false
            target = transcriber
        }
    }

    public func resetVAD() {
        lock.withLock {
            vad = VoiceActivityDetector()
            pending = []
            capturing = false
            preRoll = []
        }
    }

    public func detach() {
        lock.withLock {
            target = nil
            capturing = false
            pending = []
        }
    }
}
