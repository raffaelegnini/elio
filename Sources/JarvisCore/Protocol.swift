import Foundation

/// Wire protocol between jarvisd and its clients (CLI, macOS app, later phone relay).
/// One JSON object per WebSocket text frame.
public enum ClientMessage: Codable, Sendable {
    case say(id: String, text: String)
    case ping

    private enum CodingKeys: String, CodingKey { case type, id, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "say": self = .say(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "ping": self = .ping
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
        }
    }
}

public enum Route: String, Codable, Sendable { case local, claude }

public struct ServerMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case delta      // streamed chunk of the reply
        case done       // reply complete; `text` holds the full reply
        case error
        case event      // unsolicited: timer fired, reminder, status change
        case pong
    }

    public var type: Kind
    public var id: String?
    public var text: String?
    public var route: Route?
    public var lang: Lang?
    public var latencyMs: Int?

    public init(type: Kind, id: String? = nil, text: String? = nil, route: Route? = nil,
                lang: Lang? = nil, latencyMs: Int? = nil) {
        self.type = type; self.id = id; self.text = text; self.route = route
        self.lang = lang; self.latencyMs = latencyMs
    }
}
