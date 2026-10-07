import Foundation
import Testing
@testable import ElioCore

struct GitGuardTests {
    @Test func restoresHooksAndConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitguard-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = GitSafety.run(dir, ["init", "-q"])
        let git = dir + "/.git"
        let config = try String(contentsOfFile: git + "/config", encoding: .utf8)
        let snap = try #require(GitGuard.snapshot(dir))
        #expect(snap.verifyAndRestore() == nil)
        try "#!/bin/sh\ntouch /tmp/pwned\n".write(toFile: git + "/hooks/pre-commit", atomically: true, encoding: .utf8)
        try (config + "[core]\n\tfsmonitor = /tmp/x\n").write(toFile: git + "/config", atomically: true, encoding: .utf8)
        let undone = try #require(snap.verifyAndRestore())
        #expect(undone.contains("config") && undone.contains("hooks/pre-commit"))
        #expect(!FileManager.default.fileExists(atPath: git + "/hooks/pre-commit"))
        #expect(try String(contentsOfFile: git + "/config", encoding: .utf8) == config)
    }

    @Test func neverFollowsASymlinkedHooksFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitguard-\(UUID().uuidString)").path
        let dir = base + "/repo", victim = base + "/victim"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: victim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        _ = GitSafety.run(dir, ["init", "-q"])
        try "keep".write(toFile: victim + "/important.plist", atomically: true, encoding: .utf8)
        let snap = try #require(GitGuard.snapshot(dir))
        try FileManager.default.removeItem(atPath: dir + "/.git/hooks")
        try FileManager.default.createSymbolicLink(atPath: dir + "/.git/hooks", withDestinationPath: victim)
        let msg = try #require(snap.verifyAndRestore())
        #expect(msg.contains("simbolici"))
        #expect(FileManager.default.fileExists(atPath: victim + "/important.plist"))
    }

    @Test func secondAgentKeepsTheFirstBaseline() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitguard-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = GitSafety.run(dir, ["init", "-q"])
        GitGuards.shared.begin(agent: "a", cwd: dir)
        try "#!/bin/sh\n".write(toFile: dir + "/.git/hooks/pre-commit", atomically: true, encoding: .utf8)
        GitGuards.shared.begin(agent: "b", cwd: dir)   // must not adopt the planted hook as "original"
        _ = GitGuards.shared.end(agent: "a")
        try "#!/bin/sh\n".write(toFile: dir + "/.git/hooks/pre-commit", atomically: true, encoding: .utf8)
        #expect(GitGuards.shared.end(agent: "b") != nil)
        #expect(!FileManager.default.fileExists(atPath: dir + "/.git/hooks/pre-commit"))
    }

    @Test func symlinkAlreadyThereAtStartIsReported() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitguard-\(UUID().uuidString)").path
        let dir = base + "/repo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        _ = GitSafety.run(dir, ["init", "-q"])
        try FileManager.default.removeItem(atPath: dir + "/.git/hooks")
        try FileManager.default.createSymbolicLink(atPath: dir + "/.git/hooks", withDestinationPath: base)
        GitGuards.shared.begin(agent: "c", cwd: dir)
        let msg = try #require(GitGuards.shared.end(agent: "c"))
        #expect(msg.contains("già alla partenza"))
    }

    @Test func linkedWorktreeGuardsTheCommonDir() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitguard-\(UUID().uuidString)").path
        let main = base + "/main", wt = base + "/wt"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        _ = GitSafety.run(main, ["init", "-q"])
        _ = GitSafety.run(main, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"])
        _ = GitSafety.run(main, ["worktree", "add", "-q", wt])
        GitGuards.shared.begin(agent: "w", cwd: wt)
        try "#!/bin/sh\n".write(toFile: main + "/.git/hooks/post-checkout", atomically: true, encoding: .utf8)
        let msg = try #require(GitGuards.shared.end(agent: "w"))
        #expect(msg.contains("hooks/post-checkout"))
        #expect(!FileManager.default.fileExists(atPath: main + "/.git/hooks/post-checkout"))
    }
}
