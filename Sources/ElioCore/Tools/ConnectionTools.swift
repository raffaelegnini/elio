import Foundation

/// Saved databases and servers (shared with the IDE): Elio saves them from a sentence, opens them in the IDE,
/// reads from databases and runs commands on servers (anything that changes something asks first).
public enum ConnectionTools {
    static let redisReadOnly: Set<String> = ["GET", "MGET", "EXISTS", "TYPE", "TTL", "PTTL", "STRLEN", "HGET", "HGETALL", "HKEYS",
                                             "HLEN", "HMGET", "LRANGE", "LLEN", "SMEMBERS", "SCARD", "ZRANGE", "ZCARD", "ZSCORE",
                                             "SCAN", "DBSIZE", "INFO", "PING", "XLEN", "XRANGE", "SISMEMBER", "GETRANGE"]

    /// SQLite files inside the user's project folders (anything else asks).
    static func sqliteInProjects(_ c: Connection, _ config: ElioConfig) -> Bool {
        let path = ((c.path as NSString).expandingTildeInPath as NSString).standardizingPath
        return config.projectRoots.contains { root in
            let r = ((root as NSString).expandingTildeInPath as NSString).standardizingPath
            return !r.isEmpty && path.hasPrefix(r + "/")
        }
    }

    /// The fields connection_save documents. Not the camelCase spellings Connection.from also reads: "sshVia"
    /// would win over the resolved "ssh_via".
    static let documentedKeys: Set<String> = ["kind", "name", "host", "port", "user", "database", "path", "key_path",
                                              "ssh_via", "remote_dir", "production"]

    /// What a confirmation shows: the real destination (user@host:port/db) and a loud production marker, never only
    /// the name (which the assistant can choose).
    static func confirmTarget(_ c: Connection) -> String {
        "\(c.kindLabel) \(c.destinationLabel)\(c.production ? " · ⚠️ PRODUZIONE" : "")"
    }
    static func confirmName(_ c: Connection) -> String {
        "«\(c.name)»\(c.production ? " (PRODUZIONE)" : "")"
    }

    /// Changes, besides the endpoint, that alter how the user recognises or uses a connection.
    static func settingsChanges(_ old: Connection, _ new: Connection) -> [String] {
        var out: [String] = []
        if old.name != new.name { out.append("Nome: «\(old.name)» → «\(new.name)»") }
        if old.production != new.production { out.append("Produzione: \(old.production ? "sì" : "no") → \(new.production ? "sì" : "no")") }
        if old.remoteDir != new.remoteDir { out.append("Cartella sul server: \(old.remoteDir) → \(new.remoteDir)") }
        if old.localRoot != new.localRoot || old.remoteRoot != new.remoteRoot {
            out.append("Deployment: \(old.localRoot) ↔ \(old.remoteRoot) → \(new.localRoot) ↔ \(new.remoteRoot)")
        }
        if old.forwards != new.forwards { out.append("Port forwarding cambiato") }
        if old.sshConfigAlias != new.sshConfigAlias { out.append("Alias di ~/.ssh/config: \(new.sshConfigAlias ? "sì" : "no")") }
        return out
    }

