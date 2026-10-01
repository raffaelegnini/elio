import AVFoundation
import Foundation

/// One ElevenLabs WebSocket session per reply: text goes in while Claude is still writing,
/// audio comes back continuously. Keeps prosody across sentences (no robotic per-sentence restarts)
/// and starts speaking sooner than one HTTP request per sentence.
final class StreamingTTS: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let format: AVAudioFormat
    private let onAudio: @Sendable (AVAudioPCMBuffer) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private let lock = NSLock()
    private var finished = false
    private var leftover = Data()
    private(set) var charactersSent = 0

    init(apiKey: String, voiceId: String, model: String, format: AVAudioFormat,
         onAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onFinish: @escaping @Sendable (Error?) -> Void) {
        var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream-input")!
        comps.queryItems = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "output_format", value: "pcm_22050"),
            URLQueryItem(name: "inactivity_timeout", value: "30"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        task = URLSession.shared.webSocketTask(with: req)
        self.format = format
        self.onAudio = onAudio
        self.onFinish = onFinish
        task.resume()
        send([
            "text": " ",
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "speed": 1.05],
            // Larger chunks keep intonation continuous (small ones made audible pauses).
            "generation_config": ["chunk_length_schedule": [120, 160, 250, 290]],
        ])
        receive()
    }

    /// Feed text; `flush` forces generation of what's buffered (end of a sentence).
    func push(_ text: String, flush: Bool) {
        let t = text.hasSuffix(" ") ? text : text + " "
        lock.withLock { charactersSent += t.count }
        send(flush ? ["text": t, "flush": true] : ["text": t])
    }

    /// No more text: ElevenLabs finishes generating and sends isFinal.
    func close() {
        send(["text": ""])
    }

    func cancel() {
        lock.withLock { finished = true }
        task.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.finish(error) }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(error)
            case .success(let message):
                guard case .string(let text) = message,
                      let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    self.receive()
                    return
                }
                if let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) {
                    self.emit(pcm)
                }
                if let err = obj["error"] as? String ?? obj["message"] as? String, obj["audio"] == nil, obj["isFinal"] == nil {
                    self.finish(VoiceError.tts(err))
                    return
                }
                if obj["isFinal"] as? Bool == true {
                    self.finish(nil)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func emit(_ pcm: Data) {
        // 16-bit samples may straddle messages.
        var data = lock.withLock { () -> Data in
            let d = leftover + pcm
            leftover = Data()
            return d
        }
        if data.count % 2 == 1 {
            lock.withLock { leftover = data.suffix(1) }
            data = data.dropLast()
        }
        for b in Speaker.buffers(fromPCM16: data, format: format) { onAudio(b) }
    }

    private func finish(_ error: Error?) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        task.cancel(with: .normalClosure, reason: nil)
        onFinish(error)
    }
}
