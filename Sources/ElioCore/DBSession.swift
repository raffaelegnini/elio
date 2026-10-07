import Darwin
import Foundation

/// One statement's outcome.
public struct QueryResult: Sendable {
    public var statement: String
    public var columns: [String] = []
    public var rows: [[String?]] = []
    public var hasResultSet = false
    public var affected: Int?
    public var error: String?
    /// Notices / warnings, or the whole reply for Redis.
    public var text: String?
    public var truncated = false
    public var ms = 0

    public init(statement: String) { self.statement = statement }

    /// For the IDE page (NULL → JSON null).
    public var dictionary: [String: Any] {
        var d: [String: Any] = ["statement": statement, "columns": columns, "hasResultSet": hasResultSet, "truncated": truncated,
                                "ms": ms, "rowCount": rows.count]
        d["rows"] = rows.map { $0.map { $0 as Any? ?? NSNull() } }
        d["affected"] = affected ?? NSNull()
        d["error"] = error ?? NSNull()
        d["text"] = text ?? NSNull()
        return d
    }

    /// Compact text for the assistant: aligned-ish rows, capped in rows and width.
    public func compactText(maxRows: Int = 50, maxCell: Int = 80) -> String {
        if let error { return "Errore: \(error)" }
        if let text, !hasResultSet { return text }
        guard hasResultSet else { return affected.map { "OK, \($0) righe interessate." } ?? "OK." }
        if rows.isEmpty { return columns.isEmpty ? "Nessuna riga." : "Nessuna riga (colonne: \(columns.joined(separator: ", ")))." }
        func cell(_ v: String?) -> String {
            guard var s = v else { return "NULL" }
            s = s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
            return s.count > maxCell ? String(s.prefix(maxCell)) + "…" : s
        }
        var lines = [columns.joined(separator: " | ")]
        for row in rows.prefix(maxRows) { lines.append(row.map(cell).joined(separator: " | ")) }
        let more = rows.count > maxRows || truncated
        lines.append("(\(rows.count)\(truncated ? "+" : "") righe\(more ? ", mostrate \(min(rows.count, maxRows))" : ""))")
        return lines.joined(separator: "\n")
    }
}

/// A live command-line client (mysql, psql, sqlite3, redis-cli) kept open: statements go in through stdin,
/// each followed by a marker, and the output up to the marker is that statement's result. One process per
/// console keeps session state (USE, variables, temporary tables, open transactions). Passwords reach the
/// client through 0600 temp files deleted right after the handshake, never argv or the environment.
public final class DBSession: @unchecked Sendable {
    public let connection: Connection
    public let database: String
    public let readOnly: Bool
    public private(set) var serverVersion = ""
    public private(set) var autocommit = true

    private let endpoint: (host: String, port: Int)?
    private var process: Process?
    private var input: FileHandle?
    private var outFD: Int32 = -1
    private var errFD: Int32 = -1
    private var pending = Data()
    private let runLock = NSLock()
    private let stateLock = NSLock()
    private var cancelled = false
    private var credDir: URL?
    private let nonce = String(UUID().uuidString.prefix(8))
    private var counter = 0
    static let nullToken = "\u{1}ELIONULL\u{1}"

    /// `endpoint` replaces host/port (an SSH tunnel's local end).
    public init(connection: Connection, database: String? = nil, readOnly: Bool = false, endpoint: (host: String, port: Int)? = nil) {
        self.connection = connection
        self.database = database ?? connection.database
        self.readOnly = readOnly
        self.endpoint = endpoint
    }

    deinit { close() }

    public var isAlive: Bool { stateLock.withLock { process?.isRunning ?? false } }

    var dialect: SQLText.Dialect {
        switch connection.kind {
        case .postgres: .postgres
        case .sqlite: .sqlite
        default: .mysql
        }
    }

    // MARK: Lifecycle

