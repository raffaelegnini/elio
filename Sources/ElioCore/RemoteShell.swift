import Darwin
import Foundation

/// SSH for the IDE and the assistant. Every command shares one ControlMaster connection per host (fast, and a
/// password is typed — by the askpass helper — once). Passwords go to ssh through SSH_ASKPASS pointing at a
/// 0700 script that prints a 0600 temp file: never argv, never the environment.
public enum SSHRunner {
    /// Socket folder. Not in Application Support: a unix socket path must stay under 104 bytes (ssh adds a
    /// 17-char suffix while creating it), so a short private folder in /tmp, owned by the user and 0700.
    public static var controlDir: String {
        let dir = "/tmp/elio-ssh-\(getuid())"
        if ensurePrivateDir(dir) { return dir }
        // Someone else's folder (or a symlink) there: a fresh private one, short enough for the socket path.
        fallbackLock.lock(); defer { fallbackLock.unlock() }
        if let d = fallbackDir, isPrivateDir(d) { return d }
        var template = Array("/tmp/es-XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil }
        let d = made ? template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : ""
        if made, isPrivateDir(d) { fallbackDir = d; return d }
        // Last resort: the per-user temporary folder (private to the user, still short enough).
        let alt = FileManager.default.temporaryDirectory.appendingPathComponent("es").path
        _ = ensurePrivateDir(alt)
        return alt
    }
    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static var fallbackDir: String?

    /// Creates `dir` 0700 if missing, then checks what is there now (another user could have raced the mkdir):
    /// a real directory, ours, mode 0700 (fixed when only the mode is off).
    static func ensurePrivateDir(_ dir: String) -> Bool {
        _ = mkdir(dir, 0o700)
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o777 != 0o700 {
            guard chmod(dir, 0o700) == 0 else { return false }
        }
        return isPrivateDir(dir)
    }

    static func isPrivateDir(_ dir: String) -> Bool {
        var st = stat()
        return !dir.isEmpty && lstat(dir, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() && st.st_mode & 0o777 == 0o700
    }

    public static var sshPath: String { "/usr/bin/ssh" }

    /// user@host, or the ~/.ssh/config alias.
    public static func destination(_ c: Connection) -> String {
        c.sshConfigAlias || c.user.isEmpty ? c.host : "\(c.user)@\(c.host)"
    }

    /// Options shared by ssh and scp. `port` is -p for ssh, -P for scp.
    public static func options(_ c: Connection, master: String = "no", scp: Bool = false, batch: Bool = true) -> [String] {
        var o = ["-o", "ControlPath=\(controlDir)/%C", "-o", "ControlMaster=\(master)", "-o", "ServerAliveInterval=30",
                 "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new"]
        if batch, c.auth != .password { o += ["-o", "BatchMode=yes"] }
        if c.auth == .password { o += ["-o", "NumberOfPasswordPrompts=1", "-o", "PreferredAuthentications=password,keyboard-interactive"] }
        if let p = c.port, !c.sshConfigAlias || p != 22 { o += [scp ? "-P" : "-p", "\(p)"] }
        if c.auth == .key, !c.keyPath.isEmpty { o += ["-i", (c.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        return o
    }

    /// Is the shared connection up?
    public static func masterAlive(_ c: Connection) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)
        p.arguments = ["-o", "ControlPath=\(controlDir)/%C", "-O", "check"] + portArgs(c) + ["--", destination(c)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func portArgs(_ c: Connection) -> [String] {
        if let p = c.port, !c.sshConfigAlias || p != 22 { return ["-p", "\(p)"] }
        return []
    }

    /// Opens the shared connection if needed (10 minutes of idle persistence).
    public static func ensureMaster(_ c: Connection, password: String? = nil) throws {
        try c.validate()
        if masterAlive(c) { return }
        let pw = c.auth == .password ? (password ?? ConnectionSecrets.password(for: c)) : nil
        if c.auth == .password, (pw ?? "").isEmpty {
            throw ToolError("Manca la password per \(c.name): salvala nella connessione o usa una chiave SSH")
        }
        let askpass = try pw.map { try Askpass($0) }
        defer { askpass?.remove() }
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("elio-ssh-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: errFile) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)
        // -f: backgrounds after authentication; the parent's exit status says whether it worked.
        p.arguments = options(c, master: "yes") + ["-o", "ControlPersist=10m", "-f", "-N", "--", destination(c)]
        var env = ProcessInfo.processInfo.environment
        if let askpass { env.merge(askpass.environment) { $1 } }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = try FileHandle(forWritingTo: errFile)
        try p.run()
        let deadline = Date().addingTimeInterval(40)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); throw ToolError("Il server \(c.host) non risponde") }
        guard p.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            throw ToolError(friendly(err, c))
        }
    }

    /// Closes the shared connection.
    public static func closeMaster(_ c: Connection) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)
        p.arguments = ["-o", "ControlPath=\(controlDir)/%C", "-O", "exit"] + portArgs(c) + ["--", destination(c)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    public struct Output: Sendable { public var out: Data; public var err: String; public var status: Int32
        public var text: String { String(decoding: out, as: UTF8.self) } }

    /// Runs a command on the server through the shared connection.
    public static func run(_ c: Connection, _ command: String, stdin: Data? = nil, timeout: TimeInterval = 60) throws -> Output {
        try ensureMaster(c)
        return try exec(sshPath, options(c) + ["--", destination(c), command], stdin: stdin, timeout: timeout)
    }

    /// scp through the shared connection (folders with -r).
    public static func scp(_ c: Connection, _ args: [String], timeout: TimeInterval = 3600) throws -> Output {
        try ensureMaster(c)
        return try exec("/usr/bin/scp", options(c, scp: true) + ["-q", "--"] + args, stdin: nil, timeout: timeout)
    }

    /// host:path for scp (remote shell quoting is not applied by scp's SFTP mode).
    public static func remoteSpec(_ c: Connection, _ path: String) -> String { "\(destination(c)):\(path)" }

    static func exec(_ bin: String, _ args: [String], stdin: Data?, timeout: TimeInterval) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        try p.run()
        if let stdin {
            DispatchQueue.global().async {
                try? inp.fileHandleForWriting.write(contentsOf: stdin)
                try? inp.fileHandleForWriting.close()
            }
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read both pipes concurrently: a chatty stderr must not block stdout.
        let group = DispatchGroup()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        timer.cancel()
        if p.terminationReason == .uncaughtSignal { throw ToolError("Comando interrotto (tempo scaduto dopo \(Int(timeout)) s)") }
        return Output(out: outData, err: String(decoding: errData, as: UTF8.self), status: p.terminationStatus)
    }

    /// ssh's errors, in words.
    static func friendly(_ err: String, _ c: Connection) -> String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.contains("Permission denied") { return "Accesso negato a \(destination(c)): controlla utente, chiave o password." }
        if e.contains("Could not resolve hostname") { return "Host sconosciuto: \(c.host)" }
        if e.contains("Connection refused") { return "Connessione rifiutata da \(c.host) (porta \(c.port ?? 22))." }
        if e.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "La chiave del server \(c.host) è cambiata rispetto a known_hosts: potrebbe essere un attacco o un server reinstallato. Verifica e poi rimuovi la vecchia chiave con ssh-keygen -R \(c.host)."
        }
        if e.contains("timed out") { return "Il server \(c.host) non risponde (timeout)." }
        let lines = e.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("Warning: Permanently added") }
        return lines.isEmpty ? "Connessione SSH a \(c.host) non riuscita" : lines.suffix(3).joined(separator: "\n")
    }

