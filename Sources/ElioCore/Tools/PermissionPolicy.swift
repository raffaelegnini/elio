import Foundation

/// Decides what a background agent may do on its own.
/// Enforced in code (not in the prompt): push, merge, deletions, outbound messages and
/// anything unrecognised need the user's confirmation; "dangerous" ones need the explicit word "confermo".
public enum PermissionPolicy {
    public enum Decision: Equatable, Sendable {
        case allow
        case confirm(ConfirmRequest.Risk)
    }

    /// `operator`: Elio acting on the whole Mac for the user (moving files, settings, debugging).
    /// Everything runs freely except what is destructive, outward-facing or sends data out.
    public static func decide(tool: String, input: [String: Any], cwd: String, onMac: Bool = false) -> Decision {
        switch tool {
        case "Read", "Grep", "Glob", "LS", "TodoWrite", "WebSearch", "WebFetch", "NotebookRead":
            return .allow
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            // .git/config (fsmonitor, pager…) and hooks run code at the next `git status`/`commit`.
            if canonical(path).components(separatedBy: "/").contains(".git") { return .confirm(.normal) }
            if onMac, isInside(path, FileManager.default.homeDirectoryForCurrentUser.path), !isSensitive(path) {
                return .allow
            }
            return isInside(path, cwd) ? .allow : .confirm(.normal)
        case "Bash":
            let command = (input["command"] as? String) ?? ""
            // Asking to run outside the OS sandbox (more files, network) is always the user's call.
            if input["dangerouslyDisableSandbox"] as? Bool == true {
                // Reading the Mac's own state (IP, listening ports, versions) needs no OK even outside the sandbox.
                if ShellCommandClassifier.isLocalReadOnly(command) { return .allow }
                let inner = decide(tool: tool, input: input.filter { $0.key != "dangerouslyDisableSandbox" }, cwd: cwd, onMac: onMac)
                return inner == .confirm(.dangerous) ? inner : .confirm(.normal)
            }
            // Only destructive or outward-facing commands need an OK; "strict" brings back the safe-list.
            if strictCodeExecution, !onMac { return decideBash(command) }
            return onMac ? decideOperatorBash(command) : decideDeveloperBash(command, cwd: cwd)
        default:
            if tool.hasPrefix("mcp__elio__") { return .allow }
            // The user asked Elio to drive their browser on its own (Settings → Autonomia).
            if tool.hasPrefix("mcp__claude-in-chrome__") && browserAutonomy { return .allow }
            if tool.hasPrefix("mcp__") { return decideIntegrationTool(tool) }
            return .confirm(.normal)
        }
    }

    /// Integration MCP tools (`mcp__<server>__<action>`). Write verbs anywhere in the action win;
    /// only an action that *starts* with a read verb and contains no write verb runs freely.
    static func decideIntegrationTool(_ tool: String) -> Decision {
        let action = (tool.components(separatedBy: "__").last ?? "").lowercased()
        let words = action.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        let destructive = ["delete", "remove", "destroy", "drop", "purge", "send", "post", "publish", "reply",
                           "forward", "share", "invite", "transfer", "pay", "execute", "run", "exec"]
        let writes = ["create", "update", "edit", "set", "add", "write", "put", "patch", "move", "archive", "complete",
                      "close", "assign", "modify", "upload", "start", "stop", "trigger", "mark", "log", "change", "rename"]
        if words.contains(where: { destructive.contains($0) }) { return .confirm(.dangerous) }
        if words.contains(where: { writes.contains($0) }) { return .confirm(.normal) }
        let reads = ["get", "list", "search", "read", "fetch", "find", "query", "show", "describe", "view", "count"]
        if let first = words.first, reads.contains(first) { return .allow }
        return .confirm(.normal)
    }

