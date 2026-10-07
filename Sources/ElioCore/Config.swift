import Foundation

/// Runtime configuration, persisted at ~/Library/Application Support/Elio/config.json.
public struct ElioConfig: Codable, Sendable {
    public var userName: String = ""
    /// The user's name for prompts and speech: "l'utente" when none is configured.
    public var displayName: String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Self.unnamedUser : name
    }
    /// "di <nome>", or "dell'utente" when no name is configured.
    public var ofUser: String { Self.of(displayName) }
    /// "a <nome>", or "all'utente" when no name is configured.
    public var toUser: String { Self.to(displayName) }
    public static let unnamedUser = "l'utente"
    public static func of(_ name: String) -> String { name == unnamedUser ? "dell'utente" : "di \(name)" }
    public static func to(_ name: String) -> String { name == unnamedUser ? "all'utente" : "a \(name)" }
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
    public var maxSquadAgents: Int = 4
    /// Model of squad members, their lead and scout (code work needs Opus; tokens are saved by the scout instead).
    public var squadModel: String = "opus"
    /// Opus by default; the light model only for jobs both Elio and the router judge trivial (~5%).
    public var smartModelRouting: Bool = true
    public var lightModel: String = "sonnet"
    /// A normal app (Dock icon, ⌘-Tab) instead of only the menu bar icon.
    public var showInDock: Bool = true
    /// Where Elio's own source is (empty = the repository it was built from).
    public var selfSourcePath: String = ""
    /// Thinking ahead while the user talks (a small read-only session), and its model.
    public var speechPrep: Bool = true
    /// A request about what's on screen ("ho degli errori qui") comes with a screenshot (deleted after the reply).
    public var screenGlance: Bool = true
    public var prepModel: String = "haiku"
    /// Rest mode ("modalità riposo"): after `idleMinutes` without keyboard/mouse the screen goes off (or dim),
    /// the Mac is kept awake for background work and Elio stops talking aloud, except for urgent things
    /// outside the quiet hours.
    public var idleAuto: Bool = true
    public var idleMinutes: Int = 15
    /// "off" (display asleep) or "dim" (built-in display at minimum brightness).
    public var idleScreen: String = "off"
    /// Minutes of the full-screen "Elio a riposo" page before the screen actually goes off/dim (0 = straight away).
    public var restScreenMinutes: Int = 5
    /// Hours when Elio never wakes the Mac or speaks on its own, even for urgent things (phone only). HH:mm.
    public var quietStart: String = "23:00"
    public var quietEnd: String = "07:30"
    /// The mic keeps listening for the wake word while at rest ("Elio, sono tornato").
    public var idleListen: Bool = true
    /// Native iPhone app (APNs, token auth): Apple Developer Team ID and the Key ID of the .p8 key
    /// (the key itself is in the Keychain, service elio-apns-key), and the app's bundle id.
    public var apnsTeamId: String = ""
    public var apnsKeyId: String = ""
    public var apnsBundleId: String = "it.dnafactory.elio.phone"

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
        squadModel = try c.decodeIfPresent(String.self, forKey: .squadModel) ?? d.squadModel
        smartModelRouting = try c.decodeIfPresent(Bool.self, forKey: .smartModelRouting) ?? d.smartModelRouting
        lightModel = try c.decodeIfPresent(String.self, forKey: .lightModel) ?? d.lightModel
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        selfSourcePath = try c.decodeIfPresent(String.self, forKey: .selfSourcePath) ?? d.selfSourcePath
        speechPrep = try c.decodeIfPresent(Bool.self, forKey: .speechPrep) ?? d.speechPrep
        screenGlance = try c.decodeIfPresent(Bool.self, forKey: .screenGlance) ?? d.screenGlance
        prepModel = try c.decodeIfPresent(String.self, forKey: .prepModel) ?? d.prepModel
        idleAuto = try c.decodeIfPresent(Bool.self, forKey: .idleAuto) ?? d.idleAuto
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        idleScreen = try c.decodeIfPresent(String.self, forKey: .idleScreen) ?? d.idleScreen
        restScreenMinutes = try c.decodeIfPresent(Int.self, forKey: .restScreenMinutes) ?? d.restScreenMinutes
        quietStart = try c.decodeIfPresent(String.self, forKey: .quietStart) ?? d.quietStart
        quietEnd = try c.decodeIfPresent(String.self, forKey: .quietEnd) ?? d.quietEnd
        idleListen = try c.decodeIfPresent(Bool.self, forKey: .idleListen) ?? d.idleListen
        apnsTeamId = try c.decodeIfPresent(String.self, forKey: .apnsTeamId) ?? d.apnsTeamId
        apnsKeyId = try c.decodeIfPresent(String.self, forKey: .apnsKeyId) ?? d.apnsKeyId
        apnsBundleId = try c.decodeIfPresent(String.self, forKey: .apnsBundleId) ?? d.apnsBundleId
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
    /// Elio's own source code (the repository it was built from), when it's on this Mac: Elio can open it
    /// in its IDE, put agents on it and rebuild itself.
    public static var selfSource: String? {
        let configured = ElioConfig.load().selfSourcePath
        let candidates = (configured.isEmpty ? [] : [(configured as NSString).expandingTildeInPath])
            + [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path]
        return candidates.first { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("Package.swift"))
            && FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("Sources/ElioCore")) }
    }

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

extension String {
    /// First letter uppercased, for a name at the start of a sentence ("l'utente" → "L'utente").
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
