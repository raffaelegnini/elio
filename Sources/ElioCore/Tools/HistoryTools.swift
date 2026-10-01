import Foundation

public enum HistoryTools {
    static let history = ElioTool(
        name: "history",
        description: """
        Archivio locale (JSON). section: days (giorni con attività), messages (conversazioni di un giorno o ricerca), \
        operations (strumenti usati in un giorno), tasks (lavori degli agenti), task_log (attività di un agente), \
        reminders, memory, cards (schede mostrate a schermo). Usalo per "cosa ti avevo chiesto ieri?", "cosa ha fatto l'agente su X?".
        """,
        properties: [
            "section": prop("days, messages, operations, tasks, task_log, reminders, memory"),
            "day": prop("Giorno yyyy-MM-dd (messages, operations)"),
            "search": prop("Testo da cercare (messages)"),
            "task_id": prop("Id del task (task_log)"),
        ],
        required: ["section"]
    ) { args, ctx in
        let m = ctx.memory
        let day = args["day"] as? String
        func json<T: Encodable>(_ v: T) -> String { v.jsonString() }
        switch args["section"] as? String ?? "" {
        case "days": return json(await m.archiveDays())
        case "messages": return json(await m.messages(onDay: day, search: args["search"] as? String))
        case "operations": return json(await m.toolCalls(onDay: day ?? Routines.dayKey(Date())))
        case "tasks": return json(await m.allTasks())
        case "task_log": return "[" + (await m.taskLog(args["task_id"] as? String ?? "")).joined(separator: ",") + "]"
        case "reminders": return json(await m.allReminders())
        case "cards": return json(await m.cards())
        case "memory":
            struct F: Encodable { let id: Int; let text: String; let category: String; let created: Date }
            return json(await m.facts().map { F(id: $0.id, text: $0.text, category: $0.category, created: $0.created) })
        default: throw ToolError("Sezione sconosciuta")
        }
    }
}