    /// Single-quotes a word for the remote shell.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The command a terminal runs to log in (in `dir` when given).
    public static func terminalArgs(_ c: Connection, dir: String? = nil) throws -> [String] {
        try c.validate()
        var args = [sshPath] + options(c, master: "auto", batch: false) + ["-o", "ControlPersist=10m", "-t", "--", destination(c)]
        let d = dir ?? c.remoteDir
        if !d.isEmpty { args.append("cd \(quote(d)) 2>/dev/null; exec \"$SHELL\" -l") }
        return args
    }
}

/// An SSH_ASKPASS helper that answers once with the password from a private temp file.
public final class Askpass: @unchecked Sendable {
    let dir: URL
    public let environment: [String: String]

    public init(_ password: String) throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("elio-askpass-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pw = dir.appendingPathComponent("p")
        let script = dir.appendingPathComponent("askpass.sh")
        guard fm.createFile(atPath: pw.path, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: script.path, contents: Data("#!/bin/sh\nexec /bin/cat '\(pw.path)'\n".utf8),
                            attributes: [.posixPermissions: 0o700]) else {
            throw ToolError("Non riesco a preparare l'autenticazione SSH")
        }
        environment = ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
    }

    public func remove() { try? FileManager.default.removeItem(at: dir) }
    deinit { remove() }
}

