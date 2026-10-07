import Foundation

/// Git hooks and repo config run programs later, outside any sandbox (on the user's next commit, status, fetch).
/// Path rules can't fully protect them — an agent can rename `.git` and rebuild it — so this checks the result:
/// a snapshot of the repository's config, hooks and info files, compared when agents end. Anything changed is
/// put back as it was and the user is told.
///
/// It runs outside the sandbox, so it never follows a symlink an agent may have planted (that would let it delete
/// or overwrite files elsewhere): any symlink where a directory or file of the snapshot should be means "don't
/// touch, tell the user".
public struct GitGuard: Sendable {
    struct Entry: Sendable, Equatable { var data: Data; var mode: Int }

    let gitDir: String          // as resolved when the snapshot was taken
    let files: [String: Entry]  // path relative to gitDir → contents + permissions

    static let watched = ["config", "info/attributes", "info/exclude", "commondir", "gitdir"]

    /// The git directory `cwd` belongs to, resolved (nil when it isn't a repository).
    public static func gitDir(_ cwd: String) -> String? {
        let out = GitSafety.output(cwd, ["rev-parse", "--absolute-git-dir"], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: out).resolvingSymlinksInPath().path
    }

    public static func snapshot(_ cwd: String) -> GitGuard? {
        guard let dir = gitDir(cwd), let files = read(dir) else { return nil }
        return GitGuard(gitDir: dir, files: files)
    }

    static func type(_ path: String) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType   // lstat: doesn't follow
    }

    /// Contents of the watched files; nil if a symlink sits anywhere we'd look (gitDir, hooks/, info/, a file).
    static func read(_ gitDir: String) -> [String: Entry]? {
        let fm = FileManager.default
        guard type(gitDir) == .typeDirectory else { return nil }
        for sub in ["hooks", "info"] {
            let p = (gitDir as NSString).appendingPathComponent(sub)
            if let t = type(p), t != .typeDirectory { return nil }
        }
        var files: [String: Entry] = [:]
        func add(_ rel: String) -> Bool {
            let path = (gitDir as NSString).appendingPathComponent(rel)
            guard let t = type(path) else { return true }          // absent
            guard t == .typeRegular else { return false }           // symlink, fifo, dir…: refuse
            let attrs = try? fm.attributesOfItem(atPath: path)
            files[rel] = Entry(data: fm.contents(atPath: path) ?? Data(), mode: (attrs?[.posixPermissions] as? Int) ?? 0o644)
            return true
        }
        for rel in watched where !add(rel) { return nil }
        let hooks = (gitDir as NSString).appendingPathComponent("hooks")
        for name in (try? fm.contentsOfDirectory(atPath: hooks)) ?? [] where !name.hasSuffix(".sample") {
            if !add("hooks/" + name) { return nil }
        }
        return files
    }

    /// Replaces (or with nil deletes) one watched file without ever following a symlink, even one swapped in after
    /// the checks above: the git dir and its subfolder are opened with O_NOFOLLOW and the file is unlinked and
    /// recreated relative to those descriptors (O_EXCL: a name that reappears in between makes it fail, not follow).
    static func rewrite(_ gitDir: String, _ rel: String, _ entry: Entry?) -> Bool {
        let root = open(gitDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return false }
        defer { close(root) }
        let parts = rel.split(separator: "/").map(String.init)
        guard let name = parts.last, parts.count <= 2 else { return false }
        var dir = root
        if parts.count == 2 {
            dir = openat(root, parts[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { return false }
        }
        defer { if dir != root { close(dir) } }
        if unlinkat(dir, name, 0) != 0 && errno != ENOENT { return false }
        guard let entry else { return true }
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(entry.mode & 0o777))
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let ok = entry.data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        _ = fchmod(fd, mode_t(entry.mode & 0o777))
        return ok
    }

    /// Compares with now and restores what changed. Returns a short Italian description of what was undone, or
    /// of why it couldn't be checked safely (nil if nothing changed).
    public func verifyAndRestore() -> String? {
        let fm = FileManager.default
        guard Self.type(gitDir) == .typeDirectory else {
            return "la cartella .git del repository è sparita o è stata sostituita (\(gitDir)): controlla il progetto prima di usare git"
        }
        guard let now = Self.read(gitDir) else {
            return "nella cartella .git ci sono collegamenti simbolici al posto di hook o configurazione: non li ho toccati, controlla tu prima di usare git"
        }
        var changed: [String] = []
        var failed: [String] = []
        for (rel, entry) in files where now[rel] != entry {
            if Self.rewrite(gitDir, rel, entry) { changed.append(rel) } else { failed.append(rel) }
        }
        for rel in now.keys where files[rel] == nil {
            if Self.rewrite(gitDir, rel, nil) { changed.append(rel) } else { failed.append(rel) }
        }
        if !failed.isEmpty {
            return "non sono riuscito a ripristinare in sicurezza " + failed.sorted().joined(separator: ", ") + " (forse un collegamento simbolico): controlla la cartella .git prima di usare git"
        }
        guard !changed.isEmpty else { return nil }
        return "ho annullato modifiche a " + changed.sorted().joined(separator: ", ")
    }
}

/// One baseline per repository while agents work in it: a second agent starting in the same repo must not take a
/// snapshot of what the first one may already have changed (it would later "restore" a planted hook).
public final class GitGuards: @unchecked Sendable {
    public static let shared = GitGuards()
    private let lock = NSLock()
    private var baselines: [String: (guard: GitGuard, agents: Set<String>)] = [:]
    private var byAgent: [String: String] = [:]

    /// Called when an agent starts in `cwd`.
    /// Repos that couldn't be snapshotted safely when an agent started (a symlink already in .git): reported when
    /// that agent ends instead of silently skipping the check.
    private var unsafeAtStart: [String: String] = [:]

    public func begin(agent: String, cwd: String) {
        guard let dir = GitGuard.gitDir(cwd) else { return }
        lock.withLock {
            if baselines[dir] == nil {
                guard let g = GitGuard.snapshot(cwd) else { unsafeAtStart[agent] = dir; return }
                baselines[dir] = (g, [])
            }
            baselines[dir]?.agents.insert(agent)
            byAgent[agent] = dir
        }
    }

    /// Called when an agent ends: checks against the repo's baseline (restoring it), releases it when no agent is
    /// left. Returns what was undone, if anything.
    public func end(agent: String) -> String? {
        lock.withLock {
            if let dir = unsafeAtStart.removeValue(forKey: agent) {
                return "già alla partenza dell'agente nella cartella .git di \(dir) c'erano collegamenti simbolici al posto di hook o configurazione: non ho potuto controllarla, verifica tu prima di usare git"
            }
            guard let dir = byAgent.removeValue(forKey: agent), let entry = baselines[dir] else { return nil }
            let undone = entry.guard.verifyAndRestore()
            baselines[dir]?.agents.remove(agent)
            if baselines[dir]?.agents.isEmpty == true { baselines[dir] = nil }
            return undone
        }
    }
}
