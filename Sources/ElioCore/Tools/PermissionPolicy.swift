import Foundation

/// Decides what a background agent may do on its own.
/// Enforced in code (not in the prompt): push, merge, deletions, outbound messages and
/// anything unrecognised need the user's confirmation; "dangerous" ones need the explicit word "confermo".
public enum PermissionPolicy {
    public enum Decision: Equatable, Sendable {
        case allow
        case confirm(ConfirmRequest.Risk)
    }

    public static func decide(tool: String, input: [String: Any], cwd: String) -> Decision {
        switch tool {
        case "Read", "Grep", "Glob", "LS", "TodoWrite", "WebSearch", "WebFetch", "NotebookRead":
            return .allow
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            return isInside(path, cwd) ? .allow : .confirm(.normal)
        case "Bash":
            return decideBash((input["command"] as? String) ?? "")
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
        if cmd.contains("$(") || cmd.contains("`") || cmd.range(of: #"(^|[^0-9&])>{1,2}\s*[^&\s]"#, options: .regularExpression) != nil {
            return .confirm(.normal)
        }
        let parts = cmd.components(separatedBy: CharacterSet(charactersIn: ";|&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let allSafe = parts.allSatisfy { part in
            // A safe command can still be turned into code execution / file writes by its options
            // (`git fetch --upload-pack=…`, `find -exec`, `eslint --rulesdir`): check every token.
            guard !tokens(part).contains(where: isForbiddenOption) else { return false }
            return activeSafe.contains { part.range(of: $0, options: .regularExpression) != nil }
        }
        return allSafe ? .allow : .confirm(.normal)
    }

    private static func isInside(_ path: String, _ dir: String) -> Bool {
        guard !path.isEmpty, !dir.isEmpty else { return false }
        let p = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir)).standardizedFileURL.path
        let d = URL(fileURLWithPath: dir).standardizedFileURL.path
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
        #"^(python3?\s+-m\s+(pytest|mypy|ruff)|pytest|ruff|mypy)(\s+[\w./:=-]+)*$"#,
    ]

    /// Read-only or local, reversible developer commands. Every pattern is anchored at both ends and
    /// only allows plain arguments (words, paths, refs); options that could run code are rejected above.
    static let safe: [String] = runsProjectCode + [
        #"^git\s+(status|diff|log|show|blame|ls-files|rev-parse|fetch)(\s+[\w./@:^~=-]+)*$"#,
        #"^git\s+branch(\s+(--list|--show-current|-a|-r|-v|-vv))*$"#,
        #"^git\s+remote\s+-v$"#,
        #"^git\s+stash(\s+(list|show|push)(\s+[\w./-]+)*)?$"#,
        #"^git\s+add(\s+[\w./*-]+)+$"#,
        #"^git\s+commit(\s+(-m|-a|-am|--all|--message)?\s*('[^']*'|"[^"]*"|[\w.-]+))+$"#,
        #"^git\s+(checkout\s+-b|switch\s+-c)\s+[\w./-]+$"#,
        #"^git\s+switch\s+[\w./-]+$"#,
        #"^(ls|pwd|cat|head|tail|wc|uniq|cut|diff|file|which|echo|printf|date|stat|du|basename|dirname|realpath)(\s+('[^']*'|"[^"]*"|[\w./@:=+,*~-]+))*$"#,
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
