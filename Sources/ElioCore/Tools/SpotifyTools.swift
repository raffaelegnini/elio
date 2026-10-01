import AppKit
import CryptoKit
import Foundation
import Network

/// Spotify: the desktop app is driven with AppleScript (no account needed, works without Premium);
/// search and the user's playlists go through the Web API (PKCE login, only a client id, no secret).
public enum Spotify {
    static let redirect = "http://127.0.0.1:8739/callback"
    static let clientService = "elio-spotify-client"
    static let tokenService = "elio-spotify-token"

    // MARK: Desktop control

    /// osascript with a hard 6 s limit: while macOS's "allow Elio to control Spotify" prompt is
    /// waiting, the Apple event blocks forever.
    @discardableResult
    static func script(_ body: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Spotify\"\n\(body)\nend tell"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let deadline = Date().addingTimeInterval(6)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            throw ToolError("macOS sta chiedendo il permesso di controllare Spotify: approvi la finestra (o Impostazioni di Sistema → Privacy e sicurezza → Automazione → eliod → Spotify).")
        }
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 {
            if errText.contains("-1743") || errText.contains("Not authorized") {
                throw ToolError("Elio non ha il permesso di controllare Spotify: Impostazioni di Sistema → Privacy e sicurezza → Automazione → eliod → attivi Spotify.")
            }
            throw ToolError("Spotify: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    /// play, pause, toggle, next, previous, now, volume_up, volume_down, volume <n>, shuffle_on/off
    public static func control(_ action: String, value: Int? = nil) throws -> String {
        guard isInstalled else { throw ToolError("Spotify non è installato su questo Mac") }
        switch action {
        case "play": try script("play"); return "Riprendo la musica."
        case "pause": try script("pause"); return "Musica in pausa."
        case "toggle": try script("playpause"); return "Fatto."
        case "next": try script("next track"); return try nowPlaying(prefix: "Avanti:")
        case "previous": try script("previous track"); return try nowPlaying(prefix: "Indietro:")
        case "volume_up": try script("set sound volume to (sound volume + 15)"); return "Alzo il volume di Spotify."
        case "volume_down": try script("set sound volume to (sound volume - 15)"); return "Abbasso il volume di Spotify."
        case "volume": try script("set sound volume to \(max(0, min(100, value ?? 50)))"); return "Volume di Spotify a \(value ?? 50)."
        case "shuffle_on": try script("set shuffling to true"); return "Riproduzione casuale attiva."
        case "shuffle_off": try script("set shuffling to false"); return "Riproduzione casuale disattivata."
        case "now": return try nowPlaying(prefix: "Sta suonando")
        default: throw ToolError("Azione sconosciuta: \(action)")
        }
    }

    static func nowPlaying(prefix: String) throws -> String {
        Thread.sleep(forTimeInterval: 0.4)
        let info = try script("if player state is stopped then return \"\"\nreturn (name of current track) & \" — \" & (artist of current track)")
        return info.isEmpty ? "Spotify è fermo." : "\(prefix) \(info)."
    }

    static func playURI(_ uri: String) throws {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
            NSWorkspace.shared.open(URL(string: "spotify:")!)
            Thread.sleep(forTimeInterval: 2.5)
        }
        try script("play track \"\(uri)\"")
    }

    // MARK: Web API

    public static var clientId: String? { KeychainItem.read(service: clientService).flatMap { $0.isEmpty ? nil : $0 } }
    public static var isLoggedIn: Bool { KeychainItem.read(service: tokenService) != nil }

    struct Token: Codable { var access: String; var refresh: String; var expires: Date }

    static func token() async throws -> String {
        guard let id = clientId else { throw ToolError("Spotify API non configurata: serve un client id (spotify_setup)") }
        guard let raw = KeychainItem.read(service: tokenService), var t = Token.fromJSON(raw) else {
            throw ToolError("Spotify non collegato: usa spotify_login")
        }
        if t.expires > Date().addingTimeInterval(60) { return t.access }
        let body = "grant_type=refresh_token&refresh_token=\(t.refresh)&client_id=\(id)"
        let obj = try await post("https://accounts.spotify.com/api/token", body: body)
        guard let access = obj["access_token"] as? String else { throw ToolError("Rinnovo del token Spotify fallito") }
        t.access = access
        if let r = obj["refresh_token"] as? String { t.refresh = r }
        t.expires = Date().addingTimeInterval(Double(obj["expires_in"] as? Int ?? 3600))
        KeychainItem.write(service: tokenService, value: t.jsonString())
        return access
    }

    static func post(_ url: String, body: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func get(_ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1\(path)")!)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError("Spotify API \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Finds the best match and returns (uri, description).
    static func search(_ query: String, type: String, mine: Bool) async throws -> (String, String)? {
        if mine || type == "liked" {
            if type == "liked" { return ("spotify:collection:tracks", "i brani che le piacciono") }
            let lists = try await get("/me/playlists?limit=50")
            let items = lists["items"] as? [[String: Any]] ?? []
            let q = query.lowercased()
            if let hit = items.first(where: { ($0["name"] as? String ?? "").lowercased().contains(q) })
                ?? items.first(where: { q.contains(($0["name"] as? String ?? "").lowercased()) }),
               let uri = hit["uri"] as? String {
                return (uri, "la sua playlist \(hit["name"] as? String ?? "")")
            }
        }
        let t = ["track", "artist", "album", "playlist"].contains(type) ? type : "track"
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let res = try await get("/search?q=\(q)&type=\(t)&limit=1&market=from_token")
        guard let item = ((res["\(t)s"] as? [String: Any])?["items"] as? [[String: Any]])?.compactMap({ $0 }).first,
              let uri = item["uri"] as? String else { return nil }
        let name = item["name"] as? String ?? query
        let artist = ((item["artists"] as? [[String: Any]])?.first?["name"] as? String).map { " di \($0)" } ?? ""
        return (uri, "\(name)\(artist)")
    }

    /// Plays something by name. Without the Web API, opens Spotify's search on it.
    public static func play(_ query: String, type: String = "track", mine: Bool = false) async throws -> String {
        guard isInstalled else { throw ToolError("Spotify non è installato su questo Mac") }
        if isLoggedIn, let (uri, what) = try await search(query, type: type, mine: mine) {
            try playURI(uri)
            return "Metto \(what)."
        }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        NSWorkspace.shared.open(URL(string: "spotify:search:\(q)")!)
        return isLoggedIn ? "Non ho trovato \(query) su Spotify." : "Ho aperto la ricerca di \(query) su Spotify (per farlo partire da solo serve collegare l'API)."
    }

    // MARK: Login (PKCE, loopback redirect)

    public static func login() async throws -> String {
        guard let id = clientId else { throw ToolError("Prima serve il client id: spotify_setup") }
        let verifier = (0..<64).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".randomElement()! }
        let v = String(verifier)
        let challenge = Data(SHA256.hash(data: Data(v.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString
        let scopes = "user-read-playback-state user-modify-playback-state playlist-read-private playlist-read-collaborative user-library-read user-read-currently-playing"
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge), .init(name: "scope", value: scopes), .init(name: "state", value: state),
        ]
        let authURL = c.url!
        let code = try await waitForCallback(state: state) { NSWorkspace.shared.open(authURL) }
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirect)&client_id=\(id)&code_verifier=\(v)"
        let obj = try await post("https://accounts.spotify.com/api/token", body: body)
        guard let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String else {
            throw ToolError("Login Spotify non riuscito: \(obj["error_description"] as? String ?? "risposta inattesa")")
        }
        let t = Token(access: access, refresh: refresh, expires: Date().addingTimeInterval(Double(obj["expires_in"] as? Int ?? 3600)))
        KeychainItem.write(service: tokenService, value: t.jsonString())
        return "Spotify collegato."
    }

    /// One-shot HTTP listener on 127.0.0.1:8739 that receives Spotify's redirect.
    static func waitForCallback(state: String, open: @escaping @Sendable () -> Void) async throws -> String {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 8739)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        defer { listener.cancel() }
        return try await withTimeout(140) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let done = OSAllocatedUnfairLockBox()
                listener.newConnectionHandler = { conn in
                    conn.start(queue: .global())
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                        let req = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                        let items = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                        let code = items.first { $0.name == "code" }?.value
                        let ok = code != nil && items.first { $0.name == "state" }?.value == state
                        let html = ok ? "<h2 style='font-family:-apple-system'>Spotify collegato a Elio. Puoi chiudere questa scheda.</h2>"
                                      : "<h2 style='font-family:-apple-system'>Collegamento non riuscito.</h2>"
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                        guard path.hasPrefix("/callback"), done.claim() else { return }
                        if ok, let code { cont.resume(returning: code) } else { cont.resume(throwing: ToolError("Accesso a Spotify negato")) }
                    }
                }
                listener.stateUpdateHandler = { s in
                    if case .ready = s { open() }
                    if case .failed(let e) = s, done.claim() { cont.resume(throwing: e) }
                }
                listener.start(queue: .global())
            }
        }
    }
}

