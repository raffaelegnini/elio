import AppKit
import ElioCore
import UniformTypeIdentifiers

/// Database and remote (SSH/SFTP) connections inside the IDE. The page's `connections.js` calls ops
/// prefixed `db.`, `ssh.` or `conn.`; IDEBridge forwards them here. Saved connections live in ElioCore
/// (connections.json + Keychain) so the assistant uses the same ones.
@MainActor
final class IDEConnections {
    static let shared = IDEConnections()
    /// Pushes an event to the IDE page (set by IDEBridge).
    var emit: ((String, Any) -> Void)?

    /// Live client sessions: "connection|database|console".
    private var sessions: [String: DBSession] = [:]
    private var pageReady = false
    private var pendingOpens: [[String: Any]] = []
    private var watchTimer: Timer?
    private var lastStamp: Date?
    private var activeForwards: Set<String> = []

    static func handles(_ op: String) -> Bool {
        op.hasPrefix("db.") || op.hasPrefix("ssh.") || op.hasPrefix("conn.")
    }

    /// The assistant asked to open a connection: delivered now, or when the page says it's ready.
    func open(id: String, what: String) {
        let req: [String: Any] = ["id": id, "what": what]
        if pageReady, let emit { emit("conn.open", req) } else { pendingOpens.append(req) }
    }

