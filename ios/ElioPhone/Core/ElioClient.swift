import Foundation
import Observation

/// The link to eliod on the Mac: one WebSocket for the conversation and events, plus the HTTP endpoints
/// the PWA uses. Everything goes through `tailscale serve` on https://<mac>.ts.net.
@Observable
final class ElioClient {
    enum State: Equatable { case idle, connecting, connected, offline }

    private(set) var state: State = .idle
    var pairing: Pairing? {
        didSet { if pairing != oldValue { disconnect() } }
    }

    @ObservationIgnored var onMessage: ((ServerMessage) -> Void)?
    @ObservationIgnored var onConnected: (() -> Void)?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let socketEvents = SocketDelegate()
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var backoff: Double = 1
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var wanted = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: socketEvents, delegateQueue: nil)
        socketEvents.onOpen = { [weak self] id in Task { @MainActor in self?.opened(taskId: id) } }
    }

    var isConnected: Bool { state == .connected }

    // MARK: Socket

    func connect() {
        guard let pairing else { return }
        wanted = true
        retry?.cancel()
        if task != nil, state == .connecting || state == .connected { return }
        generation += 1
        let gen = generation
        var request = URLRequest(url: pairing.socketURL)
        // The remote socket authenticates with the `t-<token>` subprotocol, exactly like the PWA
        // (browsers can't set headers); the header is sent too for a Mac that checks it.
        request.setValue("elio, t-\(pairing.token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(pairing.token, forHTTPHeaderField: "X-Elio-Token")
        request.timeoutInterval = 15
        let t = session.webSocketTask(with: request)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        if state != .offline { state = .connecting }
        t.resume()
        Task { await receive(t, gen) }
    }

    func disconnect() {
        wanted = false
        retry?.cancel()
        pinger?.cancel()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    /// Reconnects at once (back to the foreground, network changed) instead of waiting for the backoff.
    func reconnectNow() {
        guard pairing != nil else { return }
        if state == .connected || state == .connecting, task != nil { return }
        backoff = 1
        task = nil
        connect()
    }

    @discardableResult
    func send(_ message: Outgoing) -> Bool {
        guard state == .connected, let task, let data = try? JSONEncoder().encode(message) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        Task { try? await task.send(.string(text)) }
        return true
    }

    private func opened(taskId: Int) {
        guard let task, task.taskIdentifier == taskId else { return }
        markConnected()
    }

    private func markConnected() {
        guard state != .connected else { return }
        state = .connected
        backoff = 1
        startPinging()
        onConnected?()
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) async {
        while gen == generation {
            do {
                let message = try await t.receive()
                guard gen == generation else { return }
                markConnected()
                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                if let m = try? JSON.decoder.decode(ServerMessage.self, from: data) { onMessage?(m) }
            } catch {
                if gen == generation { dropped() }
                return
            }
        }
    }

    private func dropped() {
        pinger?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        state = .offline
        guard wanted else { return }
        let delay = backoff * Double.random(in: 0.8...1.2)
        backoff = min(backoff * 2, 15)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// Proxies on the way (tailscale serve) drop idle sockets: a ping every 25 s keeps it alive and
    /// notices a dead link sooner.
    private func startPinging() {
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self, let task = self.task else { return }
                task.sendPing { _ in }
                self.send(.ping)
            }
        }
    }

    // MARK: HTTP

    enum ClientError: LocalizedError {
        case notPaired
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notPaired: "Telefono non associato."
            case .http(let code, let body): body.isEmpty ? "errore \(code)" : body
            }
        }
    }

    private func makeRequest(_ path: String, method: String) throws -> URLRequest {
        guard let pairing else { throw ClientError.notPaired }
        var r = URLRequest(url: URL(string: path, relativeTo: pairing.baseURL)!)
        r.httpMethod = method
        r.setValue(pairing.token, forHTTPHeaderField: "X-Elio-Token")
        return r
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    func get(_ path: String) async throws -> Data {
        try await run(try makeRequest(path, method: "GET"))
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSON.decoder.decode(type, from: try await get(path))
    }

    @discardableResult
    func post(_ path: String, json: [String: Any]? = nil) async throws -> Data {
        var r = try makeRequest(path, method: "POST")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await run(r)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any], as type: T.Type) async throws -> T {
        try JSON.decoder.decode(type, from: try await post(path, json: json))
    }

    /// A whole sentence of Elio's voice (ElevenLabs through the Mac), saved to a temp file.
    func ttsFile(_ text: String) async throws -> URL {
        let data = try await post("tts", json: ["text": String(text.prefix(2000))])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tts-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    func ttsData(_ text: String) async throws -> Data {
        try await post("tts", json: ["text": String(text.prefix(2000))])
    }

    /// Streamed voice: a one-shot ticket so the token never appears in a URL.
    func ttsStreamURL(_ text: String) async throws -> URL {
        struct Ticket: Decodable { var ticket: String }
        let t = try await post("tts/ticket", json: ["text": String(text.prefix(2000))], as: Ticket.self)
        guard let pairing else { throw ClientError.notPaired }
        return URL(string: "tts/stream?k=\(t.ticket)", relativeTo: pairing.baseURL)!
    }

    /// Fallback transcription on the Mac (ElevenLabs Scribe) when on-device speech isn't available.
    func stt(file: URL, mime: String) async throws -> String {
        struct Out: Decodable { var text: String? }
        var r = try makeRequest("stt", method: "POST")
        r.setValue(mime, forHTTPHeaderField: "Content-Type")
        r.httpBody = try Data(contentsOf: file)
        return (try JSON.decoder.decode(Out.self, from: try await run(r))).text ?? ""
    }

    /// An attachment saved on the Mac; returns the path Elio will open.
    func upload(_ data: Data, filename: String, mime: String) async throws -> String {
        struct Out: Decodable { var path: String }
        var r = try makeRequest("api/upload", method: "POST")
        // Same encoding as encodeURIComponent: headers must stay ASCII.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        r.setValue(filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? "allegato", forHTTPHeaderField: "X-Filename")
        r.setValue(mime, forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 180
        r.httpBody = data
        return try JSON.decoder.decode(Out.self, from: try await run(r)).path
    }

    /// Timings and audio errors go to the Mac (~/Library/Logs/Elio/phone.log): fire and forget.
    func log(_ line: String) {
        guard var r = try? makeRequest("api/log", method: "POST") else { return }
        r.httpBody = Data(("[ios] " + line).prefix(1500).utf8)
        let req = r
        Task { _ = try? await run(req) }
    }

    /// The user has the app in front of them: the Mac stops repeating urgent alerts.
    func ack() {
        Task { _ = try? await post("api/ack") }
    }
}

/// URLSession's delegate lives off the main actor; it only reports which socket opened.
nonisolated final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable (Int) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?(webSocketTask.taskIdentifier)
    }

    /// The token only ever goes to the paired host: a redirect elsewhere is refused, never followed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let from = task.originalRequest?.url
        let to = request.url
        let sameHost = from?.host()?.lowercased() == to?.host()?.lowercased() && from?.port == to?.port && to?.scheme == "https"
        completionHandler(sameHost ? request : nil)
    }
}
