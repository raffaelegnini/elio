import Foundation

/// Runtime configuration, persisted at ~/Library/Application Support/Elio/config.json.
public struct ElioConfig: Codable, Sendable {
    public var userName: String = "Raffaele"
    /// Brand / identity (shared with colleagues: everything here is editable in Settings).
    public var assistantName: String = "Elio"
    public var addressAs: String = "Signore"          // how the assistant addresses the user
    public var wakeAliases: [String] = ["helio", "ellio"]             // extra spellings the recognizer produces
    public var accentColor: String = "#FFD360"        // DNA yellow
    public var claudePath: String = ElioConfig.defaultClaudePath()
    public var claudeModel: String = "sonnet"
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

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so old config files keep working after new fields are added.
        let d = ElioConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        assistantName = try c.decodeIfPresent(String.self, forKey: .assistantName) ?? d.assistantName
        addressAs = try c.decodeIfPresent(String.self, forKey: .addressAs) ?? d.addressAs
        wakeAliases = try c.decodeIfPresent([String].self, forKey: .wakeAliases) ?? d.wakeAliases
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor) ?? d.accentColor
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
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
    }

    static func defaultClaudePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }
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
