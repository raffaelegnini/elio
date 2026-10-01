import Foundation

/// Runtime configuration, persisted at ~/Library/Application Support/Jarvis/config.json.
public struct JarvisConfig: Codable, Sendable {
    public var userName: String = "Raffaele"
    public var claudePath: String = JarvisConfig.defaultClaudePath()
    public var claudeModel: String = "sonnet"
    public var port: UInt16 = 8765
    public var elevenLabsVoiceId: String = "JBFqnCBsd6RMkjVDRZzb" // George
    public var elevenLabsModel: String = "eleven_flash_v2_5"
    /// Model for background agents (code, reviews).
    public var agentModel: String = "opus"
    /// Where to look for git repositories.
    public var projectRoots: [String] = ["~/Desktop/dev"]

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so old config files keep working after new fields are added.
        let d = JarvisConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        elevenLabsVoiceId = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? d.elevenLabsVoiceId
        elevenLabsModel = try c.decodeIfPresent(String.self, forKey: .elevenLabsModel) ?? d.elevenLabsModel
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel) ?? d.agentModel
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots) ?? d.projectRoots
    }

    static func defaultClaudePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }
}

public enum JarvisPaths {
    public static var support: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var config: URL { support.appendingPathComponent("config.json") }
    public static var database: URL { support.appendingPathComponent("jarvis.sqlite") }
    public static var token: URL { support.appendingPathComponent("token") }
    /// Working directory of the Claude session; keeps its project settings isolated.
    public static var claudeWorkspace: URL {
        let url = support.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension JarvisConfig {
    public static func load() -> JarvisConfig {
        if let data = try? Data(contentsOf: JarvisPaths.config),
           let cfg = try? JSONDecoder().decode(JarvisConfig.self, from: data) {
            return cfg
        }
        let cfg = JarvisConfig()
        cfg.save()
        return cfg
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: JarvisPaths.config) }
    }
}

/// Shared secret required by every client of the local daemon.
/// Browsers cannot set custom WebSocket headers, so this also blocks web pages
/// from driving Jarvis through ws://127.0.0.1.
public enum AuthToken {
    public static func loadOrCreate() throws -> String {
        let url = JarvisPaths.token
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw JarvisError.tokenGeneration
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}

public enum JarvisError: Error, CustomStringConvertible {
    case tokenGeneration
    case claudeNotRunning
    case claudeExited(Int32)
    case claudeTimeout
    case database(String)

    public var description: String {
        switch self {
        case .tokenGeneration: "Impossibile generare il token"
        case .claudeNotRunning: "Sessione Claude non attiva"
        case .claudeExited(let code): "Claude è terminato (exit \(code))"
        case .claudeTimeout: "Claude non risponde"
        case .database(let msg): "Database: \(msg)"
        }
    }
}
