import AVFoundation
import Speech

/// Runs on the audio thread: measures level, detects speech by energy (same thresholds as the PWA's ambient
/// mode) and routes buffers to the current sink (speech request and/or a file for the Mac's STT).
/// Everything shared with the main actor goes through the lock.
nonisolated final class CaptureTap: @unchecked Sendable {
    enum Event: Sendable { case speechStart, speechEnd, level(Float) }

    private let lock = NSLock()
    private var floor: Float = -55
    private var inSpeech = false
    private var loudMs = 0.0
    private var silenceMs = 0.0
    private var speechMs = 0.0
    private var levelMs = 0.0
    private var vad = false
    private var forced = false
    private var muted = false
    private var silenceToEnd = 950.0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var file: AVAudioFile?
    private var hasSink = false
    /// Audio from just before speech was detected, and from before the sink was attached.
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollMs = 0.0

    var onEvent: (@Sendable (Event) -> Void)?

    func configure(vad: Bool, silenceMs: Double) {
        lock.withLock {
            if !vad, self.vad, inSpeech, !forced { inSpeech = false }
            self.vad = vad
            silenceToEnd = silenceMs
        }
    }

    func setMuted(_ on: Bool) { lock.withLock { muted = on } }

    /// Push-to-talk: capture from now on regardless of the detector.
    func force(_ on: Bool) {
        lock.withLock {
            forced = on
            if on { inSpeech = false; loudMs = 0 }
        }
    }

    /// Attaches the sink for the utterance in progress and hands it the audio buffered so far.
    func attach(request: SFSpeechAudioBufferRecognitionRequest?, file: AVAudioFile?) {
        lock.withLock {
            self.request = request
            self.file = file
            hasSink = true
            for b in preroll { feed(b) }
            preroll.removeAll()
            prerollMs = 0
        }
    }

    func detach() {
        lock.withLock {
            request = nil
            file = nil
            hasSink = false
        }
    }

    /// Ends an utterance the main actor gave up on (e.g. Elio started speaking in ambient mode).
    func abortSpeech() {
        lock.withLock { inSpeech = false; loudMs = 0; silenceMs = 0 }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = data[0][i]; sum += v * v }
        let db = 10 * log10(sum / Float(n) + 1e-10)
        let ms = Double(n) / buffer.format.sampleRate * 1000
        var events: [Event] = []

        lock.withLock {
            let level = muted ? 0 : max(0, min(1, (db - floor) / 30))
            if muted { return }
            if !inSpeech && !forced { floor += (db - floor) * (db < floor ? 0.2 : 0.02) * Float(ms / 50) }
            let capturing = forced || inSpeech
            if let copy = Self.copy(buffer) {
                if capturing && hasSink { feed(copy) } else { keep(copy, ms: ms, capturing: capturing) }
            }
            if vad && !forced {
                if !inSpeech {
                    loudMs = db > floor + 14 ? loudMs + ms : 0
                    if loudMs >= 120 {
                        inSpeech = true; silenceMs = 0; speechMs = 0
                        events.append(.speechStart)
                    }
                } else {
                    silenceMs = db > floor + 7 ? 0 : silenceMs + ms
                    speechMs += ms
                    if silenceMs >= silenceToEnd || speechMs > 30_000 {
                        inSpeech = false; loudMs = 0
                        events.append(.speechEnd)
                    }
                }
            }
            levelMs += ms
            if levelMs >= 50 { levelMs = 0; events.append(.level(capturing ? max(level, 0.05) : level)) }
        }
        for e in events { onEvent?(e) }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        try? file?.write(from: buffer)
    }

    private func keep(_ buffer: AVAudioPCMBuffer, ms: Double, capturing: Bool) {
        preroll.append(buffer)
        prerollMs += ms
        // Idle: the last ~0.4 s, so the first syllable isn't lost. Waiting for a sink: up to 3 s.
        let cap = capturing ? 3000.0 : 400.0
        while prerollMs > cap, preroll.count > 1 {
            let first = preroll.removeFirst()
            prerollMs -= Double(first.frameLength) / first.format.sampleRate * 1000
        }
    }

    /// The engine reuses tap buffers: anything kept past the callback needs its own copy.
    private static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength),
              let s = src.floatChannelData, let d = dst.floatChannelData else { return nil }
        dst.frameLength = src.frameLength
        for ch in 0..<Int(src.format.channelCount) {
            d[ch].update(from: s[ch], count: Int(src.frameLength))
        }
        return dst
    }
}
