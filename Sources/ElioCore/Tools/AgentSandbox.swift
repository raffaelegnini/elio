import Foundation

/// OS-level sandbox (Claude Code's Seatbelt sandbox) for background agents' Bash commands. PermissionPolicy is a
/// list of patterns and will never be a real boundary; the sandbox is: Bash and everything it starts can only write
/// where the agent works and only reach the network hosts listed here. A command that needs to step outside asks
/// to run unsandboxed, and that request goes to the user (see PermissionPolicy.decide). Write/Edit/Read are Claude
/// tools, not Bash: they stay under PermissionPolicy.
public enum AgentSandbox {
    /// Hosts developer agents need for dependencies and git over HTTPS.
    static let developerDomains = [
        "github.com", "*.github.com", "*.githubusercontent.com", "gitlab.com", "*.gitlab.com", "bitbucket.org",
        "registry.npmjs.org", "registry.yarnpkg.com", "*.npmjs.org", "nodejs.org",
        "packagist.org", "*.packagist.org", "getcomposer.org", "repo.magento.com",
        "pypi.org", "files.pythonhosted.org", "rubygems.org", "*.rubygems.org", "crates.io", "*.crates.io",
        "proxy.golang.org", "sum.golang.org", "pub.dev", "*.pub.dev", "storage.googleapis.com",
        "swift.org", "download.swift.org", "cocoapods.org", "cdn.cocoapods.org",
        "services.gradle.org", "repo.maven.apache.org", "repo1.maven.org", "dl.google.com",
    ]

    /// Caches that package managers and build tools write outside the project.
    static let developerCaches = [
        "~/.npm", "~/.yarn", "~/.pnpm-store", "~/Library/pnpm", "~/.cache", "~/Library/Caches", "~/.composer", "~/.config/composer",
        "~/.gradle", "~/.m2", "~/.cargo", "~/.rustup", "~/go/pkg", "~/.pub-cache", "~/.swiftpm",
        "~/Library/Developer/Xcode/DerivedData", "~/Library/org.swift.swiftpm", "~/.bun", "~/.deno",
    ]

    /// Never readable or writable from Bash: keys, credentials, Elio's own tokens.
    static func secrets() -> [String] {
        ["~/.ssh", "~/.aws", "~/.gnupg", "~/.kube", "~/.docker/config.json", "~/.netrc", "~/.config/gh",
         "~/Library/Keychains", "~/Library/Cookies", ElioPaths.support.path]
    }

    /// The `--settings` JSON for an agent of this kind ("code", "squad", "scout", "lead", "mac").
    public static func settings(kind: String) -> String {
        var sandbox: [String: Any] = [
            "enabled": true,
            // Sandboxed commands still go through PermissionPolicy: two layers, not one.
            "autoAllowBashIfSandboxed": false,
            // Stepping outside is possible, but only through the permission prompt (the user decides).
            "allowUnsandboxedCommands": true,
        ]
        if kind == "mac" {
            // Operator agents organise the user's files: the home is writable, secrets and startup items aren't.
            // Apple Events don't work inside the sandbox, so app scripting runs outside it — and PermissionPolicy
            // asks for any inline or file script.
            sandbox["excludedCommands"] = ["osascript", "open", "shortcuts"]
            sandbox["filesystem"] = [
                "allowWrite": ["~"],
                "denyWrite": secrets() + ["~/Library/LaunchAgents", "~/Library/LaunchDaemons", "~/Library/Application Support/com.apple.backgroundtaskmanagementagent"],
                "denyRead": secrets(),
            ]
            sandbox["network"] = ["allowedDomains": [String]()]
        } else {
            sandbox["filesystem"] = [
                "allowWrite": developerCaches,
                "denyWrite": secrets(),
                "denyRead": secrets(),
            ]
            sandbox["network"] = ["allowedDomains": developerDomains, "allowLocalBinding": true]
        }
        let obj: [String: Any] = ["sandbox": sandbox]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
