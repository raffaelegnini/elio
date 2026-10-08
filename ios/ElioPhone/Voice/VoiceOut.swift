import AVFoundation
import Observation

/// Elio's voice: replies spoken sentence by sentence through the Mac's TTS. Each sentence is downloaded whole as
/// soon as it arrives and played with AVAudioPlayer; the next one downloads while the current one plays.
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
        let audio: Task<Data?, Never>
    }

    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var finishedOK = false

    func speak(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }
        // Every sentence is downloaded whole (no streaming: AVPlayer and one-shot stream tickets didn't mix), starting
        // right away, so the next one is ready while the current one plays.
        let audio = Task { () -> Data? in
            do { return try await client.ttsData(text) } catch { client.log("tts download failed: \(error.localizedDescription)"); return nil }
        }
        queue.append(Item(text: text, audio: audio))
        if !isSpeaking { Task { await run() } }
    }

    func stop() {
        generation += 1
        for item in queue { item.audio.cancel() }
        queue.removeAll()
        player?.stop()
        wake()
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

    private func run() async {
        let gen = generation
        isSpeaking = true
        AudioRoute.activate()
        onStart?()
        while gen == generation, !queue.isEmpty {
            let item = queue.removeFirst()
            currentText = item.text
            let t0 = Date()
            guard let data = await item.audio.value, gen == generation else { continue }
            let ok = await play(data, gen: gen)
            let s = AVAudioSession.sharedInstance()
            let route = s.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
            client?.log("tts \(ok ? "played" : "FAILED") \(data.count / 1024)KB after \(Int(Date().timeIntervalSince(t0) * 1000))ms "
                        + "route=\(route) category=\(s.category.rawValue) mode=\(s.mode.rawValue) volume=\(s.outputVolume)")
            recent.append((item.text, Date()))
        }
        guard gen == generation else { return }
        isSpeaking = false
        currentText = ""
        onIdle?()
    }

    /// Plays one sentence to the end. False if it failed or never started.
    private func play(_ data: Data, gen: Int) async -> Bool {
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        } catch {
            client?.log("tts: can't decode audio: \(error.localizedDescription)")
            return false
        }
        player = p
        finishedOK = false
        let delegate = PlayerDelegate { [weak self] ok, error in
            MainActor.assumeIsolated {
                if !ok { self?.client?.log("tts: player finished unsuccessfully\(error.map { ": \($0.localizedDescription)" } ?? "") (duration \(p.duration)s)") }
                self?.finishedOK = ok; self?.wake()
            }
        }
        p.delegate = delegate
        p.prepareToPlay()
        let started = p.play()
        if !started {
            client?.log("tts: play() refused, duration \(p.duration)s, session active=\(AVAudioSession.sharedInstance().isOtherAudioPlaying ? "other audio" : "?")")
            return false
        }
        // A sentence never takes longer than its length plus a margin: don't hang if the delegate never fires.
        let limit = p.duration + 3
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            // Cancelled when the sentence ends normally: waking now would cut the NEXT sentence short.
            guard !Task.isCancelled else { return }
            self?.wake()
        }
        await withCheckedContinuation { c in waiter = c }
        watchdog.cancel()
        _ = delegate
        if gen == generation, !finishedOK { p.stop() }
        return finishedOK
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let done: (Bool, Error?) -> Void
    init(_ done: @escaping (Bool, Error?) -> Void) { self.done = done }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { done(flag, nil) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { done(false, error) }
}
