import Foundation

/// Hardening for every git call Elio makes on its own in a user folder (IDE views, hover card, diffs, sensors).
/// A repository's own config (.git/config and the files it pulls in with include.path / includeIf) can name
/// programs that even read-only commands run: fsmonitor, pager, editors, external diff, clean/smudge filters,
/// signature verification (log.showSignature + gpg.program), hooks, ssh, credential helpers. Command-line
/// config wins over every config file, so these overrides neutralise them. One source of truth: the IDE
/// (ElioApp) builds its git calls from here too.
public enum GitSafety {
    public static let gitPath = "/usr/bin/git"

    /// No pager, no editor, no optional index writes, never a credential prompt.
    public static let environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "GIT_EDITOR": "true",
                                     "GIT_SEQUENCE_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0"]

    /// Always set: nothing configured by the repo runs while reading it.
    static let always = ["core.fsmonitor=false", "core.pager=cat", "core.editor=true", "sequence.editor=true", "diff.external=",
                         "protocol.ext.allow=never", "protocol.file.allow=never", "log.showSignature=false"]

    /// Signature programs (verification runs them on log/show): off unless a trusted folder signs a commit or tag.
    static let noSigning = ["gpg.program=false", "gpg.ssh.program=false", "gpg.x509.program=false", "gpg.format=openpgp",
                            "commit.gpgSign=false", "tag.gpgSign=false", "push.gpgSign=false"]

    /// Folders the user hasn't trusted: no hooks, plain ssh, no credential helpers or askpass, no submodule recursion
    /// (a nested repository brings its own config).
    static let untrusted = ["core.hooksPath=/dev/null", "core.sshCommand=ssh", "credential.helper=", "core.askPass=",
                            "submodule.recurse=false", "diff.ignoreSubmodules=all"]

    /// Subcommands that may sign (commit.gpgSign, tag.gpgSign, merge commits…).
    static let signingCommands: Set<String> = ["commit", "tag", "merge", "rebase", "cherry-pick", "revert", "pull", "push", "am"]

    /// Global arguments (before the subcommand) for a call in `root`.
    public static func args(trusted: Bool, subcommand: String?) -> [String] {
        var c = always
        if !(trusted && signingCommands.contains(subcommand ?? "")) { c += noSigning }
        if !trusted { c += untrusted }
        return ["--no-pager"] + c.flatMap { ["-c", $0] }
    }

    /// Subcommand flags every diff-producing call gets, whatever the call site passes: no external diff, no
    /// textconv (both are programs named by the repo's .gitattributes + config), no signature verification.
    public static func harden(_ args: [String]) -> [String] {
        guard let sub = args.first else { return args }
        var extra: [String] = []
        switch sub {
        case "diff", "log", "show", "diff-tree", "diff-index", "diff-files", "format-patch", "blame", "annotate", "whatchanged":
            extra = ["--no-ext-diff", "--no-textconv"]
        default: break
        }
        if ["log", "show", "whatchanged"].contains(sub) { extra.append("--no-show-signature") }
        // Always added (repeating a flag is harmless): a path named "--no-textconv" after "--" can't suppress it.
        return extra.isEmpty ? args : [sub] + extra + args.dropFirst()
    }

    /// Environment for a call in `root`: the fixed variables, plus (untrusted folders) every driver program the
    /// repo's config defines blanked. Passed as GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n: a driver name with "=" or
    /// spaces can't break the key the way it would in `-c key=value`.
    public static func environment(_ root: String, trusted: Bool) -> [String: String] {
        var env = environment
        guard !trusted else { return env }
        let keys = driverOverrides(root)
        env["GIT_CONFIG_COUNT"] = "\(keys.count)"
        for (i, kv) in keys.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = kv.key
            env["GIT_CONFIG_VALUE_\(i)"] = kv.value
        }
        return env
    }

    static let driverPattern = #"^(filter\..+\.(clean|smudge|process|required)|diff\..+\.(textconv|command)|merge\..+\.driver)$"#

    /// Drivers defined outside the user's own global/system config (the local file and anything it includes,
    /// worktree config). Filters: programs blanked and `required` off, so a racily-clean file in `status` or a
    /// worktree `diff`/`add` never runs them. Diff textconv/command and merge drivers: blanked (a call that would
    /// still use one fails instead of running it).
    static func driverOverrides(_ root: String) -> [(key: String, value: String)] {
        let r = Exec.run(gitPath, ["-C", root, "--no-pager", "config", "--includes", "--show-scope", "--name-only", "--get-regexp",
                                   driverPattern], timeout: 10)
        return driverOverrides(listing: r.out)
    }

    /// Parses `scope<TAB><section>.<name>.<key>` lines.
    static func driverOverrides(listing: String) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        var filters: [String] = []
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] != "global", parts[0] != "system" else { continue }
            let key = parts[1]
            guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: "."), firstDot < lastDot else { continue }
            let section = key[..<firstDot], name = String(key[key.index(after: firstDot)..<lastDot])
            guard !name.isEmpty else { continue }
            if section == "filter" {
                if !filters.contains(name) { filters.append(name) }
            } else if (section == "diff" || section == "merge"), !out.contains(where: { $0.key == key }) {
                out.append((key: key, value: ""))
            }
        }
        for n in filters {
            out += [("filter.\(n).clean", ""), ("filter.\(n).smudge", ""), ("filter.\(n).process", ""), ("filter.\(n).required", "false")]
                .map { (key: $0.0, value: $0.1) }
        }
        return out
    }

    /// Runs a hardened git command (folders Elio wasn't told to trust). Blocking.
    @discardableResult
    public static func run(_ root: String, _ args: [String], timeout: TimeInterval = 30) -> (code: Int32, out: String, err: String) {
        Exec.run(gitPath, ["-C", root] + Self.args(trusted: false, subcommand: args.first) + harden(args), timeout: timeout,
                 env: environment(root, trusted: false))
    }

    /// stdout of a hardened git command, trimmed; "" on failure.
    public static func output(_ root: String, _ args: [String], timeout: TimeInterval = 30) -> String {
        let r = run(root, args, timeout: timeout)
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}
