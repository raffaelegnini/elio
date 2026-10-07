import AppKit
import Foundation

/// "Ho degli errori nell'IDE", "cosa vedi?", "che significa questo?": when a request is about what's on screen,
/// Elio takes a screenshot right away and hands it to Claude with the request — no extra tool round trip, no
/// need to ask. The image lives in a temporary folder inside the session workspace (Read needs no extra
/// permission there) and is deleted as soon as the reply is done; leftovers older than ten minutes go too.
public enum ScreenGlance {
    /// Phrases that point at what the user is looking at. Conservative: a plain question isn't one.
    static let pattern = #"""
        (?ix)\b(
        (sul|sullo|nel|nello|lo|il|mio|questo)\s+schermo | cosa\s+vedi | vedi\s+(questo|qui|qua|l'error\w*|cosa) |
        guarda\s+(qui|qua|questo|questa|un\s+attimo|lo\s+schermo|che) | dai\s+un'?occhiata |
        (questo|quest'|questi|sto|st')\s*(errore|errori|warning|messaggio|avviso|codice|file|grafico|popup|dialogo) |
        (ho|c'è|ci\s+sono|mi\s+(da|dà|esce|escono))\s+(un|uno|degli|dei|questo|questi|sto|un\s+sacco\s+di)?\s*(errore|errori|warning|problemi?) |
        (che|cosa)\s+(significa|vuol\s+dire|è)\s+(questo|questa|qui|sto) | qui\s+(sopra|sotto|davanti) |
        (in|su)\s+(questa|sta)\s+(finestra|pagina|schermata|app) | leggi(mi)?\s+(qui|questo|questa|cosa\s+c'è)
        )\b
        """#

    public static func wants(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static var folder: URL {
        let url = ElioPaths.claudeWorkspace.appendingPathComponent("glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Screenshot of the front window (the whole main screen when Elio itself is in front, e.g. typed in the
    /// dashboard). Nil when capture fails (no Screen Recording permission).
    public static func capture() -> URL? {
        cleanup()
        let file = folder.appendingPathComponent("screen-\(UUID().uuidString.prefix(8)).png")
        var args = ["-x", "-t", "png"]
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if !front.hasPrefix("it.dnafactory.elio"), let id = DesktopTools.frontWindowID() { args += ["-l", "\(id)", "-o"] } else { args += ["-m"] }
        _ = try? shell("/usr/sbin/screencapture", args + [file.path])
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        _ = try? shell("/usr/bin/sips", ["-Z", "1800", file.path])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func discard(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    static func cleanup() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-600)
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < limit {
            try? fm.removeItem(at: f)
        }
    }

    /// What Claude reads with the request.
    static func note(_ file: URL) -> String {
        "\n\n[Screenshot dello schermo dell'utente adesso, preso perché la richiesta parla di ciò che sta guardando: \(file.path) — aprilo con Read prima di rispondere e rispondi su quello che vedi (errori, messaggi, codice). Non descriverlo per intero: vai al punto.]"
    }
}
