import Foundation
import ElioCore
import Network
import Synchronization

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
                    // Confirmations and questions asked while this app was offline: show them now, with their buttons.
                    for msg in await self.brain.gate.replay() { self.send(msg, on: conn) }
                }
                // The phone shows whether the Mac is at rest from the moment it connects.
                if self.mode == .remote { self.send(Self.idleState(), on: conn) }
                self.receive(on: conn)
            case .failed, .cancelled:
                Task { await self.brain.unsubscribe(sinkId) }
                // The app that put the Mac at rest is gone (quit, crashed): it can't be at rest any more.
                let wasOwner = self.idleOwner.withLock { owner -> Bool in
                    guard owner == ObjectIdentifier(conn) else { return false }
                    owner = nil
                    return true
                }
                if wasOwner, Presence.idle {
                    Presence.setIdle(false)
                    self.brain.publish(Self.idleState())
                }
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
            Presence.noteRequest(remote: mode == .remote)
            Task {
                for await reply in await brain.handle(id: id, text: text) {
                    self.send(reply, on: conn)
                }
            }
        case .answer(let id, let text):
            Presence.noteRequest(remote: mode == .remote)
            Task { await brain.gate.reply(id: id, text: text) }
        case .taskControl(let id, let action):
            Task { await brain.tasks.control(id, action: action) }
        case .cancelTurn:
            Task { await brain.cancelCurrentTurn() }
        case .ambient(let id, let text):
            // Always-on mic: answers to a pending question/confirmation, the wake word, or (on the Mac only)
            // anything the classifier says is for Elio; a chat with someone else is dropped. The phone is in a
            // pocket or on a table among people, so there it takes the wake word or an awaited answer.
            Presence.noteRequest(remote: mode == .remote)
            Task {
                let wake = WakeWord.strip(text)
                let command = wake ?? text
                var forElio = wake != nil
                if !forElio, self.mode == .remote {
                    forElio = await brain.gate.awaitingAnswer
                } else if !forElio {
                    let verdict = await Addressee.classify(said: text, elioSaying: nil, wakeWord: false)
                    forElio = verdict.target != .other && verdict.intent != .backchannel
                }
                guard forElio, !command.isEmpty else {
                    log("ambient: not for Elio (\(text.count) chars)")
                    self.send(ServerMessage(type: .done, id: id, text: "", route: .local), on: conn)
                    return
                }
                for await reply in await brain.handle(id: id, text: command, overheard: true) { self.send(reply, on: conn) }
            }
        case .prepare(let id, let text):
            guard mode == .local else { return }
            Task { await brain.prepare(id: id, text: text) }
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
            Presence.noteRequest(remote: mode == .remote)
            Task { await brain.gate.answer(id: id, approved: approved) }
        case .idle(let on):
            if mode == .local {
                // The Mac app reports its rest state: the daemon pushes instead of waiting, and tells Claude.
                idleOwner.withLock { $0 = on ? ObjectIdentifier(conn) : nil }
                guard Presence.idle != on else { return }
                Presence.setIdle(on)
                log("rest mode \(on ? "on" : "off")")
                brain.publish(Self.idleState())
            } else {
                // From the phone: the app does the switching (screen, voice) and then reports back.
                brain.publish(ServerMessage(type: .event, text: on ? "on" : "off", kind: "idleRequest"))
            }
        }
    }

    /// Connection of the app that put the Mac at rest.
    private let idleOwner = Mutex<ObjectIdentifier?>(nil)

    static func idleState() -> ServerMessage {
        ServerMessage(type: .event, text: Presence.idle ? "on" : "off", kind: "idle")
    }

    private func dispatchTool(_ message: ClientMessage, on conn: NWConnection) {
        switch message {
        case .listTools(let id):
            send(ServerMessage(type: .toolResult, id: id, payload: ToolRegistry.listingJSON()), on: conn)
        case .tool(let id, let name, let args):
            // The app's own background reads (dashboard, archive) are not "activity".
            let quiet = args.contains("\"_quiet\":true")
            // Background agents have their own live log: the activity line is for the conversation.
            let feed = !quiet && !args.contains("\"_task\"")
            Task {
                let ctx = await brain.toolContext
                let start = Date()
                if !quiet {
                    brain.publish(ServerMessage(type: .event, id: id, text: name, kind: "tool",
                                                payload: "{\"phase\":\"start\"}"))
                }
                if feed {
                    brain.publish(.activity(id: id, tool: name, text: ActivityText.describe(tool: name, inputJSON: args), phase: "start"))
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
                if feed {
                    brain.publish(.activity(id: id, tool: name, text: ActivityText.outcome(tool: name, result: result, isError: isError) ?? "",
                                            phase: "end", ok: !isError, ms: ms))
                }
                self.send(ServerMessage(type: .toolResult, id: id, payload: result, isError: isError), on: conn)
            }
        default:
            break
        }
    }

    /// Reply text waiting for the end of its sentence, per request (phone only).
    private let pendingText = Mutex<[String: String]>([:])

    /// Appends a delta and returns the complete sentences it closed, if any.
    private func phoneSentences(_ message: ServerMessage) -> String? {
        guard let id = message.id, let chunk = message.text else { return nil }
        return pendingText.withLock { pending -> String? in
            let text = (pending[id] ?? "") + chunk
            // Last sentence end: punctuation followed by a space or a newline.
            guard let r = text.range(of: #"[.!?…:;]\s|\n"#, options: [.regularExpression, .backwards]) else {
                pending[id] = text
                return nil
            }
            pending[id] = String(text[r.upperBound...])
            return String(text[..<r.upperBound])
        }
    }

    /// Live briefing text the Mac would read aloud as it streams.
    static let spokenStreamKinds: Set<String> = ["routineDelta", "briefStart", "recapStart"]

    private func send(_ message: ServerMessage, on conn: NWConnection) {
        var message = message
        // Spoken events go to the device the user is on (see Presence); the other one just shows them.
        if message.type == .event {
            let onPhone = Presence.onPhone
            if mode == .local, onPhone {
                if let k = message.kind, Self.spokenStreamKinds.contains(k) { return }
                message.speak = message.speak == true ? false : message.speak
            } else if mode == .remote, !onPhone, message.speak == true {
                message.speak = false
            }
        }
        if mode == .remote {
            if message.type == .delta {
                // The phone speaks the reply sentence by sentence: deltas go out as whole sentences only,
                // so the secret filter sees complete text (a token split across chunks would slip through).
                guard let sentences = phoneSentences(message) else { return }
                message.text = sentences
            } else if message.type == .done || message.type == .error, let id = message.id {
                pendingText.withLock { $0[id] = nil }
            }
            message.text = message.text.map { SecretFilter.redact($0) }
            message.payload = message.payload.map { SecretFilter.redact($0) }
        }
        guard let data = try? encoder.encode(message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}
