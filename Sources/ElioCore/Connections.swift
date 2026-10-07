import Foundation
import Security

/// A saved database or SSH host (PhpStorm's Data Sources / Remote Hosts). Shared by the IDE (app) and the
/// assistant (daemon) through ~/Library/Application Support/Elio/connections.json. Never holds secrets:
/// passwords live in the Keychain (`ConnectionSecrets`).
public struct Connection: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case ssh, mysql, postgres, sqlite, redis }
    public enum Auth: String, Codable, Sendable { case agent, key, password }

    /// Local port → host:port seen from the SSH server.
    public struct Forward: Codable, Sendable, Equatable {
        public var localPort: Int
        public var remoteHost: String
        public var remotePort: Int
        public init(localPort: Int, remoteHost: String, remotePort: Int) {
            self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var host: String
    public var port: Int?
    public var user: String
    /// MySQL/Postgres database, Redis db index.
    public var database: String
    /// SQLite file.
    public var path: String
    public var auth: Auth
    public var keyPath: String
    /// Id of a saved SSH host to tunnel through (databases only).
    public var sshVia: String
    /// Remote start folder (SSH).
    public var remoteDir: String
    /// Production: red everywhere, every write confirmed.
    public var production: Bool
    public var color: String
    public var tag: String
    /// Deployment mapping: local project folder ↔ remote folder (SSH).
    public var localRoot: String
    public var remoteRoot: String
    public var forwards: [Forward]
    /// Imported from ~/.ssh/config: `host` is the alias and ssh resolves the rest.
    public var sshConfigAlias: Bool
    /// A DDEV project's database: host port and credentials are read from `ddev describe` at every connect.
    public var ddevRoot: String
    /// Created or confirmed by the user (IDE form, or a confirmation): the assistant may use it without asking.
    public var verified: Bool
    public var created: Date

    public init(id: String = Connection.newId(), name: String, kind: Kind, host: String = "", port: Int? = nil, user: String = "",
                database: String = "", path: String = "", auth: Auth = .agent, keyPath: String = "", sshVia: String = "",
                remoteDir: String = "", production: Bool = false, color: String = "", tag: String = "",
                localRoot: String = "", remoteRoot: String = "", forwards: [Forward] = [], sshConfigAlias: Bool = false,
                ddevRoot: String = "", verified: Bool = false, created: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port; self.user = user
        self.database = database; self.path = path; self.auth = auth; self.keyPath = keyPath; self.sshVia = sshVia
        self.remoteDir = remoteDir; self.production = production; self.color = color; self.tag = tag
        self.localRoot = localRoot; self.remoteRoot = remoteRoot; self.forwards = forwards
        self.sshConfigAlias = sshConfigAlias; self.ddevRoot = ddevRoot; self.verified = verified; self.created = created
    }

    public static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Every field optional on disk: older files and hand edits keep decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Connection.newId()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .ssh
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try? c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        auth = (try? c.decodeIfPresent(Auth.self, forKey: .auth)) ?? .agent
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        sshVia = try c.decodeIfPresent(String.self, forKey: .sshVia) ?? ""
        remoteDir = try c.decodeIfPresent(String.self, forKey: .remoteDir) ?? ""
        production = try c.decodeIfPresent(Bool.self, forKey: .production) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        localRoot = try c.decodeIfPresent(String.self, forKey: .localRoot) ?? ""
        remoteRoot = try c.decodeIfPresent(String.self, forKey: .remoteRoot) ?? ""
        forwards = (try? c.decodeIfPresent([Forward].self, forKey: .forwards)) ?? []
        sshConfigAlias = try c.decodeIfPresent(Bool.self, forKey: .sshConfigAlias) ?? false
        ddevRoot = try c.decodeIfPresent(String.self, forKey: .ddevRoot) ?? ""
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date(timeIntervalSince1970: 0)
        if name.isEmpty { name = host.isEmpty ? (path as NSString).lastPathComponent : host }
    }

    // MARK: Validation (values end up in ssh/scp/client argv: nothing may look like an option)

    /// Host name, IPv4, bare IPv6, or [IPv6]; never starting with "-".
    public static func isValidHost(_ h: String, allowColon: Bool = true) -> Bool {
        guard !h.isEmpty, h.count <= 253, !h.hasPrefix("-") else { return false }
        if h.hasPrefix("[") && h.hasSuffix("]") {
            return h.dropFirst().dropLast().allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" || $0.isLetter || $0.isNumber) }
        }
        return h.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || (allowColon && $0 == ":")) }
    }

    public static func isValidUser(_ u: String) -> Bool {
        u.isEmpty || (!u.hasPrefix("-") && u.count <= 128 && !u.contains("@")
                      && !u.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
    }

    /// Database names: no control characters, no leading "-", and for Postgres nothing libpq would read as a
    /// connection string ("host=…", postgres:// URIs).
    public static func isValidDatabaseName(_ d: String, kind: Kind) -> Bool {
        if d.isEmpty { return true }
        guard d.count <= 128, !d.hasPrefix("-"),
              !d.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { return false }
        if kind == .postgres {
            let l = d.lowercased()
            if d.contains("=") || l.hasPrefix("postgres://") || l.hasPrefix("postgresql://") { return false }
        }
        if kind == .redis { return Int(d) != nil }
        return true
    }

    /// A private key: an existing file inside the home folder.
    public static func isValidKeyPath(_ p: String) -> Bool {
        let path = ((p as NSString).expandingTildeInPath as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dir: ObjCBool = false
        return path.hasPrefix(home + "/") && !(path as NSString).lastPathComponent.hasPrefix("-")
            && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }

    /// Throws a clear Italian message for anything unsafe or malformed.
    public func validate() throws {
        if let p = port, !(1...65535).contains(p) { throw ToolError("Porta non valida: \(p)") }
        if kind == .sqlite {
            guard !path.isEmpty else { throw ToolError("Manca il file SQLite") }
            guard !(path as NSString).lastPathComponent.hasPrefix("-") else { throw ToolError("Percorso SQLite non valido") }
            return
        }
        let needsHost = kind == .ssh
        if needsHost || !host.isEmpty {
            guard Connection.isValidHost(host) else { throw ToolError("Host non valido: \(host.prefix(60))") }
        }
        guard Connection.isValidUser(user) else { throw ToolError("Utente non valido") }
        guard Connection.isValidDatabaseName(database, kind: kind) else { throw ToolError("Nome del database non valido: \(database.prefix(60))") }
        if !keyPath.isEmpty, kind == .ssh, auth == .key {
            guard Connection.isValidKeyPath(keyPath) else { throw ToolError("Chiave SSH non trovata (deve essere un file nella tua home): \(keyPath)") }
        }
        for f in forwards {
            guard (1...65535).contains(f.localPort), (1...65535).contains(f.remotePort),
                  Connection.isValidHost(f.remoteHost, allowColon: false) || (f.remoteHost.hasPrefix("[") && Connection.isValidHost(f.remoteHost)) else {
                throw ToolError("Inoltro porta non valido: \(f.localPort) → \(f.remoteHost):\(f.remotePort)")
            }
        }
    }

    public var isDatabase: Bool { kind != .ssh }

    /// Where a stored secret may be sent. The Keychain item carries it; a connection retargeted elsewhere
    /// (by the assistant or by hand) no longer gets the old password.
    public var endpointFingerprint: String {
        [kind.rawValue, host.lowercased(), "\(effectivePort)", user, kind == .postgres ? database : "", sshVia, ddevRoot,
         kind == .sqlite ? path : "", sshConfigAlias ? "alias" : ""].joined(separator: "|")
    }

    /// Something that decides where (or as whom) we connect changed.
    public func endpointChanged(from old: Connection) -> Bool {
        endpointFingerprint != old.endpointFingerprint || auth != old.auth || keyPath != old.keyPath
    }

    /// "deploy@1.2.3.4:22 (via SSH)" for confirmations.
    public var destinationLabel: String {
        if kind == .sqlite { return path }
        var s = (user.isEmpty ? "" : "\(user)@") + (host.isEmpty ? "localhost" : host) + ":\(effectivePort)"
        if kind == .postgres || kind == .mysql, !database.isEmpty { s += "/\(database)" }
        if !sshVia.isEmpty { s += " via SSH \(sshVia)" }
        if !ddevRoot.isEmpty { s += " (DDEV)" }
        return s
    }

    public var defaultPort: Int {
        switch kind {
        case .ssh: 22
        case .mysql: 3306
        case .postgres: 5432
        case .redis: 6379
        case .sqlite: 0
        }
    }
    public var effectivePort: Int { port ?? defaultPort }

    public var kindLabel: String {
        switch kind {
        case .ssh: "SSH"
        case .mysql: "MySQL"
        case .postgres: "PostgreSQL"
        case .sqlite: "SQLite"
        case .redis: "Redis"
        }
    }

    /// One line for lists and the assistant (no secrets).
    public var summary: String {
        var s = "\(name) [\(kindLabel)] "
        switch kind {
        case .sqlite: s += path
        case .ssh: s += (user.isEmpty ? "" : "\(user)@") + host + (port.map { ":\($0)" } ?? "")
        default:
            s += (user.isEmpty ? "" : "\(user)@") + (host.isEmpty ? "localhost" : host) + ":\(effectivePort)"
            if !database.isEmpty { s += "/\(database)" }
        }
        if !sshVia.isEmpty { s += " via SSH" }
        if production { s += " (PRODUZIONE)" }
        return s + " id \(id)"
    }

    /// Metadata for the IDE page (never the password).
    public var dictionary: [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "kind": kind.rawValue, "host": host, "user": user, "database": database,
                                "path": path, "auth": auth.rawValue, "keyPath": keyPath, "sshVia": sshVia, "remoteDir": remoteDir,
                                "production": production, "color": color, "tag": tag, "localRoot": localRoot, "remoteRoot": remoteRoot,
                                "forwards": forwards.map { ["localPort": $0.localPort, "remoteHost": $0.remoteHost, "remotePort": $0.remotePort] },
                                "sshConfigAlias": sshConfigAlias, "ddevRoot": ddevRoot, "verified": verified, "defaultPort": defaultPort, "kindLabel": kindLabel]
        d["port"] = port ?? NSNull()
        return d
    }

    /// Builds a connection from page/tool fields (unknown keys ignored; absent ones keep `base`).
    public static func from(_ a: [String: Any], base: Connection? = nil) -> Connection {
        var c = base ?? Connection(name: "", kind: Kind(rawValue: a["kind"] as? String ?? "") ?? .ssh)
        func s(_ k: String) -> String? { (a[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        if let v = s("kind"), let k = Kind(rawValue: v) { c.kind = k }
        if let v = s("name") { c.name = v }
        if let v = s("host") { c.host = v }
        if let v = a["port"] { c.port = (v as? Int) ?? (v as? String).flatMap { Int($0) } ?? (v is NSNull ? nil : c.port) }
        if let v = s("user") { c.user = v }
        if let v = s("database") { c.database = v }
        if let v = s("path") { c.path = (v as NSString).expandingTildeInPath }
        if let v = s("auth"), let au = Auth(rawValue: v) { c.auth = au }
        if let v = s("keyPath") ?? s("key_path") { c.keyPath = (v as NSString).expandingTildeInPath }
        if let v = s("sshVia") ?? s("ssh_via") { c.sshVia = v }
        if let v = s("remoteDir") ?? s("remote_dir") { c.remoteDir = v }
        if let v = a["production"] as? Bool { c.production = v }
        if let v = s("color") { c.color = v }
        if let v = s("tag") { c.tag = v }
        if let v = s("localRoot") { c.localRoot = (v as NSString).expandingTildeInPath }
        if let v = s("remoteRoot") { c.remoteRoot = v }
        if let v = a["sshConfigAlias"] as? Bool { c.sshConfigAlias = v }
        if let list = a["forwards"] as? [[String: Any]] {
            c.forwards = list.compactMap { f in
                guard let l = (f["localPort"] as? Int) ?? (f["localPort"] as? String).flatMap({ Int($0) }),
                      let r = (f["remotePort"] as? Int) ?? (f["remotePort"] as? String).flatMap({ Int($0) }) else { return nil }
                return Forward(localPort: l, remoteHost: (f["remoteHost"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1", remotePort: r)
            }
        }
        if c.auth == .agent, !c.keyPath.isEmpty { c.auth = .key }
        if c.name.isEmpty { c.name = c.kind == .sqlite ? (c.path as NSString).lastPathComponent : (c.host.isEmpty ? c.kindLabel : c.host) }
        return c
    }
}

/// connections.json: load, save, look up by id or by (fuzzy) name.
public enum ConnectionStore {
    public static var url: URL { ElioPaths.support.appendingPathComponent("connections.json") }
    private static let lock = NSLock()

    public static func load() -> [Connection] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// Accepts the current file ({"connections": [...]}) and a bare array.
    public static func decode(_ data: Data) -> [Connection] {
        struct File: Decodable { var connections: [Connection] }
        if let f = try? JSONDecoder.iso.decode(File.self, from: data) { return f.connections }
        return (try? JSONDecoder.iso.decode([Connection].self, from: data)) ?? []
    }

    public static func save(_ list: [Connection]) throws {
        try lock.withLock { try write(list) }
    }

    @discardableResult
    public static func upsert(_ c: Connection) throws -> Connection {
        try c.validate()
        try lock.withLock {
            var list = load()
            if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
            try write(list)
        }
        return c
    }

    public static func remove(_ id: String) throws {
        try lock.withLock {
            try write(load().filter { $0.id != id })
        }
        ConnectionSecrets.delete(id)
    }

    static func write(_ list: [Connection]) throws {
        struct Shape: Encodable { let version: Int; let connections: [Connection] }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Shape(version: 1, connections: list)).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Exactly this id (references stored in a connection, like the tunnel's host: never a fuzzy name match,
    /// which a renamed or newly saved host could hijack).
    public static func byId(_ id: String, kinds: Set<Connection.Kind>? = nil, in list: [Connection]? = nil) -> Connection? {
        guard !id.isEmpty else { return nil }
        return (list ?? load()).first { $0.id == id && (kinds?.contains($0.kind) ?? true) }
    }

    /// By id, exact name, then a name/host that contains the query ("staging", "db di comitiva").
    public static func find(_ query: String, kinds: Set<Connection.Kind>? = nil, in list: [Connection]? = nil) -> Connection? {
        let all = (list ?? load()).filter { kinds?.contains($0.kind) ?? true }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all.count == 1 ? all[0] : nil }
        if let c = all.first(where: { $0.id == q }) { return c }
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: #"[\s_.-]+"#, with: "", options: .regularExpression) }
        let nq = norm(q)
        if let c = all.first(where: { norm($0.name) == nq }) { return c }
        if let c = all.first(where: { $0.host.lowercased() == q.lowercased() }) { return c }
        return all.first { !nq.isEmpty && (norm($0.name).contains(nq) || nq.contains(norm($0.name)) || norm($0.host).contains(nq)) }
    }
}

/// Connection passwords in the login Keychain, readable by both the app and the daemon without prompts.
public enum ConnectionSecrets {
    static func service(_ id: String) -> String { "elio-conn-\(id)" }

    /// The password, only if it was saved for this same endpoint (host, port, user…).
    public static func password(for c: Connection) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(c.id),
                                    kSecReturnData as String: true, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data else { return nil }
        guard matches(stored: dict[kSecAttrComment as String] as? String, c) else { return nil }
        // Not trimmed: a password may legitimately end with a space.
        return String(data: data, encoding: .utf8)
    }

    /// A secret goes only to the endpoint it was saved for.
    public static func matches(stored fingerprint: String?, _ c: Connection) -> Bool {
        fingerprint == c.endpointFingerprint
    }

    /// Passwords travel through option files, env and askpass: no control characters (a newline would inject).
    public static func validatePassword(_ pw: String) throws {
        if pw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            throw ToolError("La password contiene caratteri di controllo (a capo, tab…): non è supportata")
        }
    }

    public static func has(_ id: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(id),
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func set(_ c: Connection, _ value: String) {
        let id = c.id
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(id)]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecAttrAccount as String] = "elio"
        item[kSecAttrLabel as String] = "Elio: connessione \(id)"
        item[kSecAttrComment as String] = c.endpointFingerprint
        item[kSecValueData as String] = Data(value.utf8)
        // Both the app and the daemon are trusted: whoever saved it, the other reads it silently.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var apps: [SecTrustedApplication] = []
        for path in [nil, "\(home)/Applications/Elio.app", ElioPaths.support.appendingPathComponent("ElioDaemon.app").path] as [String?] {
            if let path, !FileManager.default.fileExists(atPath: path) { continue }
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        if SecAccessCreate("Elio: connessione \(id)" as CFString, apps as CFArray, &access) == errSecSuccess, let access {
            item[kSecAttrAccess as String] = access
        }
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func delete(_ id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(id)] as CFDictionary)
    }
}

/// `Host` entries of ~/.ssh/config, for one-click import.
public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String
    public var user: String
    public var port: Int?
    public var identityFile: String
    public var proxyJump: String

    public static func parse(_ text: String) -> [SSHConfigHost] {
        var out: [SSHConfigHost] = []
        var current: [SSHConfigHost] = []
        func flush() { out += current; current = [] }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Key value", "Key=value" or "Key = value".
            var key = "", value = ""
            if let eq = line.firstIndex(of: "="), !line[..<eq].trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) {
                key = line[..<eq].trimmingCharacters(in: .whitespaces)
                value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            } else {
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                key = String(parts[0]); value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            switch key.lowercased() {
            case "host":
                flush()
                // Patterns (*, ?, !) are defaults, not hosts one can connect to.
                current = value.split(whereSeparator: \.isWhitespace).map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && Connection.isValidHost($0, allowColon: false) }
                    .map { SSHConfigHost(alias: $0, hostName: "", user: "", port: nil, identityFile: "", proxyJump: "") }
            case "match":
                flush()
            case "hostname": for i in current.indices where current[i].hostName.isEmpty { current[i].hostName = value }
            case "user": for i in current.indices where current[i].user.isEmpty { current[i].user = value }
            case "port": for i in current.indices where current[i].port == nil { current[i].port = Int(value) }
            case "identityfile": for i in current.indices where current[i].identityFile.isEmpty { current[i].identityFile = value }
            case "proxyjump": for i in current.indices where current[i].proxyJump.isEmpty { current[i].proxyJump = value }
            default: break
            }
        }
        flush()
        return out
    }

    public static func load() -> [SSHConfigHost] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }
}

