import AppKit
import Foundation

/// Executes local intents on the Mac. Only non-destructive actions live here;
/// anything that sends, pushes or deletes must go through the confirmation gate (Phase 4).
public struct LocalActions: Sendable {
    public init() {}

    // MARK: - Apps

    private static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome",
        "vscode": "Visual Studio Code", "vs code": "Visual Studio Code", "code": "Visual Studio Code",
        "terminale": "Terminal", "terminal": "Terminal",
        "impostazioni": "System Settings", "settings": "System Settings",
        "calendario": "Calendar", "musica": "Music", "note": "Notes", "promemoria": "Reminders",
        "posta": "Mail", "messaggi": "Messages", "foto": "Photos", "mappe": "Maps",
        "calcolatrice": "Calculator", "finder": "Finder", "app store": "App Store",
    ]

    private static let searchDirs: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/System/Library/CoreServices"].map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent("Applications")]
    }()

    /// Finds an installed app by spoken name: exact → prefix → word match. Nil means "not an app".
    public func resolveApp(_ spoken: String) -> URL? {
        let wanted = (Self.aliases[spoken] ?? spoken).lowercased()
        var apps: [(name: String, url: URL)] = []
        for dir in Self.searchDirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                apps.append((url.deletingPathExtension().lastPathComponent.lowercased(), url))
            }
        }
        if let hit = apps.first(where: { $0.name == wanted }) { return hit.url }
        guard wanted.count >= 3 else { return nil }
        if let hit = apps.first(where: { $0.name.hasPrefix(wanted) }) { return hit.url }
        return apps.first(where: { $0.name.split(separator: " ").contains(Substring(wanted)) })?.url
    }

    public func openApp(at url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: - Volume

    public func setVolume(_ change: LocalIntent.VolumeChange) throws -> Int {
        let script: String
        switch change {
        case .set(let n): script = "set volume output volume \(n)"
        case .up: script = "set volume output volume ((output volume of (get volume settings)) + 15)"
        case .down: script = "set volume output volume ((output volume of (get volume settings)) - 15)"
        case .mute: script = "set volume with output muted"
        case .unmute: script = "set volume without output muted"
        }
        try runAppleScript(script)
        let level = try runAppleScript("output volume of (get volume settings)")
        return Int(level.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    // MARK: - Notifications

    public func notify(title: String, body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        _ = try? runAppleScript("display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\"")
    }

    @discardableResult
    func runAppleScript(_ source: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - Spoken replies

public enum Replies {
    public static func opened(_ app: String, _ lang: Lang) -> String {
        lang == .it ? "Apro \(app)." : "Opening \(app)."
    }

    public static func time(_ date: Date, _ lang: Lang) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: lang == .it ? "it_IT" : "en_GB")
        f.dateFormat = "HH:mm"
        return lang == .it ? "Sono le \(f.string(from: date))." : "It's \(f.string(from: date))."
    }

    public static func timerStarted(_ seconds: Int, _ lang: Lang) -> String {
        lang == .it ? "Timer di \(duration(seconds, lang)) avviato." : "Timer set for \(duration(seconds, lang))."
    }

    public static func timerFired(_ seconds: Int, _ lang: Lang) -> String {
        lang == .it ? "Il timer di \(duration(seconds, lang)) è scaduto." : "Your \(duration(seconds, lang)) timer is done."
    }

    public static func volume(_ change: LocalIntent.VolumeChange, level: Int, _ lang: Lang) -> String {
        switch change {
        case .mute: return lang == .it ? "Audio disattivato." : "Muted."
        case .unmute: return lang == .it ? "Audio riattivato." : "Unmuted."
        default: return lang == .it ? "Volume al \(level) per cento." : "Volume at \(level) percent."
        }
    }

    public static func stopped(_ lang: Lang) -> String { lang == .it ? "Ok." : "Okay." }

    public static func duration(_ seconds: Int, _ lang: Lang) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append(lang == .it ? "\(h) \(h == 1 ? "ora" : "ore")" : "\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append(lang == .it ? "\(m) \(m == 1 ? "minuto" : "minuti")" : "\(m) \(m == 1 ? "minute" : "minutes")") }
        if s > 0 { parts.append(lang == .it ? "\(s) \(s == 1 ? "secondo" : "secondi")" : "\(s) \(s == 1 ? "second" : "seconds")") }
        return parts.joined(separator: lang == .it ? " e " : " and ")
    }
}