    /// Starts the client and checks the connection (throws the client's own error, e.g. access denied).
    public func start(password: String?) throws {
        guard let bin = DBClients.client(for: connection.kind) else { throw DBClients.missing(connection.kind) }
        try connection.validate()
        guard Connection.isValidDatabaseName(database, kind: connection.kind) else { throw ToolError("Nome del database non valido") }
        let host = endpoint?.host ?? connection.host
        let port = endpoint?.port ?? connection.port
        // Checked here too, not only on save: these go into option files and argv (a newline would add options).
        guard Connection.isValidUser(connection.user), host.isEmpty || Connection.isValidHost(host) else {
            throw ToolError("Utente o host della connessione non validi")
        }
        var args: [String] = []
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        defer { removeCredentials() }

        switch connection.kind {
        case .mysql:
            // local-infile=0: a rogue server can't make the client upload files from this Mac (LOAD DATA LOCAL).
            var cnf = "[client]\nlocal-infile=0\n"
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            if !connection.user.isEmpty { cnf += "user=\(q(connection.user))\n" }
            if let password, !password.isEmpty {
                // A newline would start a new option line (init-command, plugin-dir…).
                guard !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ToolError("La password contiene caratteri di controllo non supportati da mysql")
                }
                cnf += "password=\(q(password))\n"
            }
            if !host.isEmpty { cnf += "host=\(q(host))\nprotocol=TCP\n" }
            if let port { cnf += "port=\(port)\n" }
            let file = try writeCredential("my.cnf", cnf)
            // --binary-mode: the client's own commands (system, source, \!) are off for piped input.
            // --force (go on after an error) only for consoles: a read-only session stops at the first error, so
            // nothing after a statement the server rejected can ever run.
            args = ["--defaults-extra-file=\(file)", "--xml", "--unbuffered"] + (readOnly ? [] : ["--force"])
                + ["--binary-mode", "--no-auto-rehash", "--default-character-set=utf8mb4", "--connect-timeout=10", "--local-infile=0"]
            if !database.isEmpty { args.append("--database=\(database)") }
        case .postgres:
            let user = connection.user.isEmpty ? NSUserName() : connection.user
            let db = database.isEmpty ? "postgres" : database
            if let password, !password.isEmpty {
                // Scoped to this exact endpoint: never a wildcard line another host could match.
                func e(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:") }
                let line = [host.isEmpty ? "localhost" : host, "\(port ?? 5432)", db, user, password].map(e).joined(separator: ":")
                env["PGPASSFILE"] = try writeCredential("pgpass", line + "\n")
            }
            env["PGCONNECT_TIMEOUT"] = "10"
            env["PGAPPNAME"] = "Elio"
            env["PGCLIENTENCODING"] = "UTF8"
            // Backslashes are never escapes in plain literals, whatever the server's default.
            env["PGOPTIONS"] = "-c standard_conforming_strings=on" + (readOnly ? " -c default_transaction_read_only=on" : "")
            // One conninfo built here (values quoted per libpq): a database name can't smuggle host= or a URI.
            args = ["-X", "-q", "-w", "--csv", "-P", "null=\(Self.nullToken)", "-v", "ON_ERROR_STOP=0",
                    "-d", PGConnInfo.build(host: host, port: port, user: user, dbname: db)]
        case .sqlite:
            let path = (connection.path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) || !readOnly else { throw ToolError("File SQLite non trovato: \(path)") }
            // -safe: no .shell/.system/.output/.import and no file functions.
            args = ["-batch", "-safe"] + (readOnly ? ["-readonly"] : []) + [path]
        case .redis:
            args = ["--no-raw"]
            if !host.isEmpty { args += ["-h", host] }
            if let port { args += ["-p", "\(port)"] }
            if let n = Int(database) { args += ["-n", "\(n)"] }
            // Credentials out of the command stream: a newline in a password can't smuggle commands.
            if let password, !password.isEmpty {
                guard !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ToolError("La password Redis contiene caratteri di controllo")
                }
                env["REDISCLI_AUTH"] = password
                args.append("--no-auth-warning")
            }
            if !connection.user.isEmpty { args += ["--user", connection.user] }
        case .ssh:
            throw ToolError("Non è un database")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        stateLock.withLock {
            process = p
            input = inPipe.fileHandleForWriting
            outFD = outPipe.fileHandleForReading.fileDescriptor
            errFD = errPipe.fileHandleForReading.fileDescriptor
            // Keep the pipes alive with the process.
            pipes = [inPipe, outPipe, errPipe]
        }
        _ = fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL) | O_NONBLOCK)
        signal(SIGPIPE, SIG_IGN)

        // Session setup + handshake: the client has read its credentials once this answers.
        var setup: [String] = []
        switch connection.kind {
        case .mysql:
            if readOnly { setup.append("SET SESSION TRANSACTION READ ONLY") }
            setup.append("SELECT VERSION()")
        case .postgres: setup.append("SHOW server_version")
        case .sqlite:
            write(".mode quote\n.headers on\n")
            setup.append("SELECT sqlite_version()")
        case .redis:
            setup.append("PING")
        default: break
        }
        let results = try runStatements(setup, maxRows: 5, maxCell: 200, timeout: 25, addLimit: false)
        if let err = results.first(where: { $0.error != nil })?.error {
            close()
            throw ToolError(err)
        }
        if connection.kind == .redis, let t = results.last?.text, !t.contains("PONG") {
            close()
            throw ToolError(t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        serverVersion = results.last?.rows.first?.first.flatMap { $0 } ?? ""
    }
    private var pipes: [Pipe] = []

    public func close() {
        let p: Process? = stateLock.withLock {
            let p = process
            process = nil
            try? input?.close()
            input = nil
            return p
        }
        if let p, p.isRunning { p.terminate() }
        removeCredentials()
    }

    /// Stops the running statement (by ending the client: the session restarts on the next run).
    public func cancel() {
        stateLock.withLock { cancelled = true }
        let p = stateLock.withLock { process }
        if let p, p.isRunning { p.terminate() }
    }

    // MARK: Running

    /// Runs a script (split into statements; stops at the first error). Blocking: call off the main thread.
    public func run(_ sql: String, maxRows: Int = 1000, maxCell: Int = 20_000, timeout: TimeInterval = 300,
                    addLimit: Bool = true) throws -> [QueryResult] {
        if connection.kind == .redis {
            let lines = sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return try runStatements(lines, maxRows: maxRows, maxCell: maxCell, timeout: timeout, addLimit: false)
        }
        guard !SQLText.isUnterminated(sql, dialect: dialect) else {
            throw ToolError("La query non è chiusa: manca un apice, una virgoletta o la fine di un commento /* */")
        }
        guard !SQLText.hasClientCommand(sql, dialect: dialect) else {
            throw ToolError(dialect == .postgres ? "Le query con \\ non sono permesse: i comandi di psql sono disattivati."
                            : dialect == .sqlite ? "I comandi .punto di sqlite3 non sono supportati: scrivi SQL."
                            : "I comandi del client mysql (\\…) non sono supportati: scrivi SQL.")
        }
        let statements = SQLText.split(sql, dialect: dialect)
        guard !statements.isEmpty else { return [] }
        // Read-only sessions (db_query's autonomous path, already checked with isAutonomousRead) run exactly one
        // statement: the engine's read-only mode then refuses anything else.
        if readOnly {
            guard statements.count == 1 else {
                throw ToolError("Sessione di sola lettura: una sola istruzione di lettura per volta")
            }
        }
        return try runStatements(statements, maxRows: maxRows, maxCell: maxCell, timeout: timeout, addLimit: addLimit)
    }

    /// Transactions: auto-commit off keeps one open transaction until commit/rollback.
    public func setAutocommit(_ on: Bool) throws {
        switch connection.kind {
        case .mysql: _ = try runStatements(["SET autocommit=\(on ? 1 : 0)"], maxRows: 1, maxCell: 100, timeout: 30, addLimit: false)
        case .postgres:
            write("\\set AUTOCOMMIT \(on ? "on" : "off")\n")
            if on { _ = try? runStatements(["COMMIT"], maxRows: 1, maxCell: 100, timeout: 30, addLimit: false) }
        case .sqlite:
            _ = try runStatements([on ? "COMMIT" : "BEGIN"], maxRows: 1, maxCell: 100, timeout: 30, addLimit: false)
        default: throw ToolError("Le transazioni non sono disponibili per \(connection.kindLabel)")
        }
        autocommit = on
    }

    public func commit(_ yes: Bool) throws -> QueryResult {
        let r = try runStatements([yes ? "COMMIT" : "ROLLBACK"], maxRows: 1, maxCell: 100, timeout: 60, addLimit: false).first
            ?? QueryResult(statement: yes ? "COMMIT" : "ROLLBACK")
        // SQLite: a new transaction right away, like the other engines in manual mode.
        if connection.kind == .sqlite, !autocommit { _ = try? runStatements(["BEGIN"], maxRows: 1, maxCell: 100, timeout: 30, addLimit: false) }
        return r
    }

    func runStatements(_ statements: [String], maxRows: Int, maxCell: Int, timeout: TimeInterval, addLimit: Bool) throws -> [QueryResult] {
        runLock.lock()
        defer { runLock.unlock() }
        stateLock.withLock { cancelled = false }
        var results: [QueryResult] = []
        for stmt in statements {
            guard isAlive else { throw ToolError(lastExitMessage()) }
            let start = Date()
            var r = try runOne(stmt, maxRows: maxRows, maxCell: maxCell, deadline: start.addingTimeInterval(timeout), addLimit: addLimit)
            r.ms = Int(Date().timeIntervalSince(start) * 1000)
            results.append(r)
            if r.error != nil { break }
        }
        return results
    }

    private func runOne(_ stmt: String, maxRows: Int, maxCell: Int, deadline: Date, addLimit: Bool) throws -> QueryResult {
        counter += 1
        let marker = "__ELIO_MK_\(nonce)_\(counter)__"
        let sql = addLimit ? SQLText.withLimit(stmt, maxRows + 1, dialect: dialect) : stmt
        var r = QueryResult(statement: stmt)
        switch connection.kind {
        case .mysql:
            write("\(sql)\n;\nSELECT ROW_COUNT() AS __elio_affected;\nSELECT '\(marker)' AS __elio_mk;\n")
            let (out, err) = try collect(until: "\(marker)</field>", then: "</resultset>", deadline: deadline)
            let sets = MySQLXML.parse(out)
            for s in sets where s.columns != ["__elio_mk"] {
                if s.columns == ["__elio_affected"] {
                    if let v = s.rows.first?.first, let n = Int(v ?? "") , n >= 0, !r.hasResultSet { r.affected = n }
                } else if !r.hasResultSet {
                    r.hasResultSet = true
                    r.columns = s.columns
                    r.rows = s.rows
                }
            }
            let errLines = err.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("ERROR") }
            if !errLines.isEmpty {
                r.error = errLines.map { $0.replacingOccurrences(of: #"^ERROR (\d+) \(([^)]*)\) at line \d+: "#, with: "ERROR $1 ($2): ", options: .regularExpression) }
                    .joined(separator: "\n")
            } else if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sets.isEmpty {
                r.error = err.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .postgres:
            write("\(sql)\n;\n\\echo \(marker) :ERROR :ROW_COUNT\n")
            let (out, err) = try collect(until: "\(marker) ", then: "\n", deadline: deadline)
            guard let mk = out.range(of: "\(marker) ", options: .backwards) else { throw ToolError("Risposta non valida da psql") }
            let csv = String(out[..<mk.lowerBound])
            let status = out[mk.upperBound...].split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let failed = status.first == "true"
            let rowCount = status.count > 1 ? Int(status[1]) : nil
            if failed {
                r.error = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Errore" : err.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                r.text = err.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !csv.isEmpty {
                let records = CSVText.parse(csv)
                r.hasResultSet = true
                r.columns = records.first?.map { $0 ?? "" } ?? []
                r.rows = records.dropFirst().map { $0.map { $0 == Self.nullToken ? nil : $0 } }
            } else if !failed {
                r.affected = rowCount
            }
        case .sqlite:
            let rows = SQLText.returnsRows(stmt, dialect: .sqlite)
            write("\(sql)\n;\n" + (rows ? "" : "SELECT changes() AS __elio_affected;\n") + ".print \(marker)\n")
            let (out, err) = try collect(until: "\(marker)\n", then: nil, deadline: deadline)
            let body = String(out.dropLast(marker.count + 1))
            let records = SQLiteQuote.parse(body)
            if let head = records.first {
                if head.map({ $0 ?? "" }) == ["__elio_affected"] {
                    r.affected = records.count > 1 ? Int(records[1].first.flatMap { $0 } ?? "") : nil
                } else {
                    r.hasResultSet = true
                    r.columns = head.map { $0 ?? "" }
                    r.rows = Array(records.dropFirst())
                }
            } else if rows {
                r.hasResultSet = true
            }
            let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if !e.isEmpty { r.error = e.replacingOccurrences(of: #"^(Parse|Runtime) error near line \d+: "#, with: "", options: .regularExpression) }
        case .redis:
            write("\(stmt)\nECHO \(marker)\n")
            let (out, err) = try collect(until: "\"\(marker)\"\n", then: nil, deadline: deadline)
            var body = String(out.dropLast(marker.count + 3))
            if body.hasSuffix("\n") { body.removeLast() }
            r.text = body
            if body.hasPrefix("(error)") || body.hasPrefix("ERR") { r.error = body }
            let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if !e.isEmpty, r.error == nil, body.isEmpty { r.error = e }
        case .ssh: break
        }
        // Caps: rows and cell size.
        if r.rows.count > maxRows { r.rows = Array(r.rows.prefix(maxRows)); r.truncated = true }
        if r.rows.contains(where: { $0.contains { ($0?.count ?? 0) > maxCell } }) {
            r.rows = r.rows.map { $0.map { v in v.map { $0.count > maxCell ? String($0.prefix(maxCell)) + "…" : $0 } } }
        }
        return r
    }

    // MARK: I/O

    private func write(_ text: String) {
        let h = stateLock.withLock { input }
        guard let h else { return }
        try? h.write(contentsOf: Data(text.utf8))
    }

    /// Reads stdout until `marker` (and then `then`) arrives; returns (stdout text, stderr text).
    private func collect(until marker: String, then: String?, deadline: Date) throws -> (String, String) {
        let markerData = Data(marker.utf8)
        let thenData = then.map { Data($0.utf8) }
        var out = pending
        pending = Data()
        var err = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var searchFrom = 0
        func finished() -> Int? {
            let from = max(0, searchFrom - markerData.count - (thenData?.count ?? 0))
            guard let m = out.range(of: markerData, in: from..<out.count) else { return nil }
            if let thenData {
                guard let t = out.range(of: thenData, in: m.upperBound..<out.count) else { return nil }
                return t.upperBound
            }
            return m.upperBound
        }
        while true {
            if let end = finished() {
                pending = out.subdata(in: end..<out.count)
                out = out.subdata(in: 0..<end)
                break
            }
            searchFrom = out.count
            if stateLock.withLock({ cancelled }) { throw ToolError("Query annullata") }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                cancel()
                throw ToolError("Tempo scaduto: la query è stata interrotta")
            }
            var fds = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0), pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, Int32(min(remaining, 0.5) * 1000))
            if n < 0, errno != EINTR { throw ToolError("Errore di lettura dal client") }
            if fds[1].revents & Int16(POLLIN) != 0 { drain(errFD, into: &err, buf: &buf) }
            if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let k = read(outFD, &buf, buf.count)
                if k > 0 { out.append(buf, count: k) }
                else if k == 0 {
                    drain(errFD, into: &err, buf: &buf)
                    stateLock.withLock { exitText = String(decoding: err, as: UTF8.self) }
                    if stateLock.withLock({ cancelled }) { throw ToolError("Query annullata") }
                    process?.waitUntilExit()
                    throw ToolError(lastExitMessage())
                }
            }
        }
        // stderr written before the marker is already in the pipe.
        drain(errFD, into: &err, buf: &buf)
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
    private var exitText = ""

    private func drain(_ fd: Int32, into data: inout Data, buf: inout [UInt8]) {
        while true {
            let k = read(fd, &buf, buf.count)
            if k > 0 { data.append(buf, count: k) } else { break }
        }
    }

    private func lastExitMessage() -> String {
        let text = stateLock.withLock { exitText }.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("mysql: [Warning]") }
        return lines.isEmpty ? "Il client \(connection.kindLabel) si è chiuso" : lines.suffix(4).joined(separator: "\n")
    }

    // MARK: Credentials

    private func writeCredential(_ name: String, _ content: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("elio-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        credDir = dir
        let file = dir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ToolError("Non riesco a preparare le credenziali temporanee")
        }
        return file.path
    }

    private func removeCredentials() {
        if let dir = credDir { try? FileManager.default.removeItem(at: dir) }
        credDir = nil
    }

    private func redisQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Output parsers

/// `mysql --xml` output: a sequence of <resultset> documents.
public enum MySQLXML {
    public struct ResultSet: Equatable { public var statement: String; public var columns: [String]; public var rows: [[String?]] }

    public static func parse(_ text: String) -> [ResultSet] {
        var out: [ResultSet] = []
        var search = text.startIndex
        while let open = text.range(of: "<resultset", range: search..<text.endIndex) {
            guard let close = text.range(of: "</resultset>", range: open.upperBound..<text.endIndex) else { break }
            let segment = String(text[open.lowerBound..<close.upperBound])
            let p = Parser()
            let xml = XMLParser(data: Data(segment.utf8))
            xml.delegate = p
            xml.shouldProcessNamespaces = false
            _ = xml.parse()
            out.append(ResultSet(statement: p.statement, columns: p.columns, rows: p.rows))
            search = close.upperBound
        }
        return out
    }

    final class Parser: NSObject, XMLParserDelegate {
        var statement = ""
        var columns: [String] = []
        var rows: [[String?]] = []
        private var row: [String?] = []
        private var rowColumns: [String] = []
        private var value: String?
        private var inField = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name {
            case "resultset": statement = attributes["statement"] ?? ""
            case "row": row = []; rowColumns = []
            case "field":
                inField = true
                rowColumns.append(attributes["name"] ?? "")
                value = attributes["xsi:nil"] == "true" ? nil : ""
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inField, value != nil { value! += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "field": row.append(value); inField = false
            case "row":
                if columns.isEmpty { columns = rowColumns }
                rows.append(row)
            default: break
            }
        }
    }
}

/// libpq connection strings: every value single-quoted, backslash and quote escaped.
public enum PGConnInfo {
    public static func quote(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    public static func build(host: String, port: Int?, user: String, dbname: String) -> String {
        var parts = ["dbname=\(quote(dbname))", "user=\(quote(user))"]
        if !host.isEmpty { parts.append("host=\(quote(host))") }
        if let port { parts.append("port=\(port)") }
        return parts.joined(separator: " ")
    }
}

/// RFC 4180 CSV (psql --csv): quoted fields may hold commas, quotes and newlines.
public enum CSVText {
    public static func parse(_ text: String) -> [[String?]] {
        var records: [[String?]] = []
        var record: [String?] = []
        var field = ""
        var quoted = false, wasQuoted = false
        var it = Array(text)
        if it.last == "\n" { it.removeLast() }
        var i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < it.count, it[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true; wasQuoted = true
            } else if c == "," {
                record.append(field); field = ""; wasQuoted = false
            } else if c == "\n" || c == "\r\n" {
                record.append(field); field = ""; wasQuoted = false
                records.append(record); record = []
            } else if c != "\r" {
                field.append(c)
            }
            i += 1
        }
        if !it.isEmpty { record.append(field); records.append(record) }
        _ = wasQuoted
        return records
    }

    /// One CSV field for export.
    public static func field(_ v: String?) -> String {
        guard let v else { return "" }
        if v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}

/// sqlite3 `.mode quote`: SQL literals ('text', NULL, 12, 1.5, X'0102') separated by commas.
public enum SQLiteQuote {
    public static func parse(_ text: String) -> [[String?]] {
        var records: [[String?]] = []
        var record: [String?] = []
        var field = "", isNull = false, started = false
        let c = Array(text)
        var i = 0
        func end() {
            record.append(isNull ? nil : field)
            field = ""; isNull = false; started = false
        }
        while i < c.count {
            let ch = c[i]
            if ch == "'" {
                // Quoted string ('' is a quote).
                i += 1
                while i < c.count {
                    if c[i] == "'" { if i + 1 < c.count, c[i + 1] == "'" { field.append("'"); i += 2; continue }; break }
                    field.append(c[i]); i += 1
                }
                started = true
            } else if ch == "X" || ch == "x", i + 1 < c.count, c[i + 1] == "'", !started {
                var hex = ""
                i += 2
                while i < c.count, c[i] != "'" { hex.append(c[i]); i += 1 }
                field = "0x" + hex.uppercased()
                started = true
            } else if ch == "," {
                end()
            } else if ch == "\n" {
                end()
                records.append(record); record = []
            } else {
                field.append(ch)
                started = true
                if field == "NULL" { isNull = true } else { isNull = false }
            }
            i += 1
        }
        if started || !record.isEmpty { end(); records.append(record) }
        return records
    }
}
