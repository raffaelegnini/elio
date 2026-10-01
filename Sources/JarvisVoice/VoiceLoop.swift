import AVFoundation
import Foundation
import JarvisCore
import Observation

/// The conversation loop: mic → VAD → on-device STT → wake word → jarvisd → TTS.
/// Also owns barge-in and the follow-up window (reply without saying "Jarvis" again).
@MainActor
@Observable
public final class VoiceLoop {
    public enum State: String { case idle, listening, hearing, thinking, speaking, off }

    public struct Turn: Identifiable {
        public let id = UUID()
        public let role: String   // "user" | "jarvis" | "event"
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
    public var alwaysListening = true
    /// Background agents, newest last.
    public private(set) var tasks: [TaskInfo] = []
    /// Actions waiting for the user's explicit OK.
    public private(set) var confirmations: [ConfirmRequest] = []
    public private(set) var diffs: [DiffPayload] = []
    public private(set) var cards: [CardPayload] = []
    /// Bumped when a new diff arrives, so the UI can open the review panel.
    public private(set) var diffSignal = 0

    private let config: JarvisConfig
    private let audio = AudioIO()
    private let pipeline: InputPipeline
    private let speaker: Speaker
    private let client: DaemonClient
    private var transcriber: UtteranceTranscriber?
    private var beginTask: Task<Void, Never>?
    private var utteranceArmed = false
    private var wakeSeen = false
    private var abandoned = false
    private var armedUntil: Date?
    private var currentRequestId: String?
    private var splitter = SentenceSplitter()
    private var requestStart = Date()

    static let followUpWindow: TimeInterval = 6
    static let acks = ["Sì?", "Dimmi."]

    public init(config: JarvisConfig, token: String) {
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

        pipeline.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        pipeline.onLevel = { [weak self] db in Task { @MainActor in self?.updateLevel(db) } }
        audio.onInput = { [pipeline] buffer, db in pipeline.process(buffer, levelDb: db) }

        do {
            try await UtteranceTranscriber.ensureModel(locale: Locale(identifier: "it_IT"))
            try audio.start()
            pipeline.inputFormat = audio.inputFormat
            VoiceLog.write("audio started, input format: \(String(describing: audio.inputFormat))")
            state = .listening
            speaker.warmCache(Self.acks)
        } catch {
            lastError = "Audio: \(error.localizedDescription)"
            state = .off
        }
    }

    /// Hotkey / click on the orb: talk now without the wake word, or interrupt Jarvis.
    public func activate() {
        if speaker.isSpeaking {
            interrupt()
            return
        }
        armedUntil = Date().addingTimeInterval(8)
        speaker.enqueue(Self.acks[0])
        speaker.endUtterance()
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
        VoiceLog.write("vad \(event) speaking=\(speaker.isSpeaking) armed=\(isArmed)")
        switch event {
        case .speechStart:
            if speaker.isSpeaking {
                // Barge-in: the user talks over Jarvis.
                interrupt()
            }
            guard alwaysListening || isArmed else { return }
            beginUtterance()
        case .speechEnd:
            if abandoned { abandoned = false; return }
            Task { await endUtterance() }
        }
    }

    private var isArmed: Bool { armedUntil.map { $0 > Date() } ?? false }

    private func beginUtterance() {
        guard let format = audio.inputFormat else { return }
        let t = UtteranceTranscriber(locale: Locale(identifier: "it_IT"))
        let armed = isArmed
        utteranceArmed = armed
        wakeSeen = false
        abandoned = false
        t.onPartial = { [weak self] text in Task { @MainActor in self?.partialChanged(text, from: t) } }
        transcriber = t
        partial = ""
        // Only light up when the user is clearly talking to Jarvis.
        if armed, state != .thinking { state = .hearing }
        beginTask = Task {
            do {
                try await t.begin(inputFormat: format)
                pipeline.attach(t)  // flushes audio captured since speech start
            } catch {
                lastError = "STT: \(error)"
            }
        }
    }

    /// Unarmed speech is only for the wake word: show it once "Jarvis" is heard,
    /// drop it as soon as it's clearly someone talking about something else.
    private func partialChanged(_ text: String, from t: UtteranceTranscriber) {
        guard transcriber === t, !abandoned else { return }
        if utteranceArmed || wakeSeen {
            partial = text
            return
        }
        if WakeWord.strip(text) != nil {
            wakeSeen = true
            partial = text
            if state != .thinking { state = .hearing }
        } else if text.split(separator: " ").count >= 2 {
            abandonUtterance()
        }
    }

