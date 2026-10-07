import AVFoundation
import Observation

/// Plays inbox messages one at a time (Elio's voice, cached on disk so replays are instant).
@Observable
final class MessagePlayer: NSObject, AVAudioPlayerDelegate {
    enum State { case idle, loading, playing, paused }

    private(set) var currentId: String?
    private(set) var state: State = .idle
    /// "Ascolta i non letti" in progress.
    private(set) var playingAll = false
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var player: AVAudioPlayer?

    @ObservationIgnored var audioFor: ((String) async throws -> Data)?
    @ObservationIgnored var onStart: ((String) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    /// Called when the queue moves to the next message (so the list can open it).
    @ObservationIgnored var onAdvance: ((String) -> Void)?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }
    var isAudible: Bool { state == .playing }

    func state(of id: String) -> State { currentId == id ? state : .idle }

    func toggle(_ id: String) {
        if currentId == id {
            switch state {
            case .playing: pause(); return
            case .paused: player?.play(); state = .playing; return
            case .loading: return
            case .idle: break
            }
        }
        queue = []
        playingAll = false
        Task { await play(id) }
    }

    func playAll(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue = ids
        playingAll = true
        next()
    }

    func pause() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
    }

    func stop() {
        player?.stop()
        player = nil
        currentId = nil
        state = .idle
        queue = []
        playingAll = false
    }

    func seek(_ fraction: Double) {
        guard let player, player.duration > 0 else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
    }

    private func next() {
        guard !queue.isEmpty else { stop(); return }
        let id = queue.removeFirst()
        onAdvance?(id)
        Task { await play(id) }
    }

    private func play(_ id: String) async {
        player?.stop()
        currentId = id
        state = .loading
        onStart?(id)
        do {
            guard let audioFor else { return }
            let data = try await audioFor(id)
            guard currentId == id else { return }
            AudioRoute.configureAssistant()
            AudioRoute.activate()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
            state = .playing
        } catch {
            guard currentId == id else { return }
            state = .idle
            currentId = nil
            onError?("Non riesco a preparare l'audio: il Mac è raggiungibile?")
            if playingAll { next() }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        state = .idle
        player = nil
        if playingAll { next() } else { currentId = nil }
    }
}