    public static func decideBash(_ command: String) -> Decision {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.isEmpty { return .confirm(.normal) }
        if dangerous.contains(where: { cmd.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return .confirm(.dangerous)
        }
        // Command substitution / redirection to files: can't reason about it safely.
        // Escaped quotes make quoting ambiguous (a "quoted" > may be a real redirection), and process
        // substitution runs commands: never auto-approve those.
        if cmd.contains("\\\"") || cmd.contains("\\'") || cmd.contains("<(") || cmd.contains(">(") {
            return .confirm(.normal)
        }
        // A ">" inside quotes ("<noreply@…>") is text, not a redirection; $( and ` expand even in double quotes.
        let unquoted = cmd.replacingOccurrences(of: #"'[^']*'|"[^"]*""#, with: "''", options: .regularExpression)
        if cmd.contains("$(") || cmd.contains("`") || unquoted.range(of: #"(^|[^0-9&])>{1,2}\s*[^&\s]"#, options: .regularExpression) != nil {
            return .confirm(.normal)
        }
        // Newlines separate commands in the shell just like ";".
        let parts = cmd.replacingOccurrences(of: #"\s+2>(/dev/null|&1)(?=\s|$|[;&|)])"#, with: "", options: .regularExpression)
            .splitOutsideQuotes(";|&\n\r")
            // Grouping parentheses/braces don't change what runs: `(git checkout x || git checkout -b x)`.
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(){}"))) }
            .filter { !$0.isEmpty }
        let allSafe = parts.allSatisfy { part in
            // A safe command can still be turned into code execution / file writes by its options
            // (`git fetch --upload-pack=…`, `find -exec`, `eslint --rulesdir`): check every token.
            guard !tokens(part).contains(where: isForbiddenOption) else { return false }
            return activeSafe.contains { part.range(of: $0, options: .regularExpression) != nil }
        }
        return allSafe ? .allow : .confirm(.normal)
    }

    /// Operator mode: no safe-list, but deletions/sudo/push/messages stay "dangerous" and anything
    /// that talks to other machines or rewrites credentials needs an OK.
    public static func decideOperatorBash(_ command: String) -> Decision {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.isEmpty { return .confirm(.normal) }
        if dangerous.contains(where: { cmd.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return .confirm(.dangerous)
        }
        let outward = [
            // Inline code can delete or overwrite anything without ever spelling "rm".
            #"\b(python[0-9.]*|node|perl|ruby|php|osascript|swift)\s+(-[a-zA-Z]*[ce]\b|-(\s|$))"#,
            #"\b(sh|bash|zsh|fish)\s+-[a-zA-Z]*c\b|\beval\b|\bxargs\b|\bsource\b|(^|[\s;&|])\.\s"#,
            // Overwrites: plain redirection, tee without -a, truncate, mv/cp without -n.
            #"\btee\s+(?!-a)"#,
            #"\btruncate\b|\bdefaults\s+delete\b|\bsrm\b"#,
            // Persistence and shell startup files.
            #"LaunchAgents|LaunchDaemons|crontab|\.zshrc|\.zprofile|\.bash_profile|\.bashrc|\.profile\b|login\s*items"#,
            #"\b(curl|wget|nc|ncat|ssh|scp|sftp|rsync|ftp|telnet)\b"#,
            #"\b(security)\s+(delete|add|import|set)"#,
            #"\.ssh/|\.aws/|\.gnupg/|Keychains/"#,
            #"\bmv\s+(-f\s+)?\S+\s+/dev/null"#,
            #"\b(launchctl)\s+(unload|remove|bootout)\b"#,
            #"\bcsrutil\b|\bnvram\b|\bfdesetup\b|\bdiskutil\s+(erase|partition|unmount)"#,
        ]
        if outward.contains(where: { cmd.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return .confirm(.normal)
        }
        // Writing files in the home is free here, so running one must not be: "write a script, then run it" would
        // otherwise execute anything (rm, curl…) without a single confirmation.
        if runsCodeFromFile(cmd) { return .confirm(.normal) }
        // mv/cp only matter when they would replace an existing file.
        let parts = cmd.splitOutsideQuotes(";|&\n").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(){}"))) }
        if parts.contains(where: wouldOverwrite) { return .confirm(.normal) }
        // Overwriting redirection (quoted text like "<noreply@…>" is not one). With escaped quotes the
        // quoting can't be trusted: look at the raw command instead (any ">" counts).
        let escaped = cmd.contains("\\\"") || cmd.contains("\\'")
        let unquoted = escaped ? cmd : cmd.replacingOccurrences(of: #"'[^']*'|"[^"]*""#, with: "''", options: .regularExpression)
        if unquoted.range(of: #"(^|[^0-9&>])>(?!>)\s*(?!/dev/null|&)\S"#, options: .regularExpression) != nil {
            return .confirm(.normal)
        }
        return .allow
    }

    /// An interpreter given a script (`python3 x.py`, `node x.js`, `bash x.sh`, `osascript x.scpt`…), a file run by
    /// path (`./x`, `~/x.sh`, `/Users/…/x`), or a task runner that executes project files (make, npm run…).
    /// Version/help flags and REPL-less checks (`python3 --version`) don't count.
    static func runsCodeFromFile(_ cmd: String) -> Bool {
        // Command and process substitution run a program we'd never see as "the program" (`echo $(python3 x.py)`).
        if cmd.contains("$(") || cmd.contains("`") || cmd.contains("<(") || cmd.contains(">(") { return true }
        let interpreters = #"python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|perl[0-9.]*|ruby|php[0-9.]*|osascript|swift|sh|bash|zsh|fish|dash|ksh|csh|tcsh|tclsh|wish|lua|luajit|Rscript|R|java|jshell|kotlin|scala|groovy|pwsh|awk|gawk|nawk|expect|jq|sqlite3|ipython|irb"#
        // Wrappers that run whatever follows them (their own options are skipped too).
        let wrappers: Set<String> = ["env", "command", "exec", "nohup", "time", "nice", "renice", "sudo", "caffeinate", "arch",
                                     "timeout", "gtimeout", "stdbuf", "unbuffer", "script", "chronic", "ionice", "taskpolicy"]
        // Programs that execute other commands by design.
        let runners: Set<String> = ["xargs", "watch", "parallel", "source", ".", "eval", "make", "gmake", "just", "rake",
                                    "gradle", "gradlew", "mvn", "ant", "npx", "pnpx", "bunx", "uvx", "pipx", "launchctl", "open"]
        let segments = cmd.splitOutsideQuotes(";|&\n").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(){}"))) }
        for seg in segments where !seg.isEmpty {
            var words = seg.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            // Skip env assignments and wrappers (with their flags and flag values, e.g. `nice -n 5`, `timeout 10`).
            while let w = words.first {
                // Words before the program must be readable literally too (`A="x y" python3`, `env $X …`).
                if w.contains("\"") || w.contains("'") || w.contains("\\") || w.contains("$") { return true }
                if w.contains("="), !w.hasPrefix("-") { words.removeFirst(); continue }
                if wrappers.contains(w) {
                    words.removeFirst()
                    while let f = words.first, f.hasPrefix("-") || Int(f) != nil || f.range(of: #"^\d+[smhd]?$"#, options: .regularExpression) != nil {
                        words.removeFirst()
                        // A flag that takes a value (`-n 5`, `-u root`): drop the value as well.
                        if f.count == 2, let v = words.first, !v.hasPrefix("-"), ["-n", "-u", "-g", "-k", "-s", "-o", "-e", "-i", "-p"].contains(f) { _ = v; words.removeFirst() }
                    }
                    continue
                }
                break
            }
            guard let raw = words.first else { continue }
            // Fail closed on a program name we can't read literally: quotes, escapes, expansions ("py"thon3, p\ython3, $X).
            if raw.contains("\"") || raw.contains("'") || raw.contains("\\") || raw.contains("$") || raw.contains("`") { return true }
            let name = (raw as NSString).lastPathComponent
            // A file run by path (system binaries excepted).
            if raw.contains("/"), !["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/opt/homebrew/bin/", "/usr/local/bin/"].contains(where: raw.hasPrefix) {
                return true
            }
            if runners.contains(name) {
                // `open` only runs code for apps/scripts/URLs it's given: opening a folder or a document is fine.
                if name == "open" {
                    let targets = words.dropFirst().filter { !$0.hasPrefix("-") }
                    if targets.contains(where: { $0.range(of: #"\.(app|command|tool|sh|scpt|applescript|workflow|terminal|pkg|mpkg)/?$|^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil }) { return true }
                    continue
                }
                return true
            }
            if name.range(of: "^(\(interpreters))$", options: .regularExpression) != nil {
                let rest = words.dropFirst()
                // A bare interpreter fed by a pipe or a redirect runs that code (`cat x | python3`, `bash < x`).
                if rest.isEmpty { if cmd.contains("|") || cmd.contains("<") { return true }; continue }
                if rest.allSatisfy({ ["--version", "-V", "-v", "--help", "-h"].contains($0) }) { continue }
                return true
            }
            if ["npm", "pnpm", "yarn", "bun", "composer", "swift", "cargo", "go", "dotnet", "deno", "uv", "poetry", "pip", "pip3"].contains(name),
               words.count > 1, ["run", "run-script", "exec", "x", "dlx", "start", "test", "install", "i", "add", "build"].contains(words[1]) {
                return true
            }
            // find -exec/-execdir/-ok run commands on every match.
            if name == "find", words.contains(where: { ["-exec", "-execdir", "-ok", "-okdir", "-delete"].contains($0) }) { return true }
        }
        return false
    }

    /// Project agents (code, squads): they work like a developer in their repo. Everything local and
    /// reversible runs — shells, pipes, loops, inline scripts, tests, builds, flutter, curl GETs, git on
    /// their branch — because git can undo it. Asked only: what destroys or can't be undone (push, history
    /// rewrites, recursive deletes of real code, DB wipes), what leaves the Mac (POSTs, ssh, publishing),
    /// what touches credentials or login items, and what eats disk/CPU (docker, global installs, simulators).
    public static func decideDeveloperBash(_ command: String, cwd: String) -> Decision {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.isEmpty { return .allow }
        // `zsh -lic 'php artisan test'`: judge what's inside, not the wrapper.
        let text = unwrapShells(cmd)
        func matches(_ patterns: [String]) -> Bool {
            patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        if matches(developerDangerous) { return .confirm(.dangerous) }
        if hasDestructiveDelete(text, cwd: cwd) { return .confirm(.dangerous) }
        if killsSomethingElse(text) || sendsDataOutside(text) { return .confirm(.dangerous) }
        if matches(developerHeavy + developerOutward) { return .confirm(.normal) }
        return .allow
    }

    /// The commands inside `sh -c '…'`, `zsh -lic "…"`, `bash -c …` (nested ones too), joined to the outer text.
    static func unwrapShells(_ cmd: String) -> String {
        var text = cmd
        for _ in 0..<3 {
            guard let r = text.range(of: #"\b(?:sh|bash|zsh|fish)\s+-[a-zA-Z]*c\s+('([^']*)'|"((?:[^"\\]|\\.)*)")"#,
                                     options: .regularExpression) else { break }
            let inner = String(text[r]).replacingOccurrences(of: #"^\S+\s+\S+\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            text.replaceSubrange(r, with: " ; " + inner + " ; ")
        }
        return text
    }

    /// `rm -r` of anything but generated folders (node_modules, build, dist, caches) or temp files,
    /// and any delete outside the project. Removing single files in the repo is fine: git has them.
    static func hasDestructiveDelete(_ text: String, cwd: String) -> Bool {
        let generated = #"^(\./)?([\w.-]+/)*(node_modules|vendor|build|dist|out|\.next|\.nuxt|coverage|\.cache|cache|tmp|\.dart_tool|\.build|DerivedData|Pods|\.gradle|\.turbo|\.pytest_cache|__pycache__|\.phpunit\.cache|storage/framework/\w+|bootstrap/cache)(/.*)?$|^/tmp/|^/private/tmp/|^\$TMPDIR"#
        for part in text.splitOutsideQuotes(";|&\n") {
            let t = tokens(part.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(){}"))))
            guard let verb = t.first.map({ ($0 as NSString).lastPathComponent }), ["rm", "rmdir", "unlink", "shred", "srm"].contains(verb) else {
                // find -delete / -exec rm: only on generated folders.
                if t.first == "find", t.contains(where: { $0 == "-delete" || $0 == "rm" }) {
                    let roots = t.dropFirst().prefix { !$0.hasPrefix("-") }
                    if roots.isEmpty || roots.contains(where: { $0.range(of: generated, options: .regularExpression) == nil }) { return true }
                }
                continue
            }
            let flags = t.dropFirst().filter { $0.hasPrefix("-") }
            let recursive = flags.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R")) } || flags.contains("--recursive")
            let targets = t.dropFirst().filter { !$0.hasPrefix("-") }
            if verb == "shred" || verb == "srm" { return true }
            for target in targets {
                let generatedTarget = target.range(of: generated, options: .regularExpression) != nil
                if generatedTarget { continue }
                // Wildcards at the top, home, absolute paths outside the project, parent dirs: never on their own.
                if target.contains("..") || target == "*" || target == "." || target.hasPrefix("~") || target.contains("$HOME") { return true }
                if target.hasPrefix("/"), !isInside(target, cwd) { return true }
                if recursive { return true }
            }
        }
        return false
    }

    /// Irreversible or outward-facing, for developer agents (always the explicit "confermo").
    static let developerDangerous: [String] = [
        #"\bgit\s+push\b"#,
        #"\bgit\s+(merge|rebase|cherry-pick)\b(?!\s+--abort)"#,
        #"\bgit\s+reset\s+--hard\b"#,
        #"\bgit\s+clean\s+-[a-zA-Z]*f"#,
        #"\bgit\s+branch\s+-[a-zA-Z]*D"#,
        // Discarding all local changes; one named file or folder is fine (git has the committed version).
        #"\bgit\s+(checkout|restore)\s+(--\s+)?\.(\s*$|\s*[;&|)])|\bgit\s+(checkout|restore)\s+--\s*($|[;&|])"#,
        #"\bgit\s+stash\s+(drop|clear)\b"#,
        #"\bgit\s+(tag\s+-d|filter-branch|filter-repo|update-ref\s+-d|reflog\s+expire)\b"#,
        #"\bgit\s+commit\b.*--amend"#,
        #"\bsudo\b"#,

        #"\bwget\b.*--post"#,
        #"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#,
        #"\b(drop|truncate)\s+(table|database|schema)\b"#,
        #"\bdelete\s+from\b"#,
        #"\bmigrate:(fresh|reset|rollback|refresh)\b|\bdb:wipe\b|\bprisma\s+migrate\s+reset\b|\bdropdb\b"#,
        #"\b(gh|bb|glab)\s+(pr|mr)\s+(create|merge|close)\b|\bgh\s+(release|repo\s+delete)\b"#,
        #"\b(npm|pnpm|yarn)\s+publish\b|\bcargo\s+publish\b|\bpod\s+trunk\s+push\b|\bflutter\s+pub\s+publish\b|\btwine\s+upload\b"#,
        #"\b(sendmail|mail)\s"#,
        #"\bosascript\b.*\b(send|delete|quit)\b"#,
        #"\bdd\s+if="#,
        #"\bdiskutil\s+(erase|partition)|\bcsrutil\b|\bnvram\b"#,
        #"\bchmod\s+-R\s+[0-7]*7[0-7]*\s+/|\bchown\s+-R\b"#,
        #"\bxargs\b[^|;&]*\b(rm|rmdir|unlink|shred)\b"#,
        // Inline scripts that delete trees.
        #"shutil\.rmtree|rmSync\(|rimraf|os\.removedirs|FileUtils\.rm_r|fs\.rm\("#,
    ]

    /// `pkill`/`killall` of anything but a dev server the agent itself started (artisan serve, vite, node…).
    static func killsSomethingElse(_ text: String) -> Bool {
        let dev = #"artisan|php\s+-S|vite|next|nuxt|node|npm|pnpm|yarn|bun|deno|flutter|dart|webpack|esbuild|tsx|nodemon|uvicorn|gunicorn|rails|puma|django|manage\.py|127\.0\.0\.1|localhost|0\.0\.0\.0|:\d{4,5}\b|serve"#
        for part in text.splitOutsideQuotes(";|&\n") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard t.range(of: #"^(sudo\s+)?(pkill|killall)\b"#, options: .regularExpression) != nil else { continue }
            if t.range(of: dev, options: [.regularExpression, .caseInsensitive]) == nil { return true }
        }
        return false
    }

    /// curl/wget that send data (POST, upload…) to a host that isn't this Mac's dev environment.
    /// Testing your own API on 127.0.0.1, localhost or a Herd/Valet `.test` domain is just development.
    static func sendsDataOutside(_ text: String) -> Bool {
        let writes = #"\bcurl\b.*(-X\s*(POST|PUT|DELETE|PATCH)|--data|\s-d\s|\s-F\s|--form|--upload-file|\s-T\s)|\bwget\b.*--post"#
        guard text.range(of: writes, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        let urls = text.matches(of: #/https?://([^/\s'"$:]+)/#).map { String($0.output.1).lowercased() }
        // No literal URL (it's in a variable we can't see): ask.
        guard !urls.isEmpty else { return true }
        let local = #"^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|[\w.-]+\.(test|local|localhost|internal))$"#
        return urls.contains { $0.range(of: local, options: .regularExpression) == nil }
    }

    /// Heavy on disk/CPU/memory or the Mac's setup: a normal OK.
    static let developerHeavy: [String] = [
        #"\b(docker|podman)\s+(build|run|compose|pull|system\s+prune|volume\s+rm|rmi)\b|\bdocker-compose\b"#,
        #"\bbrew\s+(install|upgrade|reinstall|uninstall|remove)\b"#,
        #"\b(npm|pnpm)\s+(i|install|add)\s+(-g|--global)\b|\byarn\s+global\s+add\b|\bpip3?\s+install\b(?!.*(-r\s|--requirement|-e\s|\.))|\bgem\s+install\b|\bcargo\s+install\b"#,
        #"\bxcrun\s+simctl\s+(create|erase|delete)\b|\bflutter\s+emulators\s+--create\b|\bavdmanager\b|\bsdkmanager\b"#,
        #"\bollama\s+(pull|run)\b|\bhuggingface-cli\s+download\b"#,
        #"\bgit\s+clone\b"#,
        #"\b(caffeinate|stress|yes)\b\s*$"#,
    ]

    /// Leaving the Mac or touching credentials / startup: a normal OK.
    static let developerOutward: [String] = [
        #"\b(ssh|scp|sftp|rsync|ftp|telnet|nc|ncat)\s"#,
        #"\bsecurity\s+(delete|add|import|set|dump)"#,
        #"\.ssh/|\.aws/|\.gnupg/|Keychains/|\.netrc"#,
        #"LaunchAgents|LaunchDaemons|crontab|\blaunchctl\s+(load|unload|bootstrap|bootout|remove)"#,
        #"(>|\btee\s+(-a\s+)?)\s*~?/?(\$HOME/)?\.(zshrc|zprofile|bashrc|bash_profile|profile|gitconfig)\b"#,
        #"\bgit\s+config\s+--global\b"#,
        #"\bdefaults\s+(write|delete)\b"#,
    ]

    /// `mv`/`cp` that would replace an existing file (sources expanded for simple globs).
    /// Unparseable forms count as overwriting, to stay on the safe side.
    static func wouldOverwrite(_ part: String) -> Bool {
        let t = tokens(part)
        guard let verb = t.first, verb == "mv" || verb == "cp" else { return false }
        let flags = t.dropFirst().filter { $0.hasPrefix("-") }
        if flags.contains(where: { $0 != "--" && $0.dropFirst().contains("n") && !$0.hasPrefix("--") }) || flags.contains("--no-clobber") {
            return false
        }
        let args = t.dropFirst().filter { !$0.hasPrefix("-") }.map(expandPath)
        guard args.count >= 2, let dest = args.last else { return true }
        let sources = args.dropLast()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let destExists = fm.fileExists(atPath: dest, isDirectory: &isDir)
        if !destExists {
            // New file/folder name, or a folder created earlier in the same command.
            return false
        }
        guard isDir.boolValue else { return true }   // replacing an existing file
        for src in sources {
            let dir = (src as NSString).deletingLastPathComponent, pattern = (src as NSString).lastPathComponent
            let names: [String]
            if pattern.contains("*") || pattern.contains("?") {
                names = ((try? fm.contentsOfDirectory(atPath: dir.isEmpty ? "." : dir)) ?? [])
                    .filter { fnmatch(pattern, $0, 0) == 0 }
            } else {
                names = [pattern]
            }
            if names.contains(where: { fm.fileExists(atPath: (dest as NSString).appendingPathComponent($0)) }) { return true }
        }
        return false
    }

    /// Dotfiles and folders that hold credentials or run code at login.
    static func isSensitive(_ path: String) -> Bool {
        let home = canonical(FileManager.default.homeDirectoryForCurrentUser.path)
        let p = canonical(path)
        guard p.hasPrefix(home + "/") else { return true }
        let rel = String(p.dropFirst(home.count + 1))
        if rel.hasPrefix(".") { return true }   // ~/.zshrc, ~/.ssh, ~/.aws, ~/.config…
        return ["Library/LaunchAgents", "Library/Keychains", "Library/Application Support/Elio",
                "Library/Preferences/com.apple.loginitems"].contains { rel.hasPrefix($0) }
    }

    /// realpath() of the deepest existing ancestor + the components that don't exist yet.
    static func canonical(_ path: String) -> String {
        var existing = path, rest: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = realpath(existing, &buf) != nil ? String(cString: buf) : existing
        return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func isInside(_ path: String, _ dir: String) -> Bool {
        guard !path.isEmpty, !dir.isEmpty else { return false }
        // Symlinks resolved on both sides (/tmp → /private/tmp), also for files that don't exist yet.
        let p = canonical(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir)).standardizedFileURL.path)
        let d = canonical(URL(fileURLWithPath: dir).standardizedFileURL.path)
        return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    /// Irreversible, outward-facing or destructive.
    static let dangerous: [String] = [
        #"\bgit\s+push\b"#,
        #"\bgit\s+merge\b"#,
        #"\bgit\s+rebase\b"#,
        #"\bgit\s+reset\s+--hard\b"#,
        #"\bgit\s+clean\b"#,
        #"\bgit\s+branch\s+-[a-zA-Z]*D"#,
        #"\bgit\s+(checkout|restore)\s+(--\s|\.)"#,
        #"\bgit\s+stash\s+(drop|clear)\b"#,
        #"\bgit\s+tag\s+-d\b"#,
        #"(^|[\s;&|])(rm|rmdir|unlink|shred)\s"#,
        #"\bfind\b.*\s-(delete|exec\s+rm)\b"#,
        #"\bsudo\b"#,
        #"\b(kill|killall|pkill)\b"#,
        #"\bcurl\b.*(-X\s*(POST|PUT|DELETE|PATCH)|--data|-d\s)"#,
        #"\b(drop|truncate)\s+(table|database|schema)\b"#,
        #"\bdelete\s+from\b"#,
        #"\bmigrate:(fresh|reset|rollback)\b"#,
        #"\b(gh|bb)\s+pr\s+(create|merge)\b"#,
        #"\b(sendmail|mail|osascript)\b"#,
        #"\bslack\b"#,
        #"\bchmod\s+-R\b|\bchown\b"#,
        #"\bdd\s+if="#,
    ]

    /// Settings → "conferma anche build e test": running the project's own code
    /// (tests, linters, builds) then needs an OK too.
    nonisolated(unsafe) public static var strictCodeExecution = false
    nonisolated(unsafe) public static var browserAutonomy = true

    static var activeSafe: [String] { strictCodeExecution ? safe.filter { !runsProjectCode.contains($0) } : safe }

    /// Options that execute programs, load code or write files, whatever the command.
    static func isForbiddenOption(_ token: String) -> Bool {
        let t = token.lowercased()
        let flags = ["--upload-pack", "--receive-pack", "--exec", "--output", "--output-directory", "--ext-diff",
                     "--textconv", "--config", "--rulesdir", "--resolve-plugins-relative-to", "--plugin", "--require",
                     "--loader", "--import", "--conftest", "--rootdir", "--confcutdir", "--pager", "--open-files-in-pager",
                     "--exec-path", "--git-dir", "--work-tree", "--template", "--init-file"]
        if flags.contains(where: { t == $0 || t.hasPrefix($0 + "=") }) { return true }
        // find actions that run or write; -o (output) style flags for writers.
        if ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"].contains(t) { return true }
        return false
    }

    /// Splits a command into words, honouring simple quotes.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch.isWhitespace {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Commands that run the project's own code (allowed by default, confirmed in strict mode).
    static let runsProjectCode: [String] = [
        #"^(npm|pnpm|yarn|bun)\s+(test|run\s+(test|lint|build|typecheck|check|format)|ci|install|i)(\s+[\w./@:=-]+)*$"#,
        #"^npx\s+(tsc|eslint|prettier|vitest|jest|playwright\s+test)(\s+[\w./@:=*-]+)*$"#,
        #"^composer\s+install(\s+[\w./=-]+)*$"#,
        #"^php\s+artisan\s+test(\s+[\w./:=-]+)*$"#,
        #"^(\./)?vendor/bin/(phpunit|pest|phpstan|pint|psalm)(\s+[\w./:=-]+)*$"#,
        #"^(swift\s+(build|test)|xcodebuild)(\s+[\w./:=-]+)*$"#,
        #"^make\s+(test|lint|check|build)$"#,
        #"^(python3?\s+-m\s+(pytest|unittest|mypy|ruff)|pytest|ruff|mypy)(\s+[\w./:=-]+)*$"#,
    ]

    /// Read-only or local, reversible developer commands. Every pattern is anchored at both ends and
    /// only allows plain arguments (words, paths, refs); options that could run code are rejected above.
    static let safe: [String] = runsProjectCode + [
        #"^git\s+(status|diff|log|show|blame|ls-files|rev-parse|fetch)(\s+[\w./@:^~=-]+)*$"#,
        #"^git\s+branch(\s+(--list|--show-current|-a|-r|-v|-vv|'[\w./*-]+'|"[\w./*-]+"|[\w./*][\w./*-]*))*$"#,
        #"^git\s+remote\s+-v$"#,
        #"^git\s+stash(\s+(list|show|push)(\s+[\w./-]+)*)?$"#,
        #"^git\s+add(\s+[\w./*-]+)+$"#,
        #"^git\s+commit(?!.*--amend)(\s+('[^']*'|"[^"]*"|[\w./@:=-]+))+$"#,
        #"^git\s+(checkout\s+-b|switch\s+-c)\s+[\w./-]+$"#,
        #"^git\s+switch\s+[\w./-]+$"#,
        #"^git\s+checkout\s+elio/[\w./-]+$"#,
        #"^(ls|pwd|cat|head|tail|wc|uniq|cut|diff|file|which|echo|printf|date|stat|du|basename|dirname|realpath|cal|mdls|pdfinfo|textutil\s+-info|lpstat)(\s+('[^']*'|"[^"]*"|[\w./@:=+,*~-]+))*$"#,
        #"^(grep|rg|ag|fd)(\s+('[^']*'|"[^"]*"|[^\s;&|<>`$]+))*$"#,
        #"^(jq|yq)(\s+('[^']*'|"[^"]*"|[\w./@:=,-]+))*$"#,
        #"^find(\s+('[^']*'|"[^"]*"|[^\s;&|<>`$]+))*$"#,
        #"^cd\s+[\w./~-]+$"#,
        #"^(npm|pnpm|yarn|bun)\s+(list|ls|outdated|audit)(\s+[\w./@-]+)*$"#,
        #"^composer\s+(dump-autoload|validate|show|outdated)(\s+[\w./-]+)*$"#,
        #"^php\s+artisan\s+(route:list|config:show|about|model:show)(\s+[\w./:=-]+)*$"#,
        #"^swift\s+package\s+(resolve|describe)$"#,
        #"^(node|python3?)\s+--version$"#,
    ]
}

extension String {
    /// Splits on any of `separators`, except inside '…' or "…" (a `;` in a quoted script is not a new command).
    func splitOutsideQuotes(_ separators: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in self {
            if let q = quote {
                cur.append(ch)
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                cur.append(ch)
            } else if separators.contains(ch) {
                out.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out
    }
}
