import Foundation

/// Integrations Jarvis sets up by itself: the user says "integra Teamwork", Jarvis researches
/// whether an MCP server or a REST API exists, proposes a configuration, the user enters the secret
/// in Settings (it never passes through Claude), and Jarvis writes usage notes it reads back later.
public struct Integration: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case api, mcp }
    public enum AuthType: String, Codable, Sendable, CaseIterable { case none, bearer, header, basic, query }

    public var id: String
    public var name: String
    public var kind: Kind
    /// REST: base URL. MCP over HTTP: server URL.
    public var baseURL: String = ""
    public var authType: AuthType = .none
    /// Header name (authType .header) or query parameter (authType .query).
    public var authParam: String = ""
    /// Basic auth username (Teamwork-style APIs put the key here and use any password).
    public var basicUser: String = ""
    /// MCP over stdio.
    public var mcpCommand: String = ""
    public var mcpArgs: [String] = []
    public var docsURL: String = ""
    /// How to use it: endpoints, parameters, gotchas — written by Jarvis after reading the docs.
    public var notes: String = ""
    public var enabled: Bool = true

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var secretService: String { "jarvis-int-\(id)" }
    public var hasSecret: Bool { KeychainItem.read(service: secretService) != nil }
    public var needsSecret: Bool { authType != .none && !hasSecret }
    public var isReady: Bool { enabled && !needsSecret && (kind == .mcp ? (!mcpCommand.isEmpty || !baseURL.isEmpty) : !baseURL.isEmpty) }

    public static func slug(_ name: String) -> String {
        let s = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "integrazione" : s
    }
}

public enum IntegrationStore {
    static var url: URL { JarvisPaths.support.appendingPathComponent("integrations.json") }

    public static func load() -> [Integration] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Integration].self, from: data)) ?? []
    }

    public static func save(_ items: [Integration]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    public static func upsert(_ item: Integration) {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == item.id }) { all[i] = item } else { all.append(item) }
        save(all)
    }

    public static func get(_ id: String) -> Integration? {
        let key = Integration.slug(id)
        return load().first { $0.id == key || $0.name.lowercased() == id.lowercased() }
    }

    /// MCP servers to add to the conversation session (secrets read from the Keychain here,
    /// written to a 0600 file — never on a command line).
    public static func mcpServers() -> [String: Any] {
        var servers: [String: Any] = [:]
        for i in load() where i.kind == .mcp && i.isReady {
            if !i.mcpCommand.isEmpty {
                var env: [String: String] = [:]
                if let secret = KeychainItem.read(service: i.secretService), !i.authParam.isEmpty {
                    env[i.authParam] = secret   // stdio servers usually read their key from an env var
                }
                servers[i.id] = ["command": i.mcpCommand, "args": i.mcpArgs, "env": env]
            } else {
                var headers: [String: String] = [:]
                if let secret = KeychainItem.read(service: i.secretService) {
                    switch i.authType {
                    case .bearer: headers["Authorization"] = "Bearer \(secret)"
                    case .header: headers[i.authParam.isEmpty ? "Authorization" : i.authParam] = secret
                    default: break
                    }
                }
                servers[i.id] = ["type": "http", "url": i.baseURL, "headers": headers]
            }
        }
        return servers
    }

    /// Lines for the system prompt: what's connected and how to use it.
    public static func promptBlock() -> String {
        let items = load().filter(\.enabled)
        guard !items.isEmpty else { return "Integrazioni configurate: nessuna." }
        return "Integrazioni configurate:\n" + items.map { i in
            var line = "- \(i.name) [id \(i.id), \(i.kind == .api ? "API REST via api_request" : "MCP: tool mcp__\(i.id)__*")]"
            if i.needsSecret { line += " — IN ATTESA della chiave nelle Impostazioni" }
            if !i.notes.isEmpty { line += "\n  Note d'uso: " + i.notes.replacingOccurrences(of: "\n", with: "\n  ") }
            return line
        }.joined(separator: "\n")
    }
}

