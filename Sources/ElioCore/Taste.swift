import Foundation

/// Elio's model of the user's taste: rules taught over time ("niente gradienti viola", "commit in inglese,
/// imperativo"), handed to every agent, checked on their work, and used to decide small things on the user's behalf.
public enum Taste {
    public static let domains = ["design", "frontend", "backend", "codice", "testi", "git", "ux", "generale"]

    /// The rules as agents read them (in their prompt and from taste_rules).
    public static func promptBlock(_ rules: [TasteRule], domain: String? = nil) -> String {
        let wanted = rules.filter { domain == nil || $0.domain == domain || $0.domain == "generale" }
        guard !wanted.isEmpty else { return "" }
        var lines = ["Gusti e standard di Raffaele (vincolanti: un revisore controlla il tuo lavoro su queste regole):"]
        for d in domains {
            let group = wanted.filter { $0.domain == d }
            guard !group.isEmpty else { continue }
            lines.append("[\(d)]")
            for r in group {
                var line = "- #\(r.id) \(r.rule)"
                if !r.why.isEmpty { line += " (perché: \(r.why))" }
                if !r.bad.isEmpty { line += "\n    no: \(r.bad)" }
                if !r.good.isEmpty { line += "\n    sì: \(r.good)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Reviewer

/// Checks what an agent wrote against the user's taste, like the user would on a code review.
public enum TasteReviewer {
    public struct Violation: Codable, Sendable {
        public var rule: Int
        public var file: String
        public var problem: String
        public var fix: String
        public var severity: String
    }
    public struct Review: Sendable {
        public var violations: [Violation]
        public var verdict: String
        public var costUSD: Double
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "violations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "rule": ["type": "integer", "description": "id della regola violata"],
                        "file": ["type": "string"],
                        "problem": ["type": "string", "description": "cosa non va, concreto"],
                        "fix": ["type": "string", "description": "come correggerlo, istruzione precisa per l'agente"],
                        "severity": ["type": "string", "enum": ["fix", "note", "ask"]],
                    ],
                    "required": ["rule", "file", "problem", "fix", "severity"],
                ],
            ],
            "verdict": ["type": "string", "description": "una frase in italiano sul lavoro rispetto ai gusti di Raffaele"],
        ],
        "required": ["violations", "verdict"],
    ]

    public static func review(agent: String, goal: String, edits: [TaskLogEntry], rules: [TasteRule],
                              config: ElioConfig) async -> Review? {
        var budget = 60_000
        var changes: [String] = []
        for e in edits {
            let chunk = "### \(e.kind == .write ? "Nuovo file" : "Modifica") \(e.title)\n" +
                (e.removed.map { $0.isEmpty ? "" : "--- prima:\n\($0)\n" } ?? "") + "+++ dopo:\n\(e.added ?? "")\n"
            guard budget - chunk.count > 0 else { break }
            budget -= chunk.count
            changes.append(chunk)
        }
        let prompt = """
            Sei il revisore personale di Raffaele: conosci i suoi gusti e controlli il lavoro di un agente come farebbe lui.

            \(Taste.promptBlock(rules))

            Obiettivo del lavoro: \(goal)
            Agente: \(agent)

            Modifiche fatte dall'agente:
            \(changes.joined(separator: "\n"))

            Istruzioni:
            - Segnala SOLO violazioni concrete e sicure delle regole qui sopra, visibili nelle modifiche. Niente gusti tuoi, \
            niente stile generico, niente bug che non c'entrano con le regole.
            - severity: usa quella della regola ("fix" se l'agente deve correggere, "note" se è solo da segnalare, \
            "ask" se serve una decisione di Raffaele).
            - fix: un'istruzione precisa ed eseguibile per l'agente (file, cosa cambiare, in cosa).
            - Se non ci sono violazioni, violations vuoto.
            """
        guard let r = await OneShot.ask(prompt, schema: schema, model: config.reviewModel, config: config) else { return nil }
        let raw = r.json["violations"] as? [[String: Any]] ?? []
        let known = Set(rules.map(\.id))
        let violations = raw.compactMap { v -> Violation? in
            guard let rule = v["rule"] as? Int, known.contains(rule) else { return nil }
            return Violation(rule: rule, file: v["file"] as? String ?? "", problem: v["problem"] as? String ?? "",
                             fix: v["fix"] as? String ?? "", severity: v["severity"] as? String ?? "fix")
        }
        return Review(violations: violations, verdict: r.json["verdict"] as? String ?? "", costUSD: r.costUSD)
    }

    /// What the agent is told when it has to fix things.
    static func correction(_ violations: [Violation], rules: [TasteRule], addressee: String) -> String {
        let byId = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = violations.map { v in
            "- \(v.file.isEmpty ? "" : "\(v.file): ")\(v.problem)\n  Regola #\(v.rule): \(byId[v.rule]?.rule ?? "")\n  Correzione: \(v.fix)"
        }
        return """
            Revisione di Elio: alcune cose non vanno come piace a \(addressee). Correggile, committa e chiudi di nuovo \
            con il riassunto di due frasi:
            \(items.joined(separator: "\n"))
            """
    }
}

// MARK: - Delegated decisions

/// Answers an agent's question in the user's place when it's small and their known taste covers it.
public enum Delegate {
    public struct Decision: Sendable {
        public var decide: Bool
        public var answer: String
        public var reason: String
        public var costUSD: Double
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "decide": ["type": "boolean", "description": "true solo se puoi decidere tu al posto di Raffaele"],
            "answer": ["type": "string", "description": "la risposta da dare all'agente, se decide è true"],
            "reason": ["type": "string", "description": "in una frase: su quale preferenza o principio ti basi, o perché serve Raffaele"],
        ],
        "required": ["decide", "answer", "reason"],
    ]

