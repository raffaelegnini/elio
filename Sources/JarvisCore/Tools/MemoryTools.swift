import Foundation

/// Long-term memory: durable facts about Raffaele, people, projects and preferences.
public enum MemoryTools {
    static let categories = ["persona", "preferenza", "lavoro", "progetto", "contatto", "routine", "generale"]

    static let remember = JarvisTool(
        name: "remember",
        description: """
        Salva un fatto da ricordare per sempre (preferenze, persone, progetti, abitudini, decisioni). \
        Usalo quando l'utente dice "ricordati che…" o rivela un'informazione stabile e utile in futuro. \
        Una frase autosufficiente per fatto, in terza persona (es. "Rosario Vitale è il referente di UnoInForma").
        """,
        properties: [
            "fact": prop("Il fatto, frase autosufficiente"),
            "category": prop("Una tra: \(categories.joined(separator: ", "))"),
        ],
        required: ["fact"]
    ) { args, ctx in
        guard let fact = (args["fact"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !fact.isEmpty else {
            throw ToolError("Fatto vuoto")
        }
        let category = (args["category"] as? String).flatMap { categories.contains($0) ? $0 : nil } ?? "generale"
        // Avoid exact duplicates.
        if await ctx.memory.facts(matching: fact, limit: 50).contains(where: { $0.text.lowercased() == fact.lowercased() }) {
            return "Lo sapevo già."
        }
        let id = await ctx.memory.addFact(fact, category: category)
        ctx.broadcast(ServerMessage(type: .event, id: "\(id)", text: fact, kind: "memory", payload: "{\"category\":\"\(category)\"}"))
        return "Memorizzato (#\(id))."
    }

    static let recall = JarvisTool(
        name: "recall",
        description: "Cerca nella memoria a lungo termine. Senza query restituisce tutto (più recenti prima).",
        properties: ["query": prop("Parole chiave (opzionale)")]
    ) { args, ctx in
        let facts = await ctx.memory.facts(matching: args["query"] as? String, limit: 60)
        guard !facts.isEmpty else { return "Nessun ricordo trovato." }
        return facts.map { "#\($0.id) [\($0.category)] \($0.text)" }.joined(separator: "\n")
    }

    static let forget = JarvisTool(
        name: "forget",
        description: "Dimentica un fatto della memoria a lungo termine, dato il suo #id (usa recall per trovarlo).",
        properties: ["id": prop("Id numerico del fatto", type: "integer")],
        required: ["id"]
    ) { args, ctx in
        guard let id = args["id"] as? Int else { throw ToolError("Serve l'id") }
        return await ctx.memory.deleteFact(id) ? "Dimenticato." : "Non trovato."
    }

    /// Facts injected in the system prompt when the conversation session starts.
    static func promptBlock(_ facts: [Memory.Fact]) -> String {
        guard !facts.isEmpty else { return "Memoria a lungo termine: ancora vuota." }
        return "Memoria a lungo termine (cose che sai su Raffaele):\n" +
            facts.prefix(80).map { "- [\($0.category)] \($0.text)" }.joined(separator: "\n")
    }
}
