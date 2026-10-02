import Foundation

/// Runtime configuration, persisted at ~/Library/Application Support/Elio/config.json.
public struct ElioConfig: Codable, Sendable {
    public var userName: String = "Raffaele"
    /// Brand / identity (shared with colleagues: everything here is editable in Settings).
    public var assistantName: String = "Elio"
    public var addressAs: String = "Signore"          // how the assistant addresses the user
    /// Who the assistant is and how it talks (start of the system prompt); empty = built-in default.
    /// Placeholders: {assistente}, {utente}, {titolo}.
    public var persona: String = ""
    public var wakeAliases: [String] = ["helio", "ellio"]             // extra spellings the recognizer produces
    public var accentColor: String = "#FFD360"        // DNA yellow
    public var claudePath: String = ElioConfig.defaultClaudePath()
    public var claudeModel: String = "sonnet"
    /// Claude Code config dir of the account in use (CLAUDE_CONFIG_DIR); empty = ~/.claude.
    public var claudeConfigDir: String = ""
    public var port: UInt16 = 8765
    public var elevenLabsVoiceId: String = "W71zT1VwIFFx3mMGH2uZ" // MarcoTrox (Italian)
    public var elevenLabsModel: String = "eleven_flash_v2_5"
    /// Model for background agents (code, reviews).
    public var agentModel: String = "opus"
    /// Where to look for git repositories.
    public var projectRoots: [String] = ["~/Desktop/dev"]
    /// Morning brief: on the first unlock after `briefEarliest` on weekdays, or at `briefLatest`.
    public var briefEarliest: String = "07:30"
    public var briefLatest: String = "09:30"
    /// Open the Meet pre-join this many minutes before a meeting (0 = off).
    public var meetingLeadMinutes: Int = 2
    public var slackClockInChannel: String = "team-saluti"
    public var slackClockInText: String = "buongiorno"
    /// Phone: ntfy topic for notifications when away (generated on first run), web/WS ports for the PWA.
    public var ntfyTopic: String = ""
    public var spokenSentences: Int = 3
    public var builtInMicWithBluetooth: Bool = true
    public var briefOpening: Bool = true
    public var recapTime: String = ""
    public var nudgeMissedMeetings: Bool = true
    public var repeatReminders: Bool = true
    public var confirmCodeExecution: Bool = false
    public var echoCancellation: Bool = false
    public var browserAutonomy: Bool = true
    /// Only the enrolled owner's voice can command or interrupt Elio.
    public var speakerVerification: Bool = true
    public var speakerThreshold: Double = 0.4
    public var webPort: UInt16 = 8766
    public var remotePort: UInt16 = 8767
    /// Simple device commands (music, apps, links, volume) handled by Apple's on-device model.
    public var appleFastPath: Bool = true
    /// Projects coloured by technology (Magento, Laravel…) in the dashboard; off = accent colour.
    public var stackColors: Bool = false
    /// Agent workflows: "talking" narrates progress, "silent" speaks only for questions, problems and the end.
    public var workflowVoice: String = "talking"
    /// Elio answers agents' small questions itself when the user's known preferences cover them.
    public var delegateDecisions: Bool = true
    /// A reviewer checks agents' work against the user's taste rules and has them fix what breaks them.
    public var tasteReview: Bool = true
    /// Model for taste reviews and delegated decisions.
    public var reviewModel: String = "sonnet"
    /// Most agents a squad may run (coordinator excluded).
    public var maxSquadAgents: Int = 8

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so old config files keep working after new fields are added.
        let d = ElioConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        assistantName = try c.decodeIfPresent(String.self, forKey: .assistantName) ?? d.assistantName
        addressAs = try c.decodeIfPresent(String.self, forKey: .addressAs) ?? d.addressAs
        persona = try c.decodeIfPresent(String.self, forKey: .persona) ?? d.persona
        wakeAliases = try c.decodeIfPresent([String].self, forKey: .wakeAliases) ?? d.wakeAliases
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor) ?? d.accentColor
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        claudeConfigDir = try c.decodeIfPresent(String.self, forKey: .claudeConfigDir) ?? d.claudeConfigDir
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        elevenLabsVoiceId = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? d.elevenLabsVoiceId
        elevenLabsModel = try c.decodeIfPresent(String.self, forKey: .elevenLabsModel) ?? d.elevenLabsModel
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel) ?? d.agentModel
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots) ?? d.projectRoots
        briefEarliest = try c.decodeIfPresent(String.self, forKey: .briefEarliest) ?? d.briefEarliest
        briefLatest = try c.decodeIfPresent(String.self, forKey: .briefLatest) ?? d.briefLatest
        meetingLeadMinutes = try c.decodeIfPresent(Int.self, forKey: .meetingLeadMinutes) ?? d.meetingLeadMinutes
        slackClockInChannel = try c.decodeIfPresent(String.self, forKey: .slackClockInChannel) ?? d.slackClockInChannel
        slackClockInText = try c.decodeIfPresent(String.self, forKey: .slackClockInText) ?? d.slackClockInText
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
        webPort = try c.decodeIfPresent(UInt16.self, forKey: .webPort) ?? d.webPort
        remotePort = try c.decodeIfPresent(UInt16.self, forKey: .remotePort) ?? d.remotePort
        spokenSentences = try c.decodeIfPresent(Int.self, forKey: .spokenSentences) ?? d.spokenSentences
        builtInMicWithBluetooth = try c.decodeIfPresent(Bool.self, forKey: .builtInMicWithBluetooth) ?? d.builtInMicWithBluetooth
        briefOpening = try c.decodeIfPresent(Bool.self, forKey: .briefOpening) ?? d.briefOpening
        recapTime = try c.decodeIfPresent(String.self, forKey: .recapTime) ?? d.recapTime
        nudgeMissedMeetings = try c.decodeIfPresent(Bool.self, forKey: .nudgeMissedMeetings) ?? d.nudgeMissedMeetings
        repeatReminders = try c.decodeIfPresent(Bool.self, forKey: .repeatReminders) ?? d.repeatReminders
        confirmCodeExecution = try c.decodeIfPresent(Bool.self, forKey: .confirmCodeExecution) ?? d.confirmCodeExecution
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) ?? d.echoCancellation
        browserAutonomy = try c.decodeIfPresent(Bool.self, forKey: .browserAutonomy) ?? d.browserAutonomy
        speakerVerification = try c.decodeIfPresent(Bool.self, forKey: .speakerVerification) ?? d.speakerVerification
        speakerThreshold = try c.decodeIfPresent(Double.self, forKey: .speakerThreshold) ?? d.speakerThreshold
        appleFastPath = try c.decodeIfPresent(Bool.self, forKey: .appleFastPath) ?? d.appleFastPath
        stackColors = try c.decodeIfPresent(Bool.self, forKey: .stackColors) ?? d.stackColors
        workflowVoice = try c.decodeIfPresent(String.self, forKey: .workflowVoice) ?? d.workflowVoice
        delegateDecisions = try c.decodeIfPresent(Bool.self, forKey: .delegateDecisions) ?? d.delegateDecisions
        tasteReview = try c.decodeIfPresent(Bool.self, forKey: .tasteReview) ?? d.tasteReview
        reviewModel = try c.decodeIfPresent(String.self, forKey: .reviewModel) ?? d.reviewModel
        maxSquadAgents = try c.decodeIfPresent(Int.self, forKey: .maxSquadAgents) ?? d.maxSquadAgents
    }

    static func defaultClaudePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }
}

