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
}
