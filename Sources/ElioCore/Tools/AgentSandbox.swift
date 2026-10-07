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

    /// Agents' own package-manager caches, separate from the user's: a poisoned cache entry can only ever be used
    /// by another sandboxed agent, never by the user's own `npm install` / `composer install` outside the sandbox.
    public static var agentCache: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Elio/agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Environment pointing package managers at `agentCache` (set on every agent process).
    public static var cacheEnvironment: [String: String] {
        let c = agentCache.path
        return ["npm_config_cache": "\(c)/npm", "YARN_CACHE_FOLDER": "\(c)/yarn", "YARN_GLOBAL_FOLDER": "\(c)/yarn-global",
                "PNPM_STORE_DIR": "\(c)/pnpm", "COMPOSER_CACHE_DIR": "\(c)/composer", "PIP_CACHE_DIR": "\(c)/pip",
                "GOMODCACHE": "\(c)/gomod", "GOCACHE": "\(c)/gobuild", "GRADLE_USER_HOME": "\(c)/gradle",
                "BUN_INSTALL_CACHE_DIR": "\(c)/bun", "DENO_DIR": "\(c)/deno", "XDG_CACHE_HOME": "\(c)/xdg"]
    }

    /// Where operator ("mac") agents may write: the user's document folders and Elio's output, nothing that runs.
    static let userFolders = ["~/Desktop", "~/Documents", "~/Downloads", "~/Pictures", "~/Movies", "~/Music", "~/Public"]

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
            // Operator agents organise the user's files: only the document folders are writable (an allowlist — a list
            // of forbidden places is never complete), never secrets or anything that runs later.
            // Apple Events don't work inside the sandbox, so app scripting runs outside it — and PermissionPolicy
            // asks for any inline or file script.
            sandbox["excludedCommands"] = ["osascript", "open", "shortcuts"]
            sandbox["filesystem"] = [
                "allowWrite": userFolders + [agentCache.path],
                "denyWrite": secrets() + autorun,
                "denyRead": secrets(),
            ]
            sandbox["network"] = ["allowedDomains": [String]()]
        } else {
            sandbox["filesystem"] = [
                "allowWrite": [agentCache.path],
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
