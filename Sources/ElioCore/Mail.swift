import AppKit
import CryptoKit
import Foundation

/// Mail, natively in the daemon, through two providers behind the same tools:
/// - Gmail API (OAuth in the browser): fast search with Gmail syntax, threads, labels;
/// - Apple Mail (AppleScript): every account already set up on the Mac (iCloud, Outlook, work mail…),
///   no keys at all.
/// Sending always goes through the user's explicit confirmation.
public struct MailMessage: Sendable {
    public var id: String          // "gmail:<email>:<id>" or "mail:<message id>"
    public var from: String
    public var to: String = ""
    public var subject: String
    public var date: Date
    public var unread: Bool
    public var snippet: String
    public var body: String = ""
    public var messageId: String = ""
    public var threadId: String = ""
    public var account: String
}

public enum MailHub {
    public static func accounts() -> [String] {
        Gmail.accounts().map { "gmail:\($0)" } + (AppleMail.isAvailable ? ["mail"] : [])
    }

    static func providers(_ account: String?) -> [String] {
        if let a = account, !a.isEmpty {
            if a == "mail" || a.lowercased().contains("apple") { return ["mail"] }
            if let g = Gmail.accounts().first(where: { a.contains($0) || $0.contains(a) }) { return ["gmail:\(g)"] }
        }
        // Gmail first (faster, better search); Apple Mail covers everything else.
        return accounts()
    }

    public static func inbox(hours: Int, unreadOnly: Bool, account: String?) async throws -> [MailMessage] {
        var all: [MailMessage] = []
        var errors: [String] = []
        for p in providers(account) {
            do {
                if p.hasPrefix("gmail:") {
                    let q = "in:inbox newer_than:\(max(1, hours))h" + (unreadOnly ? " is:unread" : "")
                    all += try await Gmail.list(account: String(p.dropFirst(6)), query: q, max: 20)
                } else {
                    all += try AppleMail.inbox(hours: hours, unreadOnly: unreadOnly, max: 20)
                }
            } catch { errors.append("\(p): \(error)") }
        }
        if all.isEmpty, !errors.isEmpty { throw ToolError(errors.joined(separator: "; ")) }
        return dedupe(all).sorted { $0.date > $1.date }
    }

    public static func search(_ query: String, account: String?) async throws -> [MailMessage] {
        var all: [MailMessage] = []
        var errors: [String] = []
        for p in providers(account) {
            do {
                if p.hasPrefix("gmail:") { all += try await Gmail.list(account: String(p.dropFirst(6)), query: query, max: 20) }
                else { all += try AppleMail.search(query, max: 20) }
            } catch { errors.append("\(p): \(error)") }
        }
        if all.isEmpty, !errors.isEmpty { throw ToolError(errors.joined(separator: "; ")) }
        return dedupe(all).sorted { $0.date > $1.date }
    }

    public static func read(_ id: String) async throws -> MailMessage {
        if id.hasPrefix("gmail:") {
            let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { throw ToolError("Id non valido") }
            return try await Gmail.get(account: parts[1], id: parts[2])
        }
        if id.hasPrefix("mail:") { return try AppleMail.read(String(id.dropFirst(5))) }
        throw ToolError("Id non valido: usa l'id mostrato da mail_inbox o mail_search")
    }

    /// The same message seen by both providers (a Gmail account also in Mail.app) is shown once.
    static func dedupe(_ list: [MailMessage]) -> [MailMessage] {
        var seen = Set<String>()
        return list.filter { m in
            let key = "\(m.subject.lowercased())|\(Int(m.date.timeIntervalSince1970 / 60))"
            return seen.insert(key).inserted
        }
    }

    static func format(_ list: [MailMessage]) -> String {
        guard !list.isEmpty else { return "Nessuna mail." }
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return list.prefix(25).map { m in
            "- [\(m.id)] \(f.string(from: m.date)) \(m.unread ? "● " : "")\(m.from): \(m.subject)\n  \(m.snippet.prefix(200))"
        }.joined(separator: "\n")
    }

