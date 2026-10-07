import AVFoundation
import Observation
import Speech

/// The microphone. Speech is transcribed on the phone (Speech framework, on-device when the model is there),
/// which is much faster than sending audio to the Mac; the Mac's `stt` endpoint is the fallback.
///
/// Three ways to listen:
/// - push-to-talk: the user holds or taps the mic;
/// - ambient: always on while the app is open, segments by voice energy, Elio replies only to its name;
/// - call: like ambient but no wake word, echo-cancelled, and the user can talk over Elio.
@Observable
final class VoiceIn {
    enum Mode: Equatable { case off, ambient, call }
    enum Source { case pushToTalk, ambient, call }

    private(set) var mode: Mode = .off
    private(set) var isRunning = false
    private(set) var pushToTalk = false
    /// Inside an utterance (detector or push-to-talk).
    private(set) var hearing = false
    private(set) var transcribing = false
    private(set) var partial = ""
    /// Ambient listening paused (Elio speaking, thinking, a message playing).
    private(set) var suspended = false
    private(set) var muted = false
    /// Live mic level 0…1 for the orb (read every frame, not observed).
    @ObservationIgnored private(set) var level: Double = 0

    @ObservationIgnored var onUtterance: ((String, Source) -> Void)?
    @ObservationIgnored var onPartial: ((String, Source) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored weak var client: ElioClient?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let tap = CaptureTap()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    @ObservationIgnored private var segment: Segment?
    @ObservationIgnored private var segmentCounter = 0
    @ObservationIgnored private var voiceProcessing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// One utterance being captured.
    private final class Segment {
        let id: Int
        let source: Source
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var file: URL?
        var partial = ""
        var final: String?
        var waiter: CheckedContinuation<String, Never>?
        init(id: Int, source: Source) { self.id = id; self.source = source }
    }

    init() {
        tap.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterChange() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .ended
            MainActor.assumeIsolated { if ended { self?.restartAfterChange() } }
        })
    }

    /// True when transcription happens on the phone (on-device or Apple's servers); false = the Mac transcribes.
    var usesPhoneRecognition: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && (recognizer?.isAvailable ?? false)
    }

    var onDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    // MARK: Permissions

    static var micGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    /// Asks for the microphone (required) and speech recognition (optional: without it the Mac transcribes).
    func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await Self.requestSpeechAuthorization()
        }
        return mic
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }

    // MARK: Modes

    /// Switches listening mode; the engine starts or stops as needed.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        let needsRestart = isRunning && (newMode == .call) != voiceProcessing
        mode = newMode
        if segment?.source != .pushToTalk { cancelSegment() }
        if newMode == .off && !pushToTalk { stopEngine(); return }
        if needsRestart { stopEngine() }
        startEngineIfNeeded()
        applyDetector()
    }

    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        if on, mode == .ambient, let s = segment, s.source == .ambient {
            // Elio's own voice or a message isn't a command.
            tap.abortSpeech()
            cancelSegment()
        }
        applyDetector()
    }

    func setMuted(_ on: Bool) {
        muted = on
        tap.setMuted(on)
        if on { tap.abortSpeech(); if segment?.source == .call { cancelSegment() } }
    }

    private func applyDetector() {
        let active = (mode == .call) || (mode == .ambient && !suspended)
        tap.configure(vad: active && !pushToTalk, silenceMs: mode == .call ? 800 : 950)
    }

    // MARK: Push-to-talk

    func beginPushToTalk() {
        guard !pushToTalk else { return }
        if segment != nil { tap.abortSpeech(); cancelSegment() }
        startEngineIfNeeded()
        guard isRunning else { return }
        pushToTalk = true
        applyDetector()
        tap.force(true)
        beginSegment(.pushToTalk)
    }

    func endPushToTalk(send: Bool = true) {
        guard pushToTalk else { return }
        pushToTalk = false
        tap.force(false)
        applyDetector()
        if let s = segment, s.source == .pushToTalk {
            if send { Task { await finish(s) } } else { cancelSegment() }
        }
        if mode == .off { stopEngine() }
    }

    // MARK: Engine

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { isRunning = true; return }
        if mode == .call { AudioRoute.configureCall() } else { AudioRoute.configureAssistant() }
        AudioRoute.activate()
        let input = engine.inputNode
        let wantVP = mode == .call
        if input.isVoiceProcessingEnabled != wantVP {
            try? input.setVoiceProcessingEnabled(wantVP)
        }
        if wantVP {
            // Keep Elio's voice at full volume while the echo canceller runs.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        voiceProcessing = wantVP
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("Microfono non disponibile.")
            return
        }
        Self.installTap(on: input, format: format, tap: tap)
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            isRunning = false
            onError?("Non riesco ad aprire il microfono.")
            client?.log("mic start failed: \(error.localizedDescription)")
        }
    }

    /// Built outside the main actor: the tap block runs on the audio thread.
    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, tap: CaptureTap) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tap.process(buffer)
        }
    }

    private func stopEngine() {
        cancelSegment()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        hearing = false
        level = 0
    }

    private func restartAfterChange() {
        guard isRunning || mode != .off else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        if mode != .off || pushToTalk { startEngineIfNeeded(); applyDetector() }
    }

    // MARK: Segments

    private func handle(_ event: CaptureTap.Event) {
        switch event {
        case .level(let v): level = Double(v)
        case .speechStart:
            guard !pushToTalk, segment == nil else { return }
            beginSegment(mode == .call ? .call : .ambient)
        case .speechEnd:
            guard let s = segment, s.source != .pushToTalk else { return }
            Task { await finish(s) }
        }
    }

    private func beginSegment(_ source: Source) {
        segmentCounter += 1
        let s = Segment(id: segmentCounter, source: source)
        segment = s
        hearing = true
        partial = ""
        var file: AVAudioFile?
        if usesPhoneRecognition, let recognizer {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.taskHint = .dictation
            request.addsPunctuation = true
            request.contextualStrings = ["Elio"]
            s.request = request
            let id = s.id
            s.task = Self.recognize(recognizer, request) { [weak self] text, isFinal, failed in
                Task { @MainActor in self?.recognized(id: id, text: text, isFinal: isFinal, failed: failed) }
            }
        } else {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(s.id)-\(UUID().uuidString).m4a")
            let format = engine.inputNode.outputFormat(forBus: 0)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                           AVSampleRateKey: min(format.sampleRate, 48_000),
                                           AVNumberOfChannelsKey: Int(format.channelCount),
                                           AVEncoderBitRateKey: 64_000]
            file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            s.file = url
        }
        tap.attach(request: s.request, file: file)
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              _ handler: @escaping @Sendable (String, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString ?? "", result?.isFinal ?? false, error != nil)
        }
    }

    private func recognized(id: Int, text: String, isFinal: Bool, failed: Bool) {
        guard let s = segment, s.id == id else {
            // A late final result for a segment already handed over.
            return
        }
        if !text.isEmpty {
            s.partial = text
            if !isFinal { partial = text; onPartial?(text, s.source) }
        }
        if isFinal || failed {
            s.final = isFinal ? text : s.partial
            s.waiter?.resume(returning: s.final ?? "")
            s.waiter = nil
        }
    }

    private func finish(_ s: Segment) async {
        guard segment === s else { return }
        tap.detach()
        hearing = false
        var text = ""
        if let request = s.request {
            request.endAudio()
            text = await withCheckedContinuation { c in
                if let f = s.final { c.resume(returning: f); return }
                s.waiter = c
                Task { [weak s] in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard let s, let w = s.waiter else { return }
                    s.waiter = nil
                    w.resume(returning: s.partial)
                }
            }
            s.task?.cancel()
        } else if let file = s.file {
            guard s.source == .pushToTalk || fileLooksLikeSpeech(file) else {
                try? FileManager.default.removeItem(at: file)
                endSegment(s)
                return
            }
            transcribing = true
            let t0 = Date()
            do {
                text = try await client?.stt(file: file, mime: "audio/mp4") ?? ""
                client?.log("stt \(Int(Date().timeIntervalSince(t0) * 1000))ms (Mac fallback)")
            } catch {
                onError?("Non sono riuscito a trascrivere: riprova.")
            }
            transcribing = false
            try? FileManager.default.removeItem(at: file)
        }
        let source = s.source
        endSegment(s)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { onUtterance?(clean, source) }
        else if source == .pushToTalk { onError?("Non ho sentito nulla.") }
    }

    private func endSegment(_ s: Segment) {
        if segment === s { segment = nil; partial = "" }
    }

    private func cancelSegment() {
        guard let s = segment else { return }
        tap.detach()
        s.task?.cancel()
        s.waiter?.resume(returning: "")
        s.waiter = nil
        if let f = s.file { try? FileManager.default.removeItem(at: f) }
        segment = nil
        hearing = false
        partial = ""
    }

    /// Tiny ambient segments (a cough, a door) aren't worth a round trip to the Mac.
    private func fileLooksLikeSpeech(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 6000
    }
}
