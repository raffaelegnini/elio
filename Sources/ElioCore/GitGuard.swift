import Foundation

/// Git hooks and repo config run programs later, outside any sandbox (on the user's next commit, status, fetch).
/// Path rules can't fully protect them — an agent can rename `.git` and rebuild it — so this checks the result:
/// a snapshot of the repository's config, hooks and info/attributes before an agent starts, compared when it ends.
/// Anything changed is put back as it was and the user is told.
public struct GitGuard: Sendable {
    let gitDir: String
    let files: [String: Data]      // path relative to gitDir → contents

    static let watched = ["config", "info/attributes", "info/exclude", "commondir", "gitdir"]

    /// Snapshot of the repository `cwd` belongs to (nil when it isn't one).
    public static func snapshot(_ cwd: String) -> GitGuard? {
        let out = GitSafety.output(cwd, ["rev-parse", "--absolute-git-dir"], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.hasPrefix("/") else { return nil }
        return GitGuard(gitDir: out, files: read(out))
    }

    static func read(_ gitDir: String) -> [String: Data] {
        let fm = FileManager.default
        var files: [String: Data] = [:]
        for rel in watched {
            if let d = fm.contents(atPath: (gitDir as NSString).appendingPathComponent(rel)) { files[rel] = d }
        }
        let hooks = (gitDir as NSString).appendingPathComponent("hooks")
        for name in (try? fm.contentsOfDirectory(atPath: hooks)) ?? [] where !name.hasSuffix(".sample") {
            let rel = "hooks/" + name
            files[rel] = fm.contents(atPath: (gitDir as NSString).appendingPathComponent(rel)) ?? Data()
        }
        return files
    }

    /// Compares with now; restores what changed. Returns a short Italian description of what was undone (nil if
    /// nothing changed).
    public func verifyAndRestore() -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir, isDirectory: &isDir), isDir.boolValue else {
            return "la cartella .git del repository è sparita o è stata sostituita (\(gitDir)): controlla il progetto prima di usare git"
        }
        let now = Self.read(gitDir)
        var changed: [String] = []
        for (rel, data) in files where now[rel] != data {
            let path = (gitDir as NSString).appendingPathComponent(rel)
            try? fm.removeItem(atPath: path)   // a symlink planted in its place goes too
            fm.createFile(atPath: path, contents: data,
                          attributes: rel.hasPrefix("hooks/") ? [.posixPermissions: 0o755] : nil)
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
