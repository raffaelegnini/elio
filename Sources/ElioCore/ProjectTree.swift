import Foundation

/// The user's projects as a tree, discovered on its own: folders that contain git repositories
/// become groups (dev/DNA/magento/…), repositories are leaves, recognised by stack.
/// Only the file system is read; git details are fetched per project on demand.
public struct ProjectNode: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isRepo: Bool
    /// laravel, magento, hyva, shopify, flutter, swift, node, react, vue, python, php…
    public var stack: String?
    public var children: [ProjectNode]

    public var repoCount: Int { isRepo ? 1 : children.reduce(0) { $0 + $1.repoCount } }
    public var repos: [ProjectNode] { isRepo ? [self] : children.flatMap(\.repos) }
}

public enum ProjectTree {
    static let skip: Set<String> = ["node_modules", "vendor", "build", "dist", "Pods", "DerivedData", "target",
                                    "Library", "Applications", "pub", "generated", "var", "storage", "tmp", "cache"]

    public static func scan(roots: [String], maxDepth: Int = 5) -> [ProjectNode] {
        roots.map(expandPath).compactMap { root in
            let name = (root as NSString).lastPathComponent
            guard let node = scanDir(root, name: name, depth: 0, maxDepth: maxDepth) else { return nil }
            return node
        }
    }

    private static func scanDir(_ dir: String, name: String, depth: Int, maxDepth: Int) -> ProjectNode? {
        let fm = FileManager.default
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
            return ProjectNode(name: name, path: dir, isRepo: true, stack: stack(of: dir), children: [])
        }
        guard depth < maxDepth, let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var children: [ProjectNode] = []
        for item in items where !item.hasPrefix(".") && !skip.contains(item) {
            let path = (dir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else { continue }
            if let child = scanDir(path, name: item, depth: depth + 1, maxDepth: maxDepth) { children.append(child) }
        }
        guard !children.isEmpty else { return nil }   // folders without repos inside aren't shown
        // Groups first, then repos, alphabetically.
        children.sort { ($0.isRepo ? 1 : 0, $0.name.lowercased()) < ($1.isRepo ? 1 : 0, $1.name.lowercased()) }
        // A folder holding a single group is collapsed into it ("apps/x" instead of two levels).
        if depth > 0, children.count == 1, !children[0].isRepo {
            var only = children[0]
            only.name = "\(name)/\(only.name)"
            return only
        }
        return ProjectNode(name: name, path: dir, isRepo: false, stack: nil, children: children)
    }

    static func stack(of dir: String) -> String? {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        func contains(_ f: String, _ s: String) -> Bool {
            guard let d = fm.contents(atPath: (dir as NSString).appendingPathComponent(f)) else { return false }
            return String(decoding: d.prefix(200_000), as: UTF8.self).contains(s)
        }
        if has("bin/magento") || has("app/etc/env.php") || contains("composer.json", "magento/") {
            return contains("composer.json", "hyva-themes") || dir.lowercased().contains("hyva") ? "hyva" : "magento"
        }
        if has("artisan") { return "laravel" }
        if has("pubspec.yaml") { return "flutter" }
        if has("Package.swift") || (try? fm.contentsOfDirectory(atPath: dir))?.contains(where: { $0.hasSuffix(".xcodeproj") }) == true { return "swift" }
        if has("config/settings_schema.json") || has("layout/theme.liquid") || has("shopify.theme.toml") { return "shopify" }
        if has("package.json") {
            if contains("package.json", "\"next\"") { return "next" }
            if contains("package.json", "react-native") || contains("package.json", "\"expo\"") { return "react-native" }
            if contains("package.json", "\"vue\"") || contains("package.json", "nuxt") { return "vue" }
            if contains("package.json", "\"react\"") { return "react" }
            return "node"
        }
        if has("composer.json") { return "php" }
        if has("pyproject.toml") || has("requirements.txt") { return "python" }
        if has("go.mod") { return "go" }
        if has("Cargo.toml") { return "rust" }
        return nil
    }

    /// Branch, uncommitted changes, last commit: for the hover card.
    public static func info(_ path: String) -> String {
        let git = { (args: [String]) in ((try? shell("/usr/bin/git", ["-C", path] + args)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"])
        let changes = git(["status", "--porcelain", "--untracked-files=normal"]).split(separator: "\n").count
        let last = git(["log", "-1", "--format=%cr · %s"])
        let remote = git(["remote", "get-url", "origin"])
            .replacingOccurrences(of: #"^.*[:/]([^/:]+/[^/]+?)(\.git)?$"#, with: "$1", options: .regularExpression)
        var lines = ["Branch: \(branch.isEmpty ? "—" : branch)",
                     changes == 0 ? "Nessuna modifica in sospeso" : "\(changes) file modificati",
                     "Ultimo commit: \(last.isEmpty ? "—" : last)"]
        if !remote.isEmpty { lines.append("Remoto: \(remote)") }
        return lines.joined(separator: "\n")
    }
}

public enum ProjectTreeTools {
    static let tree = ElioTool(
        name: "project_tree",
        description: "Albero dei progetti dell'utente (cartelle che raggruppano repository, es. DNA/magento/…), in JSON.",
        properties: [:]
    ) { _, ctx in
        ProjectTree.scan(roots: ctx.config.projectRoots).jsonString()
    }

    static let info = ElioTool(
        name: "project_info",
        description: "Stato git di un progetto: branch, modifiche in sospeso, ultimo commit, remoto.",
        properties: ["path": prop("Percorso assoluto del repository")],
        required: ["path"]
    ) { args, _ in
        let path = expandPath(args["path"] as? String ?? "")
        guard FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) else {
            throw ToolError("Non è un repository: \(path)")
        }
        return ProjectTree.info(path)
    }
}