    private func abandonUtterance() {
        abandoned = true
        pipeline.detach()
        if let t = transcriber { Task { await t.cancel() } }
        transcriber = nil
        beginTask = nil
        partial = ""
    }

    private func endUtterance() async {
        guard let t = transcriber else { return }
        transcriber = nil
        await beginTask?.value  // short utterances can end before the analyzer is ready
        beginTask = nil
        pipeline.detach()
        let text = await t.finish()
        VoiceLog.write("stt final: '\(text)' (fed \(t.fedBuffers) buffers)")
        partial = ""
        if state == .hearing { state = .listening }
        guard !text.isEmpty else { return }

        let command: String
        if isArmed {
            command = WakeWord.strip(text) ?? text
        } else if let afterWake = WakeWord.strip(text) {
            command = afterWake
        } else {
            return  // background speech, not for Jarvis
        }
        if command.isEmpty {
            activate()
            return
        }
        if answerByVoice(command) { return }
        send(command)
    }

    // MARK: - Daemon

    private func send(_ text: String) {
        if speaker.isSpeaking { speaker.stop() }
        armedUntil = nil
        splitter = SentenceSplitter()
        requestStart = Date()
        turns.append(Turn(role: "user", text: text))
        turns.append(Turn(role: "jarvis", text: ""))
        currentRequestId = client.say(text)
        VoiceLog.write("→ daemon: '\(text)'")
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
            for sentence in splitter.push(msg.text ?? "") { speaker.enqueue(sentence) }
        case .done:
            if msg.route == .local {
                appendToReply(msg.text ?? "")
                speaker.enqueue(msg.text ?? "", lang: msg.lang)
            } else if let rest = splitter.flush() {
                speaker.enqueue(rest)
            }
            if let i = turns.lastIndex(where: { $0.role == "jarvis" }) {
                turns[i].route = msg.route
                turns[i].latencyMs = msg.latencyMs
            }
            speaker.endUtterance()
            currentRequestId = nil
            if !speaker.isSpeaking { state = .listening }
        case .error:
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
        case "task", "taskDone":
            if let info = TaskInfo.fromJSON(msg.payload) {
                if let i = tasks.firstIndex(where: { $0.id == info.id }) { tasks[i] = info } else { tasks.append(info) }
                if tasks.count > 30 { tasks.removeFirst(tasks.count - 30) }
            }
        case "confirm":
            if let req = ConfirmRequest.fromJSON(msg.payload), !confirmations.contains(where: { $0.id == req.id }) {
                confirmations.append(req)
            }
        case "confirmResolved":
            confirmations.removeAll { $0.id == msg.id }
        case "diff":
            if let d = DiffPayload.fromJSON(msg.payload) {
                diffs.insert(d, at: 0)
                if diffs.count > 10 { diffs.removeLast() }
                diffSignal += 1
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
        // Split long proactive messages (briefing) so the voice starts on the first sentence.
        var splitter = SentenceSplitter()
        for sentence in splitter.push(text + " ") { speaker.enqueue(sentence, lang: msg.lang) }
        if let rest = splitter.flush() { speaker.enqueue(rest, lang: msg.lang) }
        speaker.endUtterance()
        trimTurns()
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
            speaker.enqueue("Procedo.")
            speaker.endUtterance()
        case .deny:
            answer(req, approved: false)
            speaker.enqueue("Annullato.")
            speaker.endUtterance()
        case .needsExplicit:
            speaker.enqueue("Per questa azione mi serve che tu dica esattamente: confermo.")
            speaker.endUtterance()
        case .unrelated:
            return false
        }
        return true
    }

    private func appendToReply(_ text: String) {
        if let i = turns.lastIndex(where: { $0.role == "jarvis" }) { turns[i].text += text }
    }

    private func trimTurns() {
        if turns.count > 60 { turns.removeFirst(turns.count - 60) }
    }

    private func speakingChanged(_ speaking: Bool) {
        if speaking {
            state = .speaking
            pipeline.speaking = true
        } else {
            pipeline.speaking = false
            if state == .speaking { state = .listening }
            // Follow-up window: answer without repeating the wake word.
            armedUntil = Date().addingTimeInterval(Self.followUpWindow)
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
        set { lock.withLock { vad.extraMarginDb = newValue ? 20 : 0 } }
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

    public func detach() {
        lock.withLock {
            target = nil
            capturing = false
            pending = []
        }
    }
}