public enum IntegrationTools {
    static let propose = JarvisTool(
        name: "integration_propose",
        description: """
        Crea o aggiorna la configurazione di un'integrazione dopo che l'utente ha scelto tra MCP e API. \
        Non chiedere mai la chiave/token all'utente in chat: l'app gli apre le Impostazioni per inserirla al sicuro. \
        Per API REST: base_url e auth_type (bearer, header con auth_param = nome header, basic con basic_user, \
        query con auth_param = nome parametro). Per MCP: mcp_command+mcp_args (stdio, auth_param = variabile d'ambiente \
        della chiave) oppure base_url (MCP via HTTP).
        """,
        properties: [
            "name": prop("Nome del servizio (es. Teamwork)"),
            "kind": prop("api oppure mcp"),
            "base_url": prop("URL base delle API o URL del server MCP HTTP"),
            "auth_type": prop("none, bearer, header, basic, query"),
            "auth_param": prop("Nome header / parametro query / variabile d'ambiente per la chiave"),
            "basic_user": prop("Username per basic auth, se fisso (opzionale)"),
            "mcp_command": prop("Comando del server MCP stdio (es. npx)"),
            "mcp_args": ["type": "array", "items": ["type": "string"], "description": "Argomenti del comando MCP"],
            "docs_url": prop("Pagina della documentazione"),
        ],
        required: ["name", "kind"]
    ) { args, ctx in
        let name = args["name"] as? String ?? "Integrazione"
        let id = Integration.slug(name)
        var item = IntegrationStore.get(id) ?? Integration(id: id, name: name,
                                                          kind: Integration.Kind(rawValue: args["kind"] as? String ?? "api") ?? .api)
        item.kind = Integration.Kind(rawValue: args["kind"] as? String ?? item.kind.rawValue) ?? item.kind
        if let v = args["base_url"] as? String { item.baseURL = v }
        if let v = args["auth_type"] as? String, let t = Integration.AuthType(rawValue: v) { item.authType = t }
        if let v = args["auth_param"] as? String { item.authParam = v }
        if let v = args["basic_user"] as? String { item.basicUser = v }
        if let v = args["mcp_command"] as? String { item.mcpCommand = v }
        if let v = args["mcp_args"] as? [String] { item.mcpArgs = v }
        if let v = args["docs_url"] as? String { item.docsURL = v }
        IntegrationStore.upsert(item)
        ctx.broadcast(ServerMessage(type: .event, id: id, text: name, kind: "integrationSetup", payload: item.jsonString()))
        if item.needsSecret {
            return "Configurazione salvata. L'app ha aperto le Impostazioni: l'utente deve inserire la chiave di \(name). Diglielo in una frase e aspetta."
        }
        if item.kind == .mcp { await ctx.requestSessionRestart() }
        return item.kind == .mcp
            ? "Integrazione MCP pronta: i suoi tool saranno disponibili dal prossimo messaggio."
            : "Integrazione pronta. Leggi la documentazione e salva le note con integration_notes."
    }

    static let notes = JarvisTool(
        name: "integration_notes",
        description: "Salva le note d'uso di un'integrazione (endpoint principali, parametri, filtri, paginazione, esempi). Le rileggerai in futuro: scrivile chiare e compatte.",
        properties: ["id": prop("Id dell'integrazione"), "notes": prop("Note d'uso")],
        required: ["id", "notes"]
    ) { args, _ in
        guard var item = IntegrationStore.get(args["id"] as? String ?? "") else { throw ToolError("Integrazione non trovata") }
        item.notes = String((args["notes"] as? String ?? "").prefix(4000))
        IntegrationStore.upsert(item)
        return "Note salvate per \(item.name)."
    }

    static let list = JarvisTool(
        name: "integration_list",
        description: "Elenca le integrazioni configurate, il loro stato e le note d'uso."
    ) { _, _ in
        IntegrationStore.promptBlock()
    }

    static let request = JarvisTool(
        name: "api_request",
        description: """
        Chiama un'API REST configurata (l'autenticazione la aggiunge Jarvis). path relativo alla base_url. \
        GET libero; POST/PUT/PATCH/DELETE passano da una conferma dell'utente.
        """,
        properties: [
            "integration": prop("Id dell'integrazione"),
            "method": prop("GET, POST, PUT, PATCH, DELETE"),
            "path": prop("Percorso, es. /projects/api/v3/tasks.json"),
            "query": ["type": "object", "description": "Parametri query (chiave → valore)"],
            "body": ["type": "object", "description": "Corpo JSON (per scritture)"],
        ],
        required: ["integration", "path"]
    ) { args, ctx in
        guard let item = IntegrationStore.get(args["integration"] as? String ?? ""), item.kind == .api else {
            throw ToolError("Integrazione API non trovata")
        }
        guard !item.needsSecret else { throw ToolError("Manca la chiave di \(item.name): va inserita nelle Impostazioni") }
        let method = (args["method"] as? String ?? "GET").uppercased()
        let path = args["path"] as? String ?? "/"
        guard var comps = URLComponents(string: item.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                                        + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw ToolError("URL non valido")
        }
        var query = (args["query"] as? [String: Any] ?? [:]).map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        let secret = KeychainItem.read(service: item.secretService)
        if item.authType == .query, let secret { query.append(URLQueryItem(name: item.authParam.isEmpty ? "api_key" : item.authParam, value: secret)) }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query }
        guard let url = comps.url, url.host == URL(string: item.baseURL)?.host else {
            throw ToolError("Il percorso deve restare sull'host dell'integrazione")
        }

        if method != "GET" && method != "HEAD" {
            let bodyText = (args["body"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            let ok = await ctx.gate.request(ConfirmRequest(
                id: UUID().uuidString, title: "Modifico dati su \(item.name) (\(method) \(path))",
                detail: "\(method) \(url.path)\n\(bodyText.prefix(600))",
                risk: method == "DELETE" ? .dangerous : .normal, taskId: ctx.taskId), timeout: 120)
            guard ok else { return "Operazione annullata dall'utente." }
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret {
            switch item.authType {
            case .bearer: req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            case .header: req.setValue(secret, forHTTPHeaderField: item.authParam.isEmpty ? "Authorization" : item.authParam)
            case .basic:
                let user = item.basicUser.isEmpty ? secret : item.basicUser
                let pass = item.basicUser.isEmpty ? "x" : secret
                req.setValue("Basic \(Data("\(user):\(pass)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            default: break
            }
        }
        if let body = args["body"], method != "GET" {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var text = String(decoding: data, as: UTF8.self)
        if text.count > 8000 { text = String(text.prefix(8000)) + "\n…[troncato]" }
        return "HTTP \(status)\n\(text)"
    }
}
