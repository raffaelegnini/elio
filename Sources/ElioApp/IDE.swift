import AppKit
import CoreServices
import ElioCore
import ElioVoice
import Observation
import UniformTypeIdentifiers
import WebKit

/// Elio's IDE: Monaco (the VS Code editor) and xterm.js terminals in a native window, with the file system,
/// git, search, shells and the agents bridged from Swift. The page lives in `ide/` (bundled in the app);
/// it talks to `IDEBridge` through `window.webkit.messageHandlers.elio` (request → reply) and receives
/// events (terminal output, file changes, agents) through `window.__elio.event(name, data)`.
@MainActor
final class IDEWindowController: NSObject, NSWindowDelegate {
    static let shared = IDEWindowController()

    private var window: IDEWindow?
    private var webView: WKWebView?
    private var bridge: IDEBridge?
    private weak var loop: VoiceLoop?
    private var pendingOpen: [String: Any]?
    private var ready = false

    /// Opens the IDE (on a folder or a file, at a line).
    func show(loop: VoiceLoop?, path: String? = nil, line: Int = 0) {
        self.loop = loop
        if window == nil { build() }
        if let path, !path.isEmpty {
            let open: [String: Any] = ["path": path, "line": line]
            if ready { bridge?.emit("open", open) } else { pendingOpen = open }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The terminal of an agent, in front.
    func showAgent(loop: VoiceLoop?, taskId: String, cwd: String?) {
        show(loop: loop, path: cwd)
        let open: [String: Any] = ["agent": taskId]
        if ready { bridge?.emit("openAgent", open) } else { pendingAgent = open }
    }
    private var pendingAgent: [String: Any]?

    private func build() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(IDESchemeHandler(), forURLScheme: "elio-ide")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let bridge = IDEBridge(loop: loop)
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "elio")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        bridge.webView = web
        bridge.onReady = { [weak self] in
            guard let self else { return }
            self.ready = true
            if let open = self.pendingOpen { bridge.emit("open", open); self.pendingOpen = nil }
            if let agent = self.pendingAgent { bridge.emit("openAgent", agent); self.pendingAgent = nil }
        }
        bridge.onTitle = { [weak self] title in self?.window?.title = title }

        let w = IDEWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        w.title = "Elio IDE"
        // A real title bar: the window can be dragged, and it shows the project.
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        w.contentView = web
        w.setFrameAutosaveName("ElioIDE")
        if w.frame.origin == .zero { w.center() }
        w.delegate = self
        w.tabbingMode = .disallowed
        w.bridge = bridge
        window = w
        webView = web
        self.bridge = bridge
        web.load(URLRequest(url: URL(string: "elio-ide://app/index.html")!))
    }

    func windowWillClose(_ notification: Notification) {
        // Terminals keep running while the window is closed: reopening finds them as they were.
        window?.orderOut(nil)
    }

    /// Where the IDE page is: inside the app, or the repo's `ide/` folder when running from source.
    static var root: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ide"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ide")
    }
}

/// Key equivalents go to the page first (Monaco handles Cmd+Z, Cmd+W…); what it doesn't take reaches the menu.
final class IDEWindow: NSWindow {
    weak var bridge: IDEBridge?
}

