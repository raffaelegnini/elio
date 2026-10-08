import Foundation

public enum ClaudeEvent: Sendable {
    case delta(String)
    /// A tool Claude runs itself (browser, web search): start / end.
    case tool(name: String, id: String, started: Bool)
    case done(text: String, durationMs: Int)
    /// Extended thinking: "" when a thinking block starts (the session's display may hide its text), then its text.
    case thinking(String)
    /// Any tool call, Elio's own included: at block start (`input` nil, Claude is still writing it) and when its
    /// input is complete (JSON object string).
    case toolCall(name: String, id: String, input: String?)
    /// A tool's result came back (`text` capped at 2000 characters).
    case toolResult(id: String, text: String, isError: Bool)
}

/// Keeps one Claude Code process alive in stream-json mode so each turn skips
/// the ~5s cold start (measured TTFT warm ≈ 0.85s with Sonnet).
/// Turns are serialized; the process is respawned (resuming the same session) if it dies.
public actor ClaudeBridge {
    public struct Options: Sendable {
        public var claudePath: String
        public var model: String
        public var systemPrompt: String
        public var workingDirectory: URL
        /// Silence after which a turn is considered stuck and the process is restarted.
        public var turnTimeout: TimeInterval = 120
        /// Hard cap per turn: tool heartbeats keep `lastActivity` fresh, so silence alone isn't enough.
        public var maxTurnDuration: TimeInterval = 1800
        /// MCP servers (JSON) available to the session; their tools are pre-approved.
        public var mcpConfig: String?
        /// Claude in Chrome: the user's real browser (already logged in everywhere).
        public var browser = false
        /// Claude account (config dir) the process runs as.
        public var account = ClaudeAccount(dir: "")
        /// Restricted sessions (speech prep): their own tool set, no permission prompts (anything not
        /// pre-approved is denied), extra readable folders. Nil = the conversation's defaults.
        public var tools: [String]?
        public var allowedTools: [String]?
        public var addDirs: [String] = []

        public init(claudePath: String, model: String, systemPrompt: String, workingDirectory: URL) {
            self.claudePath = claudePath
            self.model = model
            self.systemPrompt = systemPrompt
            self.workingDirectory = workingDirectory
        }
    }

    private var options: Options
    private var pendingOptions: Options?
    private var process: Process?
    private var stdin: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var generation = 0
    /// External tools running (id → name): they end when their result comes back.
    private var openTools: [String: String] = [:]
    /// Content blocks of the message being streamed, by index: tool calls accumulate their input here.
    private var blocks: [Int: (type: String, name: String, id: String, json: String)] = [:]
    private var shuttingDown = false
    private var consecutiveExits = 0
    private var sessionId: String?
    private var onSessionId: (@Sendable (String) -> Void)?

    private var current: AsyncThrowingStream<ClaudeEvent, Error>.Continuation?
    private var currentText = ""
    private var currentStart = Date()
    private var lastActivity = Date()
    private var turnInFlight = false
    /// A tool is running (a confirmation or a question can wait for the user for minutes): the silence
    /// timeout doesn't apply then, only the hard cap. Killing the turn there gave "Claude non risponde".
    private var waitingOnTool = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(options: Options, resumeSessionId: String? = nil) {
        self.options = options
        self.sessionId = resumeSessionId
        // A conversation that grew huge would make every reply slow after a pause (cache gone, all of it re-read).
        if let id = resumeSessionId, Self.sessionFileSize(id: id, account: options.account) > Self.maxSessionBytes {
            log("session \(id.prefix(8)) too large: starting a fresh one")
            sessionId = nil
            freshSession = true
        }
    }

    /// Past this, the next turn starts a fresh conversation (recent turns and long-term memory carry over).
    static let maxSessionBytes = 1_500_000
    /// After this long without a turn, a not-so-small conversation is restarted too: the prompt cache is long gone
    /// and re-reading it would cost seconds for nothing.
    static let staleAfter: TimeInterval = 2 * 3600
    private var lastTurnAt = Date()
    /// True when the current/next turn starts a new conversation (the caller adds a short recap of recent turns).
    public private(set) var freshSession = false

    static func sessionFileSize(id: String, account: ClaudeAccount) -> Int {
        let base = account.dir.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path : account.dir
        let projects = (base as NSString).appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return 0 }
        for d in dirs {
            let f = ((projects as NSString).appendingPathComponent(d) as NSString).appendingPathComponent("\(id).jsonl")
            if let size = (try? FileManager.default.attributesOfItem(atPath: f))?[.size] as? Int { return size }
        }
        return 0
    }

    /// Called before a turn: rotates the conversation when it's too big, or big-ish and cold.
    public func rotateIfNeeded() -> Bool {
        guard let id = sessionId else { return freshSession }
        let size = Self.sessionFileSize(id: id, account: options.account)
        let idle = Date().timeIntervalSince(lastTurnAt)
        guard size > Self.maxSessionBytes || (idle > Self.staleAfter && size > 300_000) else { return false }
        log("rotating session \(id.prefix(8)) (\(size / 1024) KB, idle \(Int(idle / 60)) min)")
        if process?.isRunning == true {
            readerTask?.cancel()
            generation += 1
            process?.terminate()
            process = nil
        }
        sessionId = nil
        freshSession = true
        return true
    }

    public func setSessionIdHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onSessionId = handler
    }

    /// Spawns the process ahead of the first request so the boot cost is paid at startup.
    public func warmUp() throws {
        if process?.isRunning != true { try spawn() }
    }

    public func ask(_ text: String) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.runTurn(text, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// New prompt / MCP servers: applied by restarting the process right before the next turn
    /// (never mid-turn), resuming the same conversation.
    public func reconfigure(_ newOptions: Options) {
        pendingOptions = newOptions
    }

    /// Stops the reply in progress (and whatever tools it is running) right away.
    public func cancelCurrentTurn() {
        guard current != nil else { return }
        finishTurn(error: ClaudeResultError(message: "interrotto dall'utente"))
        restart()  // the process is respawned (same conversation) for the next message
    }

    public func shutdown() {
        shuttingDown = true
        readerTask?.cancel()
        try? stdin?.close()
        process?.terminate()
        process = nil
    }

    // MARK: - Turn handling

    private func runTurn(_ text: String, _ continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation) async {
        await acquireTurn()
        defer { releaseTurn() }
        do {
            if let next = pendingOptions {
                pendingOptions = nil
                options = next
                if process?.isRunning == true {
                    readerTask?.cancel()
                    generation += 1          // ignore the old process's exit
                    process?.terminate()
                    process = nil
                }
            }
            if process?.isRunning != true { try spawn() }
            lastTurnAt = Date()
            current = continuation
            currentText = ""
            blocks = [:]
            openTools = [:]
            currentStart = Date()
            lastActivity = Date()
            waitingOnTool = false

            let message: [String: Any] = [
                "type": "user",
                "message": ["role": "user", "content": text],
            ]
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try stdin?.write(contentsOf: data)

            // Wait until the reader finishes the turn, watching for a stuck process.
            while current != nil {
                try await Task.sleep(for: .milliseconds(200))
                if (!waitingOnTool && Date().timeIntervalSince(lastActivity) > options.turnTimeout)
                    || Date().timeIntervalSince(currentStart) > options.maxTurnDuration {
                    finishTurn(error: ElioError.claudeTimeout)
                    restart()
                }
            }
        } catch {
            finishTurn(error: error)
        }
    }

    private func acquireTurn() async {
        if !turnInFlight { turnInFlight = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseTurn() {
        if waiters.isEmpty { turnInFlight = false } else { waiters.removeFirst().resume() }
    }

    private func finishTurn(error: Error? = nil) {
        guard let c = current else { return }
        current = nil
        if let error { c.finish(throwing: error) } else { c.finish() }
    }

    // MARK: - Process

    private func spawn() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: options.claudePath)
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", options.model,
            // Only the Elio workspace settings: keeps the user's hooks/plugins out of this session.
            "--setting-sources", "project",
            "--strict-mcp-config",
            // No shell or file edits in the conversational session: web research plus Elio
            // tools. Code work goes to background agents behind the confirmation gate.
            "--tools"] + (options.tools ?? ["WebSearch", "WebFetch", "Read", "Write", "Edit", "Glob", "Grep", "Bash", "Skill"]) + [
            "--system-prompt", options.systemPrompt,
        ]
        if let allowed = options.allowedTools {
            // Restricted session: read-only tools pre-approved, everything else denied (no prompt tool).
            if let mcp = options.mcpConfig { args += ["--mcp-config", mcp] }
            args += ["--allowedTools"] + allowed
            for dir in options.addDirs { args += ["--add-dir", dir] }
        } else if let mcp = options.mcpConfig {
            // Integration MCP tools are not pre-approved: they go through PermissionPolicy via `approve`.
            args += ["--mcp-config", mcp, "--allowedTools", "mcp__elio", "WebSearch", "WebFetch", "Read", "Glob", "Grep", "Skill",
                     "--add-dir", ElioPaths.outputDir.path]
            if options.browser { args += ["mcp__claude-in-chrome"] }
            args += ["--permission-prompt-tool", "mcp__elio__approve"]
        }
        if options.browser {
            args += ["--chrome"]
        }
        if let sessionId { args += ["--resume", sessionId] }
        p.arguments = args
        p.currentDirectoryURL = options.workingDirectory

        p.environment = options.account.environment()

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        // One generation per process: lines or exits from a dead process are ignored.
        generation += 1
        let gen = generation
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { await self?.processExited(code, generation: gen) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        log("claude started pid=\(p.processIdentifier) resume=\(sessionId ?? "-")")

        let lines = LineReader.stream(outPipe.fileHandleForReading)
        readerTask = Task { [weak self] in
            for await line in lines { await self?.handle(line: line, generation: gen) }
        }
        let errLines = LineReader.stream(errPipe.fileHandleForReading)
        Task.detached {
            for await line in errLines { log("claude stderr: \(line)") }
        }
    }

    private func restart() {
        readerTask?.cancel()
        process?.terminate()
        process = nil
    }

    private func processExited(_ code: Int32, generation gen: Int) {
        log("claude exited code=\(code)")
        guard gen == generation else { return }
        process = nil
        finishTurn(error: ElioError.claudeExited(code))
        guard !shuttingDown else { return }
        // Respawn right away so the next request finds a warm process;
        // back off exponentially if it keeps dying (e.g. logged out).
        consecutiveExits += 1
        let delay = min(60, 1 << min(consecutiveExits - 1, 6))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if process == nil, !shuttingDown {
                do { try spawn() } catch { log("claude respawn failed: \(error)") }
            }
        }
    }

    private func handle(line: String, generation gen: Int) {
        guard gen == generation else { return }
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        lastActivity = Date()

        switch type {
        case "system":
            if event["subtype"] as? String == "init", let id = event["session_id"] as? String {
                sessionId = id
                freshSession = false
                onSessionId?(id)
            }
        case "user":
            waitingOnTool = false   // tool results arrived
            for item in (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            where item["type"] as? String == "tool_result" {
                guard let id = item["tool_use_id"] as? String else { continue }
                current?.yield(.toolResult(id: id, text: String(Self.resultText(item["content"]).prefix(2000)),
                                           isError: item["is_error"] as? Bool == true))
                if let name = openTools.removeValue(forKey: id) { current?.yield(.tool(name: name, id: id, started: false)) }
            }
        case "stream_event":
            guard let inner = event["event"] as? [String: Any] else { return }
            let index = inner["index"] as? Int ?? -1
            switch inner["type"] as? String {
            case "message_start":
                blocks = [:]
            case "content_block_start":
                guard let block = inner["content_block"] as? [String: Any] else { return }
                let type = block["type"] as? String ?? ""
                waitingOnTool = type == "tool_use"
                if type == "tool_use" {
                    let name = block["name"] as? String ?? "tool"
                    let id = block["id"] as? String ?? UUID().uuidString
                    blocks[index] = (type, name, id, "")
                    // Elio's own tools are reported by the daemon itself when they run.
                    if !name.hasPrefix("mcp__elio__") {
                        openTools[id] = name
                        current?.yield(.tool(name: name, id: id, started: true))
                    }
                    current?.yield(.toolCall(name: name, id: id, input: nil))
                } else if type == "thinking" || type == "redacted_thinking" {
                    current?.yield(.thinking(""))
                } else if type == "text", !currentText.isEmpty, currentText.last?.isWhitespace == false {
                    // A new text block after a tool call ("Certo, controllo…" → tool → answer): keep them apart.
                    currentText += "\n"
                    current?.yield(.delta("\n"))
                }
            case "content_block_delta":
                guard let delta = inner["delta"] as? [String: Any] else { return }
                switch delta["type"] as? String {
                case "text_delta":
                    guard let text = delta["text"] as? String else { return }
                    currentText += text
                    current?.yield(.delta(text))
                case "thinking_delta":
                    if let text = delta["thinking"] as? String, !text.isEmpty { current?.yield(.thinking(text)) }
                case "input_json_delta":
                    if let part = delta["partial_json"] as? String, blocks[index] != nil { blocks[index]?.json += part }
                default:
                    break
                }
            case "content_block_stop":
                if let b = blocks.removeValue(forKey: index), b.type == "tool_use" {
                    current?.yield(.toolCall(name: b.name, id: b.id, input: b.json.isEmpty ? "{}" : b.json))
                }
            default:
                break
            }
        case "result":
            for (id, name) in openTools { current?.yield(.tool(name: name, id: id, started: false)) }
            openTools = [:]
            let final = (event["result"] as? String) ?? currentText
            let ms = Int(Date().timeIntervalSince(currentStart) * 1000)
            if event["is_error"] as? Bool == true {
                finishTurn(error: ClaudeResultError(message: final))
            } else {
                current?.yield(.done(text: final, durationMs: ms))
                consecutiveExits = 0
                finishTurn()
            }
        default:
            break
        }
    }

    /// Text of a tool_result's content: a string or a list of blocks.
    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return parts.joined(separator: "\n")
    }
}

/// Splits a pipe into lines as soon as bytes arrive. `FileHandle.bytes.lines` buffers
/// pipe output until EOF, which made replies arrive only after the process exited.
enum LineReader {
    static func stream(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = Buffer()
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in buffer.append(chunk) { continuation.yield(line) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Only touched from the file handle's serial readability queue.
    private final class Buffer: @unchecked Sendable {
        private var data = Data()

        func append(_ chunk: Data) -> [String] {
            data.append(chunk)
            var lines: [String] = []
            while let nl = data.firstIndex(of: 0x0A) {
                let lineData = data[data.startIndex..<nl]
                data.removeSubrange(data.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }
}

public struct ClaudeResultError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "Claude: \(message)" }
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
}
