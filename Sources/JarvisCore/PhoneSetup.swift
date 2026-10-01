import Foundation

/// Publishing Jarvis to the phone over Tailscale (private tailnet, HTTPS by `tailscale serve`).
public enum PhoneSetup {
    static let cliCandidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    public static var tailscaleCLI: String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This Mac's MagicDNS name (e.g. "macbook-air.tail1234.ts.net"), if Tailscale is up.
    public static func hostname() -> String? {
        guard let cli = tailscaleCLI,
              let out = try? shell(cli, ["status", "--json"]),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let me = obj["Self"] as? [String: Any],
              let dns = me["DNSName"] as? String, !dns.isEmpty else { return nil }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }

    /// `https://<mac>.ts.net` → PWA, `/ws` → remote socket. Idempotent.
    public static func publish(config: JarvisConfig) throws {
        guard let cli = tailscaleCLI else { throw ToolError("Tailscale non è installato") }
        try shell(cli, ["serve", "--bg", "--https=443", "http://127.0.0.1:\(config.webPort)"])
        try shell(cli, ["serve", "--bg", "--https=443", "--set-path", "/ws", "http://127.0.0.1:\(config.remotePort)"])
    }

    public static func pairingURL() -> String? {
        guard let host = hostname(), let token = try? AuthToken.loadOrCreateRemote() else { return nil }
        return "https://\(host)/#pair=\(token)"
    }

    public static func status(config: JarvisConfig) -> String {
        var lines: [String] = []
        if tailscaleCLI == nil {
            lines.append("Tailscale: non installato → https://tailscale.com/download (Mac e iPhone, stesso account)")
        } else if let host = hostname() {
            lines.append("Tailscale: attivo come \(host)")
        } else {
            lines.append("Tailscale: installato ma non connesso (apri Tailscale e fai login)")
        }
        lines.append("Notifiche: app ntfy su iPhone → iscriviti al topic \(config.ntfyTopic.isEmpty ? "(generato al primo avvio)" : config.ntfyTopic)")
        return lines.joined(separator: "\n")
    }
}
