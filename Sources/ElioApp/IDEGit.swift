import Foundation
import ElioCore

/// Git for the IDE: parsed views (status, branches, log graph, commit details, blame) and the one-shot
/// commands the page runs through `raw`. The page confirms destructive ones before calling.
enum IDEGit {
    /// Every git call goes through here: no credential prompts (no terminal to answer them), no optional
    /// index writes (our own `status` must not wake the file watcher in a loop), and the hardening of `GitSafety`.
    static func git(_ root: String, _ args: [String], timeout: TimeInterval = 60, batch: Bool = false, stdin: Data? = nil) -> IDEProc.Output {
        let trusted = IDETrust.isTrusted(root)
        var env = GitSafety.environment(root, trusted: trusted)
        if batch { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10" }
        return IDEProc.run(GitSafety.gitPath, ["-C", root] + safetyConfig(trusted: trusted, subcommand: args.first) + GitSafety.harden(args),
                           timeout: timeout, env: env, stdin: stdin)
    }

    /// A repo-local .git/config (and the files it includes) can run programs: fsmonitor, external diff, hooks, ssh
    /// command, clean/smudge filters, gpg.program through log.showSignature. The IDE's own calls never run them;
    /// hooks, the repo's ssh command and signing stay only in folders the user trusts (see `GitSafety`).
    static func safetyConfig(trusted: Bool, subcommand: String?) -> [String] {
        ["-c", "color.ui=false", "-c", "core.quotepath=false"] + GitSafety.args(trusted: trusted, subcommand: subcommand)
    }

    /// Ops that can reach the network, merge or run hooks/drivers from the repo's config: only in trusted folders
    /// (the page asks first). Read-only views (status, log, show, blame, branches) stay allowed, hardened.
    /// add / reset / rollback write the index or the work tree through the repo's filter drivers: trusted folders only
    /// too (filters are blanked elsewhere, this keeps the blanking from being the only guard).
    static let userOps: Set<String> = ["commit", "push", "pull", "fetch", "checkout", "rollback"]
    static let trustedRaw: Set<String> = ["fetch", "pull", "push", "merge", "rebase", "cherry-pick", "revert", "stash", "checkout", "commit",
                                          "add", "reset"]

    // MARK: Argument safety

    /// Ref names, remotes and hashes come from the repository (a cloned repo can carry a ref named "--upload-pack=…"):
    /// nothing page-supplied may start with "-" unless it is one of the flags the IDE itself uses.
    private static let rawCommands: Set<String> = ["add", "branch", "checkout", "cherry-pick", "diff", "fetch", "log", "merge", "pull",
                                                   "push", "rebase", "reset", "revert", "stash", "tag", "show", "rev-parse"]
    private static let allowedFlags: Set<String> = ["--rebase", "--no-rebase", "--autostash", "--no-edit", "-m", "-d", "-D", "-b", "--track",
                                                    "--delete", "-u", "-q", "--soft", "--mixed", "--hard", "--keep", "--name-status", "-M",
                                                    "-n", "-1", "--force-with-lease", "--", "--end-of-options", "push", "pop", "--abbrev-ref", "--merge"]
    private static let forbidden = ["--upload-pack", "--receive-pack", "--exec", "-c", "--config", "--config-env", "core.sshcommand",
                                    "core.pager", "core.editor", "core.hookspath", "--output", "--ext-diff", "-o"]

    static func unsafeArg(_ a: String) -> Bool {
        if a.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" }) { return true }
        let low = a.lowercased()
        if forbidden.contains(where: { low == $0 || low.hasPrefix($0 + "=") || low.contains("core.sshcommand") || low.contains("core.pager") }) { return true }
        return false
    }

    /// nil when the argv is acceptable for `raw`, else the reason.
    static func validateRaw(_ args: [String]) -> String? {
        guard let sub = args.first, rawCommands.contains(sub) else { return "comando git non consentito: \(args.first ?? "")" }
        var afterDashes = false
        for a in args.dropFirst() {
            if unsafeArg(a) { return "argomento git non consentito: \(a)" }
            if afterDashes { continue }
            if a == "--" || a == "--end-of-options" { afterDashes = true; continue }
            if a.hasPrefix("-") && !allowedFlags.contains(a) && !a.hasPrefix("--format=") && !(a.hasPrefix("-") && Int(a.dropFirst()) != nil) {
                return "opzione git non consentita: \(a)"
            }
        }
        return nil
    }

    /// A revision/ref from the page: never an option, no control characters, no "-"-led path component.
    static func safeRev(_ r: String) -> Bool {
        !r.isEmpty && !r.hasPrefix("-") && !r.contains("/-") && !r.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } && !r.contains("..")
            || r.range(of: #"^[0-9a-fA-F]{4,40}(\^|~\d*)?$"#, options: .regularExpression) != nil
    }

    private static func lines(_ s: String) -> [String] { s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    static func run(root: String, cmd: String, args: [String], opts: [String: Any]) -> [String: Any] {
        func ok(_ r: IDEProc.Output) -> [String: Any] { ["ok": r.ok, "output": r.all.trimmingCharacters(in: .whitespacesAndNewlines)] }
        func refused(_ why: String) -> [String: Any] { ["ok": false, "output": why, "content": "", "exists": false] }
        let needsTrust = userOps.contains(cmd) || (cmd == "raw" && trustedRaw.contains(args.first ?? ""))
        if needsTrust && !IDETrust.isTrusted(root) {
            if cmd == "fetch" && opts["background"] as? Bool == true { return ["ok": false, "output": "", "skipped": true] }
            return ["ok": false, "untrusted": true, "output": "Cartella non ancora fidata: conferma prima di eseguire operazioni git che usano la sua configurazione (hook, remoti, driver)."]
        }
        switch cmd {
        case "status": return status(root)
        case "branches": return branches(root)
        case "graph":
            if let b = opts["branch"] as? String, !b.isEmpty, !safeRev(b) { return ["commits": [], "error": "branch non valido"] }
            for k in ["author", "text"] { if let v = opts[k] as? String, unsafeArg(v) { return ["commits": [], "error": "filtro non valido"] } }
            return graph(root, opts)
        case "commitInfo":
            let hash = opts["hash"] as? String ?? ""
            guard hash.range(of: #"^[0-9a-fA-F]{4,40}$"#, options: .regularExpression) != nil else { return [:] }
            return commitInfo(root, hash)
        case "blame": return blame(root, args.first ?? "")
        case "show":
            // args: [path relative to root, rev = HEAD]. "./" makes the path relative to root, not the repo top.
            let rev = args.count > 1 ? args[1] : "HEAD"
            guard safeRev(rev) else { return refused("revisione non valida") }
            var path = args.first ?? ""
            if path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
            let r = git(root, ["show", "--no-textconv", "--no-show-signature", "\(rev):./\(path)"], timeout: 20)
            return ["content": r.ok ? r.out : "", "exists": r.ok]
        case "log":
            // History of a path (or of everything).
            let r = git(root, ["log", "--no-ext-diff", "--no-textconv", "--no-show-signature", "-60", "--format=%H%x1f%h%x1f%an%x1f%ar%x1f%s%x1f%at", "--follow", "--"] + (args.isEmpty ? ["."] : args))
            return ["commits": lines(r.out).map { line in
                let p = line.components(separatedBy: "\u{1f}")
                return ["full": p[safe: 0] ?? "", "hash": p[safe: 1] ?? "", "author": p[safe: 2] ?? "", "when": p[safe: 3] ?? "",
                        "subject": p[safe: 4] ?? "", "at": Double(p[safe: 5] ?? "") ?? 0]
            }]
        case "commit": return commit(root, opts)
        case "pushInfo": return pushInfo(root)
        case "push":
            // args: extra flags from the page (--force-with-lease, -u origin branch…); never --force alone.
            // Only the shapes the push dialog builds: [--force-with-lease] [-u <remote> <branch>].
            var pushArgs: [String] = []
            var rest = args[...]
            if rest.first == "--force-with-lease" { pushArgs.append("--force-with-lease"); rest = rest.dropFirst() }
            if rest.first == "-u" {
                let tail = Array(rest.dropFirst())
                guard tail.count == 2, tail.allSatisfy(safeRev) else { return refused("push non valido") }
                pushArgs += ["-u", "--end-of-options"] + tail
                rest = []
            }
            guard rest.isEmpty else { return refused("push non valido") }
            let r = git(root, ["push", "--porcelain"] + pushArgs, timeout: 180)
            return ok(r)
        case "pull":
            let r = git(root, ["pull", args.contains("--rebase") ? "--rebase" : "--no-rebase", "--autostash"], timeout: 180)
            return ok(r)
        case "fetch":
            let background = opts["background"] as? Bool ?? false
            let r = git(root, ["fetch", "--all", "--prune", "--quiet"], timeout: 120, batch: background)
            return ok(r)
        case "checkout":
            guard args.allSatisfy(safeRev) else { return refused("revisione non valida") }
            return ok(git(root, ["checkout", "--end-of-options"] + args))
        case "rollback":
            // Tracked files back to HEAD (staged and unstaged); added files are only unstaged (they stay on disk).
            let added = opts["added"] as? [String] ?? []
            var out: [String] = []
            var good = true
            if !added.isEmpty { let r = git(root, ["reset", "-q", "--"] + added); good = good && r.ok; out.append(r.all) }
            let tracked = args.filter { !added.contains($0) }
            if !tracked.isEmpty { let r = git(root, ["checkout", "HEAD", "--"] + tracked); good = good && r.ok; out.append(r.all) }
            return ["ok": good, "output": out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)]
        case "raw":
            if let why = validateRaw(args) { return refused(why) }
            var argv = args
            if ["diff", "log", "show"].contains(args.first ?? "") { argv.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 1) }
            if ["log", "show"].contains(args.first ?? "") { argv.insert("--no-show-signature", at: 1) }
            return ok(git(root, argv, timeout: opts["timeout"] as? Double ?? 120))
        case "toplevel":
            let r = git(root, ["rev-parse", "--show-toplevel"], timeout: 10)
            return ["ok": r.ok, "top": r.out.trimmingCharacters(in: .whitespacesAndNewlines)]
        default:
            return ["ok": false, "output": "comando git non previsto: \(cmd)"]
        }
    }

    // MARK: Status

    /// One `git status --porcelain=v2` per root: branch, tracking, changes, untracked and ignored paths (absolute).
    static func status(_ root: String) -> [String: Any] {
        let rp = git(root, ["rev-parse", "--show-toplevel", "--absolute-git-dir"], timeout: 10)
        guard rp.ok else { return ["repo": false] }
        let rpl = lines(rp.out)
        let top = rpl.first ?? root, gitDir = rpl[safe: 1] ?? top + "/.git"
        // Untrusted: no recursion into submodules (a nested repo brings config whose filters we haven't blanked).
        let sub = IDETrust.isTrusted(top) ? [] : ["--ignore-submodules=all"]
        let r = git(top, ["status", "--porcelain=v2", "-z", "--branch", "-uall", "--ignored=matching"] + sub, timeout: 60)
        guard r.ok else { return ["repo": true, "top": top, "error": r.err] }
        var branch = "", upstream = "", oid = "", ahead = 0, behind = 0
        var files: [[String: Any]] = [], ignored: [String] = []
        let tokens = r.out.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        func abs(_ p: String) -> String { top + "/" + (p.hasSuffix("/") ? String(p.dropLast()) : p) }
        while i < tokens.count {
            let t = tokens[i]; i += 1
            guard let first = t.first else { continue }
            switch first {
            case "#":
                let parts = t.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.head": branch = parts[2]
                case "branch.oid": oid = parts[2]
                case "branch.upstream": upstream = parts[2]
                case "branch.ab":
                    let ab = parts[2].split(separator: " ")
                    ahead = Int(ab.first?.dropFirst() ?? "0") ?? 0
                    behind = Int(ab.last?.dropFirst() ?? "0") ?? 0
                default: break
                }
            case "1", "2", "u":
                let fields = first == "1" ? 8 : first == "2" ? 9 : 10
                let parts = t.split(separator: " ", maxSplits: fields, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == fields + 1 else { continue }
                let xy = Array(parts[1])
                let x = String(xy[0]), y = String(xy[1])
                var f: [String: Any] = ["path": abs(parts[fields]), "x": x, "y": y]
                if first == "2", i < tokens.count { f["from"] = abs(tokens[i]); i += 1 }
                let kind: String
                if first == "u" || (x == "A" && y == "A") || (x == "D" && y == "D") { kind = "C" }
                else if x == "A" { kind = "A" }
                else if x == "D" || y == "D" { kind = "D" }
                else if first == "2" { kind = "R" }
                else { kind = "M" }
                f["kind"] = kind
                if files.count < 20_000 { files.append(f) }
            case "?":
                if files.count < 20_000 { files.append(["path": abs(String(t.dropFirst(2))), "x": "?", "y": "?", "kind": "U"]) }
            case "!":
                if ignored.count < 5_000 { ignored.append(abs(String(t.dropFirst(2)))) }
            default: break
            }
        }
        let fm = FileManager.default
        let state = fm.fileExists(atPath: gitDir + "/MERGE_HEAD") ? "merging" :
            fm.fileExists(atPath: gitDir + "/rebase-merge") || fm.fileExists(atPath: gitDir + "/rebase-apply") ? "rebasing" :
            fm.fileExists(atPath: gitDir + "/CHERRY_PICK_HEAD") ? "cherry-picking" : fm.fileExists(atPath: gitDir + "/REVERT_HEAD") ? "reverting" : ""
        let detached = branch == "(detached)"
        return ["repo": true, "top": top, "branch": detached ? String(oid.prefix(8)) : branch, "detached": detached, "oid": oid,
                "upstream": upstream, "ahead": ahead, "behind": behind, "files": files, "ignored": ignored, "state": state]
    }

    // MARK: Branches

    static func branches(_ root: String) -> [String: Any] {
        let fmt = "%(refname)%00%(objectname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(HEAD)%00%(subject)"
        let r = git(root, ["for-each-ref", "--sort=-committerdate", "--format=" + fmt, "refs/heads", "refs/remotes", "refs/tags"], timeout: 20)
        var local: [[String: Any]] = [], remote: [[String: Any]] = [], tags: [[String: Any]] = []
        var current = ""
        for line in lines(r.out) {
            let p = line.components(separatedBy: "\0")
            guard p.count >= 7 else { continue }
            let ref = p[0]
            var b: [String: Any] = ["ref": ref, "hash": p[1], "upstream": p[2], "track": p[3], "date": Double(p[4]) ?? 0, "subject": p[6]]
            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst(11))
                b["name"] = name
                if p[5] == "*" { current = name; b["current"] = true }
                local.append(b)
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst(13))
                if name.hasSuffix("/HEAD") { continue }
                b["name"] = name
                remote.append(b)
            } else if ref.hasPrefix("refs/tags/"), tags.count < 300 {
                b["name"] = String(ref.dropFirst(10))
                tags.append(b)
            }
        }
        // Recently checked-out branches, from the reflog (what PhpStorm calls "Recent").
        var recent: [String] = []
        let names = Set(local.compactMap { $0["name"] as? String })
        for line in lines(git(root, ["reflog", "-n", "400", "--format=%gs"], timeout: 10).out) where line.hasPrefix("checkout: moving from ") {
            guard let to = line.components(separatedBy: " to ").last, names.contains(to), !recent.contains(to) else { continue }
            recent.append(to)
            if recent.count >= 6 { break }
        }
        if !current.isEmpty, !recent.contains(current) { recent.insert(current, at: 0) }
        let remotes = lines(git(root, ["remote"], timeout: 10).out)
        return ["current": current, "local": local, "remote": remote, "tags": tags, "recent": recent, "remotes": remotes]
    }

    // MARK: Log graph

    /// One page of the commit graph. Lanes are computed by the page (it keeps them across pages).
    static func graph(_ root: String, _ o: [String: Any]) -> [String: Any] {
        let skip = o["skip"] as? Int ?? 0, limit = o["limit"] as? Int ?? 300
        var args = ["log", "--no-ext-diff", "--no-textconv", "--no-show-signature", "--date-order", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s%x1e", "--skip=\(skip)", "-n", "\(limit)"]
        if let author = o["author"] as? String, !author.isEmpty { args.append("--author=\(author)"); args.append("-i") }
        if let text = o["text"] as? String, !text.isEmpty { args += ["--grep=\(text)", "-i"] }
        if let branch = o["branch"] as? String, !branch.isEmpty { args.append(branch) } else { args.append("--all") }
        if let path = o["path"] as? String, !path.isEmpty { args += ["--", path] }
        let r = git(root, args, timeout: 60)
        let commits: [[String: Any]] = r.out.components(separatedBy: "\u{1e}").compactMap { rec in
            let rec = rec.trimmingCharacters(in: .newlines)
            let p = rec.components(separatedBy: "\0")
            guard p.count >= 7, p[0].count >= 7 else { return nil }
            return ["hash": p[0], "parents": p[1].split(separator: " ").map(String.init), "author": p[2], "email": p[3],
                    "at": Double(p[4]) ?? 0, "refs": p[5].isEmpty ? [] : p[5].components(separatedBy: ", "), "subject": p[6]]
        }
        let head = git(root, ["rev-parse", "HEAD"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["commits": commits, "head": head, "error": r.ok ? "" : r.err]
    }

    static func commitInfo(_ root: String, _ hash: String) -> [String: Any] {
        guard !hash.isEmpty else { return [:] }
        let info = git(root, ["show", "-s", "--no-show-signature", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ct%x00%D%x00%B", hash], timeout: 15)
        let p = info.out.components(separatedBy: "\0")
        let parents = (p[safe: 1] ?? "").split(separator: " ").map(String.init)
        let diff = parents.isEmpty ? git(root, ["diff-tree", "--root", "-r", "--name-status", "-M", "--no-commit-id", hash], timeout: 30)
                                   : git(root, ["diff", "--no-ext-diff", "--no-textconv", "--name-status", "-M", parents[0], hash], timeout: 30)
        let files: [[String: Any]] = lines(diff.out).prefix(3000).compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2 else { return nil }
            var o: [String: Any] = ["status": String(f[0].prefix(1)), "path": f.last!]
            if f.count == 3 { o["from"] = f[1] }
            return o
        }
        let top = git(root, ["rev-parse", "--show-toplevel"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["hash": p[safe: 0] ?? hash, "parents": parents, "author": p[safe: 2] ?? "", "email": p[safe: 3] ?? "",
                "at": Double(p[safe: 4] ?? "") ?? 0, "committer": p[safe: 5] ?? "", "cat": Double(p[safe: 6] ?? "") ?? 0,
                "refs": p[safe: 7] ?? "", "body": (p[safe: 8] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "files": files, "top": top]
    }

    // MARK: Blame

    static func blame(_ root: String, _ path: String) -> [String: Any] {
        guard !unsafeArg(path) else { return ["ok": false, "output": "percorso non valido"] }
        let r = git(root, ["blame", "--no-textconv", "--porcelain", "--", path], timeout: 30)
        guard r.ok else { return ["ok": false, "output": r.err] }
        var commits: [String: [String: Any]] = [:]
        var lineHashes: [String] = []
        var current = ""
        for raw in r.out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") { lineHashes.append(current); continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            if let h = parts.first, h.count == 40, h.allSatisfy(\.isHexDigit) {
                current = String(h)
                if commits[current] == nil { commits[current] = [:] }
                continue
            }
            guard parts.count == 2 else { continue }
            let key = String(parts[0]), value = String(parts[1])
            switch key {
            case "author": commits[current]?["author"] = value
            case "author-time": commits[current]?["at"] = Double(value) ?? 0
            case "summary": commits[current]?["summary"] = value
            default: break
            }
        }
        return ["ok": true, "lines": lineHashes, "commits": commits]
    }

    // MARK: Commit / push

    /// Commits the chosen paths only (or everything): untracked ones are added first, `--only` semantics for the rest.
    static func commit(_ root: String, _ o: [String: Any]) -> [String: Any] {
        let message = o["message"] as? String ?? ""
        let paths = o["paths"] as? [String] ?? []
        let untracked = o["untracked"] as? [String] ?? []
        let amend = o["amend"] as? Bool ?? false
        let all = o["all"] as? Bool ?? false
        if all {
            let add = git(root, ["add", "-A"])
            guard add.ok else { return ["ok": false, "output": add.all] }
            let r = git(root, ["commit", "-m", message] + (amend ? ["--amend"] : []))
            return ["ok": r.ok, "output": r.all]
        }
        if !untracked.isEmpty {
            let add = git(root, ["add", "--"] + untracked)
            guard add.ok else { return ["ok": false, "output": add.all] }
        }
        guard !paths.isEmpty || amend else { return ["ok": false, "output": "Nessun file scelto"] }
        let r = git(root, ["commit", "-m", message] + (amend ? ["--amend"] : []) + (paths.isEmpty ? [] : ["--only", "--"] + paths))
        return ["ok": r.ok, "output": r.all]
    }

    static func pushInfo(_ root: String) -> [String: Any] {
        let branch = git(root, ["rev-parse", "--abbrev-ref", "HEAD"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let up = git(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 10)
        let upstream = up.ok ? up.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let range = upstream.isEmpty ? ["HEAD", "--not", "--remotes"] : ["@{u}..HEAD"]
        let log = git(root, ["log", "--no-show-signature", "-200", "--format=%h%x1f%s%x1f%an%x1f%ar"] + range, timeout: 20)
        let commits = lines(log.out).map { l -> [String: String] in
            let p = l.components(separatedBy: "\u{1f}")
            return ["hash": p[safe: 0] ?? "", "subject": p[safe: 1] ?? "", "author": p[safe: 2] ?? "", "when": p[safe: 3] ?? ""]
        }
        let remotes = lines(git(root, ["remote"], timeout: 10).out)
        return ["branch": branch, "upstream": upstream, "commits": commits, "remotes": remotes]
    }
}
