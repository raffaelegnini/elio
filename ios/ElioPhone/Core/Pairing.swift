import Foundation

/// Where the Mac is and the token it gave this phone. Kept in the Keychain.
struct Pairing: Codable, Equatable, Sendable {
    /// Host (and optional port) of the Mac on the tailnet, e.g. "mac.tailnet.ts.net".
    var host: String
    var token: String

    /// Built from parts (never by string concatenation), so the URL connects exactly to the validated host.
    var baseURL: URL { url(scheme: "https", path: "/") }
    var socketURL: URL { url(scheme: "wss", path: "/ws") }

    private func url(scheme: String, path: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        let parts = Self.split(host)
        c.host = parts?.name ?? "invalid.invalid"
        c.port = parts?.port
        c.path = path
        return c.url ?? URL(string: "https://invalid.invalid/")!
    }

    /// "name" or "name:port", strictly: ASCII letters, digits, dots and dashes only. No '@', '/', '?', '#',
    /// '%', spaces or Unicode, so nothing can smuggle another host past the checks.
    static func split(_ host: String) -> (name: String, port: Int?)? {
        guard let m = host.wholeMatch(of: /([a-z0-9-]+(?:\.[a-z0-9-]+)*)(?::([0-9]{1,5}))?/) else { return nil }
        let name = String(m.1)
        var port: Int?
        if let p = m.2 {
            guard let n = Int(p), (1...65535).contains(n) else { return nil }
            port = n
        }
        return (name, port)
    }

    /// Valid host syntax, and the host URLSession will actually use is that same name.
    var isValid: Bool {
        guard let parts = Self.split(host) else { return false }
        return baseURL.host()?.lowercased() == parts.name && socketURL.host()?.lowercased() == parts.name
    }

    /// Accepts the Mac's link (`https://host/#pair=TOKEN`), `elio://pair?link=…` or `elio://pair?host=…&token=…`,
    /// or a bare token when the host is known from elsewhere.
    /// Only tailnet hosts (`*.ts.net`) unless `allowAnyHost`, which only the manual "advanced" field may pass:
    /// a link or QR code must never point the app at someone else's server.
    static func parse(_ raw: String, fallbackHost: String? = nil, allowAnyHost: Bool = false) -> Pairing? {
        guard let p = parseAny(raw, fallbackHost: fallbackHost), p.isValid else { return nil }
        return allowAnyHost || p.isTailnet ? p : nil
    }

    /// The Mac reached through `tailscale serve`.
    var isTailnet: Bool {
        guard isValid, let name = baseURL.host()?.lowercased() else { return false }
        return name.hasSuffix(".ts.net") && name.count > ".ts.net".count
    }

    private static func parseAny(_ raw: String, fallbackHost: String?) -> Pairing? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "elio" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
                if let link = item("link") { return parseAny(link, fallbackHost: nil) }
                if let host = item("host"), let token = item("token") { return make(host: host, token: token) }
                return nil
            }
            // Credentials in a link ("user@host") only serve to disguise the real host: refused.
            if scheme == "https", url.user() == nil, url.password() == nil, !text.contains("@"),
               let host = url.host(), let token = token(in: text) {
                return make(host: host + (url.port.map { ":\($0)" } ?? ""), token: token)
            }
        }
        guard let fallbackHost, !fallbackHost.isEmpty else { return nil }
        if let token = token(in: text) { return make(host: fallbackHost, token: token) }
        if text.wholeMatch(of: /[A-Za-z0-9_-]{20,}/) != nil { return make(host: fallbackHost, token: text) }
        return nil
    }

    private static func token(in text: String) -> String? {
        text.firstMatch(of: /pair=([A-Za-z0-9_-]+)/).map { String($0.1) }
    }

    /// Strips a scheme or path the user may have typed around the host.
    static func cleanHost(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        h = h.lowercased()
        // "mac.tailnet.ts.net." and "mac.tailnet.ts.net" are the same host.
        if let colon = h.lastIndex(of: ":") {
            var name = String(h[..<colon])
            while name.hasSuffix(".") { name.removeLast() }
            h = name + h[colon...]
        } else {
            while h.hasSuffix(".") { h.removeLast() }
        }
        return h
    }

    private static func make(host: String, token: String) -> Pairing? {
        let h = cleanHost(host)
        // The token goes into headers and a subprotocol: same alphabet as the Mac generates.
        guard split(h) != nil, token.wholeMatch(of: /[A-Za-z0-9_-]{16,256}/) != nil else { return nil }
        let p = Pairing(host: h, token: token)
        return p.isValid ? p : nil
    }

    // MARK: Storage

    private static let account = "pairing"

    static func load() -> Pairing? {
        guard let data = Keychain.read(account) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Keychain.write(data, account: Self.account) }
    }

    static func clear() { Keychain.delete(account) }
}
