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
            if tool.hasPrefix("mcp__jarvis__") { return .allow }
            return .confirm(.normal)
        }
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
            safe.contains { part.range(of: $0, options: .regularExpression) != nil }
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

    /// Read-only or local, reversible developer commands.
    static let safe: [String] = [
        #"^git\s+(status|diff|log|show|branch(\s+--?(list|show-current|a|r|v)\b.*)?$|branch$|rev-parse|ls-files|blame|fetch|remote\s+-v|stash(\s+(list|show|push)\b.*)?$|add\b|commit\b|checkout\s+-b\b|switch\s+(-c\s)?[\w./-]+$)"#,
        #"^(ls|pwd|cat|head|tail|wc|sort|uniq|cut|tr|diff|file|which|echo|printf|date|env|tree|stat|du|basename|dirname|realpath)\b"#,
        #"^(grep|rg|ag|fd|jq|yq)\b"#,
        #"^sed\s+-n\b"#,
        #"^find\b"#,
        #"^cd\s"#,
        #"^(npm|pnpm|yarn|bun)\s+(test|run\s+(test|lint|build|typecheck|check|format)|ci|install|i|list|ls|outdated|audit)\b"#,
        #"^npx\s+(tsc|eslint|prettier|vitest|jest|playwright\s+test)\b"#,
        #"^(composer)\s+(install|dump-autoload|validate|show|outdated)\b"#,
        #"^(php\s+artisan\s+(test|route:list|config:show|about|model:show))\b"#,
        #"^(\./)?vendor/bin/(phpunit|pest|phpstan|pint|psalm)\b"#,
        #"^(swift\s+(build|test|package\s+(resolve|describe))|xcodebuild)\b"#,
        #"^(make\s+(test|lint|check|build))\b"#,
        #"^(python3?\s+-m\s+(pytest|mypy|ruff)|pytest|ruff|mypy)\b"#,
        #"^(node|python3?)\s+--version\b"#,
    ]
}
