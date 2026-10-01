import AppKit
import Foundation

public enum MacTools {
    static let openURL = ElioTool(
        name: "open_url",
        description: "Apre un URL nel browser predefinito (o un deep link di un'app).",
        properties: ["url": prop("URL completo")],
        required: ["url"]
    ) { args, _ in
        guard let s = args["url"] as? String, let url = URL(string: s), url.scheme != nil else {
            throw ToolError("URL non valido")
        }
        guard ["http", "https", "slack", "zoommtg", "teams", "vscode", "x-apple.systempreferences"].contains(url.scheme!.lowercased()) else {
            throw ToolError("Schema \(url.scheme!) non consentito")
        }
        NSWorkspace.shared.open(url)
        return "Aperto \(s)"
    }

    static let openApp = ElioTool(
        name: "open_app",
        description: "Apre un'applicazione del Mac per nome (es. Slack, Google Chrome, Visual Studio Code).",
        properties: ["name": prop("Nome dell'app")],
        required: ["name"]
    ) { args, _ in
        let actions = LocalActions()
        guard let name = args["name"] as? String, let url = actions.resolveApp(name.lowercased()) else {
            throw ToolError("App non trovata")
        }
        try await actions.openApp(at: url)
        return "Aperta \(url.deletingPathExtension().lastPathComponent)"
    }
}

public enum ProjectTools {
    /// Git repositories under the configured roots (two levels deep).
    public static func projects(roots: [String]) -> [(name: String, path: String)] {
        var found: [(String, String)] = []
        let fm = FileManager.default
        func scan(_ dir: String, depth: Int) {
            guard depth <= 2, let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for item in items where !item.hasPrefix(".") && item != "node_modules" && item != "vendor" {
                let path = (dir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                    found.append((item, path))
                } else {
                    scan(path, depth: depth + 1)
                }
            }
        }
        roots.map(expandPath).forEach { scan($0, depth: 1) }
        return found.sorted { $0.0.lowercased() < $1.0.lowercased() }
    }

    static let list = ElioTool(
        name: "list_projects",
        description: "Elenca i repository git locali dell'utente con il loro percorso. Usalo per trovare il progetto giusto prima di avviare un task o mostrare un diff."
    ) { _, ctx in
        let items = projects(roots: ctx.config.projectRoots)
        return items.isEmpty ? "Nessun repository trovato." : items.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
    }

    public static func defaultBase(repo: String) -> String {
        for candidate in ["develop", "main", "master"] {
            if (try? shell("/usr/bin/git", ["-C", repo, "rev-parse", "--verify", "--quiet", candidate])) != nil {
                return candidate
            }
        }
        return "HEAD~1"
    }

    public static func diff(repo: String, base: String?, head: String?) throws -> DiffPayload {
        let base = base ?? defaultBase(repo: repo)
        let current = try shell("/usr/bin/git", ["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = head ?? current
        var diff = try shell("/usr/bin/git", ["-C", repo, "diff", "--no-color", "\(base)...\(head)"])
        // Uncommitted work on the current branch counts too.
        let working = (try? shell("/usr/bin/git", ["-C", repo, "diff", "--no-color", "HEAD"])) ?? ""
        if !working.isEmpty { diff += working }
        return DiffPayload(title: "\(head) → \(base)", repo: repo, base: base, head: head, diff: diff)
    }

    static let showDiff = ElioTool(
        name: "show_diff",
        description: "Mostra nell'app il diff di un branch rispetto alla base (develop/main), incluse le modifiche non committate, per la revisione. Restituisce statistiche sui file cambiati.",
        properties: [
            "repo_path": prop("Percorso del repository"),
            "base": prop("Branch base (default: develop, main o master)"),
            "head": prop("Branch da confrontare (default: branch corrente)"),
        ],
        required: ["repo_path"]
    ) { args, ctx in
        let repo = expandPath(args["repo_path"] as? String ?? "")
        let payload = try diff(repo: repo, base: args["base"] as? String, head: args["head"] as? String)
        if payload.diff.isEmpty { return "Nessuna differenza tra \(payload.head) e \(payload.base)." }
        ctx.broadcast(ServerMessage(type: .event, text: "Diff \(payload.title)", kind: "diff", payload: payload.jsonString()))
        let stat = (try? shell("/usr/bin/git", ["-C", repo, "diff", "--shortstat", "\(payload.base)...\(payload.head)"])) ?? ""
        return "Diff mostrato a schermo. \(stat.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public enum ScreenTools {
    static let show = ElioTool(
        name: "show_on_screen",
        description: """
        Apre sul Mac una finestra con una scheda (markdown: tabelle, liste, codice, link) che resta finché l'utente \
        non la chiude, e la salva nell'archivio. Usalo per tutto ciò che è lungo, tabellare o da tenere sott'occhio; \
        a voce dai solo la sintesi. Per un file vero usa save_document.
        """,
        properties: ["title": prop("Titolo breve"), "body": prop("Contenuto in markdown")],
        required: ["title", "body"]
    ) { args, ctx in
        let card = CardPayload(title: args["title"] as? String ?? "", body: args["body"] as? String ?? "")
        let id = await ctx.memory.addCard(title: card.title, body: card.body)
        ctx.broadcast(ServerMessage(type: .event, id: "\(id)", text: card.title, kind: "card", payload: card.jsonString()))
        return "Mostrato a schermo in una finestra (resta aperta) e salvato nell'archivio."
    }
}

public enum ReminderTools {
    static let set = ElioTool(
        name: "set_reminder",
        description: "Programma un promemoria: all'ora indicata Elio lo dice a voce e manda una notifica. Calcola tu l'orario assoluto dal contesto.",
        properties: [
            "text": prop("Cosa ricordare, formulato come lo dirai (es. 'Chiamare Marco')"),
            "at": prop("Quando, ISO8601 con fuso orario"),
        ],
        required: ["text", "at"]
    ) { args, ctx in
        guard let text = args["text"] as? String, let at = (args["at"] as? String).flatMap(parseDate) else {
            throw ToolError("Servono text e at (ISO8601)")
        }
        guard at > Date().addingTimeInterval(-60) else { throw ToolError("L'orario è nel passato") }
        await ctx.scheduler.add(text: text, at: at)
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM 'alle' HH:mm"
        return "Promemoria impostato per \(f.string(from: at))."
    }

    static let list = ElioTool(
        name: "list_reminders",
        description: "Elenca i promemoria futuri."
    ) { _, ctx in
        let items = await ctx.scheduler.upcoming()
        guard !items.isEmpty else { return "Nessun promemoria." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE d MMM HH:mm"
        return items.map { "- \(f.string(from: $0.at)): \($0.text)" }.joined(separator: "\n")
    }
}
