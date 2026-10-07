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
    /// The to-do list as the daemon last published it (dashboard panel).
    public var todoBoard: TodoBoard?
    /// When each tool first fired during the current routine.
    public private(set) var litTools: [String: Date] = [:]
    private var routineSpeaking = false
    private var routineLive = false
    private var routineStreaming = false
    private var routineText = ""
    private var routineSplitter = SentenceSplitter()

    /// Claude is now waiting for the user (confirmation/question): close the speech stream it was
    /// feeding, or the question would queue behind a stream that never ends (and block answers).
    private func closeOpenStreams() {
        if routineStreaming {
            if let rest = routineSplitter.flush() { speaker.streamSentence(rest, flush: true) }
            speaker.endStream()
            routineStreaming = false
        }
        if replyStreaming {
            if let rest = splitter.flush() { speaker.streamSentence(rest, flush: true) }
            speaker.endStream()
            replyStreaming = false
        }
    }

    static func greeting(addressAs: String, brief: Bool) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello = hour < 13 ? "Buongiorno" : hour < 18 ? "Buon pomeriggio" : "Buonasera"
        return brief ? "\(hello), \(addressAs). Le faccio il briefing di oggi."
                     : "\(hello), \(addressAs). Le faccio il riassunto di oggi."
    }
    public var alwaysListening = true
    /// Background agents, newest last.
    public private(set) var tasks: [TaskInfo] = []
    /// Squads of agents and their message board.
    public private(set) var squads: [SquadInfo] = []
    public private(set) var squadMessages: [SquadMessage] = []
    /// Timeline of each workflow (decisions, corrections, completed steps…), newest last.
    public var workflowEvents: [String: [WorkflowEvent]] = [:]
    /// Claude token usage (refreshed by the daemon every minute).
    public private(set) var usage: UsageSnapshot?

    /// Fills the observable state with sample data (`ElioApp --snapshot`, UI checks without a daemon).
    public func loadSample(tasks: [TaskInfo], squads: [SquadInfo], messages: [SquadMessage], usage: UsageSnapshot?,
                           routine: Bool, lit: [String], state: State) {
        self.tasks = tasks; self.squads = squads; self.squadMessages = messages; self.usage = usage
        self.routineMode = routine
        self.litTools = Dictionary(uniqueKeysWithValues: lit.map { ($0, Date()) })
        self.state = state
        self.connected = true
    }
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
    private var utteranceBegan = Date()

    // MARK: Long requests

    /// A request that may not be over: the user paused mid-sentence ("…e poi"), or a long dictation the VAD
    /// cut. Held for a moment; if they go on, the next segment is joined to it instead of starting a new turn.
    private var pendingCommand: String?
    private var pendingFlush: Task<Void, Never>?
    /// Id of the request being spoken: partial transcripts go to the daemon under it (it thinks ahead),
    /// and the final `say` reuses it so the two are joined.
    private var prepKey: String?
    private var prepWords = 0
    private var prepSentAt = Date.distantPast

    /// Partial transcript of a request for Elio: sent ahead every few words so the daemon can get ready.
    private func sendPrep(_ live: String) {
        let text = [pendingCommand, WakeWord.strip(live) ?? live].compactMap { $0 }.joined(separator: " ")
        let words = text.split(separator: " ").count
        guard words >= 6, words - prepWords >= 4, Date().timeIntervalSince(prepSentAt) > 1.2 else { return }
        let key = prepKey ?? UUID().uuidString
        prepKey = key
        prepWords = words
        prepSentAt = Date()
        client.send(.prepare(id: key, text: text))
    }

    /// Joins this segment to what was held, then either waits for more or sends.
    private func continueOrSend(_ command: String, cutByLimit: Bool) {
        pendingFlush?.cancel()
        let full = [pendingCommand, command].compactMap { $0 }.joined(separator: " ")
        let wait = EndOfTurn.wait(full, cutByLimit: cutByLimit)
        guard wait > 0 else {
            pendingCommand = nil
            send(full, voice: true)
            return
        }
        VoiceLog.write(String(format: "holding %.1fs for more: '%@'", wait, full))
        pendingCommand = full
        partial = full
        state = .hearing
        armedUntil = Date().addingTimeInterval(wait + 2)
        schedulePendingFlush(after: wait)
    }

    private func schedulePendingFlush(after wait: TimeInterval) {
        pendingFlush?.cancel()
        pendingFlush = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            // A segment in progress may be the rest of the request: give it a few seconds to end (its
            // endUtterance joins it and reschedules), then send what we have anyway — never hold forever.
            let deadline = Date().addingTimeInterval(6)
            while !Task.isCancelled, self.inUtterance, !self.speaker.isSpeaking, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, let text = self.pendingCommand else { return }
            self.pendingCommand = nil
            self.partial = ""
            self.send(text, voice: true)
        }
    }
    /// When Elio last stopped talking (its voice may still echo in the room).
    private var lastSpeechEnd = Date.distantPast
    private var emptyWithAEC = 0

    // MARK: Speaker verification
    private let voiceTap = VoiceTap()
    private var speakerID: SpeakerID?
    private var verifyOwner = true
    private var ownerThreshold: Float = 0.4
    private var utteranceStart = 0
    private var bargeChecked = false
    /// Enrollment in progress: clips of the owner reading the sentences.
    public private(set) var enrollment: [[Float]]? = nil
    public private(set) var enrollmentStep = 0
    public static let enrollmentSentences = [
        "Buongiorno Elio, oggi vorrei sapere cosa ho in agenda e se qualcuno mi ha scritto.",
        "Ricordami di chiamare il cliente domani mattina e prepara il riepilogo del progetto.",
        "Scrivi al team che la nuova versione del sito è pronta e che la rilasciamo stasera.",
    ]
    public var isOwnerEnrolled: Bool { speakerID?.isEnrolled ?? false }
    public var speakerModelAvailable: Bool { speakerID != nil }
    /// Last verification score, shown in Settings.
    public private(set) var lastOwnerScore: Float?

    private var ownerGateActive: Bool { verifyOwner && (speakerID?.isEnrolled ?? false) }

    /// True if the audio of the current utterance is the owner (or verification is off).
    /// `threshold` overrides the configured one (lower for short answers to Elio's own questions:
    /// "Sì" lasts half a second and scores ~0.4 even for the owner; other people score < 0.3).
    /// Under ~1.2 s ("Elio", "sì") the voiceprint is unreliable: no verdict, the command passes.
    private func isOwner(minSeconds: Double = 1.2, threshold: Double? = nil) -> Bool? {
        guard ownerGateActive, let sid = speakerID else { return true }
        let samples = voiceTap.samples(since: utteranceStart)
        guard Double(samples.count) / SpeakerID.sampleRate >= minSeconds, let score = sid.bestWindowScore(samples) else { return nil }
        lastOwnerScore = score
        let limit = Float(threshold ?? Double(ownerThreshold))
        VoiceLog.write(String(format: "speaker score %.2f (threshold %.2f)", score, limit))
        return score >= limit
    }

    /// Dangerous confirmations by voice: only with an enrolled voiceprint that recognizes the owner on at least
    /// 1.5 s of speech. No verdict (too short) or no voiceprint means no.
    private func ownerVerifiedForDangerous() -> Bool {
        guard ownerGateActive else { return false }
        return isOwner(minSeconds: 1.5) == true
    }

    /// Starts recording the owner's voice: they read `enrollmentSentences` aloud.
    public func startEnrollment() {
        guard speakerID != nil else { lastError = "Modello vocale mancante: reinstalla Elio."; return }
        enrollment = []
        enrollmentStep = 0
        speaker.enqueue("Leggi ad alta voce le tre frasi che vedi, una alla volta.")
        speaker.endUtterance()
    }

    public func cancelEnrollment() { enrollment = nil; enrollmentStep = 0 }

    public func forgetOwnerVoice() { speakerID?.forget() }

    private func enrollmentClip() {
        let clip = voiceTap.samples(since: utteranceStart, lead: 0.1)
        guard Double(clip.count) / SpeakerID.sampleRate >= 1.5 else { return }
        enrollment?.append(clip)
        enrollmentStep = enrollment?.count ?? 0
        guard enrollmentStep >= Self.enrollmentSentences.count, let clips = enrollment else { return }
        let ok = speakerID?.enroll(clips) ?? false
        enrollment = nil
        VoiceLog.write("speaker enrollment \(ok ? "saved" : "failed")")
        speaker.enqueue(ok ? "Perfetto, \(addressAs): da ora riconosco la sua voce." : "Non sono riuscito a registrarla, riproviamo.")
        speaker.endUtterance()
    }
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
        if replyStreaming {
            speaker.streamSentence(rest, flush: true)
        } else {
            speaker.enqueue(rest)
            speaker.endUtterance()
        }
    }

    /// The reply is being built across tool calls ("Slack: due menzioni… Teamwork: tre task…"):
    /// every sentence is spoken as soon as it's written, on the socket that stays open between tools.
    private var replyHadTools = false

    private func speakReply(_ sentence: String) {
        replySentences += 1
        // We already acknowledged locally: skip Claude's own "Certo, Signore, controllo…".
        if localAckSpoken, replySentences == 1, Acknowledgement.isAcknowledgement(sentence) { return }
        guard sentenceBudget > 0 else { return }
        sentenceBudget -= 1
        if replyStreaming {
            if replyHadTools {
                // Text arrives in bursts between tools: say each sentence now, keep the socket for the next one.
                speaker.streamSentence(sentence, flush: true)
            } else {
                speaker.streamSentence(sentence)
                // All that will be spoken is in: close now so it's generated in one fluid take.
                if sentenceBudget == 0 {
                    speaker.endStream()
                    replyStreaming = false
                }
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
    /// Owner check for answers to a pending confirmation/question (dangerous ones still need "confermo").
    static let answerThreshold = 0.35
    static let wakeWindow: TimeInterval = 10
    static let acks = ["Sì?", "Dimmi."]

    public init(config: ElioConfig, token: String) {
        self.config = config
        pipeline = InputPipeline()
        speaker = Speaker(audio: audio, voiceId: config.elevenLabsVoiceId, model: config.elevenLabsModel)
        client = DaemonClient(port: config.port, token: token)
    }

    public func start() async {
        // The on-device model that tells who a sentence is for: loaded now, ready in ~0.5 s when needed.
        Addressee.prewarm()
        client.onMessage = { [weak self] msg in Task { @MainActor in self?.handle(msg) } }
        client.onConnectionChange = { [weak self] up in
            Task { @MainActor in
                guard let self else { return }
                self.connected = up
                // A restarted daemon forgets: tell it again that the Mac is at rest.
                if up, self.resting { self.client.send(.idle(true)) }
            }
        }
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
        let voiceTap = self.voiceTap
        audio.onInput = { [pipeline, stt] buffer, db in
            stt.feed(buffer)
            voiceTap.feed(buffer)
            pipeline.process(buffer, levelDb: db)
        }
        Task { [weak self] in
            let sid = await Task.detached { SpeakerID() }.value
            self?.speakerID = sid
        }

        muted = UserDefaults.standard.bool(forKey: "elio.muted")
        voiceId = config.elevenLabsVoiceId
        applySettings(config)
        do {
            VoiceLog.write("startup: speech model…")
            try await UtteranceTranscriber.ensureModel(locale: Locale(identifier: "it_IT"))
            VoiceLog.write("startup: audio…")
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
            speaker.warmCache(Self.acks + Acknowledgement.all(addressAs: addressAs)
                              + ["Buongiorno", "Buon pomeriggio", "Buonasera"].flatMap { h in
                                  ["\(h), \(addressAs). Le faccio il briefing di oggi.",
                                   "\(h), \(addressAs). Le faccio il riassunto di oggi."] })
        } catch {
            VoiceLog.write("startup failed: \(error)")
            lastError = "Audio: \(error.localizedDescription)"
            state = .off
        }
    }

    /// Hotkey / click on the orb: talk now without the wake word, or interrupt Elio.
    public func activate() {
        lastInteraction = Date()
        if resting, onRestCommand?("") == true { return }
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
    /// `persist: false` for temporary changes (rest mode) that must not survive a restart.
    public func setMuted(_ on: Bool, persist: Bool = true) {
        guard on != muted else { return }
        do {
            try audio.setInputEnabled(!on)
        } catch {
            lastError = "Microfono: \(error.localizedDescription)"
            return
        }
        muted = on
        if persist { UserDefaults.standard.set(on, forKey: "elio.muted") }
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
    public var onSettingsChanged: ((ElioConfig) -> Void)?
    /// A card to keep on screen (the app opens it in its own window).
    public var onCard: ((CardPayload) -> Void)?
    public var onOpenView: ((String, String, String) -> Void)?

    // MARK: Rest mode (the app's IdleMode decides; the loop only applies it)

    /// The Mac is at rest: events aren't spoken unless `onRestEvent` lets them through. Reported to the daemon.
    public var resting = false {
        didSet { if resting != oldValue { client.send(.idle(resting)) } }
    }
    /// An event arrived while resting: true = wake up and say it (ring first), false = keep quiet.
    public var onRestEvent: ((ServerMessage) -> Bool)?
    /// The user talked to Elio (or typed, or pressed the hotkey) while resting. True = handled, don't send it on.
    public var onRestCommand: ((String) -> Bool)?
    /// "Mettiti a riposo" / the phone's switch: the daemon asks the app to enter or leave rest mode.
    public var onIdleRequest: ((Bool) -> Void)?
    /// Last time the user talked to Elio or typed to it (voice use counts as being at the Mac).
    public private(set) var lastInteraction = Date()

    /// One line of Elio's own (the "welcome back" summary): said, or only shown when `speak` is false.
    public func announce(_ text: String, speak: Bool = true) {
        turns.append(Turn(role: "event", text: text))
        trimTurns()
        guard speak else { return }
        spokenText = text
        speaker.say(text)
    }
    /// "Aprimi il controller del login": the IDE on a path (and line).
    public var onOpenIDE: ((String, Int) -> Void)?
    /// "Apri una console sul DB di staging": a saved connection (id) to open in the IDE (terminal, files, console, tables).
    public var onIDEConnect: ((String, String) -> Void)?
    private var spokenSentences = 3
    private var briefOpeningEnabled = true

    /// Settings saved: apply what the app owns right away (the daemon restarts on its own).
    public func applySettings(_ config: ElioConfig) {
        spokenSentences = config.spokenSentences
        verifyOwner = config.speakerVerification
        ownerThreshold = Float(config.speakerThreshold)
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

    /// Elio's last words end with a question (or ask for something): the user may answer without "Elio".
    static func invitesReply(_ spoken: String) -> Bool {
        let t = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        let tail = String(t.suffix(160))
        if tail.contains("?") { return true }
        return tail.range(of: #"(mi dica|mi faccia sapere|me lo conferma|preferisce|vuole che|devo procedere|procedo\b)[^.!]*$"#,
                          options: .regularExpression) != nil
    }

    // MARK: Talking over Elio

    /// The user started talking while Elio speaks: its voice is lowered until we know what they want.
    private var bargeDucked = false
    /// Things said for Elio while it spoke, taken into account once it has finished.
    private var pendingRemarks: [String] = []

    private func duckForBarge(_ said: String) {
        guard !bargeDucked else { return }
        bargeDucked = true
        VoiceLog.write("user talking over Elio ('\(said)'): ducking")
        audio.player.volume = 0.3
        // If it was nothing (a cough, a word), the voice comes back by itself.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if self.bargeDucked, !self.inUtterance { self.restoreVoice() }
        }
    }

    private func restoreVoice() {
        bargeDucked = false
        audio.player.volume = 1
    }

    /// What the user said while Elio was speaking: stop, change course, keep it for later, or ignore it.
    private func handleSpokenOver(_ said: String) async {
        let saying = speaker.recentlySpoken(within: 15)
        if let owner = isOwner(minSeconds: 0.6), !owner {
            VoiceLog.write("spoken over Elio, not the owner: '\(said)'")
            restoreVoice()
            return
        }
        let verdict = await Addressee.classify(said: said, elioSaying: saying, wakeWord: WakeWord.strip(said) != nil)
        VoiceLog.write("spoken over Elio: '\(said)' → \(verdict.target.rawValue)/\(verdict.intent.rawValue)")
        restoreVoice()
        guard verdict.target != .other else { return }
        switch verdict.intent {
        case .stop:
            interrupt()
            if currentRequestId != nil { client.send(.cancelTurn) }
            state = .listening
        case .change, .request:
            let command = WakeWord.strip(said) ?? said
            if currentRequestId != nil { client.send(.cancelTurn) }
            speaker.stop()
            send("[Ti ho interrotto mentre dicevi: «\(String(saying.suffix(300)))»]\n\(command)")
        case .remark:
            // Elio finishes its sentence, then takes it into account (now, if it has already finished).
            pendingRemarks.append(WakeWord.strip(said) ?? said)
            if !speaker.isSpeaking { deliverRemarks() }
        case .backchannel:
            break
        }
    }

    /// Elio finished talking: what the user told it meanwhile becomes the next turn.
    private func deliverRemarks() {
        guard !pendingRemarks.isEmpty, currentRequestId == nil, !speaker.isSpeaking else { return }
        let said = pendingRemarks.joined(separator: " ")
        pendingRemarks = []
        send("[Mentre parlavi ti ho detto questo: tienine conto, rispondi in breve e poi continua da dove eri, senza ripetere]\n\(said)")
    }

    /// The user closed the exchange ("grazie", "ok perfetto", "basta"): no follow-up window after the reply.
    private var lastCommandClosed = false

    static func isClosing(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return t.range(of: #"^(ok(ay)?|va bene|perfetto|grazie( mille)?( elio)?|basta( così)?|a posto|niente|tutto qui|ottimo|bene|fatto)([ ,.!]+(grazie|perfetto|elio|così))*$"#,
                       options: .regularExpression) != nil
    }

    public func interrupt() {
        speaker.stop()
        currentRequestId = nil
        armedUntil = Date().addingTimeInterval(Self.followUpWindow)
        state = .listening
    }

    /// "Basta" / the stop button: silence Elio *and* stop the work in progress.
    public func stopEverything() {
        if currentRequestId != nil || state == .thinking { client.send(.cancelTurn) }
        interrupt()
    }

    public func controlTask(_ id: String, _ action: String) { client.send(.taskControl(id: id, action: action)) }


    /// Typed input from the HUD: same path as voice, skips the wake word. Attachments are files on this Mac:
    /// Elio gets their paths and opens them itself.
    public func submit(text: String, attachments: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let names = attachments.map(\.lastPathComponent).joined(separator: ", ")
        send(Attachments.compose(trimmed, paths: attachments.map(\.path)),
             display: attachments.isEmpty ? nil : [trimmed, "Allegati: \(names)"].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    // MARK: - Mic events

    private func handle(_ event: InputPipeline.Event) {
        switch event {
        case .speechStart:
            // With echo cancellation or headphones, interrupt as soon as real words are recognized
            // (see heard()): a cough or a keystroke must not cut Elio off.
            inUtterance = true
            utteranceBegan = Date()
            utteranceArmed = isArmed
            if pendingCommand != nil {
                // Maybe they're going on: this segment would continue the held request. The flush isn't
                // cancelled here (Elio's own voice or a noise also "starts speech"); it waits for this segment.
                utteranceArmed = true
            }
            wakeSeen = false
            utteranceStart = voiceTap.position
            bargeChecked = false
            // Drop what the recognizer heard before (background, Elio's own voice).
            stt?.resetSegment()
            partial = ""
            if utteranceArmed, state != .thinking { state = .hearing; speaker.prewarm() }
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
            guard !words.isEmpty else { return }
            var stop = false
            if ownerGateActive {
                // Only the owner's voice interrupts; people chatting nearby don't.
                if !bargeChecked, let owner = isOwner(minSeconds: 0.8) {
                    bargeChecked = true
                    stop = owner
                }
            } else {
                // No voiceprint: only the name, a stop word or an answer to Elio's question interrupt.
                let said: String = words.map { String($0) }.joined(separator: " ")
                var pendingAnswer = false
                if let req = confirmations.first {
                    pendingAnswer = ConfirmationAnswer.parse(said, risk: req.risk) != .unrelated
                }
                let stopWord = BargeIn.detect(text, whileSaying: speaker.recentlySpoken())
                stop = pendingAnswer || stopWord || WakeWord.strip(text) != nil
            }
            let said = words.map { String($0) }.joined(separator: " ")
            if stop, BargeIn.detect(text, whileSaying: speaker.recentlySpoken()) || confirmations.first != nil {
                // "Basta", "stop", or the answer to its question: no need to wait for the end of the sentence.
                VoiceLog.write("barge-in on: '\(text)'")
                interrupt()
                utteranceArmed = true
                state = .hearing
                partial = text
            } else if stop || (!ownerGateActive && words.count >= 3) {
                // The user is talking over Elio: lower its voice and listen; what they said decides the rest.
                duckForBarge(said)
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
            } else {
                // Words that aren't Elio's own: maybe the user talking over it. Listen to the end, then decide.
                let mine = Echo.remove(from: text, spoken: speaker.recentlySpoken())
                if mine.split(separator: " ").filter({ $0.count >= 2 }).count >= 3, isOwner(minSeconds: 0.8) != false {
                    duckForBarge(mine)
                }
            }
            return
        }
        if utteranceArmed || wakeSeen {
            partial = [pendingCommand, text].compactMap { $0 }.joined(separator: " ")
            sendPrep(text)
        } else if WakeWord.strip(text) != nil {
            wakeSeen = true
            speaker.prewarm()
            partial = text
            if state != .thinking { state = .hearing }
            sendPrep(text)
        }
    }

    private func endUtterance() async {
        guard let stt else { return }
        var text = await stt.finalizeSegment()
        if enrollment != nil {
            enrollmentClip()
            return
        }
        let spokeRecently = speaker.isSpeaking || Date().timeIntervalSince(lastSpeechEnd) < 3
        VoiceLog.write("heard: '\(text)'\(spokeRecently ? " (Elio spoke recently)" : "")\(audio.aecActive ? " [aec]" : "")")
        // Safety net: if echo cancellation swallows the user's voice, turn it off by itself.
        let mediaPlaying = (opening?.isPlaying ?? false) || speaker.isSpeaking || Date().timeIntervalSince(lastSpeechEnd) < 3
        if audio.aecActive, !mediaPlaying {
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
        if state == .hearing, !isArmed, pendingCommand == nil { state = .listening }
        guard !text.isEmpty else {
            // A noise during the pause: the held request still goes, a moment later.
            if pendingCommand != nil { schedulePendingFlush(after: 0.4) }
            return
        }
        // Answers to a pending confirmation/question always count, even while Elio is talking.
        let awaitingAnswer = !confirmations.isEmpty || !questions.isEmpty
        if (speaker.isSpeaking || bargeDucked), !awaitingAnswer {
            // Only when we heard the user over Elio (not leftovers of Elio's own voice in the mic).
            if bargeDucked { await handleSpokenOver(text) }
            // A held request still goes.
            if pendingCommand != nil { schedulePendingFlush(after: 0.3) }
            return
        }

        let command: String
        if isArmed || utteranceArmed || awaitingAnswer {
            command = WakeWord.strip(text) ?? text
            // Said without "Elio" during a follow-up window: was it for Elio, or for someone nearby?
            if WakeWord.strip(text) == nil, !awaitingAnswer, pendingCommand == nil {
                let verdict = await Addressee.classify(said: command, elioSaying: speaker.recentlySpoken(within: 15), wakeWord: false)
                if verdict.target == .other {
                    VoiceLog.write("not for Elio: '\(command)'")
                    if state == .hearing { state = .listening }
                    return
                }
            }
        } else if let afterWake = WakeWord.strip(text) {
            command = afterWake
        } else if resting, let back = Self.restReturn(text) {
            // At rest, "Elio, sono tornato" also when the recognizer heard the name as "E io".
            command = back
        } else {
            prepKey = nil
            if pendingCommand != nil { schedulePendingFlush(after: 0.3) }
            return  // background speech, not for Elio
        }
        // Only the owner can command Elio (when a voiceprint is enrolled).
        if let owner = isOwner(threshold: awaitingAnswer ? Self.answerThreshold : nil), !owner {
            VoiceLog.write("ignored: not the owner's voice ('\(command)')")
            prepKey = nil
            partial = ""
            if state == .hearing { state = .listening }
            return
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
        continueOrSend(command, cutByLimit: Date().timeIntervalSince(utteranceBegan) >= 44)
    }

    /// "Elio, sono tornato" when the recognizer mangled the name ("E io sono tornato", "Ellio, eccomi"): the name
    /// (or one of those mishearings) is required, so "sono tornato" said to someone else doesn't end rest mode.
    /// Returns the phrase without the name.
    static func restReturn(_ text: String) -> String? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let r = t.range(of: #"^(e io|eh io|ehi o|ei o|e lio|ellio|elio|helio|ilio)[ ,]+"#, options: .regularExpression) else { return nil }
        let rest = String(t[r.upperBound...])
        guard rest.range(of: #"^(sono tornat[oa]|son tornat[oa]|sono qui|ci sono|eccomi|rieccomi|svegliati)\b"#, options: .regularExpression) != nil,
              rest.split(separator: " ").count <= 6 else { return nil }
        return rest
    }

    // MARK: - Daemon

    private func send(_ text: String, voice: Bool = false, display: String? = nil) {
        // "Basta" / "stop" / "fermati": stop talking and stop the work in progress, locally.
        lastInteraction = Date()
        if resting, onRestCommand?(text) == true { return }
        if IntentMatcher().match(text)?.intent == .stop {
            stopEverything()
            return
        }
        if speaker.isSpeaking { speaker.stop() }
        armedUntil = nil
        lastCommandClosed = Self.isClosing(text)
        splitter = SentenceSplitter()
        requestStart = Date()
        turns.append(Turn(role: "user", text: display ?? text))
        turns.append(Turn(role: "elio", text: ""))
        spokenText = ""
        sentenceBudget = Self.wantsDetail(text) ? 50 : spokenSentences
        // A spoken request reuses the id its partial transcripts were sent under (the daemon prepared it).
        if voice, let key = prepKey {
            client.say(text, id: key)
            currentRequestId = key
        } else {
            currentRequestId = client.say(text)
        }
        prepKey = nil
        prepWords = 0
        VoiceLog.write("→ daemon: '\(text)'")
        firstDeltaLogged = false
        firstAudioLogged = false
        // Open the TTS socket while Claude is thinking: saves the ~0.4s handshake.
        replyStreaming = speaker.beginStream()
        localAckSpoken = false
        replyHadTools = false
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
            if msg.route == .local, (msg.text ?? "").isEmpty {
                if replyStreaming { speaker.cancelStream(); replyStreaming = false }
                if let i = turns.lastIndex(where: { $0.role == "elio" }), turns[i].text.isEmpty { turns.remove(at: i) }
                currentRequestId = nil
                state = .listening
                return
            }
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
        var msg = msg
        var ringFirst = false
        if resting {
            if onRestEvent?(msg) == true {
                // Woken up for something urgent: a ring first, it's heard from across the room (the alarm rings
                // on its own; if the app left rest mode instead, e.g. the user is back for the briefing, no ring).
                ringFirst = resting && msg.kind != "alarm"
            } else {
                switch msg.kind {
                case "briefStart", "recapStart", "routineDelta", "routineDone":
                    return  // no theme and no live reading in an empty room; the text stays in the history
                case "alarm":
                    // No ring at rest during the quiet hours: the phone got the urgent push.
                    if let text = msg.text { turns.append(Turn(role: "event", text: text, route: msg.route)); trimTurns() }
                    return
                default:
                    msg.speak = msg.speak == true ? false : msg.speak
                }
            }
        }
        switch msg.kind {
        case "briefStart", "recapStart":
            let isBrief = msg.kind == "briefStart"
            if briefOpeningEnabled { playOpening(recap: !isBrief) }
            routineMode = true
            litTools = [:]
            routineSpeaking = false
            onRoutineStart?()
            // Greeting right away (cached), the theme dips under it; then Elio tells the briefing live.
            duckOpening()
            speaker.enqueue(Self.greeting(addressAs: addressAs, brief: isBrief))
            speaker.endUtterance()
            routineSplitter = SentenceSplitter()
            routineText = ""
            routineLive = true
            turns.append(Turn(role: "elio", text: ""))
        case "routineDelta":
            guard routineLive, let chunk = msg.text else { break }
            if routineText.isEmpty {
                routineStreaming = speaker.beginStream()
                // The theme fades when Elio's voice is actually there, not when Claude starts writing.
                // The theme stays as a soft bed under Elio's voice until the clip ends.
                speaker.onStreamAudio = { [weak self] in
                    self?.opening?.setVolume(0.12, fadeDuration: 1.0)
                    self?.speaker.onStreamAudio = nil
                }
            }
            routineText += chunk
            if let i = turns.lastIndex(where: { $0.role == "elio" }) { turns[i].text = routineText }
            for sentence in routineSplitter.push(chunk) {
                if routineStreaming { speaker.streamSentence(sentence, flush: true) } else { speaker.enqueue(sentence); speaker.endUtterance() }
            }
        case "routineDone":
            if let rest = routineSplitter.flush() {
                if routineStreaming { speaker.streamSentence(rest, flush: true) } else { speaker.enqueue(rest) }
            }
            if routineStreaming { speaker.endStream() } else { speaker.endUtterance() }
            routineStreaming = false
            routineLive = false
            routineSpeaking = true
        case "brief", "recap":
            // Already told live; keep it only for history.
            return
        case "taskLog":
            if let entry = TaskLogEntry.fromJSON(msg.payload) {
                var log = taskLogs[entry.taskId] ?? []
                log.append(entry)
                if log.count > 300 { log.removeFirst(log.count - 300) }
                taskLogs[entry.taskId] = log
            }
        case "question":
            closeOpenStreams()
            if let q = QuestionRequest.fromJSON(msg.payload), !questions.contains(where: { $0.id == q.id }) {
                questions.append(q)
                armedUntil = Date().addingTimeInterval(20)
            }
        case "questionResolved":
            questions.removeAll { $0.id == msg.id }
        case "settingsChanged":
            let cfg = ElioConfig.load()
            applySettings(cfg)
            onSettingsChanged?(cfg)
        case "openIDE":
            if let p = msg.payload, let obj = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: Any] {
                onOpenIDE?(obj["path"] as? String ?? "", obj["line"] as? Int ?? 0)
            }
        case "ideConnect":
            if let p = msg.payload, let obj = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: Any] {
                onIDEConnect?(obj["id"] as? String ?? "", obj["what"] as? String ?? "")
            }
        case "idleRequest":
            onIdleRequest?(msg.text == "on")
        case "openView":
            if let p = msg.payload, let obj = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: String] {
                onOpenView?(obj["view"] ?? "dashboard", obj["tab"] ?? "", obj["integration"] ?? "")
            }
        case "integrationUpdated":
            break  // Elio configures integrations itself; Settings just shows the result
        case "squad", "squadDone":
            if let sq = SquadInfo.fromJSON(msg.payload) {
                if let i = squads.firstIndex(where: { $0.id == sq.id }) { squads[i] = sq } else { squads.append(sq) }
                if squads.count > 8 { squads.removeFirst() }
            }
        case "workflowEvent":
            if let e = WorkflowEvent.fromJSON(msg.payload) {
                var list = workflowEvents[e.workflow] ?? []
                list.append(e)
                if list.count > 400 { list.removeFirst(list.count - 400) }
                workflowEvents[e.workflow] = list
            }
        case "squadMessage":
            if let m = SquadMessage.fromJSON(msg.payload) {
                squadMessages.append(m)
                if squadMessages.count > 300 { squadMessages.removeFirst(squadMessages.count - 300) }
            }
        case "usage":
            usage = UsageSnapshot.fromJSON(msg.payload)
        case "task", "taskDone":
            if let info = TaskInfo.fromJSON(msg.payload) {
                if let i = tasks.firstIndex(where: { $0.id == info.id }) { tasks[i] = info } else { tasks.append(info) }
                if tasks.count > 30 { tasks.removeFirst(tasks.count - 30) }
            }
        case "confirm":
            closeOpenStreams()
            if let req = ConfirmRequest.fromJSON(msg.payload), !confirmations.contains(where: { $0.id == req.id }) {
                confirmations.append(req)
                armedUntil = Date().addingTimeInterval(30)  // the answer needs no wake word
            }
        case "confirmResolved":
            confirmations.removeAll { $0.id == msg.id }
        case "todos":
            if let board = TodoBoard.fromJSON(msg.payload) { todoBoard = board }
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
                if currentRequestId != nil {
                    // Whatever was written before this tool (the acknowledgement, or what the previous tool found)
                    // is said now; the socket stays open and each step gets its own sentence budget.
                    replyHadTools = true
                    sentenceBudget = max(sentenceBudget, spokenSentences)
                    if firstDeltaLogged { splitterFlushForAck() }
                }
                if routineMode, litTools[name] == nil { litTools[name] = Date() }
                if routineLive, routineStreaming, let rest = routineSplitter.flush() { speaker.streamSentence(rest, flush: true) }
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
        case "alarm":
            // "Chiamami quando…": it rings first so it's heard from across the room, then says what happened.
            guard let text = msg.text else { return }
            turns.append(Turn(role: "event", text: text, route: msg.route))
            trimTurns()
            Task { @MainActor [weak self] in
                for _ in 0..<3 {
                    NSSound(named: "Glass")?.play()
                    try? await Task.sleep(for: .milliseconds(650))
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                self.spokenText = text
                self.speaker.say(text, lang: msg.lang)
            }
            return
        case "card":
            if let c = CardPayload.fromJSON(msg.payload) {
                onCard?(c)
                cards.insert(c, at: 0)
                if cards.count > 10 { cards.removeLast() }
                turns.append(Turn(role: "card", text: "\(c.title)\n\(c.body)"))
            }
        default:
            break
        }
        guard msg.speak == true, let text = msg.text else { return }
        turns.append(Turn(role: "event", text: text, route: msg.route))
        trimTurns()
        guard ringFirst else {
            spokenText = text
            speaker.say(text, lang: msg.lang)
            return
        }
        let lang = msg.lang
        Task { @MainActor [weak self] in
            NSSound(named: "Glass")?.play()
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            self.spokenText = text
            self.speaker.say(text, lang: lang)
        }
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
        // "Che comando è?", "dimmi tutto", "leggimelo": the full detail, then ask again.
        if text.lowercased().range(of: #"\b(che|quale|qual è il|leggi\w*|dimmi\w*|cosa (fa|esegue|c'è)|nel dettaglio|tutto il|per intero|comando)\b"#,
                                   options: .regularExpression) != nil,
           ConfirmationAnswer.parse(text, risk: req.risk) == .unrelated {
            let detail = String(Speakable.clean(req.detail).prefix(700))
            speaker.enqueue("È questo: \(detail). Procedo, \(addressAs)?")
            speaker.endUtterance()
            armedUntil = Date().addingTimeInterval(30)
            return true
        }
        switch ConfirmationAnswer.parse(text, risk: req.risk) {
        case .approve where req.risk == .dangerous && !ownerVerifiedForDangerous():
            // A "confermo" is under a second: too short for the voiceprint, and anyone in the room (or in a call)
            // can say it. Dangerous actions need the owner's recognized voice on a longer phrase, or a click.
            speaker.enqueue(ownerGateActive
                ? "È un'azione delicata, \(addressAs): me lo confermi con una frase più lunga, per esempio \"confermo, procedi pure\", oppure col pulsante Conferma."
                : "È un'azione delicata, \(addressAs): la confermi col pulsante Conferma.")
            speaker.endUtterance()
            armedUntil = Date().addingTimeInterval(30)
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

    /// ~/Library/Application Support/Elio/sounds/brief-opening.m4a, if present. The recap uses
    /// sounds/recap-opening.m4a when there is one, otherwise the same theme.
    private func playOpening(recap: Bool = false) {
        let sounds = ElioPaths.support.appendingPathComponent("sounds")
        let own = sounds.appendingPathComponent("recap-opening.m4a")
        let url = recap && FileManager.default.fileExists(atPath: own.path) ? own : sounds.appendingPathComponent("brief-opening.m4a")
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 0.8
        player.play()
        opening = player
    }

    /// The greeting plays over the theme: lower it, keep it going until the briefing starts.
    private func duckOpening() {
        opening?.setVolume(0.25, fadeDuration: 0.6)
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
        if !speaking { lastSpeechEnd = Date() }
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
            if bargeDucked, !inUtterance { restoreVoice() }
            if !pendingRemarks.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    self.deliverRemarks()
                }
            }
            // Follow-up without the wake word only when Elio asked something (or wants a confirmation):
            // after a plain answer it goes back to waiting for "Elio", so a chat with someone nearby
            // isn't taken as a command. Never shortens a longer window (confirmations set their own).
            if Self.invitesReply(speaker.recentlySpoken(within: 12)), !lastCommandClosed {
                let followUp = Date().addingTimeInterval(Self.followUpWindow)
                armedUntil = max(armedUntil ?? followUp, followUp)
            }
        }
    }

    private var levelSmoothed: Float = 0
    private var lastLevelPublish = Date.distantPast

    /// The mic level drives the orbs; publishing it on every audio buffer (~40/s) re-rendered views
    /// constantly. Published at most ~12 times a second, and only when it visibly changes.
    private func updateLevel(_ db: Float) {
        let normalized = max(0, min(1, (db + 60) / 50))
        levelSmoothed = levelSmoothed * 0.6 + normalized * 0.4
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) > 0.08, abs(levelSmoothed - level) > 0.03 else { return }
        lastLevelPublish = now
        level = levelSmoothed
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
