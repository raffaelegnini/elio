import Foundation

public enum ClaudeEvent: Sendable {
    case delta(String)
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

        public init(claudePath: String, model: String, systemPrompt: String, workingDirectory: URL) {
            self.claudePath = claudePath
            self.model = model
            self.systemPrompt = systemPrompt
            self.workingDirectory = workingDirectory
        }
    }

    private let options: Options
    private var process: Process?
    private var stdin: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var generation = 0
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
                if Date().timeIntervalSince(lastActivity) > options.turnTimeout {
                    finishTurn(error: JarvisError.claudeTimeout)
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
            // Only the Jarvis workspace settings: keeps the user's hooks/plugins out of this session.
            "--setting-sources", "project",
            "--strict-mcp-config",
            "--tools", "",
            "--system-prompt", options.systemPrompt,
        ]
        if let sessionId { args += ["--resume", sessionId] }
        p.arguments = args
        p.currentDirectoryURL = options.workingDirectory

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env

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
        finishTurn(error: JarvisError.claudeExited(code))
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
            guard let inner = event["event"] as? [String: Any],
                  let delta = inner["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            currentText += text
            current?.yield(.delta(text))
        case "result":
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
