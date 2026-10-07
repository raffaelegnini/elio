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
    private var pendingActions: [[String: Any]] = []
    private let navGuard = IDENavigationGuard()

    /// Runs an IDE action from outside the page (the native menu): commit, push, gitLog, terminal…
    func perform(_ action: String, loop: VoiceLoop? = nil, _ extra: [String: Any] = [:]) {
        show(loop: loop ?? self.loop)
        var payload = extra
        payload["action"] = action
        if ready { bridge?.emit("ideAction", payload) } else { pendingActions.append(payload) }
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(IDESchemeHandler(), forURLScheme: "elio-ide")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let bridge = IDEBridge(loop: loop)
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "elio")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        // The bridge runs shells and git: the web view only ever shows our own elio-ide:// page.
        web.navigationDelegate = navGuard
        web.uiDelegate = navGuard
        bridge.webView = web
        bridge.onReady = { [weak self] in
            guard let self else { return }
            self.ready = true
            if let open = self.pendingOpen { bridge.emit("open", open); self.pendingOpen = nil }
            if let agent = self.pendingAgent { bridge.emit("openAgent", agent); self.pendingAgent = nil }
            self.pendingActions.forEach { bridge.emit("ideAction", $0) }
            self.pendingActions = []
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

/// Keeps the IDE web view on its own page: main-frame navigations only to elio-ide://app/, links and
/// window.open (Monaco links, terminal links) go to the default browser when they are http(s) or mailto, never
/// file://, javascript: or custom schemes; no new windows.
@MainActor
final class IDENavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    static func isOwnPage(_ url: URL?) -> Bool { url?.scheme?.lowercased() == "elio-ide" && url?.host == "app" }

    /// Only these leave the app (to the default browser / mail client).
    static func externalURL(_ s: String) -> URL? {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url
        default: return nil
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if Self.isOwnPage(url) { decisionHandler(.allow); return }
        // Subframes may load about:blank / blob: from our own page (Monaco, xterm); never anything remote.
        if !(action.targetFrame?.isMainFrame ?? true), let scheme = url?.scheme?.lowercased(), ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true,
           let u = url.flatMap({ Self.externalURL($0.absoluteString) }) {
            NSWorkspace.shared.open(u)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url.flatMap({ Self.externalURL($0.absoluteString) }) { NSWorkspace.shared.open(u) }
        return nil
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
    private var watchers: [String: DirWatcher] = [:]
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
        // Only our own page's main frame may call the bridge (not an iframe, not a page navigated elsewhere).
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "elio-ide",
              message.frameInfo.securityOrigin.host == "app" else {
            replyHandler(nil, "origine non consentita")
            return
        }
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
            // Every root of the workspace (several projects open at once).
            watch(a["roots"] as? [String] ?? [str("root")])
            return nil
        case "pickFolder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Aggiungi al workspace"
            panel.message = "Scegli le cartelle da aprire nel workspace"
            if let first = ElioConfig.load().projectRoots.first {
                panel.directoryURL = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
            }
            let response: NSApplication.ModalResponse
            if let window = webView?.window { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
            return response == .OK ? panel.urls.map(\.path) : []
        case "check":
            let path = str("path")
            return await Task.detached { IDEChecks.check(path: path) }.value
        case "checkDeep":
            let path = str("path"), root = str("root")
            return await Task.detached { IDEChecks.deep(path: path, root: root) }.value
        case "tsc":
            let root = str("root")
            return await Task.detached { IDEChecks.tsc(root: root) }.value
        case "runScripts":
            let root = str("root")
            return await Task.detached { IDERun.detect(root: root) }.value
        case "runConfigs.get":
            let root = str("root")
            return await Task.detached { IDERun.load(root: root) }.value
        case "runConfigs.set":
            let root = str("root"), configs = ArgsBox(["c": a["configs"] as? [[String: Any]] ?? []])
            try await Task.detached { try IDERun.save(root: root, configs: configs.value["c"] as? [[String: Any]] ?? []) }.value
            return nil
        case "trust.get":
            let root = str("root")
            return await Task.detached { IDETrust.isTrusted(root) }.value
        case "trust.set":
            let root = str("root"), value = a["trusted"] as? Bool ?? false
            try await Task.detached { try IDETrust.set(root, trusted: value) }.value
            return nil
        case "elioState":
            return elioState()
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
            let opts = ArgsBox(a["opts"] as? [String: Any] ?? [:])
            return await Task.detached { IDEGit.run(root: root, cmd: cmd, args: args, opts: opts.value) }.value
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: str("path"))])
            return nil
        case "openExternal":
            // A web link (terminal, editor): http(s)/mailto only, to the default browser.
            if !str("url").isEmpty {
                guard let u = IDENavigationGuard.externalURL(str("url")) else { throw ToolError("Link non consentito: solo http, https e mailto") }
                NSWorkspace.shared.open(u)
                return nil
            }
            // A local file: "Apri in PhpStorm", else its default app (never one that would run it).
            let path = str("path"), app = str("app")
            try IDEFiles.checkOpenable(path, app: app)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = app.isEmpty ? [path] : ["-a", app, path]   // path is absolute: never an option
            try p.run()
            return nil
        case "ptyCreate":
            // `command`: a shell line (run by the login shell); `argv`: an exact argument list (ssh -p 22 user@host).
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            var command = (a["command"] as? String).map { [shell, "-lc", $0] }
            if let argv = a["argv"] as? [String], !argv.isEmpty {
                command = [shell, "-lc", "exec \"$@\"", "elio"] + argv
            }
            return try createPTY(cwd: str("cwd"), cols: a["cols"] as? Int ?? 100, rows: a["rows"] as? Int ?? 30, command: command)
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
        case "pageError":
            // The page has no visible console: its errors go to a log file.
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Elio", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(str("kind")): \(str("message"))\n\(str("where"))\n"
            let file = dir.appendingPathComponent("ide.log")
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: file) }
            return nil
        case "closeWindow":
            webView?.window?.performClose(nil)
            return nil
        default:
            if IDEConnections.handles(op) {
                IDEConnections.shared.emit = { [weak self] name, payload in self?.emit(name, payload) }
                return try await IDEConnections.shared.handle(op, a)
            }
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

    private func watch(_ roots: [String]) {
        let wanted = Set(roots.filter { !$0.isEmpty })
        for root in watchers.keys where !wanted.contains(root) { watchers[root] = nil }
        for root in wanted where watchers[root] == nil {
            watchers[root] = DirWatcher(path: root) { [weak self] paths, gitTouched in
                if !paths.isEmpty { self?.emit("fsChanged", ["paths": paths, "root": root]) }
                // Commits, checkouts, pulls made outside the IDE (terminal, agents): refresh git state.
                if gitTouched { self?.emit("gitChanged", ["root": root]) }
            }
        }
    }

    private func elioState() -> [String: Any] {
        ["state": loop?.state.rawValue ?? "off", "connected": loop?.connected ?? false]
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
        func trackState() {
            withObservationTracking {
                _ = loop.state
                _ = loop.connected
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.emit("elioState", self.elioState())
                    trackState()
                }
            }
        }
        trackState()
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

    /// Apps the page may name for "open with".
    static let externalApps: Set<String> = ["PhpStorm"]
    /// Types the default app would execute or that redirect elsewhere (a binary double-clicked in a cloned repo).
    static let runnableExtensions: Set<String> = ["app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "fish",
                                                  "py", "rb", "pl", "php", "js", "scpt", "scptd", "applescript", "workflow",
                                                  "action", "jar", "pkg", "mpkg", "dmg", "webloc", "inetloc", "fileloc", "url",
                                                  "shortcut", "prefpane", "saver", "kext", "plugin", "bundle", "osax", "mobileconfig",
                                                  "configprofile", "itermcolors", "terminalprofile"]

    /// An absolute path to an existing file, opened only in an allowed app or with a default app that won't run it.
    static func checkOpenable(_ path: String, app: String) throws {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw ToolError("File non trovato") }
        if !app.isEmpty {
            guard externalApps.contains(app) else { throw ToolError("App non consentita: \(app)") }
            return
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let runnable = isDir.boolValue || runnableExtensions.contains(ext) || FileManager.default.isExecutableFile(atPath: path)
            || [UTType.executable, .application, .applicationBundle, .script, .shellScript, .package, .bundle]
                .contains { type?.conforms(to: $0) == true }
        if runnable { throw ToolError("Per sicurezza non apro questo file con l'app predefinita: potrebbe eseguirlo. Usa Mostra nel Finder.") }
    }

    /// Every file of the project (for Go to file / Search everywhere): git's view when it's a repo.
    static func allFiles(_ root: String) -> [String] {
        // Hardened like every IDE git call: a cloned repo's core.fsmonitor must not run on "Go to file".
        let r = IDEGit.git(root, ["ls-files", "--cached", "--others", "--exclude-standard"], timeout: 30)
        if r.ok, !r.out.isEmpty {
            return r.out.split(separator: "\n").prefix(60_000).map(String.init)
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
        var args = ["grep", "-n", "-I", "--untracked", "--column", "--no-color", "-e", query]
        if !regex { args.insert("-F", at: 2) }
        if !caseSensitive { args.insert("-i", at: 2) }
        let g = IDEGit.git(root, args, timeout: 60)
        var raw = g.ok ? g.out : ""
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

// MARK: - File system events

/// Folder changes (agents writing files, git checkouts) reported in batches.
final class DirWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor ([String], Bool) -> Void

    init(path: String, onChange: @escaping @MainActor ([String], Bool) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let all = list.prefix(count)
            let relevant = all.filter { !$0.contains("/.git/") && !$0.contains("/node_modules/") }
            // Only the files that mean "the repo moved": HEAD, the index, refs (not objects or our own reads).
            let gitTouched = all.contains { p in
                guard let r = p.range(of: "/.git/") else { return false }
                let rest = p[r.upperBound...]
                return rest == "HEAD" || rest == "index" || rest.hasPrefix("refs/") || rest == "MERGE_HEAD" || rest == "packed-refs"
            }
            guard !relevant.isEmpty || gitTouched else { return }
            let changed = Array(relevant)
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange(changed, gitTouched) } }
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