/// Local port forwards (`ssh -N -L`): DB connections through a server, and the user's forwards.
public final class SSHTunnels: @unchecked Sendable {
    public static let shared = SSHTunnels()
    private let lock = NSLock()
    private var tunnels: [String: (process: Process, port: Int, lastUse: Date)] = [:]

    public static func key(_ ssh: Connection, _ host: String, _ port: Int, local: Int? = nil) -> String {
        "\(ssh.id)|\(host)|\(port)|\(local ?? 0)"
    }

    /// Opens (or reuses) a tunnel and returns the local port. `localPort` nil → a free one.
    public func open(ssh: Connection, remoteHost: String, remotePort: Int, localPort: Int? = nil) throws -> Int {
        try ssh.validate()
        guard Connection.isValidHost(remoteHost, allowColon: false) || (remoteHost.hasPrefix("[") && Connection.isValidHost(remoteHost)),
              (1...65535).contains(remotePort), localPort.map({ (1...65535).contains($0) }) ?? true else {
            throw ToolError("Destinazione del tunnel non valida: \(remoteHost):\(remotePort)")
        }
        let key = Self.key(ssh, remoteHost, remotePort, local: localPort)
        if let t = lock.withLock({ tunnels[key] }), t.process.isRunning {
            lock.withLock { tunnels[key]?.lastUse = Date() }
            return t.port
        }
        let port = localPort ?? Self.freePort()
        let pw = ssh.auth == .password ? ConnectionSecrets.password(for: ssh) : nil
        if ssh.auth == .password, (pw ?? "").isEmpty { throw ToolError("Manca la password per \(ssh.name)") }
        let askpass = try pw.map { try Askpass($0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHRunner.sshPath)
        // Its own connection (ControlPath=none): it lives as long as the DB session, not the shared master.
        var opts = SSHRunner.options(ssh)
        if let i = opts.firstIndex(of: "ControlPath=\(SSHRunner.controlDir)/%C") { opts[i] = "ControlPath=none" }
        p.arguments = opts + ["-o", "ExitOnForwardFailure=yes", "-N", "-L", "127.0.0.1:\(port):\(remoteHost):\(remotePort)", "--", SSHRunner.destination(ssh)]
        var env = ProcessInfo.processInfo.environment
        if let askpass { env.merge(askpass.environment) { $1 } }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        defer { askpass?.remove() }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !p.isRunning {
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ToolError(e.contains("Address already in use") || e.contains("cannot listen")
                                ? "La porta locale \(port) è già occupata" : SSHRunner.friendly(e, ssh))
            }
            if Self.canConnect(port) {
                lock.withLock { tunnels[key] = (p, port, Date()) }
                return port
            }
            usleep(100_000)
        }
        p.terminate()
        throw ToolError("Il tunnel SSH verso \(ssh.host) non si è aperto in tempo")
    }

    public func close(ssh: Connection, remoteHost: String, remotePort: Int, localPort: Int? = nil) {
        let key = Self.key(ssh, remoteHost, remotePort, local: localPort)
        if let t = lock.withLock({ tunnels.removeValue(forKey: key) }), t.process.isRunning { t.process.terminate() }
    }

    public func isOpen(ssh: Connection, remoteHost: String, remotePort: Int, localPort: Int? = nil) -> Bool {
        lock.withLock { tunnels[Self.key(ssh, remoteHost, remotePort, local: localPort)]?.process.isRunning ?? false }
    }

    /// Closes tunnels unused for `idle` seconds (the daemon's, opened for one query).
    public func closeIdle(_ idle: TimeInterval) {
        let stale = lock.withLock { tunnels.filter { Date().timeIntervalSince($0.value.lastUse) > idle } }
        for (k, t) in stale { t.process.terminate(); lock.withLock { _ = tunnels.removeValue(forKey: k) } }
    }