/// Resume-once guard for callback-based continuations.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}

public enum SpotifyTools {
    static let control = ElioTool(
        name: "spotify",
        description: "Controlla Spotify sul Mac: play, pause, toggle, next, previous, now (cosa suona), volume_up, volume_down, volume (value 0-100), shuffle_on, shuffle_off.",
        properties: ["action": prop("Azione"), "value": prop("Volume 0-100 (solo per volume)", type: "integer")],
        required: ["action"]
    ) { args, _ in
        try Spotify.control(args["action"] as? String ?? "", value: args["value"] as? Int)
    }

    static let play = ElioTool(
        name: "spotify_play",
        description: """
        Fa partire su Spotify un brano, artista, album o playlist per nome. type: track, artist, album, playlist, liked \
        (i brani che piacciono all'utente). mine=true per cercare tra le playlist dell'utente ("la mia playlist X").
        """,
        properties: ["query": prop("Cosa cercare"), "type": prop("track, artist, album, playlist o liked"),
                     "mine": prop("Playlist dell'utente", type: "boolean")],
        required: ["query"]
    ) { args, _ in
        try await Spotify.play(args["query"] as? String ?? "", type: args["type"] as? String ?? "track",
                               mine: args["mine"] as? Bool ?? false)
    }

    static let setup = ElioTool(
        name: "spotify_setup",
        description: """
        Salva il client id dell'app Spotify per l'API (si crea su developer.spotify.com/dashboard: Web API, \
        redirect URI esattamente http://127.0.0.1:8739/callback). Poi chiama spotify_login.
        """,
        properties: ["client_id": prop("Client ID dell'app Spotify")],
        required: ["client_id"]
    ) { args, _ in
        let id = (args["client_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 20 else { throw ToolError("Client id non valido") }
        KeychainItem.write(service: Spotify.clientService, value: id)
        return "Client id salvato. Ora spotify_login."
    }

    static let login = ElioTool(
        name: "spotify_login",
        description: "Apre il login di Spotify nel browser e aspetta che l'utente autorizzi Elio (fino a 2 minuti).",
        properties: [:]
    ) { _, _ in
        try await Spotify.login()
    }
}
