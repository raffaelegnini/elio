import Foundation

/// A capability Claude can call through the Elio MCP server.
public struct ElioTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema of the input object.
    public let schema: [String: any Sendable]
    public let run: @Sendable (_ args: [String: Any], _ ctx: ToolContext) async throws -> String

    public init(name: String, description: String, properties: [String: [String: any Sendable]] = [:],
                required: [String] = [],
                run: @escaping @Sendable (_ args: [String: Any], _ ctx: ToolContext) async throws -> String) {
        self.name = name
        self.description = description
        self.schema = ["type": "object", "properties": properties, "required": required]
        self.run = run
    }

    var listing: [String: Any] {
        ["name": name, "description": description, "inputSchema": schema]
    }
}

public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// Everything a tool may touch.
public struct ToolContext: Sendable {
    public init(config: ElioConfig, memory: Memory, broadcast: @escaping @Sendable (ServerMessage) -> Void,
                gate: ConfirmationGate, tasks: TaskRunner, scheduler: Scheduler,
                restartSession: @escaping @Sendable () async -> Void = {},
                sync: SyncEngine? = nil,
                restartAfterTurn: @escaping @Sendable () async -> Void = {},
                runRoutine: @escaping @Sendable (String) async -> Void = { _ in }, taskId: String? = nil) {
        self.config = config; self.memory = memory; self.broadcast = broadcast; self.gate = gate
        self.tasks = tasks; self.scheduler = scheduler; self.restartSession = restartSession
        self.runRoutine = runRoutine; self.sync = sync; self.restartAfterTurn = restartAfterTurn; self.taskId = taskId
    }

    public let config: ElioConfig
    public let memory: Memory
    public let broadcast: @Sendable (ServerMessage) -> Void
    public let gate: ConfirmationGate
    public let tasks: TaskRunner
    public let scheduler: Scheduler
    /// Rebuild the conversation session (new MCP integration, new prompt) before the next message.
    public var restartSession: @Sendable () async -> Void = {}
    public var sync: SyncEngine?
    public var restartAfterTurn: @Sendable () async -> Void = {}
    public func requestRestartAfterTurn() async { await restartAfterTurn() }
    /// Starts a routine ("brief" / "recap") after the current turn.
    public var runRoutine: @Sendable (String) async -> Void = { _ in }

    public func startRoutine(_ which: String) async { await runRoutine(which) }
    /// Set when the call comes from a background agent (for approvals).
    public var taskId: String?

    public func requestSessionRestart() async { await restartSession() }
}

public enum ToolRegistry {
    public static let all: [ElioTool] = [
        CalendarTools.events,
        MacTools.openURL,
        MacTools.openApp,
        MeetingTools.joinNext,
        ProjectTools.list,
        ProjectTools.showDiff,
        AskTools.ask,
        TaskTools.start,
        TaskTools.schedule,
        RoutineTools.brief,
        DayTools.summary,
        RoutineControl.run,
        HistoryTools.history,
        TaskTools.list,
        TaskTools.control,
        TaskTools.cancel,
        ScreenTools.show,
        FileTools.save,
        FileTools.open,
        FileTools.printFile,
        FileTools.pdf,
        ReminderTools.set,
        ReminderTools.list,
        ApprovalTool.approve,
        SelfTools.get,
        SelfTools.set,
        SelfTools.open,
        DirectoryTools.lookup,
        DirectoryTools.refresh,
        DirectoryTools.integrationSync,
        IntegrationTools.propose,
        IntegrationTools.setSecret,
        IntegrationTools.activate,
        IntegrationTools.notes,
        IntegrationTools.list,
        IntegrationTools.request,
        MemoryTools.remember,
        MemoryTools.recall,
        MemoryTools.forget,
        SlackTools.clockIn,
        SlackTools.send,
        SlackTools.mentions,
        SlackTools.dms,
        SquadTools.macTask,
        SquadTools.progress,
        SquadTools.start,
        SquadTools.send,
        SquadTools.status,
        SquadTools.stop,
        SquadTools.post,
        SquadTools.inbox,
        SquadTools.usage,
        SpotifyTools.control,
        SpotifyTools.play,
        SpotifyTools.setup,
        SpotifyTools.login,
        DesktopTools.context,
        DesktopTools.screenshot,
        DesktopTools.typeText,
        DesktopTools.arrange,
        DesktopTools.find,
        DesktopTools.clipboard,
    ]

    public static func listingJSON() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: all.map(\.listing))) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func call(name: String, argsJSON: String, ctx: ToolContext) async -> (String, Bool) {
        guard let tool = all.first(where: { $0.name == name }) else { return ("Tool sconosciuto: \(name)", true) }
        var args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        var taskCtx = ctx
        if let task = args.removeValue(forKey: "_task") as? String, !task.isEmpty { taskCtx.taskId = task }
        args.removeValue(forKey: "_quiet")
        let ctx = taskCtx
        // Approvals wait for the user; everything else must answer quickly, or the
        // conversation stalls (e.g. a macOS permission prompt nobody has clicked yet).
        let timeout: TimeInterval = switch name {
        case "approve": 600
        case "ask_user": 1560
        case "slack_clock_in", "slack_send", "integration_activate": 150   // waits for the user's confirmation
        case "slack_mentions", "slack_dms": 45
        case "start_task", "mac_task", "squad_start", "squad_send": 60
        case "spotify_login": 150
        case "spotify_play": 30
        default: 20
        }
        let box = ArgsBox(args)
        do {
            return (try await withTimeout(timeout) { try await tool.run(box.value, ctx) }, false)
        } catch is TimeoutError {
            return ("Lo strumento \(name) non ha risposto entro \(Int(timeout)) secondi. Probabilmente macOS sta chiedendo un permesso a Elio: controlla se c'è una finestra di autorizzazione aperta.", true)
        } catch {
            return ("Errore: \(error)", true)
        }
    }
}

// MARK: - Helpers

struct TimeoutError: Error {}

private final class ArgsBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Races an operation against a deadline. Unlike a task group it returns on time even when the
/// operation is stuck in a blocking call that ignores cancellation (it is left to finish on its own).
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        let once = Once()
        Task.detached {
            do {
                let value = try await op()
                if once.claim() { c.resume(returning: value) }
            } catch {
                if once.claim() { c.resume(throwing: error) }
            }
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() { c.resume(throwing: TimeoutError()) }
        }
    }
}

func prop(_ description: String, type: String = "string") -> [String: any Sendable] {
    ["type": type, "description": description]
}

@discardableResult
public func shell(_ launchPath: String, _ args: [String], cwd: String? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw ToolError("\((args.first ?? launchPath)) exit \(p.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self)
}

func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