    public func closeAll() {
        let all = lock.withLock { defer { tunnels = [:] }; return tunnels }
        all.values.forEach { if $0.process.isRunning { $0.process.terminate() } }
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

/// Opens a database session: password from the Keychain, through an SSH tunnel when configured.
public enum DBConnector {
    public static func open(_ c: Connection, database: String? = nil, readOnly: Bool = false, password: String? = nil) throws -> DBSession {
        var endpoint: (String, Int)? = nil
        let secret = password ?? ConnectionSecrets.password(for: c)
        var c = c
        if !c.ddevRoot.isEmpty {
            let d = try DDEV.describe(c.ddevRoot)
            guard d.running, let port = d.port else { throw ToolError("Il progetto DDEV \(d.name) è fermo: avvialo con ddev start") }
            c.host = "127.0.0.1"; c.port = port
            if c.user.isEmpty { c.user = d.user }
        }
        if !c.sshVia.isEmpty, c.kind != .sqlite {
            guard let ssh = ConnectionStore.byId(c.sshVia, kinds: [.ssh]) else { throw ToolError("Host SSH del tunnel non trovato (\(c.sshVia))") }
            let remoteHost = c.host.isEmpty ? "127.0.0.1" : c.host
            let port = try SSHTunnels.shared.open(ssh: ssh, remoteHost: remoteHost, remotePort: c.effectivePort)
            endpoint = ("127.0.0.1", port)
        }
        let s = DBSession(connection: c, database: database, readOnly: readOnly, endpoint: endpoint)
        try s.start(password: password ?? ConnectionSecrets.password(for: c))
        return s
    }
}

/// One entry of a remote folder.
public struct RemoteEntry: Equatable, Sendable {
    public var name: String
    public var type: String       // d, f, l
    public var targetIsDir: Bool
    public var size: Int64
    public var mtime: Double
    public var mode: String
    public var owner: String

    public var dictionary: [String: Any] {
        ["name": name, "type": type, "dir": type == "d" || (type == "l" && targetIsDir), "link": type == "l", "size": size,
         "mtime": mtime, "mode": mode, "owner": owner]
    }
}

public enum RemoteFS {
    /// Lists a folder: GNU find where available, a portable stat loop otherwise (BSD/macOS servers).
    public static func listCommand(_ path: String) -> String {
        let q = SSHRunner.quote(path)
        return "cd \(q) && { find . -mindepth 1 -maxdepth 1 -printf '%y\\t%Y\\t%s\\t%T@\\t%m\\t%u\\t%f\\n' 2>/dev/null || "
            + "for f in .[!.]* ..?* *; do [ -e \"$f\" ] || [ -L \"$f\" ] || continue; "
            + "if [ -L \"$f\" ]; then t=l; elif [ -d \"$f\" ]; then t=d; else t=f; fi; if [ -d \"$f\" ]; then y=d; else y=f; fi; "
            + "printf '%s\\t%s\\t' \"$t\" \"$y\"; stat -n -f '%z%t%m%t%Lp%t%Su%t' \"$f\"; printf '%s\\n' \"$f\"; done; }"
    }

    /// Parses `type \t targetType \t size \t mtime \t mode \t owner \t name` lines.
    public static func parseListing(_ text: String) -> [RemoteEntry] {
        var out: [RemoteEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let p = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 7, !p[6].isEmpty, p[6] != ".", p[6] != ".." else { continue }
            out.append(RemoteEntry(name: p[6], type: p[0] == "d" ? "d" : p[0] == "l" ? "l" : "f", targetIsDir: p[1] == "d",
                                   size: Int64(p[2]) ?? 0, mtime: Double(p[3]) ?? 0, mode: p[4], owner: p[5]))
        }
        return out.sorted {
            let d0 = $0.dictionary["dir"] as? Bool ?? false, d1 = $1.dictionary["dir"] as? Bool ?? false
            if d0 != d1 { return d0 }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// mtime of one file (GNU or BSD stat).
    public static func mtimeCommand(_ path: String) -> String {
        let q = SSHRunner.quote(path)
        return "stat -c %Y \(q) 2>/dev/null || stat -f %m \(q)"
    }
}