/// A Claude Code login: each account lives in its own config dir (`~/.claude`, `~/.claude-personale`…),
/// selected with CLAUDE_CONFIG_DIR, so switching account is just pointing claude at another dir.
public struct ClaudeAccount: Sendable, Hashable, Identifiable {
    /// Empty for the default ~/.claude.
    public let dir: String
    public var id: String { dir }

    public init(dir: String) { self.dir = ClaudeAccount.normalize(dir) }

    static func normalize(_ dir: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = (dir.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return expanded.isEmpty || expanded == "\(home)/.claude" ? "" : expanded
    }

    public var path: String {
        dir.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path : dir
    }

    /// "principale" for ~/.claude, otherwise the suffix of ~/.claude-<name> (or the folder name).
    public var name: String {
        if dir.isEmpty { return "principale" }
        let last = (dir as NSString).lastPathComponent
        return last.hasPrefix(".claude-") ? String(last.dropFirst(8)) : last
    }

    /// Email of the logged-in account, from Claude Code's own state file.
    public var email: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = dir.isEmpty ? home.appendingPathComponent(".claude.json") : URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    public var label: String { email.map { "\(name) · \($0)" } ?? "\(name) (non collegato)" }

    /// ~/.claude plus every ~/.claude-* folder, and `current` if it lives elsewhere.
    public static func detect(including current: String = "") -> [ClaudeAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var found = [ClaudeAccount(dir: "")]
        for n in names.sorted() where n.hasPrefix(".claude-") {
            var isDir: ObjCBool = false
            let path = home.appendingPathComponent(n).path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                found.append(ClaudeAccount(dir: path))
            }
        }
        let cur = ClaudeAccount(dir: current)
        if !found.contains(cur) { found.append(cur) }
        return found
    }

    /// Environment for a claude process running as this account.
    public func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        if dir.isEmpty { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") } else { env["CLAUDE_CONFIG_DIR"] = dir }
        return env
    }

    /// Sessions belong to one account: each keeps its own conversation to resume.
    public var sessionKey: String { dir.isEmpty ? "claude.session_id" : "claude.session_id@\(dir)" }
}

extension ElioConfig {
    public var claudeAccount: ClaudeAccount { ClaudeAccount(dir: claudeConfigDir) }
}

public enum ElioPaths {
    public static var support: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Elio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var config: URL { support.appendingPathComponent("config.json") }
    /// Where Elio puts the documents it creates (free to write here, elsewhere it asks).
    public static var outputDir: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Elio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var database: URL { support.appendingPathComponent("elio.sqlite") }
    public static var token: URL { support.appendingPathComponent("token") }
    /// Working directory of the Claude session; keeps its project settings isolated.
    public static var claudeWorkspace: URL {
        let url = support.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension ElioConfig {
    public static func load() -> ElioConfig {
        if let data = try? Data(contentsOf: ElioPaths.config),
           let cfg = try? JSONDecoder().decode(ElioConfig.self, from: data) {
            return cfg
        }
        let cfg = ElioConfig()
        cfg.save()
        return cfg
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: ElioPaths.config) }
    }
}

/// Shared secret required by every client of the local daemon.
/// Browsers cannot set custom WebSocket headers, so this also blocks web pages
/// from driving Elio through ws://127.0.0.1.
public enum AuthToken {
    /// Separate secret for the phone, so it can be revoked without touching local clients.
    public static func loadOrCreateRemote() throws -> String {
        try loadOrCreate(at: ElioPaths.support.appendingPathComponent("remote-token"))
    }

    public static func loadOrCreate() throws -> String {
        try loadOrCreate(at: ElioPaths.token)
    }

    static func loadOrCreate(at url: URL) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ElioError.tokenGeneration
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}

public enum ElioError: Error, CustomStringConvertible {
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
