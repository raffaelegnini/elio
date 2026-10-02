import Foundation

/// Makes the user's Claude skills available to Elio's session, and keeps them in sync.
///
/// The session only loads the Elio workspace's project settings (to keep the user's hooks and
/// plugins out), so user skills aren't seen by default. Every skill folder found in
/// ~/.claude/skills (also the ones synced from claude.ai, and those linked from ~/.agents) is
/// symlinked into <workspace>/.claude/skills. A change (new, removed or edited skill) is
/// reported so the session can be rebuilt on the next message.
public enum SkillSync {
    static var sources: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/skills"), home.appendingPathComponent(".agents/skills")]
    }
    static var target: URL { ElioPaths.claudeWorkspace.appendingPathComponent(".claude/skills", isDirectory: true) }

    /// Skills that would change how Elio speaks rather than add abilities.
    static let excluded: [String] = ["caveman"]

    /// name → folder of every skill (a folder with SKILL.md), searched two levels deep.
    static func discover() -> [String: URL] {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        func visit(_ dir: URL, depth: Int) {
            guard depth <= 3, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                let real = item.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: real.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if fm.fileExists(atPath: real.appendingPathComponent("SKILL.md").path) {
                    let name = item.lastPathComponent
                    guard !excluded.contains(where: { name.hasPrefix($0) }) else { continue }
                    if found[name] == nil { found[name] = real }
                } else {
                    visit(real, depth: depth + 1)
                }
            }
        }
        sources.forEach { visit($0, depth: 0) }
        return found
    }

    /// Signature of the skills' content: changes when one is added, removed or edited.
    static func signature(_ skills: [String: URL]) -> String {
        skills.keys.sorted().map { name -> String in
            let md = skills[name]!.appendingPathComponent("SKILL.md")
            let date = (try? FileManager.default.attributesOfItem(atPath: md.path)[.modificationDate] as? Date) ?? .distantPast
            return "\(name)@\(Int(date.timeIntervalSince1970))"
        }.joined(separator: "|")
    }

    /// Mirrors the skills into the workspace as symlinks. Returns the skill names.
    @discardableResult
    static func link(_ skills: [String: URL]) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        // Remove links that no longer point to a skill (only our symlinks, never real folders).
        for item in (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] {
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil
            if isLink, skills[item.lastPathComponent] == nil { try? fm.removeItem(at: item) }
        }
        for (name, url) in skills {
            let link = target.appendingPathComponent(name)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), dest == url.path { continue }
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { try? fm.removeItem(at: link) }
            guard !fm.fileExists(atPath: link.path) else { continue }   // a real folder the user put there
            try? fm.createSymbolicLink(at: link, withDestinationURL: url)
        }
        return skills.keys.sorted()
    }

    /// Links now, then checks every `interval` seconds; calls `changed` when skills change.
    public static func start(every interval: TimeInterval = 60, changed: @escaping @Sendable ([String]) async -> Void) {
        Task.detached {
            var last = ""
            while true {
                let skills = discover()
                let sig = signature(skills)
                if sig != last {
                    let names = link(skills)
                    if !last.isEmpty { await changed(names) }
                    last = sig
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}