    public static func decide(question: String, from: String, goal: String, board: [SquadMessage],
                              rules: [TasteRule], facts: [Memory.Fact], config: ElioConfig) async -> Decision? {
        let user = config.userName
        let prompt = """
            Sei \(config.assistantName), l'assistente di \(user), e fai le sue veci mentre i suoi agenti lavorano. \
            Un agente gli fa una domanda. Rispondi tu SOLO se tutte queste condizioni sono vere:
            1. È una decisione piccola e reversibile: dettagli di implementazione, naming, stile, struttura di file, \
            scelta tra opzioni equivalenti, come procedere su un passo ovvio.
            2. I gusti di \(user) qui sotto, i fatti che sai di lui o il buon senso di uno sviluppatore senior che lavora \
            come lui la coprono chiaramente.
            3. NON riguarda: soldi o acquisti, account, credenziali o chiavi, accettare termini, inviare cose fuori, \
            cancellare dati, push/merge/deploy, scelte di prodotto o architettura importanti, informazioni che solo lui ha.
            In ogni altro caso decide = false: la domanda va a \(user).

            \(Taste.promptBlock(rules))

            Fatti su \(user):
            \(facts.prefix(40).map { "- \($0.text)" }.joined(separator: "\n"))

            Obiettivo del lavoro: \(goal)
            \(board.isEmpty ? "" : "Ultimi messaggi tra gli agenti:\n" + board.suffix(8).map { "\($0.from) → \($0.to): \($0.text.prefix(300))" }.joined(separator: "\n"))

            Domanda di \(from):
            \(question)

            Se decidi, la risposta è diretta e operativa, come la darebbe \(user) ("Usa X, non Y: …").
            """
        guard let r = await OneShot.ask(prompt, schema: schema, model: config.reviewModel, config: config, timeout: 90) else { return nil }
        return Decision(decide: r.json["decide"] as? Bool ?? false, answer: r.json["answer"] as? String ?? "",
                        reason: r.json["reason"] as? String ?? "", costUSD: r.costUSD)
    }
}

// MARK: - Tools

