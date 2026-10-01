import Foundation

/// Keeps a local, searchable directory of the things Elio needs to resolve instantly — Slack people
/// and channels, local projects, and records of any integration (e.g. Teamwork projects and people).
/// Refreshed in the background on a schedule with plain API calls: no Claude tokens, no wait at
/// request time ("scrivi a Rosario Vitale" resolves Rosario from here in milliseconds).
public actor SyncEngine {
    struct Source {
        let id: String
        let every: TimeInterval
        let fetch: @Sendable () async throws -> [(key: String, kind: String, title: String, search: String, data: String)]
    }

    private let memory: Memory
    private let config: ElioConfig
    private var loop: Task<Void, Never>?
    private var running: Set<String> = []

    public init(memory: Memory, config: ElioConfig) {
        self.memory = memory
        self.config = config
    }

    public func start() {
        loop = Task {
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await runDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Refreshes one source now (or all, with nil). Returns a short report.
    public func refresh(_ only: String? = nil) async -> String {
        var lines: [String] = []
        for s in sources() where only == nil || s.id == only || s.id.hasPrefix((only ?? "") + ".") {
            lines.append(await sync(s))
        }
        return lines.isEmpty ? "Nessuna sorgente \(only ?? "")." : lines.joined(separator: "\n")
    }

    private func runDue() async {
        for s in sources() {
            let last = Double(await memory.get("sync.last.\(s.id)") ?? "") ?? 0
            if Date().timeIntervalSince1970 - last >= s.every { _ = await sync(s) }
        }
    }

    private func sync(_ s: Source) async -> String {
        guard !running.contains(s.id) else { return "\(s.id): già in corso" }
        running.insert(s.id)
        defer { running.remove(s.id) }
        let start = Date()
        do {
            let records = try await s.fetch()
            await memory.replaceCache(source: s.id, records: records)
            await memory.set("sync.last.\(s.id)", "\(Date().timeIntervalSince1970)")
            let msg = "\(s.id): \(records.count) elementi in \(Int(Date().timeIntervalSince(start) * 1000)) ms"
            log("sync \(msg)")
            return msg
        } catch {
            // Back off: try again at the next interval, keep the previous snapshot.
            await memory.set("sync.last.\(s.id)", "\(Date().timeIntervalSince1970)")
            log("sync \(s.id) failed: \(error)")
            return "\(s.id): errore (\(error))"
        }
    }

    // MARK: - Sources

    private func sources() -> [Source] {
        var list: [Source] = []
        let roots = config.projectRoots
        list.append(Source(id: "projects", every: 1800) {
            ProjectTools.projects(roots: roots).map { p in
                (key: p.path, kind: "project", title: p.name, search: "\(p.name) \(p.path)", data: "{\"path\":\(Self.json(p.path))}")
            }
        })
        if KeychainItem.read(service: "elio-slack") != nil {
            list.append(Source(id: "slack.people", every: 6 * 3600) { try await Self.slackPeople() })
            list.append(Source(id: "slack.channels", every: 6 * 3600) { try await Self.slackChannels() })
        }
        for integration in IntegrationStore.load() where integration.enabled && integration.kind == .api {
            for spec in integration.syncs {
                list.append(Source(id: "\(integration.id).\(spec.name)", every: Double(max(5, spec.everyMinutes)) * 60) {
                    try await Self.integrationRecords(integration, spec)
                })
            }
        }
        return list
    }

    static func slackPeople() async throws -> [(key: String, kind: String, title: String, search: String, data: String)] {
        var out: [(key: String, kind: String, title: String, search: String, data: String)] = []
        var cursor = ""
        repeat {
            var p = ["limit": "200"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let r = try await SlackAPI.shared.call("users.list", p)
            for u in r["members"] as? [[String: Any]] ?? [] where u["deleted"] as? Bool != true && u["is_bot"] as? Bool != true {
                guard let id = u["id"] as? String, id != "USLACKBOT" else { continue }
                let profile = u["profile"] as? [String: Any] ?? [:]
                let real = (profile["real_name"] as? String) ?? (u["real_name"] as? String) ?? ""
                let display = profile["display_name"] as? String ?? ""
                let handle = u["name"] as? String ?? ""
                let title = !real.isEmpty ? real : (!display.isEmpty ? display : handle)
                let role = profile["title"] as? String ?? ""
                out.append((key: id, kind: "person", title: title, search: "\(real) \(display) \(handle) \(role)",
                            data: "{\"slack_id\":\(json(id)),\"handle\":\(json(handle)),\"role\":\(json(role))}"))
            }
            cursor = ((r["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        } while !cursor.isEmpty
        return out
    }

    static func slackChannels() async throws -> [(key: String, kind: String, title: String, search: String, data: String)] {
        var out: [(key: String, kind: String, title: String, search: String, data: String)] = []
        var cursor = ""
        repeat {
            var p = ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": "1000"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let r = try await SlackAPI.shared.call("conversations.list", p)
            for c in r["channels"] as? [[String: Any]] ?? [] {
                guard let id = c["id"] as? String, let name = c["name"] as? String else { continue }
                let purpose = (c["purpose"] as? [String: Any])?["value"] as? String ?? ""
                out.append((key: id, kind: "channel", title: "#\(name)", search: "\(name) \(purpose)",
                            data: "{\"slack_id\":\(json(id))}"))
            }
            cursor = ((r["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        } while !cursor.isEmpty
        return out
    }

    /// Generic: GET an integration endpoint, take the array at `itemsPath`, one record per item.
    static func integrationRecords(_ item: Integration, _ spec: Integration.SyncSpec) async throws
        -> [(key: String, kind: String, title: String, search: String, data: String)] {
        let (status, body) = try await IntegrationHTTP.send(item, method: "GET", path: spec.path, query: spec.query, body: nil)
        guard (200..<300).contains(status) else { throw ToolError("HTTP \(status)") }
        var node: Any = try JSONSerialization.jsonObject(with: Data(body.utf8))
        for part in spec.itemsPath.split(separator: ".") where !part.isEmpty {
            guard let dict = node as? [String: Any], let next = dict[String(part)] else { throw ToolError("items_path non trovato: \(part)") }
            node = next
        }
        guard let items = node as? [[String: Any]] else { throw ToolError("items_path non è una lista") }
        return items.prefix(5000).compactMap { obj in
            guard let key = obj[spec.keyField].map({ "\($0)" }) else { return nil }
            let title = obj[spec.titleField].map { "\($0)" } ?? key
            let data = (try? JSONSerialization.data(withJSONObject: obj)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            // Search over the title and the item's other short string fields.
            let extra = obj.values.compactMap { $0 as? String }.filter { $0.count < 80 }.joined(separator: " ")
            return (key: key, kind: spec.kind, title: title, search: "\(title) \(extra)", data: String(data.prefix(4000)))
        }
    }

    static func json(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            .dropFirst().dropLast().description
    }
}

/// Ranked lookup over the synced directory.
public enum Directory {
    public static func find(_ query: String, kind: String? = nil, memory: Memory, limit: Int = 8) async -> [Memory.CachedRecord] {
        let q = Memory.fold(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var candidates = await memory.searchCache(q, kind: kind)
        if candidates.isEmpty, let first = q.split(separator: " ").first {
            // Loose fallback: any record matching the first word (e.g. only the first name was said).
            candidates = await memory.searchCache(String(first), kind: kind)
        }
        func score(_ r: Memory.CachedRecord) -> Int {
            let t = Memory.fold(r.title)
            if t == q || t == "#" + q { return 100 }
            if t.hasPrefix(q) { return 80 }
            if q.split(separator: " ").allSatisfy({ t.contains($0) }) { return 60 }
            return 30
        }
        return candidates.sorted { score($0) != score($1) ? score($0) > score($1) : $0.title.count < $1.title.count }
            .prefix(limit).map { $0 }
    }
}

public enum DirectoryTools {
    static let lookup = ElioTool(
        name: "lookup",
        description: """
        Cerca istantaneamente nella rubrica locale sincronizzata: persone e canali Slack, progetti, \
        e i dati delle integrazioni (es. progetti/persone/task di Teamwork). Usalo PRIMA di chiamare API \
        per risolvere nomi: è immediato e non costa nulla.
        """,
        properties: [
            "query": prop("Nome o parole da cercare"),
            "kind": prop("Opzionale: person, channel, project, o il tipo di un'integrazione"),
        ],
        required: ["query"]
    ) { args, ctx in
        let found = await Directory.find(args["query"] as? String ?? "", kind: args["kind"] as? String, memory: ctx.memory)
        guard !found.isEmpty else { return "Nessun risultato nella rubrica locale (prova cache_refresh o le API)." }
        return found.map { "- [\($0.kind)] \($0.title) (key \($0.key), fonte \($0.source)) \($0.data.prefix(200))" }.joined(separator: "\n")
    }

    static let refresh = ElioTool(
        name: "cache_refresh",
        description: "Aggiorna subito la rubrica locale (tutte le sorgenti, o una: projects, slack.people, slack.channels, <integrazione>.<nome>). Mostra anche lo stato.",
        properties: ["source": prop("Opzionale: sorgente da aggiornare")]
    ) { args, ctx in
        let report = await ctx.sync?.refresh(args["source"] as? String) ?? "Sincronizzazione non disponibile."
        let stats = await ctx.memory.cacheStats().map { "- \($0.source): \($0.count) (aggiornato \($0.updated.formatted(date: .omitted, time: .shortened)))" }
        return report + "\nStato rubrica:\n" + stats.joined(separator: "\n")
    }

    static let integrationSync = ElioTool(
        name: "integration_sync",
        description: """
        Fa sincronizzare periodicamente (in background, senza token) un elenco di un'integrazione API nella rubrica locale, \
        così poi lookup lo trova all'istante. Indica: endpoint GET, ogni quanti minuti, dove sta la lista nel JSON \
        (items_path con punti, vuoto se è la radice), campo chiave e campo titolo, e un kind (es. project, person, task).
        """,
        properties: [
            "integration": prop("Id dell'integrazione"),
            "name": prop("Nome breve della sincronizzazione (es. projects)"),
            "path": prop("Endpoint GET relativo alla base URL"),
            "every_minutes": prop("Frequenza in minuti (min 5)", type: "integer"),
            "items_path": prop("Percorso della lista nel JSON, es. projects o data.items"),
            "key_field": prop("Campo id dell'elemento"),
            "title_field": prop("Campo nome/titolo dell'elemento"),
            "kind": prop("Tipo dei record (project, person, task…)"),
            "query": ["type": "object", "description": "Parametri query fissi (es. pageSize)"],
        ],
        required: ["integration", "name", "path", "key_field", "title_field", "kind"]
    ) { args, ctx in
        guard var item = IntegrationStore.get(args["integration"] as? String ?? ""), item.kind == .api else {
            throw ToolError("Integrazione API non trovata")
        }
        let spec = Integration.SyncSpec(
            name: Integration.slug(args["name"] as? String ?? "dati"), path: args["path"] as? String ?? "/",
            query: (args["query"] as? [String: Any] ?? [:]).mapValues { "\($0)" },
            everyMinutes: args["every_minutes"] as? Int ?? 60, itemsPath: args["items_path"] as? String ?? "",
            keyField: args["key_field"] as? String ?? "id", titleField: args["title_field"] as? String ?? "name",
            kind: args["kind"] as? String ?? "record")
        item.syncs.removeAll { $0.name == spec.name }
        item.syncs.append(spec)
        IntegrationStore.upsert(item)
        let report = await ctx.sync?.refresh("\(item.id).\(spec.name)") ?? ""
        return "Sincronizzazione impostata (ogni \(spec.everyMinutes) min). \(report)"
    }
}
