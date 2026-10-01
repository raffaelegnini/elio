import AVFoundation
import CryptoKit
import Foundation
import JarvisCore

/// Speaks sentences in order with ElevenLabs streaming TTS.
/// - Each sentence is fetched as soon as it's enqueued (pipelined), played strictly in order.
/// - Short phrases are cached on disk: repeats cost zero credits and zero latency.
/// - On any ElevenLabs failure (quota, network) it falls back to the on-device Apple voice.
@MainActor
public final class Speaker {
    public var onSpeakingChange: ((Bool) -> Void)?
    public var onCharactersSent: ((Int) -> Void)?
    public private(set) var isSpeaking = false

    private let audio: AudioIO
    private let voiceId: String
    private let model: String
    private let apiKey: String?
    private let cacheDir: URL
    private var jobs: AsyncStream<SentenceJob>.Continuation?
    private var consumer: Task<Void, Never>?
    private var pendingBuffers = 0
    private var utteranceOpen = false
    private var generation = 0
    private let fallback = AVSpeechSynthesizer()

    private nonisolated static let cacheMaxChars = 80

    public init(audio: AudioIO, voiceId: String, model: String) {
        self.audio = audio
        self.voiceId = voiceId
        self.model = model
        self.apiKey = Keychain.read(service: "jarvis-elevenlabs")
        cacheDir = JarvisPaths.support.appendingPathComponent("tts-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        startConsumer()
    }

    /// Queue a sentence of the current reply.
    public func enqueue(_ sentence: String, lang: Lang? = nil) {
        let text = Speakable.clean(sentence)
        guard !text.isEmpty else { return }
        utteranceOpen = true
        setSpeaking(true)
        jobs?.yield(SentenceJob(text: text, buffers: produce(text, lang: lang)))
    }

    /// The reply is complete: once the queue drains, speaking ends.
    public func endUtterance() {
        utteranceOpen = false
        checkFinished()
    }

    /// Barge-in: drop everything immediately.
    public func stop() {
        generation += 1
        jobs?.finish()
        consumer?.cancel()
        audio.player.stop()
        audio.player.play()
        pendingBuffers = 0
        utteranceOpen = false
        startConsumer()
        setSpeaking(false)
    }

    /// Pre-generates cached clips for fixed phrases (acks), so they play instantly.
    public func warmCache(_ phrases: [String]) {
        for phrase in phrases where cachedAudio(for: phrase) == nil {
            Task {
                for try await _ in self.produce(phrase, lang: nil) {}
            }
        }
    }

    // MARK: - Playback

    private struct SentenceJob {
        let text: String
        let buffers: AsyncThrowingStream<AVAudioPCMBuffer, Error>
    }

    private func startConsumer() {
        let (stream, continuation) = AsyncStream<SentenceJob>.makeStream()
        jobs = continuation
        let gen = generation
        consumer = Task { [weak self] in
            for await job in stream {
                do {
                    for try await buffer in job.buffers {
                        guard let self, self.generation == gen else { return }
                        self.schedule(buffer, generation: gen)
                    }
                } catch {
                    NSLog("Jarvis TTS job failed: \(error)")
                }
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation gen: Int) {
        pendingBuffers += 1
        audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.pendingBuffers -= 1
                self.checkFinished()
            }
        }
    }

    private func checkFinished() {
        // Give the next sentence a moment to arrive before declaring the reply over.
        guard !utteranceOpen, pendingBuffers == 0 else { return }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if self.generation == gen, !self.utteranceOpen, self.pendingBuffers == 0 { self.setSpeaking(false) }
        }
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onSpeakingChange?(value)
    }

    // MARK: - Synthesis

    private nonisolated func produce(_ text: String, lang: Lang?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let format = audio.playbackFormat
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let cached = await self.cachedAudio(for: text) {
                    for b in Self.buffers(fromPCM16: cached, format: format) { continuation.yield(b) }
                    continuation.finish()
                    return
                }
                do {
                    try await self.streamElevenLabs(text, format: format, continuation)
                } catch {
                    NSLog("Jarvis ElevenLabs failed, using Apple voice: \(error)")
                    for b in await self.appleVoice(text, lang: lang, format: format) { continuation.yield(b) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated func streamElevenLabs(
        _ text: String, format: AVAudioFormat,
        _ out: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        guard let key = await apiKey else { throw VoiceError.tts("missing API key") }
        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "pcm_22050")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.8, "speed": 1.05],
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw VoiceError.tts("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body.prefix(200))")
        }
        await MainActor.run { self.onCharactersSent?(text.count) }

        var all = Data()
        var chunk = Data()
        // First chunk small (~50ms) to start playing fast, then ~200ms chunks.
        var target = 2205
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= target {
                let even = chunk.count & ~1
                let piece = chunk.prefix(even)
                for b in Self.buffers(fromPCM16: piece, format: format) { out.yield(b) }
                all.append(piece)
                chunk.removeFirst(even)
                target = 8820
            }
        }
        if chunk.count >= 2 {
            let piece = chunk.prefix(chunk.count & ~1)
            for b in Self.buffers(fromPCM16: piece, format: format) { out.yield(b) }
            all.append(piece)
        }
        if text.count <= Self.cacheMaxChars { await storeCache(all, for: text) }
    }

    private func appleVoice(_ text: String, lang: Lang?, format: AVAudioFormat) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        let language = (lang ?? Self.guessLang(text)) == .en ? "en-GB" : "it-IT"
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        var result: [AVAudioPCMBuffer] = []
        var converter: BufferConverter?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            fallback.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !finished { finished = true; done.resume() }
                    return
                }
                if converter == nil { converter = BufferConverter(from: pcm.format, to: format) }
                if let converted = converter?.convert(pcm) { result.append(converted) }
            }
        }
        return result
    }

    static func guessLang(_ text: String) -> Lang {
        let en = [" the ", " you ", " is ", " and ", " to ", "i'm", "it's"]
        let lower = " \(text.lowercased()) "
        return en.filter { lower.contains($0) }.count >= 2 ? .en : .it
    }

    // MARK: - Cache

    private func cacheURL(for text: String) -> URL {
        let key = "\(voiceId)|\(model)|\(text)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash.prefix(32)).pcm")
    }

    private func cachedAudio(for text: String) -> Data? {
        try? Data(contentsOf: cacheURL(for: Speakable.clean(text)))
    }

    private func storeCache(_ data: Data, for text: String) {
        try? data.write(to: cacheURL(for: text))
    }

    // MARK: - PCM

    nonisolated static func buffers(fromPCM16 data: Data, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return [] }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return [buffer]
    }
}

public enum Keychain {
    public static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
