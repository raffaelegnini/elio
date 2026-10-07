import ElioCore
import Foundation

// MARK: - Processes

/// Runs command-line tools for the IDE off the main thread, with a timeout and never waiting on a terminal.
enum IDEProc {
    struct Output: Sendable {
        var out: String
        var err: String
        var code: Int32
        var timedOut: Bool
        var ok: Bool { code == 0 && !timedOut }
        var all: String { err.isEmpty ? out : out.isEmpty ? err : out + "\n" + err }
    }

    static func run(_ exe: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 30,
                    env extra: [String: String] = [:], stdin: Data? = nil) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd, !cwd.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ToolEnv.environment
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return Output(out: "", err: "\(error)", code: -1, timedOut: false) }
        if let stdin {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        // stderr on its own thread: a chatty tool must not block on a full pipe while we read stdout.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let timer = DispatchWorkItem { if p.isRunning { errBox.timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        timer.cancel()
        return Output(out: String(decoding: data, as: UTF8.self), err: String(decoding: errBox.data, as: UTF8.self),
                      code: p.terminationStatus, timedOut: errBox.timedOut)
    }

    private final class DataBox: @unchecked Sendable { var data = Data(); var timedOut = false }
}

/// The user's PATH as their login shell sees it (GUI apps get a bare one: no Homebrew, nvm, Herd…).
enum ToolEnv {
    static let path: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "printf '\\n__ELIO__%s__ELIO__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        guard (try? p.run()) != nil else { return fallback }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let a = text.range(of: "__ELIO__"), let b = text.range(of: "__ELIO__", range: a.upperBound..<text.endIndex) else { return fallback }
        let found = String(text[a.upperBound..<b.lowerBound])
        return found.isEmpty ? fallback : found + ":" + fallback
    }()

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }()

    static func which(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":") {
            let full = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}

// MARK: - Problems (checkers)

/// On-save checks of one file with the tools the machine (or the project) has. Fast syntax checks and the
/// slow project analyzers (PHPStan, ESLint) are separate ops so syntax errors show up at once.
enum IDEChecks {
    private static func problem(_ line: Int, _ col: Int = 1, _ message: String, _ source: String, _ sev: String = "error",
                                endLine: Int? = nil, endCol: Int? = nil) -> [String: Any] {
        var p: [String: Any] = ["line": max(1, line), "col": max(1, col), "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
                                "source": source, "severity": sev]
        if let endLine { p["endLine"] = endLine }
        if let endCol { p["endCol"] = endCol }
        return p
    }