/// DDEV projects (Magento on Docker): the database's published port changes at every `ddev start`.
public enum DDEV {
    public struct DB: Sendable { public var name: String; public var root: String; public var type: String; public var port: Int?
        public var user: String; public var password: String; public var database: String; public var running: Bool }

    public static var binary: String? { DBClients.find("ddev") }

    /// The project at (or above) `path`, if it's a DDEV project.
    public static func projectRoot(_ path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ddev/config.yaml").path) { return dir.path }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return nil
    }

    public static func describe(_ root: String) throws -> DB {
        guard let bin = binary else { throw ToolError("DDEV non è installato (brew install ddev/ddev/ddev)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["describe", "-j"]
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = obj["raw"] as? [String: Any] else {
            throw ToolError("ddev describe non ha risposto per \(root)")
        }
        let info = raw["dbinfo"] as? [String: Any] ?? [:]
        let port = (info["published_port"] as? Int) ?? (info["published_port"] as? String).flatMap { Int($0) }
        return DB(name: raw["name"] as? String ?? (root as NSString).lastPathComponent, root: raw["approot"] as? String ?? root,
                  type: info["database_type"] as? String ?? "mariadb", port: port == 0 ? nil : port,
                  user: info["username"] as? String ?? "db", password: info["password"] as? String ?? "db",
                  database: info["dbname"] as? String ?? "db", running: (raw["status"] as? String) == "running")
    }
}

/// The official command-line clients, wherever Homebrew or the system put them.
public enum DBClients {
    public static let dirs = ["/opt/homebrew/bin", "/opt/homebrew/opt/mysql-client/bin", "/opt/homebrew/opt/mariadb/bin",
                              "/opt/homebrew/opt/libpq/bin", "/opt/homebrew/opt/postgresql@17/bin", "/opt/homebrew/opt/postgresql@16/bin",
                              "/usr/local/bin", "/usr/local/opt/mysql-client/bin", "/usr/local/opt/libpq/bin", "/usr/bin", "/bin",
                              "/Applications/Postgres.app/Contents/Versions/latest/bin"]

    public static func find(_ name: String) -> String? {
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs + env {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// The binary for an engine (mysql falls back to mariadb).
    public static func client(for kind: Connection.Kind) -> String? {
        switch kind {
        case .mysql: find("mysql") ?? find("mariadb")
        case .postgres: find("psql")
        case .sqlite: find("sqlite3")
        case .redis: find("redis-cli")
        case .ssh: find("ssh")
        }
    }

    public static func brewHint(for kind: Connection.Kind) -> String {
        switch kind {
        case .mysql: "brew install mysql-client && brew link --force mysql-client"
        case .postgres: "brew install libpq && brew link --force libpq"
        case .sqlite: "brew install sqlite"
        case .redis: "brew install redis"
        case .ssh: ""
        }
    }

    public static func missing(_ kind: Connection.Kind) -> ToolError {
        ToolError("Manca il client \(kind == .mysql ? "mysql" : kind == .postgres ? "psql" : kind == .redis ? "redis-cli" : "sqlite3"). Installalo con: \(brewHint(for: kind))")
    }
}
