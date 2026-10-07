import Foundation
import Observation

/// Messaggi: things Elio left to read or listen to later (GET/POST api/messages).
@Observable
final class InboxModel {
    private(set) var messages: [InboxMessage] = []
    private(set) var loaded = false
    private(set) var error: String?
    var openId: String?
    let player = MessagePlayer()

    @ObservationIgnored weak var client: ElioClient?
    @ObservationIgnored var onToast: ((String) -> Void)?
    @ObservationIgnored var onUnreadChange: ((Int) -> Void)?
    /// A message starts playing: Elio's live voice stops.
    @ObservationIgnored var onPlay: (() -> Void)?

    var unread: Int { messages.filter { !$0.read }.count }

    init() {
        player.audioFor = { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.audio(for: id)
        }
        player.onStart = { [weak self] id in
            self?.onPlay?()
            guard let self, let m = self.messages.first(where: { $0.id == id }), !m.read else { return }
            self.act("read", id: id)   // listening is reading
        }
        player.onAdvance = { [weak self] id in self?.openId = id }
        player.onError = { [weak self] text in self?.onToast?(text) }
    }

    func load() async {
        guard let client else { return }
        do {
            set(try await client.get("api/messages", as: InboxPayload.self))
        } catch {
            if !loaded { self.error = "Non riesco a leggere i messaggi dal Mac." }
        }
    }

    /// read, unread, delete, readAll, clearRead: applied here at once, then replaced by the Mac's answer.
    func act(_ action: String, id: String? = nil) {
        switch action {
        case "read", "unread":
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].read = action == "read" }
        case "delete": messages.removeAll { $0.id == id }
        case "readAll": for i in messages.indices { messages[i].read = true }
        case "clearRead": messages.removeAll { $0.read }
        default: break
        }
        onUnreadChange?(unread)
        guard let client else { return }
        var body: [String: Any] = ["action": action]
        if let id { body["id"] = id }
        Task {
            do { set(try await client.post("api/messages", json: body, as: InboxPayload.self)) }
            catch { onToast?("Il Mac non ha ricevuto la modifica: riprova quando torna raggiungibile.") }
        }
    }

    /// A "message" event from the socket.
    func add(_ m: InboxMessage) {
        guard !messages.contains(where: { $0.id == m.id }) else { return }
        messages.insert(m, at: 0)
        onUnreadChange?(unread)
    }

    /// Unread ones, oldest first: a calm catch-up in the order they arrived.
    func playUnread() {
        player.playAll(messages.filter { !$0.read }.map(\.id).reversed())
    }

    #if DEBUG
    func setForDemo(_ list: [InboxMessage]) { messages = list; loaded = true }
    #endif

    private func set(_ payload: InboxPayload) {
        loaded = true
        error = nil
        messages = payload.messages ?? []
        let ids = Set(messages.map(\.id))
        if let id = player.currentId, !ids.contains(id) { player.stop() }
        Self.pruneCache(keeping: ids)
        onUnreadChange?(unread)
    }

    // MARK: Audio cache (survives restarts)

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("msg-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(_ id: String) -> URL {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return cacheDir.appendingPathComponent(safe + ".mp3")
    }

    private func audio(for id: String) async throws -> Data {
        let file = Self.cacheFile(id)
        if let data = try? Data(contentsOf: file) { return data }
        guard let m = messages.first(where: { $0.id == id }), let client else { throw CancellationError() }
        let data = try await client.ttsData(m.speech)
        try? data.write(to: file)
        return data
    }

    private static func pruneCache(keeping ids: Set<String>) {
        let keep = Set(ids.map { cacheFile($0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where !keep.contains(f.lastPathComponent) { try? FileManager.default.removeItem(at: f) }
    }
}
