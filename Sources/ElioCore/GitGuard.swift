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
        for (rel, entry) in files where now[rel] != entry {
            let path = (gitDir as NSString).appendingPathComponent(rel)
            // read() just verified the parents are real directories and the file isn't a symlink.
            try? fm.removeItem(atPath: path)
            fm.createFile(atPath: path, contents: entry.data, attributes: [.posixPermissions: entry.mode])
            changed.append(rel)
        }
        for rel in now.keys where files[rel] == nil {
            try? fm.removeItem(atPath: (gitDir as NSString).appendingPathComponent(rel))
            changed.append(rel)
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
    public func begin(agent: String, cwd: String) {
        guard let dir = GitGuard.gitDir(cwd) else { return }
        lock.withLock {
            if baselines[dir] == nil {
                guard let g = GitGuard.snapshot(cwd) else { return }
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
            guard let dir = byAgent.removeValue(forKey: agent), let entry = baselines[dir] else { return nil }
            let undone = entry.guard.verifyAndRestore()
            baselines[dir]?.agents.remove(agent)
            if baselines[dir]?.agents.isEmpty == true { baselines[dir] = nil }
            return undone
        }
    }
}
