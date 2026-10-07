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

    /// Contents of the watched files; nil if a symlink (or anything but a regular file / real folder) sits anywhere
    /// we'd look. Everything is read through descriptors opened with O_NOFOLLOW, so nothing swapped in between a
    /// check and the read can make it read (and later write back into the repo) a file from elsewhere.
    static func read(_ gitDir: String) -> [String: Entry]? {
        let root = open(gitDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { close(root) }
        var files: [String: Entry] = [:]
        // nil = refuse (not a regular file); .some(nil) = absent.
        func readFile(_ dir: Int32, _ name: String) -> Entry?? {
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0 { return errno == ENOENT ? .some(nil) : nil }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 4_000_000 else { return nil }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 { return nil }
                if n == 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            return .some(Entry(data: data, mode: Int(st.st_mode & 0o777)))
        }
        func subdir(_ name: String) -> Int32?? {
            let fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { return errno == ENOENT ? .some(nil) : nil }
            return .some(fd)
        }
        for rel in watched {
            let parts = rel.split(separator: "/").map(String.init)
            var dir = root
            if parts.count == 2 {
                guard let sub = subdir(parts[0]) else { return nil }
                guard let fd = sub else { continue }
                dir = fd
            }
            let r = readFile(dir, parts.last!)
            if dir != root { close(dir) }
            guard let entry = r else { return nil }
            if let entry { files[rel] = entry }
        }
        guard let hooksFd = subdir("hooks") else { return nil }
        if let hd = hooksFd {
            // fdopendir takes ownership of its descriptor: give it a duplicate, read files relative to the original.
            guard let d = fdopendir(dup(hd)) else { close(hd); return nil }
            var names: [String] = []
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
                if name != ".", name != "..", !name.hasSuffix(".sample") { names.append(name) }
            }
            closedir(d)
            for name in names {
                guard let r = readFile(hd, name) else { close(hd); return nil }
                if let entry = r { files["hooks/" + name] = entry }
            }
            close(hd)
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