    static let save = ElioTool(
        name: "connection_save",
        description: """
        Salva (o aggiorna) una connessione nell'IDE di Elio: un server SSH/SFTP o un database (mysql, postgres, sqlite, \
        redis). Usalo quando l'utente dà i dati di accesso ("collegati al server 1.2.3.4 utente deploy", "il DB di staging è…"). \
        La password va direttamente nel Portachiavi e non viene mai riletta: non ripeterla. Per un DB raggiungibile solo dal \
        server metti ssh_via (id o nome dell'host SSH salvato). production=true per i sistemi di produzione (ogni scrittura \
        chiede conferma). Restituisce l'id; poi usa connection_open per aprirla.
        """,
        properties: [
            "kind": prop("ssh | mysql | postgres | sqlite | redis"),
            "name": prop("Nome leggibile (es. \"Staging Comitiva\")"),
            "id": prop("Id di una connessione esistente da aggiornare (opzionale)"),
            "host": prop("Host o IP"), "port": prop("Porta (opzionale)", type: "integer"), "user": prop("Utente"),
            "database": prop("Database (mysql/postgres) o numero db (redis)"), "path": prop("File SQLite"),
            "password": prop("Password (va nel Portachiavi, opzionale)"), "key_path": prop("Chiave privata SSH (opzionale)"),
            "ssh_via": prop("Host SSH per il tunnel (solo database)"), "remote_dir": prop("Cartella iniziale sul server (SSH)"),
            "production": prop("È produzione", type: "boolean"),
        ],
        required: ["kind"]
    ) { args, ctx in
        let list = ConnectionStore.load()
        let kind = Connection.Kind(rawValue: (args["kind"] as? String ?? "").lowercased()) ?? .ssh
        var base: Connection? = nil
        if let id = args["id"] as? String, !id.isEmpty { base = list.first { $0.id == id } }
        if base == nil, let name = args["name"] as? String, !name.isEmpty {
            base = list.first { $0.kind == kind && $0.name.lowercased() == name.lowercased() }
        }
        // Only the documented fields: nothing else (verified, forwards, localRoot, sshConfigAlias…) from the model.
        var a = args.filter { documentedKeys.contains($0.key) }
        a["kind"] = kind.rawValue
        a.removeValue(forKey: "password")
        if let via = args["ssh_via"] as? String, !via.isEmpty {
            guard let ssh = ConnectionStore.find(via, kinds: [.ssh], in: list) else { throw ToolError("Host SSH \"\(via)\" non trovato: salvalo prima") }
            a["ssh_via"] = ssh.id
        }
        var c = Connection.from(a, base: base)
        // SSH with a password and no key: password authentication.
        if c.kind == .ssh, c.keyPath.isEmpty, let pw = args["password"] as? String, !pw.isEmpty { c.auth = .password }
        try c.validate()
        let newPassword = (args["password"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let newPassword { try ConnectionSecrets.validatePassword(newPassword) }
        // Retargeting a saved connection (another host, user, tunnel…) or changing what the user recognises it by
        // (name, production flag, folders) is confirmed by the user; the old password never follows a new destination.
        let endpointChanged = base.map { c.endpointChanged(from: $0) } ?? false
        if let old = base, endpointChanged || !settingsChanges(old, c).isEmpty {
            var lines = settingsChanges(old, c)
            if endpointChanged { lines.insert("Destinazione: \(old.destinationLabel) → \(c.destinationLabel)", at: 0) }
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: "Modifico la connessione \(confirmName(old))",
                                                           detail: (["Ora: " + confirmTarget(old)] + lines).joined(separator: "\n"),
                                                           risk: .dangerous, taskId: ctx.taskId), timeout: 180)
            guard ok else { return "Connessione non modificata: l'utente non ha confermato." }
            if endpointChanged, newPassword == nil { ConnectionSecrets.delete(c.id) }
        }
        // Replacing a stored password is a change of credentials: confirmed too.
        if let old = base, newPassword != nil, !endpointChanged, ConnectionSecrets.has(old.id) {
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: "Cambio la password salvata di \(confirmName(old))",
                                                           detail: confirmTarget(c), risk: .dangerous, taskId: ctx.taskId), timeout: 180)
            guard ok else { return "Password non cambiata: l'utente non ha confermato." }
        }
        // Every new connection proposed by the assistant is confirmed by the user (it could come from injected text).
        if base == nil {
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString, title: "Salvo una nuova connessione \(c.kindLabel) \(confirmName(c))",
                                                           detail: confirmTarget(c), risk: .dangerous, taskId: ctx.taskId), timeout: 180)
            guard ok else { return "Connessione non salvata: l'utente non ha confermato." }
            c.verified = true
        } else if endpointChanged {
            c.verified = true   // confirmed above
        }
        try ConnectionStore.upsert(c)
        if let pw = newPassword { ConnectionSecrets.set(c, pw) }
        return "Connessione salvata: \(c.summary)\(ConnectionSecrets.password(for: c) != nil ? " (password nel Portachiavi)" : "")."
    }

    static let list = ElioTool(
        name: "connection_list",
        description: "Elenca le connessioni salvate nell'IDE (server SSH e database), senza password.",
        properties: ["kind": prop("Filtra per tipo (opzionale)")]
    ) { args, _ in
        let kind = (args["kind"] as? String).flatMap { Connection.Kind(rawValue: $0.lowercased()) }
        let all = ConnectionStore.load().filter { kind == nil || $0.kind == kind }
        return all.isEmpty ? "Nessuna connessione salvata." : all.map(\.summary).joined(separator: "\n")
    }

    static let open = ElioTool(
        name: "connection_open",
        description: """
        Apre una connessione salvata nell'IDE di Elio: what = terminal (terminale SSH), files (sfoglia i file del server), \
        console (console SQL sul database), tables (albero delle tabelle). Usalo per "apri una console sul DB di staging", \
        "fammi vedere le tabelle", "aprimi i file del server".
        """,
        properties: ["connection": prop("Id o nome della connessione"), "what": prop("terminal | files | console | tables")],
        required: ["connection"]
    ) { args, ctx in
        let q = args["connection"] as? String ?? ""
        guard let c = ConnectionStore.find(q) else { throw ToolError("Connessione \"\(q)\" non trovata. Salvala con connection_save.") }
        var what = (args["what"] as? String ?? "").lowercased()
        if what.isEmpty { what = c.kind == .ssh ? "terminal" : "tables" }
        if c.kind == .ssh, !["terminal", "files"].contains(what) { what = "files" }
        if c.kind != .ssh, !["console", "tables"].contains(what) { what = "tables" }
        let data = (try? JSONSerialization.data(withJSONObject: ["id": c.id, "what": what])) ?? Data()
        ctx.broadcast(ServerMessage(type: .event, kind: "ideConnect", payload: String(decoding: data, as: UTF8.self)))
        let label = ["terminal": "terminale SSH", "files": "file del server", "console": "console SQL", "tables": "tabelle"][what] ?? what
        return "Apro \(label) di \(c.name) nell'IDE."
    }

    static let query = ElioTool(
        name: "db_query",
        description: """
        Esegue SQL su un database salvato e restituisce il risultato in testo compatto (max 200 righe). Le letture \
        (SELECT, SHOW, EXPLAIN, DESCRIBE) partono subito in una sessione di sola lettura; qualunque altra istruzione chiede \
        conferma all'utente. Per Redis: un comando per riga.
        """,
        properties: ["connection": prop("Id o nome della connessione"), "sql": prop("Query SQL (o comandi Redis)"),
                     "database": prop("Database diverso da quello salvato (opzionale)")],
        required: ["connection", "sql"]
    ) { args, ctx in
        let q = args["connection"] as? String ?? ""
        guard let c = ConnectionStore.find(q), c.isDatabase else { throw ToolError("Database \"\(q)\" non trovato tra le connessioni salvate.") }
        let sql = args["sql"] as? String ?? ""
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("SQL vuoto") }
        let db = (args["database"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // readOnly: the wording of the question. autonomous: what may run unasked, in a one-statement read-only session.
        let readOnly: Bool, autonomous: Bool
        if c.kind == .redis {
            readOnly = sql.split(whereSeparator: \.isNewline).allSatisfy {
                redisReadOnly.contains($0.split(separator: " ").first.map { $0.uppercased() } ?? "")
            }
            autonomous = readOnly
        } else {
            let dialect: SQLText.Dialect = c.kind == .postgres ? .postgres : c.kind == .sqlite ? .sqlite : .mysql
            readOnly = SQLText.isReadOnly(sql, dialect: dialect)
            autonomous = SQLText.isAutonomousRead(sql, dialect: dialect)
        }
        let trusted = c.verified && (c.kind != .sqlite || sqliteInProjects(c, ctx.config))
        if !autonomous || !trusted {
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString,
                                                           title: "\(readOnly ? "Leggo dal" : "Eseguo una modifica sul") database \(confirmName(c))",
                                                           detail: "\(confirmTarget(c))\n\(sql.prefix(2000))", risk: .dangerous, taskId: ctx.taskId), timeout: 180)
            guard ok else { return "Non eseguita: l'utente non ha confermato." }
        }
        SSHTunnels.shared.closeIdle(600)
        let text = try await Task.detached { () throws -> String in
            let s = try DBConnector.open(c, database: db, readOnly: autonomous)
            defer { s.close() }
            let results = try s.run(sql, maxRows: 200, maxCell: 200, timeout: 50)
            return results.map { r in
                (results.count > 1 ? "> \(r.statement.prefix(120))\n" : "") + r.compactText(maxRows: 200, maxCell: 120)
            }.joined(separator: "\n\n")
        }.value
        return SecretFilter.redact(String(text.prefix(12_000)))
    }

    static let sshRun = ElioTool(
        name: "ssh_run",
        description: """
        Esegue un comando su un server SSH salvato e restituisce l'output. I comandi di sola lettura più comuni (ls, cat, \
        tail, df, du, ps, grep, find senza azioni, git status/log/diff) partono subito; tutto il resto chiede conferma.
        """,
        properties: ["host": prop("Id o nome dell'host SSH salvato"), "command": prop("Comando da eseguire")],
        required: ["host", "command"]
    ) { args, ctx in
        let q = args["host"] as? String ?? ""
        guard let c = ConnectionStore.find(q, kinds: [.ssh]) else { throw ToolError("Host SSH \"\(q)\" non trovato tra le connessioni salvate.") }
        var command = args["command"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError("Comando vuoto") }
        // Unverified hosts: even a "read-only" command line could carry data to someone else's server.
        if !c.verified || !ShellCommandClassifier.isReadOnly(command) {
            let ok = await ctx.gate.request(ConfirmRequest(id: UUID().uuidString,
                                                           title: "Eseguo un comando su \(confirmName(c))",
                                                           detail: "\(confirmTarget(c))\n\(command)", risk: .dangerous, taskId: ctx.taskId), timeout: 180)
            guard ok else { return "Non eseguito: l'utente non ha confermato." }
        }
        if !c.remoteDir.isEmpty { command = "cd \(SSHRunner.quote(c.remoteDir)) 2>/dev/null; " + command }
        let cmd = command
        let out = try await Task.detached { try SSHRunner.run(c, cmd, timeout: 100) }.value
        var text = out.text
        if !out.err.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr] " + out.err }
        if text.count > 10_000 { text = "…" + String(text.suffix(10_000)) }
        return SecretFilter.redact("exit \(out.status)\n" + text)
    }
}
