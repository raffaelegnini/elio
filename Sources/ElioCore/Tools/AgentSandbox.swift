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

    /// Caches that package managers and build tools write outside the project. Only data caches: no folder whose
    /// contents something runs later outside the sandbox (~/.cargo/bin, ~/.rustup toolchains, ~/.bun/bin, Homebrew).
    static let developerCaches = [
        "~/.npm/_cacache", "~/.yarn/berry/cache", "~/Library/Caches/Yarn", "~/Library/pnpm/store", "~/.pnpm-store",
        "~/.cache/pip", "~/Library/Caches/pip", "~/.cache/composer", "~/Library/Caches/composer", "~/.composer/cache",
        "~/.gradle/caches", "~/.m2/repository", "~/.cargo/registry", "~/.cargo/git", "~/go/pkg/mod", "~/.pub-cache/hosted",
        "~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm", "~/Library/Developer/Xcode/DerivedData",
        "~/.bun/install/cache", "~/Library/Caches/deno",
    ]

    /// Files and folders that run later outside the sandbox (shell startup, PATH folders, git config, login items):
    /// writing there would be a delayed escape.
    static let autorun = [
        "~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.zlogin", "~/.zlogout", "~/.bashrc", "~/.bash_profile", "~/.profile",
        "~/.config/fish", "~/.gitconfig", "~/.config/git", "~/.npmrc", "~/.yarnrc", "~/.yarnrc.yml", "~/.cargo/config.toml",
        "~/.cargo/bin", "~/.local/bin", "~/bin", "~/.bun/bin", "~/.rustup", "~/go/bin", "~/.composer/vendor/bin",
        "~/Applications", "~/Library/LaunchAgents", "~/Library/LaunchDaemons", "~/Library/Application Support/com.apple.backgroundtaskmanagementagent",
        "~/Library/Scripts", "~/Library/Services", "~/Library/Workflows", "~/Library/Preferences", "~/.claude", "~/.config/claude",
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
                "denyWrite": secrets() + autorun,
                "denyRead": secrets(),
            ]
            sandbox["network"] = ["allowedDomains": [String]()]
        } else {
            sandbox["filesystem"] = [
                "allowWrite": developerCaches,
                "denyWrite": secrets() + autorun,
                "denyRead": secrets(),
            ]
            sandbox["network"] = ["allowedDomains": developerDomains, "allowLocalBinding": true]
        }
        let obj: [String: Any] = ["sandbox": sandbox]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