    /// RFC 2822 message (UTF-8, base64 body) for the Gmail API.
    static func rfc822(from: String, to: String, cc: String?, subject: String, body: String,
                       inReplyTo: String?) -> String {
        let encSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        var h = ["From: \(from)", "To: \(to)"]
        if let cc, !cc.isEmpty { h.append("Cc: \(cc)") }
        h += ["Subject: \(encSubject)", "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8",
              "Content-Transfer-Encoding: base64"]
        if let r = inReplyTo, !r.isEmpty { h += ["In-Reply-To: \(r)", "References: \(r)"] }
        let b64 = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return h.joined(separator: "\r\n") + "\r\n\r\n" + b64
    }
}

// MARK: - Gmail API

public enum Gmail {
    static let clientService = "elio-google-client"       // {"id","secret"} of the user's OAuth desktop client
    static let accountsFile = ElioPaths.support.appendingPathComponent("gmail-accounts.json")
    static let redirectPort: UInt16 = 8740
    static let scopes = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send"

    struct Client: Codable { var id: String; var secret: String }
    struct Token: Codable { var access: String; var refresh: String; var expires: Date }

    public static var hasClient: Bool { client() != nil }
    static func client() -> Client? { KeychainItem.read(service: clientService).flatMap { Client.fromJSON($0) } }
    static func tokenService(_ email: String) -> String { "elio-gmail-\(email.lowercased())" }

