import Foundation

// Wire types: the same JSON eliod speaks (Sources/ElioCore/Protocol.swift). Decoding is lenient on purpose:
// the Mac may add fields, and an older Mac may lack some.

struct ServerMessage: Decodable {
    var type: String
    var id: String?
    var text: String?
    var route: String?
    var latencyMs: Int?
    var kind: String?
    var payload: String?
    var speak: Bool?
    var isError: Bool?
}

/// Client → server frame. Nil fields are left out, matching ClientMessage's coding keys.
struct Outgoing: Encodable {
    var type: String
    var id: String?
    var text: String?
    var approved: Bool?
    var on: Bool?

    static func say(_ id: String, _ text: String) -> Outgoing { Outgoing(type: "say", id: id, text: text) }
    static func ambient(_ id: String, _ text: String) -> Outgoing { Outgoing(type: "ambient", id: id, text: text) }
    static func confirm(_ id: String, _ ok: Bool) -> Outgoing { Outgoing(type: "confirm", id: id, approved: ok) }
    static func answer(_ id: String, _ text: String) -> Outgoing { Outgoing(type: "answer", id: id, text: text) }
    static func taskControl(_ id: String, _ action: String) -> Outgoing { Outgoing(type: "taskControl", id: id, text: action) }
    static func mode(_ mode: String) -> Outgoing { Outgoing(type: "mode", text: mode) }
    static func idle(_ on: Bool) -> Outgoing { Outgoing(type: "idle", on: on) }
    static let ping = Outgoing(type: "ping")
}

struct ConfirmRequest: Decodable, Equatable {
    var id: String
    var title: String
    var detail: String?
    var risk: String?
    var isDangerous: Bool { risk == "dangerous" }
}

struct QuestionRequest: Decodable, Equatable {
    var id: String
    var question: String
    var from: String?
}

struct TaskInfo: Decodable, Identifiable, Equatable {
    var id: String
    var title: String
    var project: String?
    var status: String
    var steps: [String]?
    var summary: String?
    var kind: String?
    var member: String?
    var role: String?
    var lastMessage: String?
    var costUSD: Double?

    var isActive: Bool { ["running", "waitingConfirmation", "paused"].contains(status) }
}

struct InboxMessage: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var text: String?
    var source: String?
    var date: Date?
    var read: Bool

    /// What gets read aloud: the title only when the text doesn't already start with it.
    var speech: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = (!t.isEmpty && !body.hasPrefix(t)) ? "\(t). \(body)" : (body.isEmpty ? t : body)
        return String(s.prefix(2000))
    }

    var sourceLabel: String? {
        guard let s = source, !s.isEmpty, s != "elio" else { return nil }
        return s.hasPrefix("monitor:") ? "Monitor · " + s.dropFirst(8) : s
    }
}

struct InboxPayload: Decodable {
    var unread: Int?
    var messages: [InboxMessage]?
}

struct TodoItem: Decodable, Identifiable, Equatable {
    var id: Int
    var text: String
    var day: String?
    var priority: Int?
    var done: Bool
    var notes: String?
    var estimate: Int?
    var time: String?
    var focus: Bool?

    var important: Bool { (priority ?? 0) > 0 }
    var isFocus: Bool { focus ?? false }
}

struct TodoBoard: Decodable, Equatable {
    var day: String?
    var today: [TodoItem]
    var overdue: [TodoItem]
    var tomorrow: [TodoItem]
    var someday: [TodoItem]

    enum CodingKeys: String, CodingKey { case day, today, overdue, tomorrow, someday }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decodeIfPresent(String.self, forKey: .day)
        today = try c.decodeIfPresent([TodoItem].self, forKey: .today) ?? []
        overdue = try c.decodeIfPresent([TodoItem].self, forKey: .overdue) ?? []
        tomorrow = try c.decodeIfPresent([TodoItem].self, forKey: .tomorrow) ?? []
        someday = try c.decodeIfPresent([TodoItem].self, forKey: .someday) ?? []
    }
}

struct WorkflowRecord: Decodable, Equatable {
    var id: String
    var title: String
    var status: String
    var startedAt: Date?
}

struct WorkflowItem: Decodable, Identifiable, Equatable {
    var workflow: WorkflowRecord
    var agents: [TaskInfo]
    var pending: Int?
    var id: String { workflow.id }
}

struct WorkflowFeed: Decodable {
    var mode: String?
    var workflows: [WorkflowItem]?
}

enum JSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // eliod encodes dates with .iso8601 (no fractional seconds); accept both forms.
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = try? Date(s, strategy: .iso8601) { return date }
            if let date = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, _ string: String?) -> T? {
        guard let string else { return nil }
        return try? decoder.decode(type, from: Data(string.utf8))
    }
}
