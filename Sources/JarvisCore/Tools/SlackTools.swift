import Foundation

/// Slack through a user token (xoxp-…, Keychain service `jarvis-slack`): Jarvis acts as Raffaele.
/// Every outgoing message goes through the confirmation gate.
public actor SlackAPI {
    public static let shared = SlackAPI()

    private var channels: [String: String] = [:]   // name → id
    private var users: [String: String] = [:]      // id → display name
    private var me: String?

    struct SlackError: Error, CustomStringConvertible {
        let description: String
    }

    private func token() throws -> String {
        guard let t = KeychainItem.read(service: "jarvis-slack"), t.hasPrefix("xox") else {
            throw SlackError(description: "Slack non è collegato: manca il token nel Portachiavi (servizio jarvis-slack).")
        }
        return t
    }

    func call(_ method: String, _ params: [String: String] = [:], post: Bool = false) async throws -> [String: Any] {
        var req: URLRequest
        if post {
            req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: params)
        } else {
            var c = URLComponents(string: "https://slack.com/api/\(method)")!
            c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            req = URLRequest(url: c.url!)
        }
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError(description: "Risposta Slack non valida")
        }
        guard obj["ok"] as? Bool == true else {
            throw SlackError(description: "Slack \(method): \(obj["error"] as? String ?? "errore")")
        }
        return obj
    }

    func myId() async throws -> String {
        if let me { return me }
        let r = try await call("auth.test")
        me = r["user_id"] as? String
        return me ?? ""
    }

    func channelId(_ raw: String) async throws -> String {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        if let id = channels[name] { return id }
        var cursor = ""
        repeat {
            var p = ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": "1000"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let r = try await call("conversations.list", p)
            for c in r["channels"] as? [[String: Any]] ?? [] {
                if let n = c["name"] as? String, let id = c["id"] as? String { channels[n.lowercased()] = id }
            }
            cursor = ((r["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        } while !cursor.isEmpty && channels[name] == nil
        guard let id = channels[name] else { throw SlackError(description: "Canale #\(name) non trovato") }
        return id
    }

    func userName(_ id: String) async -> String {
        if let n = users[id] { return n }
        guard let r = try? await call("users.info", ["user": id]),
              let u = r["user"] as? [String: Any] else { return id }
        let profile = u["profile"] as? [String: Any]
        let name = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (u["real_name"] as? String) ?? (u["name"] as? String) ?? id
        users[id] = name
        return name
    }

    func userId(named raw: String) async throws -> String {
        let wanted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        var cursor = ""
        repeat {
            var p = ["limit": "500"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let r = try await call("users.list", p)
            for u in r["members"] as? [[String: Any]] ?? [] where u["deleted"] as? Bool != true {
                let profile = u["profile"] as? [String: Any]
                let names = [u["name"], u["real_name"], profile?["display_name"], profile?["real_name"]]
                    .compactMap { ($0 as? String)?.lowercased() }
                if names.contains(wanted) || names.contains(where: { $0.hasPrefix(wanted + " ") }),
                   let id = u["id"] as? String { return id }
            }
            cursor = ((r["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        } while !cursor.isEmpty
        throw SlackError(description: "Utente \(raw) non trovato")
    }

    func post(channel: String, text: String) async throws {
        _ = try await call("chat.postMessage", ["channel": channel, "text": text], post: true)
    }

    /// Messages matching a Slack search query, newest first.
    func search(_ query: String, count: Int = 20) async throws -> [String] {
        let r = try await call("search.messages", ["query": query, "sort": "timestamp", "sort_dir": "desc", "count": "\(count)"])
        let matches = ((r["messages"] as? [String: Any])?["matches"] as? [[String: Any]]) ?? []
        // Resolve every author once, in parallel (users.info per message was slow).
        let ids = Set(matches.compactMap { $0["user"] as? String }).subtracting(users.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { _ = await self.userName(id) } }
        }
        var lines: [String] = []
        for m in matches {
            let user = await userName(m["user"] as? String ?? "")
            let channel = (m["channel"] as? [String: Any]).map { c -> String in
                (c["is_im"] as? Bool == true) ? "DM" : "#\(c["name"] as? String ?? "?")"
            } ?? "?"
            let ts = Double(m["ts"] as? String ?? "0") ?? 0
            let f = DateFormatter()
            f.dateFormat = "dd/MM HH:mm"
            let text = (m["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            lines.append("- \(f.string(from: Date(timeIntervalSince1970: ts))) \(channel) \(user): \(text.prefix(300))")
        }
        return lines
    }
}

public enum SlackTools {
    static func sinceDate(_ hours: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // Slack's after: is exclusive and day-granular: go one day further back.
        return f.string(from: Date().addingTimeInterval(-Double(hours) * 3600 - 86400))
    }

    static let clockIn = JarvisTool(
        name: "slack_clock_in",
        description: "Fa il clock in: scrive il saluto del mattino nel canale Slack configurato (default #team-saluti, 'buongiorno'). Chiede conferma all'utente."
    ) { _, ctx in
        let today = Routines.dayKey(Date())
        if await ctx.memory.get("slack.clockin.last") == today { return "Clock in già fatto oggi." }
        let channel = ctx.config.slackClockInChannel
        let text = ctx.config.slackClockInText
        let approved = await ctx.gate.request(ConfirmRequest(
            id: UUID().uuidString, title: "Scrivo \"\(text)\" in #\(channel)", detail: "#\(channel): \(text)",
            risk: .normal, taskId: nil), timeout: 120)
        guard approved else { return "Clock in annullato dall'utente." }
        let id = try await SlackAPI.shared.channelId(channel)
        try await SlackAPI.shared.post(channel: id, text: text)
        await ctx.memory.set("slack.clockin.last", today)
        return "Clock in fatto: scritto \"\(text)\" in #\(channel)."
    }

    static let send = JarvisTool(
        name: "slack_send",
        description: "Invia un messaggio Slack a nome dell'utente in un canale (#nome) o in DM a una persona (@nome). Richiede la conferma esplicita: riporta all'utente il testo esatto.",
        properties: [
            "to": prop("#canale oppure @persona"),
            "text": prop("Testo esatto del messaggio"),
        ],
        required: ["to", "text"]
    ) { args, ctx in
        let to = (args["to"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let text = args["text"] as? String ?? ""
        guard !to.isEmpty, !text.isEmpty else { throw ToolError("Servono destinatario e testo") }
        let approved = await ctx.gate.request(ConfirmRequest(
            id: UUID().uuidString, title: "Invio un messaggio Slack a \(to)", detail: "\(to): \(text)",
            risk: .dangerous, taskId: nil), timeout: 120)
        guard approved else { return "Messaggio non inviato: l'utente non ha confermato." }
        let channel: String
        if to.hasPrefix("@") {
            let user = try await SlackAPI.shared.userId(named: to)
            let r = try await SlackAPI.shared.call("conversations.open", ["users": user], post: true)
            channel = (r["channel"] as? [String: Any])?["id"] as? String ?? ""
        } else {
            channel = try await SlackAPI.shared.channelId(to)
        }
        try await SlackAPI.shared.post(channel: channel, text: text)
        return "Messaggio inviato a \(to)."
    }

    static let mentions = JarvisTool(
        name: "slack_mentions",
        description: "Messaggi Slack recenti in cui l'utente è menzionato.",
        properties: ["hours": prop("Quante ore indietro (default 16)", type: "integer")]
    ) { args, _ in
        let hours = args["hours"] as? Int ?? 16
        let me = try await SlackAPI.shared.myId()
        let lines = try await SlackAPI.shared.search("<@\(me)> after:\(sinceDate(hours))")
        return lines.isEmpty ? "Nessuna menzione." : lines.joined(separator: "\n")
    }

    static let dms = JarvisTool(
        name: "slack_dms",
        description: "Messaggi diretti Slack ricevuti di recente (escludendo i propri).",
        properties: ["hours": prop("Quante ore indietro (default 16)", type: "integer")]
    ) { args, _ in
        let hours = args["hours"] as? Int ?? 16
        let me = try await SlackAPI.shared.myId()
        let lines = try await SlackAPI.shared.search("is:dm -from:<@\(me)> after:\(sinceDate(hours))")
        return lines.isEmpty ? "Nessun messaggio diretto." : lines.joined(separator: "\n")
    }
}

/// Generic-password items in the login Keychain.
public enum KeychainItem {
    public static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
