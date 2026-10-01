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

    private let config: JarvisConfig
    private let audio = AudioIO()
    private let pipeline: InputPipeline
    private let speaker: Speaker
    private let client: DaemonClient
    private var transcriber: UtteranceTranscriber?
    private var beginTask: Task<Void, Never>?
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
        switch event {
        case .speechStart:
            if speaker.isSpeaking {
                // Barge-in: the user talks over Jarvis.
                interrupt()
            }
            guard alwaysListening || isArmed else { return }
            beginUtterance()
        case .speechEnd:
            Task { await endUtterance() }
        }
    }

    private var isArmed: Bool { armedUntil.map { $0 > Date() } ?? false }

    private func beginUtterance() {
        guard let format = audio.inputFormat else { return }
        let t = UtteranceTranscriber(locale: Locale(identifier: "it_IT"))
        t.onPartial = { [weak self] text in Task { @MainActor in self?.partial = text } }
        transcriber = t
        partial = ""
        if state != .thinking { state = .hearing }
        beginTask = Task {
            do {
                try await t.begin(inputFormat: format)
                pipeline.attach(t)  // flushes audio captured since speech start
            } catch {
                lastError = "STT: \(error)"
            }
        }
    }

    private func endUtterance() async {
        guard let t = transcriber else { return }
        transcriber = nil
        await beginTask?.value  // short utterances can end before the analyzer is ready
        beginTask = nil
        pipeline.detach()
        let text = await t.finish()
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
        state = .thinking
    }

    private func handle(_ msg: ServerMessage) {
        if msg.type == .event, let text = msg.text {
            turns.append(Turn(role: "event", text: text, route: msg.route))
            speaker.enqueue(text, lang: msg.lang)
            speaker.endUtterance()
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
final class InputPipeline: @unchecked Sendable {
    enum Event { case speechStart, speechEnd }

    var onEvent: ((Event) -> Void)?
    var onLevel: ((Float) -> Void)?
    var inputFormat: AVAudioFormat?
    var speaking: Bool {
        get { lock.withLock { vad.extraMarginDb > 0 } }
        set { lock.withLock { vad.extraMarginDb = newValue ? 8 : 0 } }
    }

    private let lock = NSLock()
    private var vad = VoiceActivityDetector()
    private var preRoll: [AVAudioPCMBuffer] = []
    /// Audio since speech start, held until the transcriber is ready.
    private var pending: [AVAudioPCMBuffer] = []
    private var capturing = false
    private var target: UtteranceTranscriber?
    private var levelTick = 0

    func process(_ buffer: AVAudioPCMBuffer, levelDb: Float) {
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
        if let event { onEvent?(event == .speechStart ? .speechStart : .speechEnd) }
    }

    func attach(_ transcriber: UtteranceTranscriber) {
        lock.withLock {
            for b in pending { transcriber.feed(b) }
            pending = []
            capturing = false
            target = transcriber
        }
    }

    func detach() {
        lock.withLock {
            target = nil
            capturing = false
            pending = []
        }
    }
}
