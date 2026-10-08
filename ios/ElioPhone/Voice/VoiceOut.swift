import AVFoundation
import Observation

/// Elio's voice: replies spoken sentence by sentence through the Mac's TTS, streamed as raw PCM and played as it
/// arrives (AVAudioEngine), so the first sound comes ~0.3 s after a sentence instead of after it's fully made.
/// Every sentence starts downloading as soon as it arrives, so the next one is ready while the current one plays.
@Observable
final class VoiceOut {
    private(set) var isSpeaking = false
    /// The sentence being spoken (for telling Elio's echo from the user in a call).
    @ObservationIgnored private(set) var currentText = ""
    @ObservationIgnored private var recent: [(text: String, at: Date)] = []

    @ObservationIgnored var onStart: (() -> Void)?
    @ObservationIgnored var onIdle: (() -> Void)?
    @ObservationIgnored weak var client: ElioClient?

    private struct Item {
        let text: String
        let audio: AsyncThrowingStream<Data, Error>
    }

    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    @ObservationIgnored private var attached = false
    @ObservationIgnored private let counter = PlayCounter()

    func speak(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }
        // The stream starts now and buffers until this sentence's turn.
        queue.append(Item(text: text, audio: client.ttsPCM(text)))
        if !isSpeaking { Task { await run() } }
    }

    func stop() {
        generation += 1
        queue.removeAll()
        node.stop()
        counter.cancel()
        if isSpeaking {
            isSpeaking = false
            currentText = ""
            onIdle?()
        }
    }

    /// Whether `heard` is just Elio's own voice picked up by the mic (words mostly from what it's saying).
    func isEcho(_ heard: String) -> Bool {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.at) > 4 }
        let spoken = ([currentText] + recent.map(\.text)).joined(separator: " ")
        let said = Set(Self.words(spoken))
        let words = Self.words(heard)
        guard !words.isEmpty, !said.isEmpty else { return false }
        let overlap = words.filter { said.contains($0) }.count
        return Double(overlap) / Double(words.count) >= 0.6
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Engine up and connected; restarted after audio-session changes (calls, interruptions) stopped it.
    private func ensureEngine() -> Bool {
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                client?.log("tts: audio engine won't start: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private func run() async {
        let gen = generation
        isSpeaking = true
        AudioRoute.activate()
        onStart?()
        while gen == generation, !queue.isEmpty {
            let item = queue.removeFirst()
            currentText = item.text
            guard ensureEngine() else { break }
            let t0 = Date()
            let (ok, firstSound) = await play(item, gen: gen)
            if gen == generation {
                let s = AVAudioSession.sharedInstance()
                let route = s.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
                client?.log("tts \(ok ? "played" : "FAILED") first sound after \(firstSound.map { "\(Int($0 * 1000))ms" } ?? "-"), "
                            + "total \(Int(Date().timeIntervalSince(t0) * 1000))ms route=\(route) mode=\(s.mode.rawValue) volume=\(s.outputVolume)")
            }
            recent.append((item.text, Date()))
        }
        guard gen == generation else { return }
        isSpeaking = false
        currentText = ""
        onIdle?()
    }

    /// Schedules the sentence's PCM as it arrives; playback starts once ~0.2 s is buffered (or the sentence is
    /// complete) and the function returns when the last sample has played. Returns success and time to first sound.
    private func play(_ item: Item, gen: Int) async -> (Bool, TimeInterval?) {
        let start = Date()
        var leftover = Data()
        var buffered = 0.0
        var firstSound: TimeInterval?
        counter.reset()
        func startIfNeeded(force: Bool) {
            guard !node.isPlaying, gen == generation, force || buffered >= 0.2 else { return }
            node.play()
            firstSound = Date().timeIntervalSince(start)
        }
        do {
            for try await chunk in item.audio {
                guard gen == generation else { return (false, nil) }
                var data = leftover + chunk
                leftover = Data()
                if data.count % 2 == 1 { leftover = data.suffix(1); data = data.dropLast() }
                guard let buffer = pcmBuffer(data) else { continue }
                counter.add()
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [counter] _ in counter.done() }
                buffered += Double(buffer.frameLength) / format.sampleRate
                startIfNeeded(force: false)
            }
        } catch {
            client?.log("tts stream failed: \(error.localizedDescription)")
            if buffered == 0 { return (false, nil) }
        }
        guard gen == generation else { return (false, nil) }
        startIfNeeded(force: true)
        await counter.waitUntilIdle()
        return (gen == generation && buffered > 0, firstSound)
    }

    /// 16-bit little-endian mono → float buffer in the engine's format.
    private func pcmBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        return buffer
    }
}

/// Buffers scheduled and not yet played back, counted on the audio thread; resumes the waiter when it reaches 0.
private final class PlayCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func reset() { lock.withLock { pending = 0 } }
    func add() { lock.withLock { pending += 1 } }

    func done() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            pending = max(0, pending - 1)
            guard pending == 0 else { return nil }
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { c in
            let resumeNow = lock.withLock { () -> Bool in
                if pending == 0 { return true }
                waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    /// Stopped: whoever waits goes on (node.stop() also calls the pending completions).
    func cancel() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            pending = 0
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }
}
