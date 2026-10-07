import Foundation
import Testing
@testable import ElioCore

/// A cloned repository whose own config (directly and through include.path) names programs that read-only git
/// commands would run. Every hardened call must leave the marker folder empty.
struct GitSafetyTests {
    @discardableResult
    func plainGit(_ dir: String, _ args: [String], stdin: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgSign=false"] + args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        try? p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func makeHostileRepo() throws -> (repo: String, markers: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("elio-gitsafety-\(UUID().uuidString)").path
        let repo = base + "/repo", markers = base + "/markers"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: markers, withIntermediateDirectories: true)
        plainGit(repo, ["init", "-q"])
        try "one\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        plainGit(repo, ["add", "."])
        plainGit(repo, ["commit", "-qm", "init"])
        // A commit carrying a signature: log.showSignature would hand it to gpg.program.
        let tree = plainGit(repo, ["rev-parse", "HEAD^{tree}"]), parent = plainGit(repo, ["rev-parse", "HEAD"])
        let obj = "tree \(tree)\nparent \(parent)\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000000 +0000\n"
            + "gpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\nsigned\n"
        let signed = plainGit(repo, ["hash-object", "-t", "commit", "-w", "--stdin"], stdin: obj)
        plainGit(repo, ["update-ref", "HEAD", signed])

        func script(_ name: String) throws -> String {
            let path = base + "/\(name).sh"
            try "#!/bin/sh\ntouch '\(markers)/\(name)'\ncat\n".write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            return path
        }
        // Drivers live in an included file (the bypass of a --local only lookup); the rest in .git/config.
        let included = """
        [filter "evil"]
        \tclean = \(try script("clean"))
        \tsmudge = \(try script("smudge"))
        \trequired = true
        [diff "evil"]
        \ttextconv = \(try script("textconv"))
        \tcommand = \(try script("diffcmd"))
        [merge "evil"]
        \tdriver = \(try script("merge"))
        """
        try included.write(toFile: base + "/inc.cfg", atomically: true, encoding: .utf8)
        plainGit(repo, ["config", "include.path", base + "/inc.cfg"])
        plainGit(repo, ["config", "core.fsmonitor", try script("fsmonitor")])
        plainGit(repo, ["config", "log.showSignature", "true"])
        plainGit(repo, ["config", "gpg.program", try script("gpg")])
        plainGit(repo, ["config", "core.pager", try script("pager")])
        try "*.txt filter=evil diff=evil merge=evil\n".write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
        // A modified file with an old mtime: status/diff must compare contents (the clean filter's moment).
        try "two\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        return (repo, markers)
    }

    @Test func hardenedCallsRunNoRepoPrograms() throws {
        let (repo, markers) = try makeHostileRepo()
        defer { try? FileManager.default.removeItem(atPath: (repo as NSString).deletingLastPathComponent) }
        // The same paths the IDE, the hover card and show_diff use.
        let calls: [[String]] = [
            ["status", "--porcelain=v2", "-z", "--branch", "-uall", "--ignored=matching", "--ignore-submodules=all"],
            ["ls-files", "--cached", "--others", "--exclude-standard"],
            ["grep", "-n", "-I", "--untracked", "-e", "one"],
            ["log", "-5", "--format=%H %s"],
            ["log", "-p", "-2"],
            ["show", "HEAD"],
            ["show", "HEAD:./f.txt"],
            ["diff"], ["diff", "--stat"], ["diff", "HEAD"], ["diff", "HEAD~1", "HEAD"],
            ["blame", "--porcelain", "--", "f.txt"],
            ["diff-tree", "-r", "-p", "HEAD"],
        ]
        for args in calls { GitSafety.run(repo, args, timeout: 30) }
        _ = ProjectTree.info(repo)
        let ran = (try? FileManager.default.contentsOfDirectory(atPath: markers)) ?? []
        #expect(ran.isEmpty, "programs run: \(ran)")
        // Sanity: the same repo does run them without the hardening (the test would otherwise prove nothing).
        plainGit(repo, ["diff", "--stat"])
        plainGit(repo, ["log", "-1"])
        let unhardened = (try? FileManager.default.contentsOfDirectory(atPath: markers)) ?? []
        #expect(unhardened.contains("textconv") || unhardened.contains("clean"))
        #expect(unhardened.contains("gpg"))
    }

    @Test func hardenAddsFlagsToEveryDiffProducingCommand() {
        #expect(GitSafety.harden(["log", "-1"]) == ["log", "--no-ext-diff", "--no-textconv", "--no-show-signature", "-1"])
        #expect(GitSafety.harden(["diff", "--", "--no-textconv"]).prefix(3) == ["diff", "--no-ext-diff", "--no-textconv"])
        #expect(GitSafety.harden(["blame", "x"]) == ["blame", "--no-ext-diff", "--no-textconv", "x"])
        #expect(GitSafety.harden(["status"]) == ["status"])
        let a = GitSafety.args(trusted: false, subcommand: "log")
        #expect(a.contains("gpg.program=false") && a.contains("log.showSignature=false") && a.contains("core.fsmonitor=false"))
        // A trusted folder can still sign its commits; reads never verify signatures.
        #expect(!GitSafety.args(trusted: true, subcommand: "commit").contains("gpg.program=false"))
        #expect(GitSafety.args(trusted: true, subcommand: "log").contains("gpg.program=false"))
    }

    @Test func driverOverridesSkipUserScopesAndKeepOddNames() {
        let listing = "global\tfilter.lfs.clean\nlocal\tfilter.a=b.c.clean\nlocal\tdiff.tc.textconv\nworktree\tmerge.m.driver\nlocal\tfilter.a=b.c.smudge\n"
        let o = GitSafety.driverOverrides(listing: listing)
        let keys = o.map(\.key)
        #expect(!keys.contains { $0.contains("lfs") })
        #expect(keys.contains("filter.a=b.c.clean") && keys.contains("filter.a=b.c.process"))
        #expect(o.first { $0.key == "filter.a=b.c.required" }?.value == "false")
        #expect(keys.contains("diff.tc.textconv") && keys.contains("merge.m.driver"))
        #expect(keys.filter { $0 == "filter.a=b.c.clean" }.count == 1)
    }
}