public enum TasteTools {
    static let learn = ElioTool(
        name: "taste_learn",
        description: """
        Impara un gusto o uno standard di Raffaele, da far rispettare agli agenti ("non voglio X", "le cose le voglio così", \
        "questo è AI slop", "i commit li scrivo così", "odio quando…"). Una regola chiara e verificabile; se lui fa esempi, \
        mettili in bad/good. Gli agenti la ricevono, un revisore controlla il loro lavoro e fa correggere, e Elio la usa \
        per decidere piccole cose al suo posto. Salvala senza chiedere quando lui esprime una preferenza su come vuole il lavoro.
        """,
        properties: [
            "domain": prop("Uno tra: \(Taste.domains.joined(separator: ", "))"),
            "rule": prop("La regola, imperativa e verificabile (es. \"Niente gradienti viola-blu né glassmorphism nei design\")"),
            "why": prop("Perché (opzionale, aiuta a generalizzare)"),
            "bad": prop("Esempi di cosa non vuole (opzionale)"),
            "good": prop("Esempi di cosa vuole (opzionale)"),
            "severity": prop("fix (l'agente deve correggere, default), note (solo segnalare), ask (decide Raffaele)"),
        ],
        required: ["domain", "rule"]
    ) { args, ctx in
        guard let rule = (args["rule"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            throw ToolError("Regola vuota")
        }
        let domain = (args["domain"] as? String).flatMap { Taste.domains.contains($0) ? $0 : nil } ?? "generale"
        let severity = (args["severity"] as? String).flatMap { ["fix", "note", "ask"].contains($0) ? $0 : nil } ?? "fix"
        if await ctx.memory.tasteRules().contains(where: { $0.rule.lowercased() == rule.lowercased() }) { return "La conoscevo già." }
        let id = await ctx.memory.addTasteRule(TasteRule(domain: domain, rule: rule, why: args["why"] as? String ?? "",
                                                         bad: args["bad"] as? String ?? "", good: args["good"] as? String ?? "",
                                                         severity: severity))
        await ctx.tasks.setTaste(await ctx.memory.tasteRules())
        ctx.broadcast(ServerMessage(type: .event, id: "\(id)", text: rule, kind: "taste", payload: "{\"domain\":\"\(domain)\"}"))
        return "Imparato (#\(id), \(domain)). Da ora gli agenti la rispettano e il revisore la controlla."
    }

    static let list = ElioTool(
        name: "taste_list",
        description: "I gusti e gli standard di Raffaele che Elio conosce, per dominio, con quante volte gli agenti li hanno violati.",
        properties: ["domain": prop("Filtra per dominio (opzionale)")]
    ) { args, ctx in
        let domain = args["domain"] as? String
        let rules = await ctx.memory.tasteRules().filter { domain == nil || $0.domain == domain }
        guard !rules.isEmpty else { return "Nessun gusto memorizzato ancora." }
        return rules.map { "#\($0.id) [\($0.domain), \($0.severity)] \($0.rule)\($0.hits > 0 ? " — violata \($0.hits) volte" : "")" }
            .joined(separator: "\n")
    }

    static let forget = ElioTool(
        name: "taste_forget",
        description: "Dimentica un gusto di Raffaele dato il suo #id (usa taste_list per trovarlo).",
        properties: ["id": prop("Id numerico", type: "integer")],
        required: ["id"]
    ) { args, ctx in
        guard let id = args["id"] as? Int else { throw ToolError("Serve l'id") }
        let ok = await ctx.memory.deleteTasteRule(id)
        await ctx.tasks.setTaste(await ctx.memory.tasteRules())
        return ok ? "Dimenticato." : "Non trovato."
    }

    /// For agents: the rules for the domain they're working in.
    static let rules = ElioTool(
        name: "taste_rules",
        description: "Gusti e standard di Raffaele da rispettare (per dominio: design, frontend, backend, codice, testi, git, ux). Leggili prima di decisioni di stile.",
        properties: ["domain": prop("Dominio (opzionale: tutti)")]
    ) { args, ctx in
        let block = Taste.promptBlock(await ctx.memory.tasteRules(), domain: args["domain"] as? String)
        return block.isEmpty ? "Nessuna regola per questo dominio: usa il buon senso di un senior." : block
    }
}
