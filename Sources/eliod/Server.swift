import Foundation
import ElioCore
import Network

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
}

/// WebSocket server on 127.0.0.1.
/// - `.local` (Mac app, CLI, MCP bridge): `X-Elio-Token` header; browser pages (Origin) rejected.
/// - `.remote` (phone PWA, reached through `tailscale serve`): the pairing token travels as a
///   WebSocket subprotocol (`t-<token>`), since browsers can't set headers. Remote clients may only
///   talk, ping and answer confirmations — never call tools directly.
final class Server: @unchecked Sendable {
    enum Mode { case local, remote }

    private let brain: Brain
    private let token: String
    private let mode: Mode
    private let listener: NWListener
    private let queue = DispatchQueue(label: "elio.server")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(brain: Brain, token: String, port: UInt16, mode: Mode = .local) throws {
        self.brain = brain
        self.token = token
        self.mode = mode

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { [token] subprotocols, headers in
            switch mode {
            case .local:
                let lower = Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
                let authorized = lower["x-elio-token"] == token && lower["origin"] == nil
                return NWProtocolWebSocket.Response(status: authorized ? .accept : .reject, subprotocol: nil)
            case .remote:
                // Network.framework doesn't trim the comma-separated list.
                let offered = subprotocols.map { $0.trimmingCharacters(in: .whitespaces) }
                let authorized = offered.contains("t-\(token)")
                return NWProtocolWebSocket.Response(status: authorized ? .accept : .reject,
                                                    subprotocol: authorized ? "elio" : nil)
            }
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ElioError.database("bad port") }
        listener = try NWListener(using: params, on: nwPort)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state { fputs("listener failed: \(err)\n", stderr); exit(1) }
            if case .ready = state, let port = self.listener.port {
                fputs("eliod \(self.mode == .local ? "local" : "remote") ws on 127.0.0.1:\(port)\n", stderr)
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        let sinkId = UUID()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task {
                    await self.brain.subscribe(id: sinkId) { [weak self] msg in self?.send(msg, on: conn) }
                }
                self.receive(on: conn)
            case .failed, .cancelled:
                Task { await self.brain.unsubscribe(sinkId) }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || meta?.opcode == .close || (data == nil && context?.isFinal == true) {
                conn.cancel()
                return
            }
            if let data, !data.isEmpty { self.dispatch(data, on: conn) }
            self.receive(on: conn)
        }
    }

    private func dispatch(_ data: Data, on conn: NWConnection) {
        guard let message = try? decoder.decode(ClientMessage.self, from: data) else {
            send(ServerMessage(type: .error, text: "invalid message"), on: conn)
            return
        }
        switch message {
        case .ping:
            send(ServerMessage(type: .pong), on: conn)
        case .say(let id, let text):
            Task {
                for await reply in await brain.handle(id: id, text: text) {
                    self.send(reply, on: conn)
                }
            }
        case .answer(let id, let text):
            Task { await brain.gate.reply(id: id, text: text) }
        case .taskControl(let id, let action):
            Task { await brain.tasks.control(id, action: action) }
        case .cancelTurn:
            Task { await brain.cancelCurrentTurn() }
        case .mode(let raw):
            let mode = Attention.Mode(rawValue: raw) ?? .talking
            Attention.set(mode)
            brain.publish(ServerMessage(type: .event, text: mode.rawValue, kind: "mode"))
        case .reload:
            guard mode == .local else { return }
            log("reload requested: restarting")
            Task {
                await brain.shutdown()
                exit(0)  // launchd (KeepAlive) starts us again with the new settings
            }
        case .listTools, .tool:
            guard mode == .local else {
                send(ServerMessage(type: .error, text: "not allowed remotely"), on: conn)
                return
            }
            dispatchTool(message, on: conn)
        case .confirm(let id, let approved):
            Task { await brain.gate.answer(id: id, approved: approved) }
        }
    }

    private func dispatchTool(_ message: ClientMessage, on conn: NWConnection) {
        switch message {
        case .listTools(let id):
            send(ServerMessage(type: .toolResult, id: id, payload: ToolRegistry.listingJSON()), on: conn)
        case .tool(let id, let name, let args):
            // The app's own background reads (dashboard, archive) are not "activity".
            let quiet = args.contains("\"_quiet\":true")
            Task {
                let ctx = await brain.toolContext
                let start = Date()
                if !quiet {
                    brain.publish(ServerMessage(type: .event, id: id, text: name, kind: "tool",
                                                payload: "{\"phase\":\"start\"}"))
                }
                let (result, isError) = await ToolRegistry.call(name: name, argsJSON: args, ctx: ctx)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if !quiet {
                    brain.publish(ServerMessage(type: .event, id: id, text: name, latencyMs: ms, kind: "tool",
                                                payload: "{\"phase\":\"end\"}", isError: isError))
                    // Tool results can contain anything (DMs, mail, .env files): never log their content.
                    log("tool \(name) → \(isError ? "error" : "ok"), \(result.count) chars, \(ms) ms")
                    await brain.recordToolCall(name: name, ok: !isError, ms: ms)
                }
                self.send(ServerMessage(type: .toolResult, id: id, payload: result, isError: isError), on: conn)
            }
        default:
            break
        }
    }

    private func send(_ message: ServerMessage, on conn: NWConnection) {
        var message = message
        if mode == .remote {
            if message.type == .delta { return }
            message.text = message.text.map { SecretFilter.redact($0) }
            message.payload = message.payload.map { SecretFilter.redact($0) }
        }
        guard let data = try? encoder.encode(message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}