/// Serves `ide/` as elio-ide://app/… (same origin: Monaco's web workers can start).
final class IDESchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let root = MainActor.assumeIsolated { IDEWindowController.root }
        let file = root.appendingPathComponent(rel.isEmpty ? "index.html" : rel).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = ["Content-Type": mime == "text/javascript" ? "application/javascript" : mime,
                       "Content-Length": "\(data.count)", "Cache-Control": "no-cache"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: - Bridge

@MainActor
final class IDEBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var webView: WKWebView?
    private weak var loop: VoiceLoop?
    var onReady: (() -> Void)?
    var onTitle: ((String) -> Void)?
    private var ptys: [String: PTY] = [:]
    private var watcher: DirWatcher?
    private var agentsObserved = false
    private var sentLogCounts: [String: Int] = [:]

    init(loop: VoiceLoop?) { self.loop = loop }

    /// Sends an event to the page.
    func emit(_ name: String, _ payload: Any) {
        guard let webView, let data = try? JSONSerialization.data(withJSONObject: ["name": name, "data": payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__elio && window.__elio.event(\(json))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "messaggio non valido")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        let box = ArgsBox(args)
        Task { @MainActor in
            do {
                replyHandler(try await self.handle(op, box.value), nil)
            } catch {
                replyHandler(nil, "\(error)")
            }
        }
    }

    private final class ArgsBox: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }

    private func handle(_ op: String, _ a: [String: Any]) async throws -> Any? {
        func str(_ k: String) -> String { a[k] as? String ?? "" }
        switch op {
        case "ready":
            onReady?()
            observeAgents()
            return nil
        case "title":
            onTitle?(str("title"))
            return nil
        case "projects":
            return await Task.detached { IDEFiles.projects() }.value
        case "watch":
            watch(str("root"))
            return nil
        case "list":
            let path = str("path")
            return try await Task.detached { try IDEFiles.list(path) }.value
        case "read":
            let path = str("path")
            return try await Task.detached { try IDEFiles.read(path) }.value
        case "write":
            let path = str("path"), content = str("content")
            return try await Task.detached { try IDEFiles.write(path, content) }.value
        case "create":
            let path = str("path"), dir = a["dir"] as? Bool ?? false
            try await Task.detached { try IDEFiles.create(path, dir: dir) }.value
            return nil
        case "rename":
            let from = str("from"), to = str("to")
            try await Task.detached { try FileManager.default.moveItem(atPath: from, toPath: to) }.value
            return nil
        case "trash":
            let path = str("path")
            try await NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
            return nil
        case "files":
            let root = str("root")
            return await Task.detached { IDEFiles.allFiles(root) }.value
        case "search":
            let root = str("root"), q = str("query"), regex = a["regex"] as? Bool ?? false, cs = a["case"] as? Bool ?? false
            return await Task.detached { IDEFiles.search(root: root, query: q, regex: regex, caseSensitive: cs) }.value
        case "git":
            let root = str("root"), cmd = str("cmd"), args = a["args"] as? [String] ?? []
            return await Task.detached { IDEGit.run(root: root, cmd: cmd, args: args) }.value
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: str("path"))])
            return nil
        case "openExternal":
            // "Apri in PhpStorm" (or any app by name), else the default app.
            let path = str("path"), app = str("app")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = app.isEmpty ? [path] : ["-a", app, path]
            try p.run()
            return nil
        case "ptyCreate":
            return try createPTY(cwd: str("cwd"), cols: a["cols"] as? Int ?? 100, rows: a["rows"] as? Int ?? 30,
                                 command: (a["command"] as? String).map { [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "-lc", $0] })
        case "ptyWrite":
            if let b64 = a["data"] as? String, let data = Data(base64Encoded: b64) { ptys[str("id")]?.write(data) }
            else { ptys[str("id")]?.write(Data(str("text").utf8)) }
            return nil
        case "ptyResize":
            ptys[str("id")]?.resize(cols: a["cols"] as? Int ?? 80, rows: a["rows"] as? Int ?? 24)
            return nil
        case "ptyKill":
            ptys[str("id")]?.kill()
            return nil
        case "ptyList":
            return ptys.values.map { ["id": $0.id, "cwd": $0.cwd] }
        case "agents":
            return agentsPayload()
        case "agentLog":
            let id = str("id")
            let log = loop?.taskLogs[id] ?? []
            sentLogCounts[id] = log.count
            return log.map(Self.logPayload)
        case "agentSend":
            guard let loop else { return "Elio non è collegato." }
            let (reply, _) = await loop.callTool("agent_message", ["id": str("id"), "text": str("text")])
            return reply
        case "agentControl":
            loop?.controlTask(str("id"), str("action"))
            return nil
        case "askElio":
            loop?.submit(text: str("text"))
            return nil
        case "closeWindow":
            webView?.window?.performClose(nil)
            return nil
        default:
            throw ToolError("operazione sconosciuta: \(op)")
        }
    }

    // MARK: Terminals

    private func createPTY(cwd: String, cols: Int, rows: Int, command: [String]?) throws -> [String: Any] {
        let dir = cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : cwd
        let pty = PTY(cwd: dir)
        let id = pty.id
        pty.onData = { [weak self] data in self?.emit("ptyData", ["id": id, "data": data.base64EncodedString()]) }
        pty.onExit = { [weak self] code in
            self?.emit("ptyExit", ["id": id, "code": Int(code)])
            self?.ptys[id] = nil
        }
        try pty.start(cols: cols, rows: rows, command: command)
        ptys[id] = pty
        return ["id": id, "cwd": dir]
    }

    // MARK: Files changing on disk (agents at work)

    private func watch(_ root: String) {
        guard !root.isEmpty else { return }
        watcher = DirWatcher(path: root) { [weak self] paths in
            self?.emit("fsChanged", ["paths": paths])
        }
    }

    // MARK: Agents

    private func agentsPayload() -> [[String: Any]] {
        (loop?.tasks ?? []).reversed().prefix(30).map { t in
            var o: [String: Any] = ["id": t.id, "title": t.title, "status": t.status.rawValue, "kind": t.kind ?? "code"]
            o["member"] = t.member ?? ""
            o["cwd"] = t.cwd ?? ""
            o["project"] = t.project ?? ""
            o["now"] = AgentActivity.now(t, log: loop?.taskLogs[t.id] ?? [])
            o["model"] = t.model ?? ""
            if let p = AgentActivity.progress(t) { o["progress"] = [p.done, p.total] }
            return o
        }
    }

    static func logPayload(_ e: TaskLogEntry) -> [String: Any] {
        ["kind": e.kind.rawValue, "title": e.title, "body": e.body, "removed": e.removed ?? "", "added": e.added ?? "",
         "at": e.date.timeIntervalSince1970]
    }

    /// Pushes agent state and new log lines to the page while it's open.
    private func observeAgents() {
        guard !agentsObserved, let loop else { return }
        agentsObserved = true
        func track() {
            withObservationTracking {
                _ = loop.tasks
                _ = loop.taskLogs
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.emit("agents", self.agentsPayload())
                    for (id, log) in loop.taskLogs {
                        let sent = self.sentLogCounts[id] ?? log.count
                        if log.count > sent {
                            self.emit("agentLog", ["id": id, "entries": log[sent...].map(Self.logPayload)])
                        }
                        self.sentLogCounts[id] = log.count
                    }
                    track()
                }
            }
        }
        track()
    }
}