    public static func accounts() -> [String] {
        ((try? Data(contentsOf: accountsFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
            .filter { KeychainItem.read(service: tokenService($0)) != nil }
    }

    static func saveAccount(_ email: String) {
        var list = (try? Data(contentsOf: accountsFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        if !list.contains(email) { list.append(email) }
        try? JSONEncoder().encode(list).write(to: accountsFile)
    }

    public static func setClient(id: String, secret: String) {
        KeychainItem.write(service: clientService, value: Client(id: id, secret: secret).jsonString())
    }

    /// Browser login (PKCE + loopback), then stores the refresh token for that Google account.
    public static func connect() async throws -> String {
        guard let c = client() else {
            throw ToolError("Serve prima un client OAuth di Google (ID client e secret di tipo \"App desktop\")")
        }
        let verifier = String((0..<64).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".randomElement()! })
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString
        let redirect = "http://127.0.0.1:\(redirectPort)/callback"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: c.id), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account"),
            .init(name: "state", value: state),
        ]
        let url = comps.url!
        let code = try await Spotify.waitForCallback(state: state, port: redirectPort, service: "Gmail") {
            NSWorkspace.shared.open(url)
        }
        let obj = try await Spotify.post("https://oauth2.googleapis.com/token", body: form([
            "code": code, "client_id": c.id, "client_secret": c.secret, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ]))
        guard let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String else {
            throw ToolError("Accesso a Google non riuscito: \(obj["error_description"] as? String ?? obj["error"] as? String ?? "risposta inattesa")")
        }
        let token = Token(access: access, refresh: refresh, expires: Date().addingTimeInterval(Double(obj["expires_in"] as? Int ?? 3600)))
        // Which account was chosen.
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let email = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["emailAddress"] as? String else {
            throw ToolError("Non riesco a leggere l'indirizzo dell'account Google")
        }
        KeychainItem.write(service: tokenService(email), value: token.jsonString())
        saveAccount(email)
        return email
    }

    static func form(_ p: [String: String]) -> String {
        p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }.joined(separator: "&")
    }

    static func accessToken(_ email: String) async throws -> String {
        guard let raw = KeychainItem.read(service: tokenService(email)), var t = Token.fromJSON(raw) else {
            throw ToolError("Gmail \(email) non è collegato")
        }
        if t.expires > Date().addingTimeInterval(60) { return t.access }
        guard let c = client() else { throw ToolError("Manca il client OAuth di Google") }
        let obj = try await Spotify.post("https://oauth2.googleapis.com/token", body: form([
            "client_id": c.id, "client_secret": c.secret, "refresh_token": t.refresh, "grant_type": "refresh_token",
        ]))
        guard let access = obj["access_token"] as? String else {
            throw ToolError("Devo ricollegarmi a Gmail \(email) (accesso scaduto o revocato)")
        }
        t.access = access
        t.expires = Date().addingTimeInterval(Double(obj["expires_in"] as? Int ?? 3600))
        KeychainItem.write(service: tokenService(email), value: t.jsonString())
        return access
    }

    static func api(_ email: String, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(try await accessToken(email))", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "errore"
            throw ToolError("Gmail: \(msg)")
        }
        return obj
    }

    public static func list(account: String, query: String, max: Int) async throws -> [MailMessage] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let res = try await api(account, "messages?maxResults=\(max)&q=\(q)")
        let ids = (res["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return try await withThrowingTaskGroup(of: MailMessage?.self) { group in
            for id in ids {
                group.addTask {
                    let m = try await api(account, "messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID")
                    return parse(m, account: account)
                }
            }
            var out: [MailMessage] = []
            for try await m in group { if let m { out.append(m) } }
            return out
        }
    }

    public static func get(account: String, id: String) async throws -> MailMessage {
        let m = try await api(account, "messages/\(id)?format=full")
        guard var msg = parse(m, account: account) else { throw ToolError("Mail non trovata") }
        msg.body = bodyText(m["payload"] as? [String: Any] ?? [:])
        return msg
    }

    static func parse(_ m: [String: Any], account: String) -> MailMessage? {
        guard let id = m["id"] as? String else { return nil }
        let headers = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func h(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
        }
        let ms = Double(m["internalDate"] as? String ?? "0") ?? 0
        let labels = m["labelIds"] as? [String] ?? []
        var msg = MailMessage(id: "gmail:\(account):\(id)", from: h("From"), subject: h("Subject"),
                              date: Date(timeIntervalSince1970: ms / 1000), unread: labels.contains("UNREAD"),
                              snippet: decodeEntities(m["snippet"] as? String ?? ""), account: account)
        msg.to = h("To")
        msg.messageId = h("Message-ID")
        msg.threadId = m["threadId"] as? String ?? ""
        return msg
    }

    /// First text/plain part (or text/html without tags), base64url-decoded.
    static func bodyText(_ part: [String: Any]) -> String {
        let mime = part["mimeType"] as? String ?? ""
        if let data = (part["body"] as? [String: Any])?["data"] as? String, mime.hasPrefix("text/") {
            let b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
            let text = Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return mime == "text/html" ? stripHTML(text) : text
        }
        let parts = part["parts"] as? [[String: Any]] ?? []
        if let plain = parts.first(where: { ($0["mimeType"] as? String) == "text/plain" }) { return bodyText(plain) }
        for p in parts { let t = bodyText(p); if !t.isEmpty { return t } }
        return ""
    }

    public static func send(account: String, to: String, cc: String?, subject: String, body: String,
                            replyTo: MailMessage?) async throws {
        let raw = MailHub.rfc822(from: account, to: to, cc: cc, subject: subject, body: body, inReplyTo: replyTo?.messageId)
        let encoded = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var payload: [String: Any] = ["raw": encoded]
        if let t = replyTo?.threadId, !t.isEmpty { payload["threadId"] = t }
        _ = try await api(account, "messages/send", method: "POST", body: payload)
    }
}

func stripHTML(_ s: String) -> String {
    s.replacingOccurrences(of: #"<(style|script)[^>]*>[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"<br\s*/?>|</p>|</div>"#, with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func decodeEntities(_ s: String) -> String {
    s.replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
}

// MARK: - Apple Mail

public enum AppleMail {
    public static var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") != nil
            && FileManager.default.fileExists(atPath: ElioPaths.support.appendingPathComponent("applemail-enabled").path)
    }

    public static func disable() {
        try? FileManager.default.removeItem(at: ElioPaths.support.appendingPathComponent("applemail-enabled"))
    }

    public static func enable() throws -> String {
        // First call asks macOS for permission to control Mail.
        let out = try run("""
        tell application "Mail"
            set n to 0
            repeat with a in accounts
                set n to n + 1
            end repeat
            return (n as string) & "|" & (unread count of inbox as string)
        end tell
        """, timeout: 60)
        FileManager.default.createFile(atPath: ElioPaths.support.appendingPathComponent("applemail-enabled").path, contents: Data())
        let parts = out.split(separator: "|")
        return "Mail collegata: \(parts.first ?? "?") account, \(parts.last ?? "?") non lette."
    }

    static func run(_ script: String, timeout: TimeInterval = 25) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            throw ToolError("Mail non risponde (forse macOS sta chiedendo il permesso di controllarla)")
        }
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 {
            if e.contains("-1743") { throw ToolError("non ho il permesso di controllare Mail (Impostazioni di Sistema, Privacy, Automazione, eliod)") }
            throw ToolError("Mail: \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static let sep = "\u{1E}", fieldSep = "\u{1F}"

    /// Messages of the unified inbox, newest first.
    static func fetch(filter: String, max: Int) throws -> [MailMessage] {
        let script = """
        set out to ""
        set rs to ASCII character 30
        set fs to ASCII character 31
        tell application "Mail"
            set msgs to (messages of inbox whose \(filter))
            set n to count of msgs
            if n > \(max) then set n to \(max)
            repeat with i from 1 to n
                set m to item i of msgs
                set c to ""
                try
                    set c to text 1 thru 300 of (content of m as string)
                on error
                    try
                        set c to content of m as string
                    end try
                end try
                set out to out & (message id of m) & fs & (sender of m) & fs & (subject of m) & fs & ((date received of m) as «class isot» as string) & fs & ((read status of m) as string) & fs & c & rs
            end repeat
        end tell
        return out
        """
        let raw = try run(script)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        iso.timeZone = .current
        return raw.components(separatedBy: sep).compactMap { rec in
            let f = rec.components(separatedBy: fieldSep)
            guard f.count >= 6 else { return nil }
            return MailMessage(id: "mail:\(f[0])", from: f[1], subject: f[2], date: iso.date(from: f[3]) ?? Date(),
                               unread: f[4] == "false", snippet: f[5].replacingOccurrences(of: "\n", with: " "), account: "mail")
        }
    }

    static func appleDate(_ d: Date) -> String {
        // AppleScript-friendly: seconds since now.
        "(current date) - \(Int(Date().timeIntervalSince(d)))"
    }

    public static func inbox(hours: Int, unreadOnly: Bool, max: Int) throws -> [MailMessage] {
        var filter = "date received > \(appleDate(Date().addingTimeInterval(-Double(hours) * 3600)))"
        if unreadOnly { filter += " and read status is false" }
        return try fetch(filter: filter, max: max)
    }

    public static func search(_ query: String, max: Int) throws -> [MailMessage] {
        let q = query.replacingOccurrences(of: "\"", with: "")
        return try fetch(filter: "(subject contains \"\(q)\" or sender contains \"\(q)\")", max: max)
    }

    public static func read(_ messageId: String) throws -> MailMessage {
        let id = messageId.replacingOccurrences(of: "\"", with: "")
        let raw = try run("""
        set fs to ASCII character 31
        tell application "Mail"
            set m to first message of inbox whose message id is "\(id)"
            return (sender of m) & fs & (subject of m) & fs & (content of m as string)
        end tell
        """)
        let f = raw.components(separatedBy: fieldSep)
        guard f.count >= 3 else { throw ToolError("Mail non trovata") }
        var m = MailMessage(id: "mail:\(messageId)", from: f[0], subject: f[1], date: Date(), unread: false,
                            snippet: "", account: "mail")
        m.body = f[2...].joined(separator: fieldSep)
        m.messageId = messageId
        return m
    }

    public static func send(to: String, cc: String?, subject: String, body: String) throws {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var recipients = to.split(separator: ",").map {
            "make new to recipient at end of to recipients with properties {address:\"\(esc($0.trimmingCharacters(in: .whitespaces)))\"}"
        }
        if let cc { recipients += cc.split(separator: ",").map {
            "make new cc recipient at end of cc recipients with properties {address:\"\(esc($0.trimmingCharacters(in: .whitespaces)))\"}"
        } }
        _ = try run("""
        tell application "Mail"
            set m to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))", visible:false}
            tell m
                \(recipients.joined(separator: "\n        "))
            end tell
            send m
        end tell
        """)
    }
}

// MARK: - Tools

public enum MailTools {
    static let inbox = ElioTool(
        name: "mail_inbox",
        description: "Mail arrivate di recente (Gmail e/o app Mail del Mac). Letto ogni volta dal server: dati sempre freschi.",
        properties: ["hours": prop("Quante ore indietro (default 24)", type: "integer"),
                     "unread_only": prop("Solo non lette", type: "boolean"),
                     "account": prop("Account (es. l'indirizzo Gmail, oppure \"mail\" per l'app Mail); vuoto = tutti")]
    ) { args, _ in
        guard !MailHub.accounts().isEmpty else { throw ToolError("Nessuna casella collegata: Impostazioni → Integrazioni → Gmail o Mail") }
        let list = try await MailHub.inbox(hours: args["hours"] as? Int ?? 24, unreadOnly: args["unread_only"] as? Bool ?? false,
                                           account: args["account"] as? String)
        return SecretFilter.redact(MailHub.format(list))
    }

    static let search = ElioTool(
        name: "mail_search",
        description: "Cerca mail. Su Gmail vale la sintassi di Gmail (from:rossella subject:fattura newer_than:7d has:attachment); sull'app Mail cerca in mittente e oggetto.",
        properties: ["query": prop("Cosa cercare"), "account": prop("Account; vuoto = tutti")],
        required: ["query"]
    ) { args, _ in
        let list = try await MailHub.search(args["query"] as? String ?? "", account: args["account"] as? String)
        return SecretFilter.redact(MailHub.format(list))
    }

    static let read = ElioTool(
        name: "mail_read",
        description: "Legge il testo completo di una mail (id da mail_inbox o mail_search).",
        properties: ["id": prop("Id della mail")],
        required: ["id"]
    ) { args, _ in
        let m = try await MailHub.read(args["id"] as? String ?? "")
        return SecretFilter.redact("Da: \(m.from)\nA: \(m.to)\nOggetto: \(m.subject)\n\n\(m.body.prefix(12000))")
    }

    static let send = ElioTool(
        name: "mail_send",
        description: """
        Invia una mail a nome dell'utente (da Gmail o dall'app Mail). Richiede la conferma esplicita: riporta destinatario, \
        oggetto e testo. Per rispondere passa reply_to con l'id della mail originale.
        """,
        properties: ["to": prop("Destinatari (indirizzi separati da virgola)"), "subject": prop("Oggetto"),
                     "body": prop("Testo"), "cc": prop("Cc (opzionale)"), "reply_to": prop("Id della mail a cui rispondere"),
                     "account": prop("Da quale account (default: Gmail se collegato)")],
        required: ["to", "subject", "body"]
    ) { args, ctx in
        let to = args["to"] as? String ?? "", subject = args["subject"] as? String ?? "", body = args["body"] as? String ?? ""
        guard to.contains("@"), !body.isEmpty else { throw ToolError("Servono destinatario e testo") }
        let original = try? await (args["reply_to"] as? String).asyncMap { try await MailHub.read($0) }
        let provider = MailHub.providers(args["account"] as? String ?? original?.account).first
        guard let provider else { throw ToolError("Nessuna casella collegata") }
        let approved = await ctx.gate.request(ConfirmRequest(
            id: UUID().uuidString, title: "Invio una mail a \(to)",
            detail: "A: \(to)\nOggetto: \(subject)\n\n\(body)", risk: .dangerous, taskId: nil), timeout: 180)
        guard approved else { return "Mail non inviata: l'utente non ha confermato." }
        if provider.hasPrefix("gmail:") {
            try await Gmail.send(account: String(provider.dropFirst(6)), to: to, cc: args["cc"] as? String,
                                 subject: subject, body: body, replyTo: original ?? nil)
        } else {
            try AppleMail.send(to: to, cc: args["cc"] as? String, subject: subject, body: body)
        }
        return "Mail inviata a \(to)."
    }

    static let accounts = ElioTool(
        name: "mail_accounts",
        description: "Caselle mail collegate.",
        properties: [:]
    ) { _, _ in
        let a = MailHub.accounts()
        return a.isEmpty ? "Nessuna casella collegata." : a.joined(separator: "\n")
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let v = self else { return nil }
        return try await f(v)
    }
}
