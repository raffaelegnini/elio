import Foundation

/// Wire protocol between eliod and its clients (CLI, macOS app, MCP bridge, later phone relay).
/// One JSON object per WebSocket text frame.
public enum ClientMessage: Codable, Sendable {
    case say(id: String, text: String)
    case ping
    /// From the MCP bridge: Claude called one of Elio's tools. `args` is a JSON object string.
    case tool(id: String, name: String, args: String)
    case listTools(id: String)
    /// From the app: the user's answer to a confirmation request.
    case confirm(id: String, approved: Bool)
    /// Settings changed: the daemon restarts to reload config, integrations and secrets.
    case reload
    /// The user's answer to an ask_user question.
    case answer(id: String, text: String)
    /// Pause / resume / stop a background agent.
    case taskControl(id: String, action: String)
    /// Stop what Elio is doing right now in the conversation (e.g. a long browser run).
    case cancelTurn

    private enum CodingKeys: String, CodingKey { case type, id, text, name, args, approved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "say": self = .say(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "ping": self = .ping
        case "tool":
            self = .tool(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                         args: try c.decodeIfPresent(String.self, forKey: .args) ?? "{}")
        case "listTools": self = .listTools(id: try c.decode(String.self, forKey: .id))
        case "reload": self = .reload
        case "answer": self = .answer(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "taskControl": self = .taskControl(id: try c.decode(String.self, forKey: .id), action: try c.decode(String.self, forKey: .text))
        case "cancelTurn": self = .cancelTurn
        case "confirm":
            self = .confirm(id: try c.decode(String.self, forKey: .id), approved: try c.decode(Bool.self, forKey: .approved))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .say(let id, let text):
            try c.encode("say", forKey: .type); try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        case .ping:
            try c.encode("ping", forKey: .type)
        case .tool(let id, let name, let args):
            try c.encode("tool", forKey: .type); try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name); try c.encode(args, forKey: .args)
        case .listTools(let id):
            try c.encode("listTools", forKey: .type); try c.encode(id, forKey: .id)
        case .reload:
            try c.encode("reload", forKey: .type)
        case .answer(let id, let text):
            try c.encode("answer", forKey: .type); try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        case .taskControl(let id, let action):
            try c.encode("taskControl", forKey: .type); try c.encode(id, forKey: .id); try c.encode(action, forKey: .text)
        case .cancelTurn:
            try c.encode("cancelTurn", forKey: .type)
        case .confirm(let id, let approved):
            try c.encode("confirm", forKey: .type); try c.encode(id, forKey: .id); try c.encode(approved, forKey: .approved)
        }
    }
}

public enum Route: String, Codable, Sendable { case local, claude }

public struct ServerMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case delta      // streamed chunk of the reply
        case done       // reply complete; `text` holds the full reply
        case error
        case event      // unsolicited: timer, reminder, task update, confirmation, diff, card
        case pong
        case toolResult // answer to `tool` / `listTools` (payload = JSON)
    }

    public var type: Kind
    public var id: String?
    public var text: String?
    public var route: Route?
    public var lang: Lang?
    public var latencyMs: Int?
    /// For events: "timer" | "reminder" | "task" | "confirm" | "diff" | "card".
    public var kind: String?
    /// Structured data as a JSON string (task state, diff, card, tool result).
    public var payload: String?
    /// Whether an event should be spoken aloud.
    public var speak: Bool?
    public var isError: Bool?

    public init(type: Kind, id: String? = nil, text: String? = nil, route: Route? = nil,
                lang: Lang? = nil, latencyMs: Int? = nil, kind: String? = nil, payload: String? = nil,
                speak: Bool? = nil, isError: Bool? = nil) {
        self.type = type; self.id = id; self.text = text; self.route = route
        self.lang = lang; self.latencyMs = latencyMs; self.kind = kind; self.payload = payload
        self.speak = speak; self.isError = isError
    }
}

// MARK: - Structured payloads

public struct TaskInfo: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, waitingConfirmation, paused, done, failed, cancelled }

    public var id: String
    public var title: String
    public var project: String?
    public var status: Status
    public var steps: [String]
    public var summary: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: String, title: String, project: String?, status: Status, steps: [String] = [],
                summary: String? = nil, startedAt: Date = Date(), endedAt: Date? = nil) {
        self.id = id; self.title = title; self.project = project; self.status = status
        self.steps = steps; self.summary = summary; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// One line of an agent's live activity (thinking, command, output, file edit…).
public struct TaskLogEntry: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case say, command, output, edit, write, read, search, ask, info }
    public var id: String
    public var taskId: String
    public var kind: Kind
    public var title: String
    public var body: String
    /// For edits: removed / added text.
    public var removed: String?
    public var added: String?
    public var date: Date

    public init(taskId: String, kind: Kind, title: String, body: String = "", removed: String? = nil, added: String? = nil) {
        id = UUID().uuidString; self.taskId = taskId; self.kind = kind; self.title = title; self.body = body
        self.removed = removed; self.added = added; date = Date()
    }
}

extension TaskLogEntry {
    /// Agents often `cat .env` or edit config files: logs never keep the secrets.
    public var redacted: TaskLogEntry {
        var e = self
        e.title = SecretFilter.redact(title)
        e.body = SecretFilter.redact(body)
        e.removed = removed.map { SecretFilter.redact($0) }
        e.added = added.map { SecretFilter.redact($0) }
        return e
    }
}

/// A question from the assistant or an agent that needs the user's answer.
public struct QuestionRequest: Codable, Sendable, Identifiable {
    public var id: String
    public var question: String
    public var from: String
    public var taskId: String?
}

public struct ConfirmRequest: Codable, Sendable, Identifiable {
    public enum Risk: String, Codable, Sendable { case normal, dangerous }

    public var id: String
    public var title: String      // short, spoken
    public var detail: String     // exact command / action, shown on screen
    public var risk: Risk
    public var taskId: String?
}

public struct DiffPayload: Codable, Sendable {
    public var title: String
    public var repo: String
    public var base: String
    public var head: String
    public var diff: String       // unified diff
}

public struct CardPayload: Codable, Sendable {
    public var title: String
    public var body: String       // markdown allowed
}

extension Encodable {
    public func jsonString() -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension Decodable {
    public static func fromJSON(_ string: String?) -> Self? {
        guard let string else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Self.self, from: Data(string.utf8))
    }
}