// MARK: - Files

enum IDEFiles {
    static let ignoredNames: Set<String> = [".git", ".DS_Store", "node_modules", ".build", "DerivedData", ".idea", ".dart_tool",
                                            "vendor", ".next", ".nuxt", "Pods", ".gradle", "__pycache__", ".turbo"]

    /// Project folders from Settings with their git repositories.
    static func projects() -> [[String: Any]] {
        let config = ElioConfig.load()
        var out: [[String: Any]] = []
        // Elio's own code first: it can be edited (and Elio rebuilt) from here.
        if let me = ElioPaths.selfSource { out.append(["name": "Elio · il mio codice", "path": me, "stack": "swift", "self": true]) }
        for repo in ProjectTree.scan(roots: config.projectRoots).flatMap(\.repos) {
            out.append(["name": repo.name, "path": repo.path, "stack": repo.stack ?? ""])
        }
        let me = out.first { $0["self"] as? Bool == true }
        let rest = out.filter { $0["self"] as? Bool != true }.sorted { ($0["name"] as? String ?? "").lowercased() < ($1["name"] as? String ?? "").lowercased() }
        return (me.map { [$0] } ?? []) + rest.filter { ($0["path"] as? String) != (me?["path"] as? String) }
    }

    static func list(_ path: String) throws -> [[String: Any]] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        var out: [[String: Any]] = []
        for name in names where name != ".DS_Store" && name != ".git" {
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            out.append(["name": name, "path": full, "dir": isDir.boolValue, "dim": ignoredNames.contains(name) || name.hasPrefix(".")])
        }
        return out.sorted {
            let d0 = $0["dir"] as? Bool ?? false, d1 = $1["dir"] as? Bool ?? false
            if d0 != d1 { return d0 }
            return ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending
        }
    }

    static func read(_ path: String) throws -> [String: Any] {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? Int) ?? 0
        guard size < 8_000_000 else { throw ToolError("File troppo grande per l'editor (\(size / 1_000_000) MB)") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.prefix(8000).contains(0) { return ["binary": true, "size": size] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return ["content": text, "mtime": (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, "size": size]
    }

    static func write(_ path: String, _ content: String) throws -> [String: Any] {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return ["mtime": (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0]
    }

    static func create(_ path: String, dir: Bool) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { throw ToolError("Esiste già") }
        if dir { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        else {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data())
        }
    }

    /// Every file of the project (for Go to file / Search everywhere): git's view when it's a repo.
    static func allFiles(_ root: String) -> [String] {
        if let out = try? shell("/usr/bin/git", ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard"]),
           !out.isEmpty {
            return out.split(separator: "\n").prefix(60_000).map(String.init)
        }
        var files: [String] = []
        let base = URL(fileURLWithPath: root)
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL, files.count < 30_000 {
            if ignoredNames.contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false {
                files.append(String(url.path.dropFirst(base.path.count + 1)))
            }
        }
        return files
    }

    /// Find in path: git grep in repos (respects .gitignore, includes untracked), grep elsewhere.
    static func search(root: String, query: String, regex: Bool, caseSensitive: Bool) -> [[String: Any]] {
        guard !query.isEmpty else { return [] }
        var args = ["-C", root, "grep", "-n", "-I", "--untracked", "--column", "--no-color", "-e", query]
        if !regex { args.insert("-F", at: 4) }
        if !caseSensitive { args.insert("-i", at: 4) }
        var raw = (try? shell("/usr/bin/git", args)) ?? ""
        if raw.isEmpty, !FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) {
            var g = ["-rnI", "--exclude-dir=node_modules", "--exclude-dir=.git", "--exclude-dir=vendor", "--exclude-dir=.build"]
            if !regex { g.append("-F") }
            if !caseSensitive { g.append("-i") }
            raw = (try? shell("/usr/bin/grep", g + ["-e", query, root])) ?? ""
        }
        var out: [[String: Any]] = []
        for line in raw.split(separator: "\n").prefix(800) {
            let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            var file = String(parts[0])
            if file.hasPrefix(root + "/") { file = String(file.dropFirst(root.count + 1)) }
            let lineNo = Int(parts[1]) ?? 0
            let hasCol = parts.count == 4 && Int(parts[2]) != nil
            let col = hasCol ? Int(parts[2]) ?? 1 : 1
            let text = hasCol ? String(parts[3]) : parts.dropFirst(2).joined(separator: ":")
            out.append(["file": file, "line": lineNo, "col": col, "text": String(text.prefix(300))])
        }
        return out
    }
}

// MARK: - Git

enum IDEGit {
    /// The git operations the IDE needs, with their output parsed for the page.
    static func run(root: String, cmd: String, args: [String]) -> [String: Any] {
        func git(_ a: [String]) -> (String, Bool) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root] + a
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return ("\(error)", false) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return p.terminationStatus == 0 ? (text, true) : (text + String(decoding: errData, as: UTF8.self), false)
        }
        switch cmd {
        case "status":
            let (out, ok) = git(["status", "--porcelain=v1", "-b", "-uall"])
            guard ok else { return ["repo": false] }
            var branch = "", ahead = 0, behind = 0
            var files: [[String: String]] = []
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("## ") {
                    let b = line.dropFirst(3)
                    branch = String(b.split(separator: ".").first ?? b).split(separator: " ").first.map(String.init) ?? ""
                    if let r = b.range(of: #"ahead (\d+)"#, options: .regularExpression) { ahead = Int(b[r].split(separator: " ").last ?? "0") ?? 0 }
                    if let r = b.range(of: #"behind (\d+)"#, options: .regularExpression) { behind = Int(b[r].split(separator: " ").last ?? "0") ?? 0 }
                    continue
                }
                guard line.count > 3 else { continue }
                let code = String(line.prefix(2))
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                files.append(["code": code, "path": path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))])
            }
            return ["repo": true, "branch": branch, "ahead": ahead, "behind": behind, "files": files]
        case "show":
            // The file as it is in HEAD (for the gutter markers and the diff).
            let (out, ok) = git(["show", "HEAD:\(args.first ?? "")"])
            return ["content": ok ? out : "", "exists": ok]
        case "log":
            let (out, _) = git(["log", "-40", "--pretty=format:%h\u{1f}%an\u{1f}%ar\u{1f}%s", "--"] + args)
            return ["commits": out.split(separator: "\n").map { line in
                let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                return ["hash": p[safe: 0] ?? "", "author": p[safe: 1] ?? "", "when": p[safe: 2] ?? "", "subject": p[safe: 3] ?? ""]
            }]
        case "branches":
            let (out, _) = git(["branch", "--format=%(refname:short)"])
            return ["branches": out.split(separator: "\n").map(String.init)]
        case "commit":
            // args: [message, paths…] (no paths = everything).
            let message = args.first ?? ""
            let paths = Array(args.dropFirst())
            let (addOut, addOk) = git(["add"] + (paths.isEmpty ? ["-A"] : ["--"] + paths))
            guard addOk else { return ["ok": false, "output": addOut] }
            let (out, ok) = git(["commit", "-m", message])
            return ["ok": ok, "output": out]
        case "push":
            let (out, ok) = git(["push"])
            return ["ok": ok, "output": out]
        case "pull":
            let (out, ok) = git(["pull", "--ff-only"])
            return ["ok": ok, "output": out]
        case "checkout":
            let (out, ok) = git(["checkout"] + args)
            return ["ok": ok, "output": out]
        case "rollback":
            // Discard local changes of one file (the page asks first).
            let (out, ok) = git(["checkout", "HEAD", "--"] + args)
            return ["ok": ok, "output": out]
        default:
            return ["ok": false, "output": "comando git non previsto"]
        }
    }
}

// MARK: - File system events

/// Folder changes (agents writing files, git checkouts) reported in batches.
final class DirWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor ([String]) -> Void

    init(path: String, onChange: @escaping @MainActor ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let relevant = list.prefix(count).filter { !$0.contains("/.git/") && !$0.contains("/node_modules/") }
            guard !relevant.isEmpty else { return }
            let changed = Array(relevant)
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange(changed) } }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
