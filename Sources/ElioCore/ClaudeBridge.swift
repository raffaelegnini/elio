import Foundation

public enum ClaudeEvent: Sendable {
    case delta(String)
    /// A tool Claude runs itself (browser, web search): start / end.
    case tool(name: String, id: String, started: Bool)
    case done(text: String, durationMs: Int)
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
        public var maxTurnDuration: TimeInterval = 900
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
    private var openTool: (name: String, id: String)?
    private var shuttingDown = false
    private var consecutiveExits = 0
    private var sessionId: String?
    private var onSessionId: (@Sendable (String) -> Void)?

    private var current: AsyncThrowingStream<ClaudeEvent, Error>.Continuation?
    private var currentText = ""
    private var currentStart = Date()
    private var lastActivity = Date()
    private var turnInFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(options: Options, resumeSessionId: String? = nil) {
        self.options = options
        self.sessionId = resumeSessionId
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
            current = continuation
            currentText = ""
            currentStart = Date()
            lastActivity = Date()

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
                if Date().timeIntervalSince(lastActivity) > options.turnTimeout
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
                onSessionId?(id)
            }
        case "stream_event":
            if let inner = event["event"] as? [String: Any], inner["type"] as? String == "content_block_start",
               let block = inner["content_block"] as? [String: Any] {
                // Any new block means the previous external tool has finished.
                if let open = openTool { current?.yield(.tool(name: open.name, id: open.id, started: false)); openTool = nil }
                if block["type"] as? String == "tool_use", let name = block["name"] as? String, !name.hasPrefix("mcp__elio__") {
                    let id = block["id"] as? String ?? UUID().uuidString
                    openTool = (name, id)
                    current?.yield(.tool(name: name, id: id, started: true))
                }
            }
            // A new text block after a tool call ("Certo, controllo…" → tool → answer): keep them apart.
            if let inner = event["event"] as? [String: Any], inner["type"] as? String == "content_block_start",
               (inner["content_block"] as? [String: Any])?["type"] as? String == "text", !currentText.isEmpty,
               currentText.last?.isWhitespace == false {
                currentText += "\n"
                current?.yield(.delta("\n"))
            }
            guard let inner = event["event"] as? [String: Any],
                  let delta = inner["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            currentText += text
            current?.yield(.delta(text))
        case "result":
            if let open = openTool { current?.yield(.tool(name: open.name, id: open.id, started: false)); openTool = nil }
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