    private static func firstInt(_ text: String, _ pattern: String) -> Int? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(text[r].filter(\.isNumber))
    }

    /// Fast syntax check for the file's language. Returns {problems, tool}.
    static func check(path: String) -> [String: Any] {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        var out: [[String: Any]] = []
        var tool = ""
        switch ext {
        case "php", "phtml":
            guard let php = ToolEnv.which("php") else { break }
            tool = "php -l"
            let r = IDEProc.run(php, ["-l", "-d", "display_errors=1", "-d", "error_reporting=E_ALL", path], timeout: 15)
            if !r.ok {
                for line in r.all.split(separator: "\n") where line.contains(" on line ") {
                    let s = String(line)
                    var msg = s.replacingOccurrences(of: #"^(PHP )?(Parse|Fatal) error:\s*"#, with: "", options: .regularExpression)
                    if let r = msg.range(of: " in /") { msg = String(msg[..<r.lowerBound]) }
                    out.append(problem(firstInt(s, #"on line \d+"#) ?? 1, 1, msg, "php"))
                }
            }
        case "js", "mjs", "cjs":
            guard let node = ToolEnv.which("node") else { break }
            tool = "node --check"
            let r = IDEProc.run(node, ["--check", path], timeout: 15)
            if !r.ok {
                let text = r.all
                let line = firstInt(text, #":\d+\n"#) ?? 1
                let msg = text.split(separator: "\n").first { $0.contains("Error:") }.map(String.init) ?? "Errore di sintassi"
                out.append(problem(line, 1, msg, "node"))
            }
        case "py":
            guard let py = ToolEnv.which("python3") else { break }
            tool = "python3"
            // ast.parse instead of py_compile: no __pycache__ left in the project.
            let r = IDEProc.run(py, ["-c", "import ast,sys\ntry:\n ast.parse(open(sys.argv[1],'rb').read(),sys.argv[1])\nexcept SyntaxError as e:\n print(f'{e.lineno or 1}\\t{e.offset or 1}\\t{e.msg}');sys.exit(1)", path], timeout: 15)
            if r.code == 1 {
                let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 2).map(String.init)
                if p.count == 3 { out.append(problem(Int(p[0]) ?? 1, Int(p[1]) ?? 1, p[2], "python")) }
            }
        case "rb":
            guard let ruby = ToolEnv.which("ruby") else { break }
            tool = "ruby -c"
            let r = IDEProc.run(ruby, ["-c", path], timeout: 15)
            if !r.ok {
                for line in r.err.split(separator: "\n") where line.contains(path) {
                    let s = String(line)
                    let msg = s.components(separatedBy: path).last?.replacingOccurrences(of: #"^:\d+:\s*"#, with: "", options: .regularExpression) ?? s
                    out.append(problem(firstInt(s, #":\d+:"#) ?? 1, 1, msg, "ruby"))
                }
            }
        case "sh", "bash", "zsh":
            let shell = ext == "zsh" ? "/bin/zsh" : "/bin/bash"
            tool = "\((shell as NSString).lastPathComponent) -n"
            let r = IDEProc.run(shell, ["-n", path], timeout: 10)
            if !r.ok {
                for line in r.err.split(separator: "\n") {
                    let s = String(line)
                    let n = firstInt(s, #"line \d+"#) ?? firstInt(s, #":\d+:"#) ?? 1
                    let msg = s.components(separatedBy: ": ").dropFirst(ext == "zsh" ? 1 : 2).joined(separator: ": ")
                    out.append(problem(n, 1, msg.isEmpty ? s : msg, "shell"))
                }
            }
        case "swift":
            tool = "swiftc -parse"
            let r = IDEProc.run("/usr/bin/swiftc", ["-parse", path], timeout: 20)
            out += compilerStyle(r.all, path: path, source: "swift")
        case "xml", "xsd", "plist", "svg", "xsl", "wsdl":
            tool = "xmllint"
            let r = IDEProc.run("/usr/bin/xmllint", ["--noout", path], timeout: 15)
            if !r.ok {
                for line in r.err.split(separator: "\n") where line.hasPrefix(path) && line.contains("error") {
                    let s = String(line)
                    let msg = s.components(separatedBy: "error : ").last ?? s
                    out.append(problem(firstInt(s, #":\d+:"#) ?? 1, 1, msg, "xml"))
                }
            }
        case "yml", "yaml":
            if let ruby = ToolEnv.which("ruby") {
                tool = "yaml"
                // Psych.parse only builds the tree: no objects are loaded from the file.
                let r = IDEProc.run(ruby, ["-ryaml", "-e", "begin; Psych.parse_file(ARGV[0]); rescue Psych::SyntaxError => e; puts \"#{e.line}\\t#{e.column}\\t#{e.problem} #{e.context}\"; exit 1; end", path], timeout: 15)
                if r.code == 1 {
                    let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 2).map(String.init)
                    if p.count == 3 { out.append(problem(Int(p[0]) ?? 1, max(1, (Int(p[1]) ?? 0)), p[2], "yaml")) }
                }
            }
        default:
            if name == "composer.json" || ext == "json" { break } // Monaco validates JSON live.
        }
        return ["problems": out, "tool": tool]
    }

    /// `file:line:col: error: message` (swiftc, clang, tsc --pretty false…).
    private static func compilerStyle(_ text: String, path: String, source: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix(path + ":") else { continue }
            let rest = s.dropFirst(path.count + 1).split(separator: ":", maxSplits: 3).map { $0.trimmingCharacters(in: .whitespaces) }
            guard rest.count == 4, let l = Int(rest[0]) else { continue }
            let sev = rest[2].contains("warning") ? "warning" : rest[2].contains("note") ? "info" : "error"
            out.append(problem(l, Int(rest[1]) ?? 1, rest[3], source, sev))
        }
        return out
    }

    private static func exists(_ root: String, _ names: [String]) -> Bool {
        names.contains { FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent($0)) }
    }

    /// The project's own analyzers, when it has them configured: PHPStan for PHP, ESLint for JS/TS.
    static func deep(path: String, root: String) -> [String: Any] {
        let ext = (path as NSString).pathExtension.lowercased()
        let fm = FileManager.default
        let phpstanBin = (root as NSString).appendingPathComponent("vendor/bin/phpstan")
        let eslintBin = (root as NSString).appendingPathComponent("node_modules/.bin/eslint")
        let wantsPhpstan = ["php", "phtml"].contains(ext) && exists(root, ["phpstan.neon", "phpstan.neon.dist", "phpstan.dist.neon"]) && fm.fileExists(atPath: phpstanBin)
        let wantsEslint = ["js", "mjs", "cjs", "jsx", "ts", "tsx", "vue"].contains(ext) && fm.fileExists(atPath: eslintBin) &&
            exists(root, ["eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts", ".eslintrc", ".eslintrc.js",
                          ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yml", ".eslintrc.yaml"])
        // Nothing project-local would run: no need to ask for trust.
        guard wantsPhpstan || wantsEslint else { return ["problems": [], "tool": ""] }
        guard IDETrust.isTrusted(root) else {
            return ["problems": [], "tool": "", "untrusted": true, "tools": (wantsPhpstan ? ["phpstan"] : []) + (wantsEslint ? ["eslint"] : [])]
        }
        var out: [[String: Any]] = []
        var tool = ""
        if wantsPhpstan, let php = ToolEnv.which("php") {
            let bin = phpstanBin
            do {
                tool = "phpstan"
                let r = IDEProc.run(php, [bin, "analyse", "--error-format=json", "--no-progress", "--no-interaction", "--memory-limit=2G", path],
                                    cwd: root, timeout: 120)
                if let start = r.out.firstIndex(of: "{"), let data = String(r.out[start...]).data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let files = json["files"] as? [String: Any] {
                    for (_, v) in files {
                        for m in (v as? [String: Any])?["messages"] as? [[String: Any]] ?? [] {
                            out.append(problem(m["line"] as? Int ?? 1, 1, m["message"] as? String ?? "", "phpstan"))
                        }
                    }
                } else if r.timedOut { tool = "phpstan (tempo scaduto)" }
            }
        }
        if wantsEslint {
            let bin = eslintBin
            do {
                tool = "eslint"
                let r = IDEProc.run(bin, ["-f", "json", path], cwd: root, timeout: 60)
                if let start = r.out.firstIndex(of: "["), let data = String(r.out[start...]).data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for f in json {
                        for m in f["messages"] as? [[String: Any]] ?? [] {
                            let rule = (m["ruleId"] as? String).map { " (\($0))" } ?? ""
                            out.append(problem(m["line"] as? Int ?? 1, m["column"] as? Int ?? 1, (m["message"] as? String ?? "") + rule, "eslint",
                                               (m["severity"] as? Int ?? 2) >= 2 ? "error" : "warning",
                                               endLine: m["endLine"] as? Int, endCol: m["endColumn"] as? Int))
                        }
                    }
                }
            }
        }
        return ["problems": out, "tool": tool]
    }

    /// Whole-project TypeScript check, on demand only (it can take a while).
    static func tsc(root: String) -> [String: Any] {
        let bin = (root as NSString).appendingPathComponent("node_modules/.bin/tsc")
        guard FileManager.default.fileExists(atPath: bin) else { return ["error": "tsc non trovato in node_modules/.bin"] }
        guard IDETrust.isTrusted(root) else { return ["untrusted": true, "tools": ["tsc"]] }
        let r = IDEProc.run(bin, ["--noEmit", "--pretty", "false"], cwd: root, timeout: 300)
        var files: [String: [[String: Any]]] = [:]
        // src/a.ts(3,5): error TS2322: message
        for line in r.out.split(separator: "\n") {
            let s = String(line)
            guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")"), open < close,
                  s[close...].hasPrefix("): ") else { continue }
            let file = String(s[..<open])
            let pos = s[s.index(after: open)..<close].split(separator: ",")
            let rest = s[s.index(close, offsetBy: 3)...]
            let sev = rest.hasPrefix("warning") ? "warning" : "error"
            let msg = rest.split(separator: ":", maxSplits: 1).last.map(String.init) ?? String(rest)
            let abs = file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file)
            files[abs, default: []].append(problem(Int(pos.first ?? "1") ?? 1, Int(pos.last ?? "1") ?? 1, msg, "tsc", sev))
        }
        return ["files": files, "timedOut": r.timedOut]
    }
}

// MARK: - Workspace trust

/// Project-local tools (vendor/bin/phpstan, node_modules/.bin/eslint, tsc) and their configs run the project's own
/// code: a freshly cloned repo must not execute anything until the user says he trusts it (once per folder).
enum IDETrust {
    private static var file: URL { ElioPaths.support.appendingPathComponent("ide-trusted.json") }
    private static let lock = NSLock()

    static func trusted() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: file), let list = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return list
    }

    /// The folder as the file system sees it: symlinks resolved, "..", "." and trailing "/" gone.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Only the exact folders the user trusted: a subfolder (a vendored repo, a nested clone) brings its own
    /// config and tools and is asked about on its own. Case-insensitive, like the default APFS volume.
    static func isTrusted(_ root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let path = canonical(root)
        return trusted().contains { canonical($0).caseInsensitiveCompare(path) == .orderedSame }
    }

    static func set(_ root: String, trusted value: Bool) throws {
        let path = canonical(root)
        var list = trusted().filter { canonical($0).caseInsensitiveCompare(path) != .orderedSame }
        if value { list.append(path) }
        lock.lock(); defer { lock.unlock() }
        try JSONSerialization.data(withJSONObject: list.sorted(), options: [.prettyPrinted]).write(to: file, options: .atomic)
    }
}

// MARK: - Run configurations

enum IDERun {
    private static var file: URL { ElioPaths.support.appendingPathComponent("ide-run-configs.json") }

    /// Scripts the project already declares: package.json, composer.json, Makefile, DDEV, Magento, SwiftPM.
    static func detect(root: String) -> [[String: Any]] {
        let fm = FileManager.default
        func at(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }
        func json(_ name: String) -> [String: Any]? {
            guard let d = fm.contents(atPath: at(name)) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        var out: [[String: Any]] = []
        func add(_ group: String, _ name: String, _ command: String) { out.append(["group": group, "name": name, "command": command, "cwd": root]) }

        let ddev = fm.fileExists(atPath: at(".ddev/config.yaml"))
        let magento = fm.fileExists(atPath: at("bin/magento"))
        if ddev {
            for c in ["start", "stop", "restart", "describe", "launch", "ssh", "logs -f", "composer install"] { add("DDEV", "ddev \(c)", "ddev \(c)") }
            if magento {
                for c in ["cache:flush", "setup:upgrade", "setup:di:compile", "indexer:reindex", "setup:static-content:deploy -f", "deploy:mode:show"] {
                    add("DDEV · Magento", "bin/magento \(c)", "ddev exec bin/magento \(c)")
                }
            }
        } else if magento {
            for c in ["cache:flush", "setup:upgrade", "setup:di:compile", "indexer:reindex"] { add("Magento", "bin/magento \(c)", "bin/magento \(c)") }
        }
        if let pkg = json("package.json"), let scripts = pkg["scripts"] as? [String: Any] {
            let runner = fm.fileExists(atPath: at("pnpm-lock.yaml")) ? "pnpm" : fm.fileExists(atPath: at("yarn.lock")) ? "yarn" :
                fm.fileExists(atPath: at("bun.lockb")) || fm.fileExists(atPath: at("bun.lock")) ? "bun" : "npm"
            for name in scripts.keys.sorted() {
                guard let q = scriptName(name) else { continue }
                add("package.json", name, "\(runner) run \(q)")
            }
        }
        if let composer = json("composer.json"), let scripts = composer["scripts"] as? [String: Any] {
            let prefix = ddev ? "ddev composer" : "composer"
            for name in scripts.keys.sorted() {
                guard let q = scriptName(name) else { continue }
                add("composer.json", name, "\(prefix) run-script \(q)")
            }
        }
        for mk in ["Makefile", "makefile", "GNUmakefile"] {
            guard let text = try? String(contentsOfFile: at(mk), encoding: .utf8) else { continue }
            var seen = Set<String>()
            for line in text.split(separator: "\n") {
                guard let r = line.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.\-/]*\s*:(?!=)"#, options: .regularExpression) else { continue }
                let target = line[r].dropLast().trimmingCharacters(in: .whitespaces)
                if target.hasPrefix(".") || seen.contains(target) { continue }
                seen.insert(target)
                guard let q = scriptName(target) else { continue }
                add("Makefile", target, "make \(q)")
            }
            break
        }
        if fm.fileExists(atPath: at("Package.swift")) {
            add("Swift", "swift build", "swift build")
            add("Swift", "swift test", "swift test")
        }
        if fm.fileExists(atPath: at("artisan")) {
            for c in ["serve", "migrate", "test", "tinker"] { add("Laravel", "artisan \(c)", "php artisan \(c)") }
        }
        return out
    }

    /// A script/target name from the project's files, ready for the shell line: only `[A-Za-z0-9:_.@/-]`, never
    /// "-"-led (an option), single-quoted anyway. nil when it doesn't qualify (the entry is skipped).
    static func scriptName(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-"),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ":_.@/-".unicodeScalars.contains($0)) })
        else { return nil }
        return "'" + name + "'"
    }

    static func load(root: String) -> [[String: Any]] {
        guard let d = try? Data(contentsOf: file), let all = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return all[root] as? [[String: Any]] ?? []
    }

    static func save(root: String, configs: [[String: Any]]) throws {
        var all: [String: Any] = [:]
        if let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { all = j }
        all[root] = configs.isEmpty ? nil : configs
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}
