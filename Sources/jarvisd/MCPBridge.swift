import Foundation
import JarvisCore

/// `jarvisd --mcp`: a stdio MCP server spawned by Claude Code. It forwards every
/// tool call to the running daemon over the local WebSocket, where tools actually run
/// (calendar permission, confirmation gate and task state live in the daemon).
enum MCPBridge {
    static func run() async -> Never {
        let config = JarvisConfig.load()
        guard let token = try? AuthToken.loadOrCreate() else { exit(1) }
        let taskId = ProcessInfo.processInfo.environment["JARVIS_TASK_ID"]
        let daemon = DaemonRPC(port: config.port, token: token)

        let input = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { exit(0) }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // Requests are handled concurrently: an `approve` can wait minutes for the user.
                Task { await handle(msg, daemon: daemon, taskId: taskId) }
            }
        }
    }

    static func handle(_ msg: [String: Any], daemon: DaemonRPC, taskId: String?) async {
        guard let method = msg["method"] as? String else { return }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "jarvis", "version": "0.3.0"],
            ])
        case "tools/list":
            let (text, _) = await daemon.call(.listTools(id: UUID().uuidString))
            let tools = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? []
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            var args = params["arguments"] as? [String: Any] ?? [:]
            if let taskId { args["_task"] = taskId }
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
            let (text, isError) = await daemon.call(.tool(id: UUID().uuidString, name: name, args: json))
            reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
        case "ping":
            reply(id, [String: Any]())
        default:
            if id != nil { error(id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    private static let out = NSLock()

    static func reply(_ id: Any?, _ result: Any) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    static func error(_ id: Any?, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    static func write(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        out.withLock { FileHandle.standardOutput.write(data) }
    }
}

/// Request/response over the daemon WebSocket, matched by message id.
final class DaemonRPC: @unchecked Sendable {
    private let client: DaemonClient
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<(String, Bool), Never>] = [:]

    init(port: UInt16, token: String) {
        client = DaemonClient(port: port, token: token)
        client.onMessage = { [weak self] msg in
            guard msg.type == .toolResult, let id = msg.id, let self else { return }
            let c = self.lock.withLock { self.waiting.removeValue(forKey: id) }
            c?.resume(returning: (msg.payload ?? msg.text ?? "", msg.isError ?? false))
        }
        client.start()
    }

    func call(_ message: ClientMessage) async -> (String, Bool) {
        let id: String
        switch message {
        case .tool(let i, _, _), .listTools(let i): id = i
        default: return ("", true)
        }
        // Wait for the socket to be up (daemon may be restarting).
        for _ in 0..<50 where !client.isConnected { try? await Task.sleep(for: .milliseconds(100)) }
        return await withCheckedContinuation { c in
            lock.withLock { waiting[id] = c }
            client.send(message)
        }
    }
}
