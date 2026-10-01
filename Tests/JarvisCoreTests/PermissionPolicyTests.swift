import Testing
@testable import JarvisCore

struct PermissionPolicyTests {
    @Test(arguments: [
        "git status", "git diff main...HEAD", "git log --oneline -20", "git checkout -b jarvis/fix-login",
        "git add -A && git commit -m 'fix'", "npm test", "npm run lint", "php artisan test",
        "./vendor/bin/pest --filter Login", "swift build", "ls -la src", "grep -rn foo src | head -20",
        "find . -name '*.php'", "cat composer.json",
    ])
    func allowsSafeCommands(cmd: String) {
        #expect(PermissionPolicy.decideBash(cmd) == .allow)
    }

    @Test(arguments: [
        "git push origin feature", "git push --force", "git merge develop", "git rebase main",
        "git reset --hard HEAD~1", "rm -rf node_modules", "cd src && rm file.php", "git branch -D old",
        "git checkout -- src/app.ts", "git clean -fd", "sudo npm i -g x",
        "curl -X POST https://hooks.slack.com/x", "php artisan migrate:fresh", "find . -name '*.log' -delete",
        "osascript -e 'tell application \"Mail\" to send'",
    ])
    func dangerousNeedExplicitConfirmation(cmd: String) {
        #expect(PermissionPolicy.decideBash(cmd) == .confirm(.dangerous))
    }

    @Test(arguments: [
        "docker compose up -d", "npm publish", "echo hi > notes.txt", "ssh server", "brew install x",
        "git commit -m \"$(cat msg)\"",
    ])
    func unknownNeedsConfirmation(cmd: String) {
        #expect(PermissionPolicy.decideBash(cmd) == .confirm(.normal))
    }

    @Test func editsInsideProjectAreAllowed() {
        #expect(PermissionPolicy.decide(tool: "Edit", input: ["file_path": "/p/app/src/a.ts"], cwd: "/p/app") == .allow)
        #expect(PermissionPolicy.decide(tool: "Write", input: ["file_path": "/p/app/../other/a.ts"], cwd: "/p/app") == .confirm(.normal))
        #expect(PermissionPolicy.decide(tool: "Write", input: ["file_path": "/etc/hosts"], cwd: "/p/app") == .confirm(.normal))
        #expect(PermissionPolicy.decide(tool: "Read", input: [:], cwd: "/p/app") == .allow)
    }
}
