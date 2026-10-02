import Foundation

/// Slack through a user token (xoxp-…, Keychain service `elio-slack`): Elio acts as Raffaele.
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
        guard let t = KeychainItem.read(service: "elio-slack"), t.hasPrefix("xox") else {
            throw SlackError(description: "Slack non è collegato: manca il token nel Portachiavi (servizio elio-slack).")
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
    /// Direct messages read straight from the conversations (real time: the search index lags by
    /// minutes, so a message that just arrived was reported as "nothing new").
    /// Needs im:history / mpim:history; returns nil if the token can't, so the caller falls back to search.
    func recentDMs(since: Date, me: String) async -> [(ts: Double, line: String)]? {
        guard let r = try? await call("users.conversations", ["types": "im,mpim", "exclude_archived": "true", "limit": "200"]),
              r["ok"] as? Bool == true, let chans = r["channels"] as? [[String: Any]] else { return nil }
        // Only conversations touched since then ("updated" is in ms); at most 25 in parallel.
        let active = chans.filter { c in
            guard let u = c["updated"] as? Double else { return true }
            return u / 1000 >= since.timeIntervalSince1970
        }.prefix(25)
        var out: [(Double, String)] = []
        var denied = false
        await withTaskGroup(of: ([(Double, [String: Any])], Bool).self) { group in
            for c in active {
                guard let id = c["id"] as? String else { continue }
                group.addTask {
                    guard let h = try? await self.call("conversations.history", ["channel": id, "oldest": String(since.timeIntervalSince1970), "limit": "20"]) else { return ([], false) }
                    if h["ok"] as? Bool != true { return ([], (h["error"] as? String) == "missing_scope") }
                    let msgs = (h["messages"] as? [[String: Any]] ?? []).map { (Double($0["ts"] as? String ?? "0") ?? 0, $0) }
                    return (msgs, false)
                }
            }
            for await (msgs, missing) in group {
                denied = denied || missing
                for (ts, m) in msgs where (m["user"] as? String) != me && m["subtype"] == nil {
                    let user = await userName(m["user"] as? String ?? "")
                    let f = DateFormatter()
                    f.dateFormat = "dd/MM HH:mm"
                    let text = (m["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    out.append((ts, "- \(f.string(from: Date(timeIntervalSince1970: ts))) DM \(user): \(text.prefix(300))"))
                }
            }
        }
        if denied && out.isEmpty { return nil }
        return out.sorted { $0.0 > $1.0 }
    }

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

    static let clockIn = ElioTool(
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

    static let send = ElioTool(
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
        // Resolve the recipient first (directory, then Slack), so the confirmation names the
        // exact person/channel the message will go to.
        let kind = to.hasPrefix("#") ? "channel" : "person"
        let name = to.trimmingCharacters(in: CharacterSet(charactersIn: "@# "))
        var recipient = to
        var target: (id: String, isPerson: Bool)?
        if let hit = await Directory.find(name, kind: kind, memory: ctx.memory, limit: 1).first,
           let data = try? JSONSerialization.jsonObject(with: Data(hit.data.utf8)) as? [String: Any],
           let slackId = data["slack_id"] as? String {
            target = (slackId, kind == "person")
            recipient = hit.title
        } else if kind == "person" {
            target = (try await SlackAPI.shared.userId(named: name), true)
        } else {
            target = (try await SlackAPI.shared.channelId(name), false)
        }
        guard let target else { throw ToolError("Destinatario non trovato: \(to)") }

        let approved = await ctx.gate.request(ConfirmRequest(
            id: UUID().uuidString, title: "Invio un messaggio Slack a \(recipient)", detail: "\(recipient): \(text)",
            risk: .dangerous, taskId: nil), timeout: 120)
        guard approved else { return "Messaggio non inviato: l'utente non ha confermato." }
        var channel = target.id
        if target.isPerson {
            let r = try await SlackAPI.shared.call("conversations.open", ["users": target.id], post: true)
            channel = (r["channel"] as? [String: Any])?["id"] as? String ?? ""
        }
        try await SlackAPI.shared.post(channel: channel, text: text)
        return "Messaggio inviato a \(recipient)."
    }

    static let mentions = ElioTool(
        name: "slack_mentions",
        description: "Messaggi Slack recenti in cui l'utente è menzionato.",
        properties: ["hours": prop("Quante ore indietro (default 16)", type: "integer")]
    ) { args, _ in
        let hours = args["hours"] as? Int ?? 16
        let me = try await SlackAPI.shared.myId()
        let lines = try await SlackAPI.shared.search("<@\(me)> after:\(sinceDate(hours))")
        return lines.isEmpty ? "Nessuna menzione (la ricerca di Slack può essere indietro di qualche minuto: per i DM usa slack_dms, che è in tempo reale)." : lines.joined(separator: "\n")
    }

    static let dms = ElioTool(
        name: "slack_dms",
        description: "Messaggi diretti Slack ricevuti di recente (escludendo i propri).",
        properties: ["hours": prop("Quante ore indietro (default 16)", type: "integer")]
    ) { args, _ in
        let hours = args["hours"] as? Int ?? 16
        let me = try await SlackAPI.shared.myId()
        // Real time first; the search (minutes behind) only as a fallback.
        if let live = await SlackAPI.shared.recentDMs(since: Date().addingTimeInterval(-Double(hours) * 3600), me: me) {
            return live.isEmpty ? "Nessun messaggio diretto (letto ora da Slack)." : live.prefix(30).map(\.line).joined(separator: "\n")
        }
        let lines = try await SlackAPI.shared.search("is:dm -from:<@\(me)> after:\(sinceDate(hours))")
        return lines.isEmpty ? "Nessun messaggio diretto (la ricerca di Slack può essere indietro di qualche minuto)." : lines.joined(separator: "\n")
    }
}

/// Generic-password items in the login Keychain.
public enum KeychainItem {
    /// Written by the daemon itself (so it can read it back without prompts).
    public static func write(service: String, value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecAttrAccount as String] = "elio"
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

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
