import AVFoundation
import Observation

/// Elio's voice: replies spoken sentence by sentence through the Mac's TTS. The first sentence streams
/// (plays on its first bytes); the next ones are fetched while the current one plays, so there's no gap.
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
        let prefetch: Task<URL?, Never>?
    }

    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var streamWorks = true
    @ObservationIgnored private var playedToEnd = false

    func speak(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }
        // While something plays, the next sentence downloads in full meanwhile.
        let prefetch: Task<URL?, Never>? = (isSpeaking || !queue.isEmpty)
            ? Task { try? await client.ttsFile(text) } : nil
        queue.append(Item(text: text, prefetch: prefetch))
        if !isSpeaking { Task { await run() } }
    }

    func stop() {
        generation += 1
        for item in queue { item.prefetch?.cancel() }
        queue.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
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
            var url = await item.prefetch?.value
            var streamed = false
            if url == nil {
                if streamWorks {
                    url = try? await client?.ttsStreamURL(item.text)
                    streamed = url != nil
                } else {
                    url = try? await client?.ttsFile(item.text)
                }
            }
            guard gen == generation else { return }
            guard let url else { client?.log("tts: no audio for a sentence"); continue }
            let ok = await play(url, gen: gen)
            if !url.isFileURL || streamed {
                client?.log("tts \(ok ? "played" : "failed") stream after \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            if !ok, streamed, gen == generation {
                // The stream didn't play: fall back to the whole file, and stop streaming for this session.
                streamWorks = false
                if let file = try? await client?.ttsFile(item.text), gen == generation { _ = await play(file, gen: gen) }
            }
            if url.isFileURL { try? FileManager.default.removeItem(at: url) }
            recent.append((item.text, Date()))
        }
        guard gen == generation else { return }
        isSpeaking = false
        currentText = ""
        onIdle?()
    }

    /// Plays one sentence to the end. False if it failed or never started.
    private func play(_ url: URL, gen: Int) async -> Bool {
        let item = AVPlayerItem(url: url)
        let p = player ?? AVPlayer()
        player = p
        p.automaticallyWaitsToMinimizeStalling = false
        p.replaceCurrentItem(with: item)
        playedToEnd = false
        let center = NotificationCenter.default
        let done = center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playedToEnd = true; self?.wake() }
        }
        let failed = center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        // AVPlayerItem.status is only observable through KVO on any thread: a light poll is simpler and safe.
        let watchdog = Task { [weak self] in
            var lastTime = -1.0
            var lastMove = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if item.status == .failed { self?.wake(); return }
                let t = item.currentTime().seconds
                if t > lastTime { lastTime = t; lastMove = Date() }
                else if Date().timeIntervalSince(lastMove) > (lastTime <= 0 ? 8 : 5) { self?.wake(); return }
            }
        }
        await withCheckedContinuation { c in
            waiter = c
            p.play()
        }
        watchdog.cancel()
        center.removeObserver(done)
        center.removeObserver(failed)
        if gen == generation, !playedToEnd { p.pause() }
        return playedToEnd
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}