    func handle(_ op: String, _ a: [String: Any]) async throws -> Any? {
        func str(_ k: String) -> String { a[k] as? String ?? "" }
        func int(_ k: String, _ d: Int) -> Int { (a[k] as? Int) ?? (a[k] as? String).flatMap { Int($0) } ?? d }
        switch op {
        // MARK: conn.*
        case "conn.ready":
            pageReady = true
            watchFile()
            let pending = pendingOpens
            pendingOpens = []
            return ["connections": listPayload(), "clients": clientsPayload(), "pending": pending]
        case "conn.list":
            return listPayload()
        case "conn.clients":
            return clientsPayload()
        case "conn.save":
            return try saveFromPage(a)
        case "conn.delete":
            let id = str("id")
            closeSessions(id)
            try ConnectionStore.remove(id)
            changed()
            return nil
        case "conn.test":
            var c = Connection.from(a["connection"] as? [String: Any] ?? [:],
                                    base: (a["connection"] as? [String: Any])?["id"].flatMap { id in ConnectionStore.load().first { $0.id == id as? String } })
            let given = (a["password"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if c.name.isEmpty { c.name = "test" }
            let start = Date()
            return try await Task.detached { () throws -> [String: Any] in
                do {
                    if c.kind == .ssh {
                        try c.validate()
                        if c.auth == .password, let given {
                            let out = try Self.withAskpassProbe(c, given)
                            return ["ok": true, "message": out]
                        }
                        let out = try SSHRunner.run(c, "echo ok; uname -sn", timeout: 30)
                        return ["ok": out.status == 0, "message": out.status == 0 ? "Connesso: \(out.text.split(separator: "\n").last ?? "")" : out.err]
                    }
                    let s = try DBConnector.open(c, password: given)
                    defer { s.close() }
                    return ["ok": true, "message": "Connesso\(s.serverVersion.isEmpty ? "" : " · \(s.serverVersion)") · \(Int(Date().timeIntervalSince(start) * 1000)) ms"]
                } catch {
                    return ["ok": false, "message": "\(error)"]
                }
            }.value
        case "conn.sshConfig":
            let saved = Set(ConnectionStore.load().filter { $0.kind == .ssh && $0.sshConfigAlias }.map(\.host))
            return SSHConfigHost.load().map { h -> [String: Any] in
                ["alias": h.alias, "hostName": h.hostName, "user": h.user, "port": h.port ?? NSNull(), "identityFile": h.identityFile,
                 "proxyJump": h.proxyJump, "imported": saved.contains(h.alias)]
            }
        case "conn.importSSH":
            guard let h = SSHConfigHost.load().first(where: { $0.alias == str("alias") }) else { throw ToolError("Host non trovato in ~/.ssh/config") }
            let c = Connection(name: h.alias, kind: .ssh, host: h.alias, user: h.user, sshConfigAlias: true, verified: true)
            try ConnectionStore.upsert(c)
            changed()
            return payload(c)
        case "conn.ddev":
            let path = str("path")
            guard let root = DDEV.projectRoot(path) else { throw ToolError("Nessun progetto DDEV in \(path)") }
            let d = try await Task.detached { try DDEV.describe(root) }.value
            let list = ConnectionStore.load()
            let kind: Connection.Kind = d.type.contains("postgres") ? .postgres : .mysql
            var c = list.first { $0.ddevRoot == d.root || $0.ddevRoot == root }
                ?? Connection(name: "DDEV · \(d.name)", kind: kind, host: "127.0.0.1", user: d.user, database: d.database, color: "green", tag: "ddev", ddevRoot: root)
            c.user = d.user; c.database = d.database; c.host = "127.0.0.1"; c.verified = true
            try ConnectionStore.upsert(c)
            ConnectionSecrets.set(c, d.password)
            changed()
            var out = payload(c)
            out["running"] = d.running
            return out
        case "conn.ddevProbe":
            // Is the current project a DDEV one? (the page shows "Connetti al DB di DDEV")
            return DDEV.projectRoot(str("path")) ?? NSNull()
        case "conn.history":
            return History.load()[str("id")] ?? []
        case "conn.historyAdd":
            History.add(str("id"), str("sql"))
            return nil
        case "conn.export":
            return try export(a)
        case "conn.chooseFiles":
            return chooseFiles(dirs: a["dirs"] as? Bool ?? true)
        case "conn.chooseFolder":
            return chooseFolder(title: str("title"))

        // MARK: db.*
        case "db.connect":
            let c = try connection(str("id"))
            let s = try await session(c, database: a["database"] as? String, console: "tree")
            return ["serverVersion": s.serverVersion, "kind": c.kind.rawValue]
        case "db.disconnect":
            closeSessions(str("id"))
            emit?("db.status", ["id": str("id"), "connected": false])
            return nil
        case "db.tree":
            let c = try connection(str("id"))
            return try await tree(c, level: str("level"), database: str("database"), schema: str("schema"), table: str("table"))
        case "db.query":
            let c = try connection(str("id"))
            let sql = str("sql"), console = str("console").isEmpty ? "console" : str("console")
            let maxRows = min(max(int("maxRows", 1000), 1), 100_000)
            let s = try await session(c, database: a["database"] as? String, console: console)
            let results = try await Task.detached { try s.run(sql, maxRows: maxRows, timeout: 3600) }.value
            if console != "data", console != "tree" { History.add(c.id, sql) }
            return ["results": results.map(\.dictionary), "autocommit": s.autocommit]
        case "db.cancel":
            let key = sessionKey(str("id"), a["database"] as? String, str("console").isEmpty ? "console" : str("console"))
            sessions.first { $0.key == key || $0.key.hasPrefix(str("id") + "|") && $0.key.hasSuffix("|" + str("console")) }?.value.cancel()
            return nil
        case "db.tx":
            let c = try connection(str("id"))
            let s = try await session(c, database: a["database"] as? String, console: str("console").isEmpty ? "console" : str("console"))
            let action = str("action")
            return try await Task.detached { () throws -> [String: Any] in
                switch action {
                case "autocommitOn": try s.setAutocommit(true)
                case "autocommitOff": try s.setAutocommit(false)
                case "commit": let r = try s.commit(true); if let e = r.error { throw ToolError(e) }
                case "rollback": let r = try s.commit(false); if let e = r.error { throw ToolError(e) }
                default: throw ToolError("azione sconosciuta")
                }
                return ["autocommit": s.autocommit]
            }.value
        case "db.ddl":
            let c = try connection(str("id"))
            return try await ddl(c, database: str("database"), schema: str("schema"), table: str("table"))
        case "db.completion":
            let c = try connection(str("id"))
            return try await completion(c, database: str("database"), schema: str("schema"))
        case "db.classify":
            let kind = Connection.Kind(rawValue: str("kind")) ?? .mysql
            let dialect = Self.dialect(kind)
            let sql = str("sql")
            let stmts = SQLText.split(sql, dialect: dialect)
            return ["readOnly": kind == .redis ? false : SQLText.isReadOnly(sql, dialect: dialect),
                    "destructive": stmts.compactMap { SQLText.destructiveReason($0, dialect: dialect) },
                    "count": stmts.count,
                    "ranges": SQLText.ranges(sql, dialect: dialect).map { [$0.start, $0.end] }]
        case "db.data":
            let c = try connection(str("id"))
            let dialect = Self.dialect(c.kind)
            let table = qualified(c, schema: str("schema"), table: str("table"))
            var sql = "SELECT * FROM \(table)"
            let wh = str("where").trimmingCharacters(in: .whitespacesAndNewlines)
            if !wh.isEmpty { sql += " WHERE \(wh)" }
            if !str("orderBy").isEmpty { sql += " ORDER BY \(SQLText.quoteIdent(str("orderBy"), dialect: dialect))\(a["desc"] as? Bool == true ? " DESC" : "")" }
            let limit = min(max(int("limit", 200), 1), 10_000), offset = max(int("offset", 0), 0)
            sql += " LIMIT \(limit + 1)" + (offset > 0 ? " OFFSET \(offset)" : "")
            let s = try await session(c, database: a["database"] as? String, console: "data")
            let r = try await Task.detached { try s.run(sql, maxRows: limit, timeout: 600, addLimit: false) }.value.first
            let pk = try await primaryKey(c, database: str("database"), schema: str("schema"), table: str("table"))
            var out = r?.dictionary ?? [:]
            out["sql"] = sql
            out["primaryKey"] = pk
            return out
        case "db.buildRow":
            let c = try connection(str("id"))
            return buildRow(c, a)

        // MARK: ssh.*
        case "ssh.connect":
            let c = try connection(str("id"))
            try await Task.detached { try SSHRunner.ensureMaster(c) }.value
            emit?("ssh.status", ["id": c.id, "connected": true])
            return ["home": try await home(c)]
        case "ssh.disconnect":
            let c = try connection(str("id"))
            await Task.detached { SSHRunner.closeMaster(c) }.value
            emit?("ssh.status", ["id": c.id, "connected": false])
            return nil
        case "ssh.list":
            let c = try connection(str("id"))
            var path = str("path")
            if path.isEmpty { path = c.remoteDir.isEmpty ? try await home(c) : c.remoteDir }
            let p = path
            let out = try await Task.detached { try SSHRunner.run(c, RemoteFS.listCommand(p), timeout: 60) }.value
            guard out.status == 0 else { throw ToolError(out.err.isEmpty ? "Cartella non leggibile: \(p)" : out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return ["path": p, "entries": RemoteFS.parseListing(out.text).map(\.dictionary)]
        case "ssh.read":
            let c = try connection(str("id"))
            let path = str("path")
            return try await Task.detached { () throws -> [String: Any] in
                let size = try SSHRunner.run(c, "wc -c < \(SSHRunner.quote(path))", timeout: 30)
                let bytes = Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                guard size.status == 0 else { throw ToolError(size.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard bytes < 8_000_000 else { throw ToolError("File troppo grande per l'editor (\(bytes / 1_000_000) MB): scaricalo") }
                let out = try SSHRunner.run(c, "cat \(SSHRunner.quote(path))", timeout: 120)
                guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let mtime = Double(try SSHRunner.run(c, RemoteFS.mtimeCommand(path), timeout: 30).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if out.out.prefix(8000).contains(0) { return ["binary": true, "size": bytes, "mtime": mtime] }
                return ["content": String(decoding: out.out, as: UTF8.self), "size": bytes, "mtime": mtime]
            }.value
        case "ssh.write":
            let c = try connection(str("id"))
            let path = str("path"), content = str("content")
            let expected = (a["mtime"] as? Double) ?? (a["mtime"] as? Int).map(Double.init)
            let force = a["force"] as? Bool ?? false
            return try await Task.detached { () throws -> [String: Any] in
                if let expected, !force {
                    let now = Double(try SSHRunner.run(c, RemoteFS.mtimeCommand(path), timeout: 30).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    if now > 0, abs(now - expected) >= 1 { return ["conflict": true, "remoteMtime": now] }
                }
                // cat > keeps the file's owner and permissions.
                let out = try SSHRunner.run(c, "cat > \(SSHRunner.quote(path))", stdin: Data(content.utf8), timeout: 120)
                guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let mtime = Double(try SSHRunner.run(c, RemoteFS.mtimeCommand(path), timeout: 30).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                return ["mtime": mtime]
            }.value
        case "ssh.mkdir": return try await remote(str("id"), "mkdir -p -- \(SSHRunner.quote(str("path")))")
        case "ssh.touch": return try await remote(str("id"), "touch -- \(SSHRunner.quote(str("path")))")
        case "ssh.rename": return try await remote(str("id"), "mv -- \(SSHRunner.quote(str("from"))) \(SSHRunner.quote(str("to")))")
        case "ssh.delete":
            let p = str("path")
            guard p.count > 1, p != "/", p != "~" else { throw ToolError("Percorso non eliminabile") }
            return try await remote(str("id"), "rm -rf -- \(SSHRunner.quote(p))")
        case "ssh.chmod":
            let mode = str("mode")
            guard mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil else { throw ToolError("Permessi non validi (es. 644)") }
            return try await remote(str("id"), "chmod \(mode) -- \(SSHRunner.quote(str("path")))")
        case "ssh.download":
            let c = try connection(str("id"))
            guard let dir = chooseFolder(title: "Scarica in…") else { return NSNull() }
            let path = str("path")
            let out = try await Task.detached { try SSHRunner.scp(c, ["-r", SSHRunner.remoteSpec(c, path), dir]) }.value
            guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let saved = (dir as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved)])
            return saved
        case "ssh.upload":
            let c = try connection(str("id"))
            let paths = (a["paths"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? chooseFiles(dirs: true)
            guard !paths.isEmpty else { return 0 }
            let dir = str("dir")
            let out = try await Task.detached { try SSHRunner.scp(c, ["-r"] + paths + [SSHRunner.remoteSpec(c, dir.hasSuffix("/") ? dir : dir + "/")]) }.value
            guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return paths.count
        case "ssh.uploadLocal":
            // Deployment: the active file goes to the mapped folder on the server.
            let local = (str("path") as NSString).standardizingPath
            let hosts = ConnectionStore.load().filter { $0.kind == .ssh && !$0.localRoot.isEmpty && !$0.remoteRoot.isEmpty
                && local.hasPrefix(($0.localRoot as NSString).standardizingPath + "/") }
            guard let c = hosts.first(where: { $0.id == str("id") }) ?? hosts.max(by: { $0.localRoot.count < $1.localRoot.count }) else {
                throw ToolError("Nessun server ha una mappatura per questa cartella: impostala nella connessione SSH (Deployment)")
            }
            let rel = String(local.dropFirst((c.localRoot as NSString).standardizingPath.count + 1))
            let remotePath = (c.remoteRoot as NSString).appendingPathComponent(rel)
            let remoteDir = (remotePath as NSString).deletingLastPathComponent
            try await Task.detached {
                _ = try SSHRunner.run(c, "mkdir -p -- \(SSHRunner.quote(remoteDir))", timeout: 30)
                let out = try SSHRunner.scp(c, [local, SSHRunner.remoteSpec(c, remotePath)])
                guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }.value
            return ["id": c.id, "name": c.name, "remotePath": remotePath]
        case "ssh.terminal":
            let c = try connection(str("id"))
            // Password hosts: the shared connection is opened here, so the terminal reuses it without asking.
            if c.auth == .password { try await Task.detached { try SSHRunner.ensureMaster(c) }.value }
            let dir = (a["dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ["command": try SSHRunner.terminalArgs(c, dir: dir), "title": "SSH · \(c.name)"]
        case "ssh.forwards":
            let c = try connection(str("id"))
            return c.forwards.enumerated().map { i, f in
                ["index": i, "localPort": f.localPort, "remoteHost": f.remoteHost, "remotePort": f.remotePort,
                 "active": SSHTunnels.shared.isOpen(ssh: c, remoteHost: f.remoteHost, remotePort: f.remotePort, localPort: f.localPort)]
            }
        case "ssh.forward":
            let c = try connection(str("id"))
            let i = int("index", -1)
            guard c.forwards.indices.contains(i) else { throw ToolError("Inoltro non trovato") }
            let f = c.forwards[i]
            if a["start"] as? Bool ?? true {
                _ = try await Task.detached { try SSHTunnels.shared.open(ssh: c, remoteHost: f.remoteHost, remotePort: f.remotePort, localPort: f.localPort) }.value
            } else {
                SSHTunnels.shared.close(ssh: c, remoteHost: f.remoteHost, remotePort: f.remotePort, localPort: f.localPort)
            }
            return nil
        default:
            throw ToolError("operazione sconosciuta: \(op)")
        }
    }

    // MARK: Connections

    private func connection(_ id: String) throws -> Connection {
        guard let c = ConnectionStore.load().first(where: { $0.id == id }) else { throw ToolError("Connessione non trovata") }
        return c
    }

    private func payload(_ c: Connection) -> [String: Any] {
        var d = c.dictionary
        d["hasPassword"] = ConnectionSecrets.password(for: c) != nil
        d["connected"] = sessions.keys.contains { $0.hasPrefix(c.id + "|") && sessions[$0]?.isAlive == true }
        d["destination"] = c.destinationLabel
        return d
    }

    private func listPayload() -> [[String: Any]] {
        ConnectionStore.load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(payload)
    }

    private func clientsPayload() -> [String: Any] {
        var out: [String: Any] = [:]
        for k in Connection.Kind.allCases where k != .ssh {
            out[k.rawValue] = ["path": nv(DBClients.client(for: k)), "install": DBClients.brewHint(for: k)]
        }
        out["ddev"] = nv(DDEV.binary)
        return out
    }

    /// The form in the IDE: the password arrives once and goes straight to the Keychain.
    private func saveFromPage(_ a: [String: Any]) throws -> [String: Any] {
        let fields = a["connection"] as? [String: Any] ?? [:]
        let old = (fields["id"] as? String).flatMap { id in ConnectionStore.load().first { $0.id == id } }
        var c = Connection.from(fields, base: old)
        c.verified = true   // the user typed it
        try c.validate()
        let password = (a["password"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let password { try ConnectionSecrets.validatePassword(password) }
        // A connection pointed elsewhere doesn't keep the old password (unless typed again).
        if let old, c.endpointChanged(from: old), password == nil { ConnectionSecrets.delete(c.id) }
        try ConnectionStore.upsert(c)
        if a["clearPassword"] as? Bool == true { ConnectionSecrets.delete(c.id) }
        if let password { ConnectionSecrets.set(c, password) }
        if let old, c.endpointChanged(from: old) { closeSessions(c.id) }
        changed()
        return payload(c)
    }

    private func changed() {
        lastStamp = Self.stamp()
        emit?("conn.changed", listPayload())
    }

    /// The assistant saves connections from the daemon: the page follows connections.json.
    private func watchFile() {
        guard watchTimer == nil else { return }
        lastStamp = Self.stamp()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let s = Self.stamp()
                if s != IDEConnections.shared.lastStamp {
                    IDEConnections.shared.lastStamp = s
                    IDEConnections.shared.emit?("conn.changed", IDEConnections.shared.listPayload())
                }
            }
        }
    }

    private static func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ConnectionStore.url.path))?[.modificationDate] as? Date
    }

    nonisolated private static func withAskpassProbe(_ c: Connection, _ password: String) throws -> String {
        try SSHRunner.ensureMaster(c, password: password)
        let out = try SSHRunner.run(c, "uname -sn", timeout: 30)
        return "Connesso: \(out.text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    // MARK: Database sessions

    private func sessionKey(_ id: String, _ database: String?, _ console: String) -> String { "\(id)|\(database ?? "")|\(console)" }

    private func session(_ c: Connection, database: String?, console: String) async throws -> DBSession {
        let key = sessionKey(c.id, database, console)
        if let s = sessions[key], s.isAlive { return s }
        sessions[key] = nil
        let s = try await Task.detached { try DBConnector.open(c, database: database) }.value
        sessions[key] = s
        emit?("db.status", ["id": c.id, "connected": true])
        return s
    }

    private func closeSessions(_ id: String) {
        for (k, s) in sessions where k.hasPrefix(id + "|") { s.close(); sessions[k] = nil }
        if let c = try? connection(id), !c.sshVia.isEmpty, let ssh = ConnectionStore.byId(c.sshVia, kinds: [.ssh]) {
            SSHTunnels.shared.close(ssh: ssh, remoteHost: c.host.isEmpty ? "127.0.0.1" : c.host, remotePort: c.effectivePort)
        }
    }

    static func dialect(_ k: Connection.Kind) -> SQLText.Dialect {
        k == .postgres ? .postgres : k == .sqlite ? .sqlite : .mysql
    }

    private func lit(_ v: String, _ c: Connection) -> String { SQLText.quoteLiteral(v, dialect: Self.dialect(c.kind)) }
    private func ident(_ v: String, _ c: Connection) -> String { SQLText.quoteIdent(v, dialect: Self.dialect(c.kind)) }

    private func qualified(_ c: Connection, schema: String, table: String) -> String {
        switch c.kind {
        case .postgres: (schema.isEmpty ? "" : ident(schema, c) + ".") + ident(table, c)
        case .mysql: (schema.isEmpty ? "" : ident(schema, c) + ".") + ident(table, c)
        default: ident(table, c)
        }
    }

    /// Runs internal schema queries on the connection's "tree" session.
    private func meta(_ c: Connection, database: String?, _ sql: String) async throws -> QueryResult {
        let s = try await session(c, database: database, console: "tree")
        let r = try await Task.detached { try s.run(sql, maxRows: 20_000, maxCell: 100_000, timeout: 120, addLimit: false) }.value.last
        if let e = r?.error { throw ToolError(e) }
        return r ?? QueryResult(statement: sql)
    }

    /// Lazy schema tree. Levels: databases → (schemas, postgres) → objects → table details.
    private func tree(_ c: Connection, level: String, database: String, schema: String, table: String) async throws -> Any {
        switch (c.kind, level) {
        case (.mysql, "databases"):
            return try await meta(c, database: nil, "SHOW DATABASES").rows.compactMap { $0.first ?? nil }.map { ["name": $0] }
        case (.postgres, "databases"):
            return try await meta(c, database: nil, "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1")
                .rows.compactMap { $0.first ?? nil }.map { ["name": $0] }
        case (.sqlite, "databases"):
            return [["name": "main"]]
        case (.postgres, "schemas"):
            return try await meta(c, database: database, """
                SELECT schema_name FROM information_schema.schemata
                WHERE schema_name NOT LIKE 'pg\\_%' AND schema_name <> 'information_schema' ORDER BY 1
                """.replacingOccurrences(of: "\\\\", with: "\\")).rows.compactMap { $0.first ?? nil }.map { ["name": $0] }
        case (.mysql, "objects"):
            let t = try await meta(c, database: nil, """
                SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, ENGINE FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = \(lit(database, c)) ORDER BY TABLE_NAME
                """)
            let r = try await meta(c, database: nil, """
                SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(lit(database, c)) ORDER BY 1
                """)
            return t.rows.map { ["name": $0[0] ?? "", "type": ($0[1] ?? "").contains("VIEW") ? "view" : "table", "rows": nv($0[2]), "engine": $0[3] ?? ""] }
                + r.rows.map { ["name": $0[0] ?? "", "type": ($0[1] ?? "").lowercased()] }
        case (.postgres, "objects"):
            let t = try await meta(c, database: database, """
                SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = \(lit(schema, c)) ORDER BY 1
                """)
            let r = try await meta(c, database: database, """
                SELECT routine_name, lower(routine_type) FROM information_schema.routines WHERE routine_schema = \(lit(schema, c)) ORDER BY 1
                """)
            return t.rows.map { ["name": $0[0] ?? "", "type": ($0[1] ?? "").contains("VIEW") ? "view" : "table"] }
                + r.rows.map { ["name": $0[0] ?? "", "type": $0[1] ?? "function"] }
        case (.sqlite, "objects"):
            return try await meta(c, database: nil, """
                SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name
                """).rows.map { ["name": $0[0] ?? "", "type": $0[1] ?? "table"] }
        case (_, "table"):
            return try await tableDetails(c, database: database, schema: schema, table: table)
        case (.redis, "keys"):
            let pattern = schema.isEmpty ? "*" : schema
            var cursor = "0", keys: [String] = []
            let s = try await session(c, database: nil, console: "tree")
            repeat {
                let cmd = "SCAN \(cursor) MATCH \(Self.redisQuote(pattern)) COUNT 1000"
                let text = try await Task.detached { try s.run(cmd, timeout: 60) }.value.first?.text ?? ""
                let parsed = Self.redisList(text)
                cursor = parsed.first ?? "0"
                keys += parsed.dropFirst()
            } while cursor != "0" && keys.count < 2000
            return keys.sorted().prefix(2000).map { ["name": $0] }
        case (.redis, "key"):
            let s = try await session(c, database: nil, console: "tree")
            let q = Self.redisQuote(table)
            let type = try await Task.detached { try s.run("TYPE \(q)", timeout: 30) }.value.first?.text ?? ""
            let t = type.trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = switch t {
            case "string": "GET \(q)"
            case "hash": "HGETALL \(q)"
            case "list": "LRANGE \(q) 0 499"
            case "set": "SSCAN \(q) 0 COUNT 500"
            case "zset": "ZRANGE \(q) 0 499 WITHSCORES"
            case "stream": "XRANGE \(q) - + COUNT 100"
            default: "TYPE \(q)"
            }
            let value = try await Task.detached { try s.run("\(cmd)\nTTL \(q)", timeout: 30) }.value
            return ["type": t, "value": value.first?.text ?? "", "ttl": value.last?.text ?? ""]
        default:
            return []
        }
    }

    private func tableDetails(_ c: Connection, database: String, schema: String, table: String) async throws -> [String: Any] {
        var columns: [[String: Any]] = [], indexes: [[String: Any]] = [], fks: [[String: Any]] = []
        switch c.kind {
        case .mysql:
            let w = "TABLE_SCHEMA = \(lit(database, c)) AND TABLE_NAME = \(lit(table, c))"
            columns = try await meta(c, database: nil, """
                SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA FROM information_schema.COLUMNS
                WHERE \(w) ORDER BY ORDINAL_POSITION
                """).rows.map { ["name": $0[0] ?? "", "type": $0[1] ?? "", "nullable": $0[2] == "YES", "key": $0[3] ?? "",
                                 "default": nv($0[4]), "extra": $0[5] ?? ""] }
            indexes = try await meta(c, database: nil, """
                SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS
                WHERE \(w) GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME
                """).rows.map { ["name": $0[0] ?? "", "unique": $0[1] == "0", "columns": $0[2] ?? ""] }
            fks = try await meta(c, database: nil, """
                SELECT CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
                WHERE \(w) AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME
                """).rows.map { ["name": $0[0] ?? "", "column": $0[1] ?? "", "refTable": $0[2] ?? "", "refColumn": $0[3] ?? ""] }
        case .postgres:
            let qt = lit(qualified(c, schema: schema, table: table), c)
            columns = try await meta(c, database: database, """
                SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
                  CASE WHEN EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY(i.indkey)) THEN 'PRI' ELSE '' END,
                  pg_get_expr(d.adbin, d.adrelid)
                FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                WHERE a.attrelid = \(qt)::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
                """).rows.map { ["name": $0[0] ?? "", "type": $0[1] ?? "", "nullable": $0[2] == "t", "key": $0[3] ?? "", "default": nv($0[4])] }
            indexes = try await meta(c, database: database, """
                SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = \(lit(schema, c)) AND tablename = \(lit(table, c)) ORDER BY 1
                """).rows.map { ["name": $0[0] ?? "", "unique": ($0[1] ?? "").contains("UNIQUE"), "columns": $0[1] ?? ""] }
            fks = try await meta(c, database: database, """
                SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE contype = 'f' AND conrelid = \(qt)::regclass ORDER BY 1
                """).rows.map { ["name": $0[0] ?? "", "column": $0[1] ?? "", "refTable": "", "refColumn": ""] }
        case .sqlite:
            let t = lit(table, c)
            columns = try await meta(c, database: nil, "SELECT name, type, \"notnull\", pk, dflt_value FROM pragma_table_info(\(t))")
                .rows.map { ["name": $0[0] ?? "", "type": $0[1] ?? "", "nullable": $0[2] == "0", "key": ($0[3] ?? "0") != "0" ? "PRI" : "", "default": nv($0[4])] }
            indexes = try await meta(c, database: nil, """
                SELECT il.name, il."unique", (SELECT group_concat(name, ',') FROM pragma_index_info(il.name)) FROM pragma_index_list(\(t)) il
                """).rows.map { ["name": $0[0] ?? "", "unique": $0[1] == "1", "columns": $0[2] ?? ""] }
            fks = try await meta(c, database: nil, "SELECT id, \"from\", \"table\", \"to\" FROM pragma_foreign_key_list(\(t))")
                .rows.map { ["name": "fk_\($0[0] ?? "")", "column": $0[1] ?? "", "refTable": $0[2] ?? "", "refColumn": $0[3] ?? ""] }
        default: break
        }
        return ["columns": columns, "indexes": indexes, "foreignKeys": fks]
    }

    private func primaryKey(_ c: Connection, database: String, schema: String, table: String) async throws -> [String] {
        let d = try await tableDetails(c, database: database, schema: schema, table: table)
        return (d["columns"] as? [[String: Any]] ?? []).filter { ($0["key"] as? String) == "PRI" }.compactMap { $0["name"] as? String }
    }

    private func ddl(_ c: Connection, database: String, schema: String, table: String) async throws -> Any {
        switch c.kind {
        case .mysql:
            let r = try await meta(c, database: nil, "SHOW CREATE TABLE \(ident(database, c)).\(ident(table, c))")
            return (r.rows.first?.dropFirst().first ?? nil) ?? ""
        case .sqlite:
            return (try await meta(c, database: nil, "SELECT sql FROM sqlite_master WHERE name = \(lit(table, c))").rows.first?.first ?? nil) ?? ""
        case .postgres:
            // Columns and constraints, close to pg_dump -s for one table (no extra password prompt needed).
            let qt = lit(qualified(c, schema: schema, table: table), c)
            let cols = try await meta(c, database: database, """
                SELECT '  ' || quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod)
                  || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
                  || COALESCE(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), '')
                FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                WHERE a.attrelid = \(qt)::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
                """).rows.compactMap { $0.first ?? nil }
            let cons = try await meta(c, database: database, """
                SELECT '  CONSTRAINT ' || quote_ident(conname) || ' ' || pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = \(qt)::regclass ORDER BY contype DESC, conname
                """).rows.compactMap { $0.first ?? nil }
            let idx = try await meta(c, database: database, """
                SELECT indexdef || ';' FROM pg_indexes WHERE schemaname = \(lit(schema, c)) AND tablename = \(lit(table, c))
                  AND indexname NOT IN (SELECT conname FROM pg_constraint WHERE conrelid = \(qt)::regclass)
                """).rows.compactMap { $0.first ?? nil }
            return "CREATE TABLE \(qualified(c, schema: schema, table: table)) (\n" + (cols + cons).joined(separator: ",\n") + "\n);\n" + idx.joined(separator: "\n")
        default:
            return ""
        }
    }

    /// Tables and their columns for the SQL console's autocomplete.
    private func completion(_ c: Connection, database: String, schema: String) async throws -> [String: [String]] {
        let r: QueryResult
        switch c.kind {
        case .mysql:
            guard !database.isEmpty else { return [:] }
            r = try await meta(c, database: nil, "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(lit(database, c)) ORDER BY TABLE_NAME, ORDINAL_POSITION")
        case .postgres:
            r = try await meta(c, database: database.isEmpty ? nil : database, """
                SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = \(lit(schema.isEmpty ? "public" : schema, c)) ORDER BY table_name, ordinal_position
                """)
        case .sqlite:
            r = try await meta(c, database: nil, """
                SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type IN ('table','view') ORDER BY m.name, p.cid
                """)
        default: return [:]
        }
        var out: [String: [String]] = [:]
        for row in r.rows { if let t = row[0], let col = row[1] { out[t, default: []].append(col) } }
        return out
    }

    /// UPDATE / INSERT / DELETE for the data view, by primary key (the page shows it before running it).
    private func buildRow(_ c: Connection, _ a: [String: Any]) -> [String: Any] {
        let table = qualified(c, schema: a["schema"] as? String ?? (c.kind == .mysql ? a["database"] as? String ?? "" : ""), table: a["table"] as? String ?? "")
        func value(_ v: Any?) -> String {
            if v == nil || v is NSNull { return "NULL" }
            return lit((v as? String) ?? "\(v!)", c)
        }
        let key = a["key"] as? [String: Any] ?? [:]
        let whereSQL = key.keys.sorted().map { k in
            key[k] is NSNull ? "\(ident(k, c)) IS NULL" : "\(ident(k, c)) = \(value(key[k]))"
        }.joined(separator: " AND ")
        let values = a["values"] as? [String: Any] ?? [:]
        let cols = values.keys.sorted()
        switch a["op"] as? String {
        case "update":
            guard !whereSQL.isEmpty, !cols.isEmpty else { return ["sql": "", "error": "Serve una chiave primaria per modificare le righe"] }
            return ["sql": "UPDATE \(table) SET " + cols.map { "\(ident($0, c)) = \(value(values[$0]))" }.joined(separator: ", ") + " WHERE \(whereSQL);"]
        case "insert":
            return ["sql": cols.isEmpty ? "INSERT INTO \(table) DEFAULT VALUES;"
                    : "INSERT INTO \(table) (" + cols.map { ident($0, c) }.joined(separator: ", ") + ") VALUES (" + cols.map { value(values[$0]) }.joined(separator: ", ") + ");"]
        case "delete":
            guard !whereSQL.isEmpty else { return ["sql": "", "error": "Serve una chiave primaria per eliminare le righe"] }
            return ["sql": "DELETE FROM \(table) WHERE \(whereSQL);"]
        default:
            return ["sql": "", "error": "operazione sconosciuta"]
        }
    }

    /// SQL NULL → JSON null.
    private func nv(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }

    static func redisQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Strings of a redis-cli --no-raw reply ("1) \"a\"", nested lists flattened).
    static func redisList(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            guard let q = line.firstIndex(of: "\""), line.hasSuffix("\"") else { continue }
            let inner = line[line.index(after: q)..<line.index(before: line.endIndex)]
            out.append(inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
        }
        return out
    }

    // MARK: Remote

    private var homes: [String: String] = [:]

    private func home(_ c: Connection) async throws -> String {
        if let h = homes[c.id] { return h }
        let out = try await Task.detached { try SSHRunner.run(c, "pwd", timeout: 30) }.value
        guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let h = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        homes[c.id] = h
        return h
    }

    private func remote(_ id: String, _ command: String) async throws -> Any? {
        let c = try connection(id)
        let out = try await Task.detached { try SSHRunner.run(c, command, timeout: 120) }.value
        guard out.status == 0 else { throw ToolError(out.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Comando non riuscito" : out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    // MARK: Panels and export

    private func chooseFolder(title: String) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = title
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return p.runModal() == .OK ? p.url?.path : nil
    }

    private func chooseFiles(dirs: Bool) -> [String] {
        let p = NSOpenPanel()
        p.canChooseDirectories = dirs
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.message = "Scegli cosa caricare sul server"
        return p.runModal() == .OK ? p.urls.map(\.path) : []
    }

    private func export(_ a: [String: Any]) throws -> Any? {
        let format = (a["format"] as? String) == "json" ? "json" : "csv"
        let columns = a["columns"] as? [String] ?? []
        let rows = a["rows"] as? [[Any]] ?? []
        let p = NSSavePanel()
        p.nameFieldStringValue = ((a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "risultato") + "." + format
        p.allowedContentTypes = [format == "json" ? .json : .commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return NSNull() }
        let data: Data
        if format == "json" {
            let objects = rows.map { row in Dictionary(uniqueKeysWithValues: zip(columns, row.map { $0 is NSNull ? NSNull() : $0 })) }
            data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        } else {
            var text = columns.map(CSVText.field).joined(separator: ",") + "\n"
            for row in rows { text += row.map { CSVText.field($0 is NSNull ? nil : "\($0)") }.joined(separator: ",") + "\n" }
            data = Data(text.utf8)
        }
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// Query history per connection (last 200).
    enum History {
        static var url: URL { ElioPaths.support.appendingPathComponent("sql-history.json") }
        static func load() -> [String: [[String: Any]]] {
            guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else { return [:] }
            return obj
        }
        static func add(_ id: String, _ sql: String) {
            let s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !s.isEmpty else { return }
            var all = load()
            var list = all[id] ?? []
            list.removeAll { ($0["sql"] as? String) == s }
            list.insert(["sql": s, "at": Date().timeIntervalSince1970], at: 0)
            all[id] = Array(list.prefix(200))
            if let data = try? JSONSerialization.data(withJSONObject: all) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
}
