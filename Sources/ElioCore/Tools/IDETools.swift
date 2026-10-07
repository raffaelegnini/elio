import Foundation

/// Elio's code editor (in the app), on any project — Elio's own code included — and Elio updating itself.
public enum IDETools {
    /// "comitiva", "aura app", "te stesso" → the project folder.
    static func resolveProject(_ query: String, config: ElioConfig) -> String? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return nil }
        if ["elio", "te stesso", "te", "tuo codice", "il tuo codice", "me stesso", "self"].contains(q) { return ElioPaths.selfSource }
        let repos = ProjectTree.scan(roots: config.projectRoots).flatMap(\.repos)
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: #"[\s_-]+"#, with: "", options: .regularExpression) }
        if let exact = repos.first(where: { norm($0.name) == norm(q) }) { return exact.path }
        return repos.first { norm($0.name).contains(norm(q)) || norm(q).contains(norm($0.name)) }?.path
    }

    static let open = ElioTool(
        name: "open_ide",
        description: """
        Apre l'IDE di Elio (editor di codice con terminali, git e il terminale di ogni agente) su qualunque progetto \
        dell'utente, su un file e una riga. path può essere un percorso o il nome del progetto ("comitiva"); "elio" apre \
        il tuo stesso codice. Usalo quando vuole vedere o toccare il codice ("aprimi comitiva", "fammi vedere il \
        controller del login", "apri il tuo codice").
        """,
        properties: ["path": prop("Percorso (cartella o file) oppure nome del progetto"), "line": prop("Riga (opzionale)", type: "integer")]
    ) { args, ctx in
        var path = expandPath(args["path"] as? String ?? "")
        if !path.isEmpty, !FileManager.default.fileExists(atPath: path) {
            guard let found = resolveProject(args["path"] as? String ?? "", config: ctx.config) else {
                throw ToolError("Progetto non trovato: \(args["path"] as? String ?? "")")
            }
            path = found
        }
        let payload: [String: Any] = ["view": "ide", "path": path, "line": args["line"] as? Int ?? 0]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        ctx.broadcast(ServerMessage(type: .event, kind: "openIDE", payload: String(decoding: data, as: UTF8.self)))
        return "IDE aperto\(path.isEmpty ? "" : " su \((path as NSString).lastPathComponent)")."
    }

    static let selfUpdate = ElioTool(
        name: "self_update",
        description: """
        Ti aggiorni da solo dopo che il tuo codice è stato modificato (da un agente o dall'utente nell'IDE): esegui i test \
        e, solo se passano, ricompili e reinstalli app e demone; la versione precedente resta come backup e torna su se \
        qualcosa va storto. Ci mette qualche minuto e ti riavvia: avvisa prima l'utente. Chiede conferma.
        """,
        properties: ["reason": prop("Cosa è cambiato, in una frase")]
    ) { args, ctx in
        guard let source = ElioPaths.selfSource else { throw ToolError("Non trovo il mio codice sorgente su questo Mac") }
        let script = (source as NSString).appendingPathComponent("scripts/self-update.sh")
        guard FileManager.default.isExecutableFile(atPath: script) else { throw ToolError("Manca scripts/self-update.sh") }
        let reason = args["reason"] as? String ?? "nuove modifiche"
        let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: "Mi aggiorno con \(reason) e mi riavvio",
                                                       detail: "Test, build e reinstallazione da \(source)", risk: .normal, taskId: ctx.taskId))
        guard ok else { return "\(ctx.config.displayName.capitalizedFirst) non ha confermato l'aggiornamento." }
        // Its own launchd job: it keeps going while this daemon is replaced.
        _ = try? shell("/bin/launchctl", ["remove", "it.dnafactory.elio.selfupdate"])
        try shell("/bin/launchctl", ["submit", "-l", "it.dnafactory.elio.selfupdate", "--", "/bin/zsh", script])
        return "Aggiornamento avviato: test, build e reinstallazione. Tra qualche minuto riparto con la nuova versione (log in ~/Library/Logs/Elio/self-update.log)."
    }
}
