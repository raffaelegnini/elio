import Foundation

/// Persistent WebSocket client to jarvisd with automatic reconnect.
/// Delivers every server message (replies and unsolicited events) to `onMessage`.
public final class DaemonClient: @unchecked Sendable {
    public var onMessage: (@Sendable (ServerMessage) -> Void)?
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let port: UInt16
    private let token: String
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var stopped = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    public func start() { connect() }

    public var isConnected: Bool { lock.withLock { connected } }

    public func stop() {
        lock.withLock { stopped = true }
        socket?.cancel(with: .goingAway, reason: nil)
    }

    @discardableResult
    public func say(_ text: String) -> String {
        let id = UUID().uuidString
        send(.say(id: id, text: text))
        return id
    }

    public func send(_ message: ClientMessage) {
        guard let data = try? encoder.encode(message),
              let task = lock.withLock({ socket }) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { error in
            if let error { log("daemon send failed: \(error)") }
        }
    }

    private func connect() {
        guard !lock.withLock({ stopped }) else { return }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
        request.setValue(token, forHTTPHeaderField: "X-Jarvis-Token")
        let task = URLSession.shared.webSocketTask(with: request)
        lock.withLock { socket = task }
        task.resume()
        // A ping confirms the handshake before we report "connected".
        task.sendPing { [weak self] error in
            guard let self else { return }
            if error == nil { self.setConnected(true) }
        }
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let frame):
                let data: Data? = switch frame {
                case .string(let s): Data(s.utf8)
                case .data(let d): d
                @unknown default: nil
                }
                if let data, let msg = try? self.decoder.decode(ServerMessage.self, from: data) {
                    self.onMessage?(msg)
                }
                self.receive(on: task)
            case .failure:
                self.setConnected(false)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.connect() }
            }
        }
    }

    private func setConnected(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { connected = value }
            return connected != value
        }
        if changed { onConnectionChange?(value) }
    }
}
