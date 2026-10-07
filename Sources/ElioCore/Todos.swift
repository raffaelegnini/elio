import Foundation
import SQLite3

/// The user's to-do list: what they want to get done today (or another day, or "prima o poi"), ticked off
/// from the dashboard, the phone or by voice. Elio plans it with them in the morning, reminds the timed ones,
/// carries over what's left and can hand a to-do to an agent.
public struct TodoItem: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var text: String
    /// yyyy-MM-dd, or nil for the "prima o poi" list.
    public var day: String?
    /// 0 normal, 1 important.
    public var priority: Int
    public var done: Bool
    public var doneAt: Date?
    public var created: Date
    /// Order inside the day (lower first).
    public var position: Int
    public var notes: String
    /// Rough time it takes, in minutes (0 = unknown).
    public var estimate: Int
    /// "HH:mm" when it has a time (a reminder goes off then).
    public var time: String?
    /// For recurring templates: "daily" | "weekdays"; instances point to their template with `parent`.
    public var recurring: String?
    public var parent: Int?
    /// The one thing being worked on now.
    public var focus: Bool

    public init(id: Int = 0, text: String, day: String?, priority: Int = 0, done: Bool = false, doneAt: Date? = nil,
                created: Date = Date(), position: Int = 0, notes: String = "", estimate: Int = 0, time: String? = nil,
                recurring: String? = nil, parent: Int? = nil, focus: Bool = false) {
        self.id = id; self.text = text; self.day = day; self.priority = priority; self.done = done; self.doneAt = doneAt
        self.created = created; self.position = position; self.notes = notes; self.estimate = estimate; self.time = time
        self.recurring = recurring; self.parent = parent; self.focus = focus
    }
}

/// What the dashboard and the phone show.
public struct TodoBoard: Codable, Sendable {
    public var day: String
    public var today: [TodoItem]
    /// Unfinished items from past days.
    public var overdue: [TodoItem]
    public var tomorrow: [TodoItem]
    public var someday: [TodoItem]
    public var recurring: [TodoItem]

    public init(day: String, today: [TodoItem], overdue: [TodoItem], tomorrow: [TodoItem], someday: [TodoItem], recurring: [TodoItem]) {
        self.day = day; self.today = today; self.overdue = overdue; self.tomorrow = tomorrow
        self.someday = someday; self.recurring = recurring
    }
}

public enum TodoDay {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func key(_ date: Date = Date()) -> String { formatter.string(from: date) }

    /// "oggi", "domani", "lunedì", "2026-10-05", "prima o poi" → day key (nil = someday).
    static func parse(_ raw: String?) -> String?? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .some(key()) }
        let cal = Calendar.current
        switch raw {
        case "oggi", "today": return .some(key())
        case "domani", "tomorrow": return .some(key(cal.date(byAdding: .day, value: 1, to: Date())!))
        case "dopodomani": return .some(key(cal.date(byAdding: .day, value: 2, to: Date())!))
        case "prima o poi", "someday", "qualche giorno", "nessuno", "none": return .some(nil)
        default: break
        }
        if formatter.date(from: raw) != nil { return .some(raw) }
        let names = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]
        if let target = names.firstIndex(where: { raw.hasPrefix(String($0.prefix(3))) }) {
            for offset in 1...7 {
                let d = cal.date(byAdding: .day, value: offset, to: Date())!
                if cal.component(.weekday, from: d) - 1 == target { return .some(key(d)) }
            }
        }
        if let d = ISO8601DateFormatter().date(from: raw) { return .some(key(d)) }
        return nil
    }
}

// MARK: - Storage

extension Memory {
    static let todoSchema = """
        CREATE TABLE IF NOT EXISTS todos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            day TEXT,
            priority INTEGER NOT NULL DEFAULT 0,
            done INTEGER NOT NULL DEFAULT 0,
            done_at REAL,
            created REAL NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            notes TEXT NOT NULL DEFAULT '',
            estimate INTEGER NOT NULL DEFAULT 0,
            time TEXT,
            recurring TEXT,
            parent INTEGER,
            focus INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS todos_day ON todos(day);
        """

    private static let todoColumns = "id, text, day, priority, done, done_at, created, position, notes, estimate, time, recurring, parent, focus"

    private static func todoRow(_ s: OpaquePointer) -> TodoItem {
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        return TodoItem(id: Int(sqlite3_column_int64(s, 0)), text: text(1) ?? "", day: text(2),
                        priority: Int(sqlite3_column_int64(s, 3)), done: sqlite3_column_int64(s, 4) == 1,
                        doneAt: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
                        created: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
                        position: Int(sqlite3_column_int64(s, 7)), notes: text(8) ?? "", estimate: Int(sqlite3_column_int64(s, 9)),
                        time: text(10), recurring: text(11),
                        parent: sqlite3_column_type(s, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 12)),
                        focus: sqlite3_column_int64(s, 13) == 1)
    }

    private func todoQuery(_ whereSQL: String, _ params: [Any?]) -> [TodoItem] {
        var rows: [TodoItem] = []
        query("SELECT \(Self.todoColumns) FROM todos WHERE \(whereSQL) ORDER BY done, priority DESC, position, id", params) {
            rows.append(Self.todoRow($0))
        }
        return rows
    }

    @discardableResult
    public func addTodo(_ t: TodoItem) -> Int {
        var position = 0
        query("SELECT COALESCE(MAX(position), 0) + 1 FROM todos WHERE day IS ?", [t.day]) { position = Int(sqlite3_column_int64($0, 0)) }
        run("""
            INSERT INTO todos (text, day, priority, done, created, position, notes, estimate, time, recurring, parent, focus)
            VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, 0)
            """, [t.text, t.day, t.priority, Date().timeIntervalSince1970, position, t.notes, t.estimate, t.time, t.recurring, t.parent])
        return Int(sqlite3_last_insert_rowid(db))
    }

    public func todo(_ id: Int) -> TodoItem? { todoQuery("id = ?", [id]).first }

    public func todos(day: String?) -> [TodoItem] {
        day == nil ? todoQuery("day IS NULL AND recurring IS NULL", []) : todoQuery("day = ?", [day])
    }

    /// Searches open to-dos by words (for "ho fatto la mail a Rosario").
    public func findTodos(_ text: String) -> [TodoItem] {
        let words = text.lowercased().split(separator: " ").filter { $0.count > 2 }.map(String.init)
        guard !words.isEmpty else { return [] }
        let all = todoQuery("recurring IS NULL AND (day IS NULL OR day >= ?)", [TodoDay.key(Date().addingTimeInterval(-7 * 86400))])
        return all.map { t in (t, words.filter { t.text.lowercased().contains($0) }.count) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public func updateTodo(_ t: TodoItem) {
        run("""
            UPDATE todos SET text = ?, day = ?, priority = ?, done = ?, done_at = ?, position = ?, notes = ?, estimate = ?,
            time = ?, recurring = ?, focus = ? WHERE id = ?
            """, [t.text, t.day, t.priority, t.done ? 1 : 0, t.doneAt?.timeIntervalSince1970, t.position, t.notes, t.estimate,
                  t.time, t.recurring, t.focus ? 1 : 0, t.id])
    }

    public func deleteTodo(_ id: Int) -> Bool {
        run("DELETE FROM todos WHERE id = ? OR parent = ?", [id, id])
        return sqlite3_changes(db) > 0
    }

    /// Only one focus at a time.
    public func setFocus(_ id: Int?) {
        run("UPDATE todos SET focus = 0 WHERE focus = 1", [])
        if let id { run("UPDATE todos SET focus = 1 WHERE id = ?", [id]) }
    }

    /// Recurring templates get today's instance the first time today's list is read.
    public func materializeRecurring(day: String = TodoDay.key()) {
        guard let date = TodoDay.formatter.date(from: day) else { return }
        let weekday = Calendar.current.component(.weekday, from: date)
        for t in todoQuery("recurring IS NOT NULL", []) {
            if t.recurring == "weekdays", weekday == 1 || weekday == 7 { continue }
            var exists = false
            query("SELECT 1 FROM todos WHERE parent = ? AND day = ?", [t.id, day]) { _ in exists = true }
            guard !exists else { continue }
            addTodo(TodoItem(text: t.text, day: day, priority: t.priority, notes: t.notes, estimate: t.estimate, time: t.time, parent: t.id))
        }
    }

    public func todoBoard(day: String = TodoDay.key()) -> TodoBoard {
        materializeRecurring(day: day)
        let tomorrow = TodoDay.key(Calendar.current.date(byAdding: .day, value: 1, to: TodoDay.formatter.date(from: day) ?? Date())!)
        return TodoBoard(day: day, today: todos(day: day),
                         overdue: todoQuery("day < ? AND done = 0 AND recurring IS NULL AND parent IS NULL", [day]),
                         tomorrow: todos(day: tomorrow), someday: todos(day: nil),
                         recurring: todoQuery("recurring IS NOT NULL", []))
    }

    /// Drops pending reminders with exactly this text (a to-do done, moved or removed).
    public func cancelReminders(text: String) {
        run("UPDATE reminders SET done = 1 WHERE done = 0 AND text = ?", [text])
    }

    /// Unfinished to-dos of past days move to `day`. Returns how many.
    public func carryOverTodos(to day: String = TodoDay.key()) -> Int {
        run("UPDATE todos SET day = ? WHERE day < ? AND done = 0 AND recurring IS NULL AND parent IS NULL", [day, day])
        let moved = Int(sqlite3_changes(db))
        // Stale instances of recurring to-dos are dropped, not carried.
        run("DELETE FROM todos WHERE day < ? AND done = 0 AND parent IS NOT NULL", [day])
        return moved
    }
}

// MARK: - Tools

public enum TodoTools {
    /// Tells every client (dashboard, phone) to show the new list.
    static func publish(_ ctx: ToolContext) async {
        ctx.broadcast(ServerMessage(type: .event, kind: "todos", payload: await ctx.memory.todoBoard().jsonString()))
    }

    static func describe(_ t: TodoItem) -> String {
        var s = "#\(t.id) [\(t.done ? "x" : " ")] \(t.text)"
        if t.priority > 0 { s += " (importante)" }
        if let time = t.time { s += " alle \(time)" }
        if t.estimate > 0 { s += " ~\(t.estimate) min" }
        if t.focus { s += " ← in corso" }
        if let r = t.recurring { s += " (ricorrente: \(r == "daily" ? "ogni giorno" : "giorni feriali"))" }
        if !t.notes.isEmpty { s += " — \(t.notes)" }
        return s
    }

    /// Done or removed: its pending reminder goes too.
    static func unremind(_ t: TodoItem, ctx: ToolContext) async {
        guard t.time != nil else { return }
        await ctx.memory.cancelReminders(text: "To-do: \(t.text)")
    }

    /// A due time today or later: a reminder goes off then.
    static func remind(_ t: TodoItem, ctx: ToolContext) async {
        await unremind(t, ctx: ctx)   // moved or re-timed: never two reminders for one to-do
        guard !t.done, let time = t.time, let day = t.day, let date = TodoDay.formatter.date(from: day) else { return }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let at = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date),
              at > Date() else { return }
        await ctx.scheduler.add(text: "To-do: \(t.text)", at: at)
    }

    static let add = ElioTool(
        name: "todo_add",
        description: """
        Aggiunge cose alla to-do list dell'utente (una o più). Usalo quando dice cosa vuole fare ("oggi devo…", "segnati di…", \
        "mettimi in lista…") e al mattino quando pianificate la giornata. day: oggi (default), domani, un giorno della settimana, \
        yyyy-MM-dd o "prima o poi". time "HH:mm" fa partire un promemoria a quell'ora. recurring: daily o weekdays per le cose \
        di ogni giorno. Una voce = un'azione concreta, breve, all'infinito ("Rispondere a Rosario sul preventivo").
        """,
        properties: [
            "items": [
                "type": "array",
                "description": "Le voci da aggiungere",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": prop("Cosa fare"), "day": prop("oggi, domani, lunedì, yyyy-MM-dd, prima o poi"),
                        "important": prop("Importante (default false)", type: "boolean"),
                        "time": prop("Orario HH:mm (opzionale)"), "estimate": prop("Minuti stimati (opzionale)", type: "integer"),
                        "notes": prop("Note (opzionale)"), "recurring": prop("daily o weekdays (opzionale)"),
                    ],
                    "required": ["text"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
        required: ["items"]
    ) { args, ctx in
        let items = args["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { throw ToolError("Nessuna voce") }
        var added: [String] = []
        for item in items {
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let recurring = (item["recurring"] as? String).flatMap { ["daily", "weekdays"].contains($0) ? $0 : nil }
            guard let day = TodoDay.parse(item["day"] as? String) else { throw ToolError("Giorno non valido: \(item["day"] ?? "")") }
            var t = TodoItem(text: text, day: recurring == nil ? day : nil, priority: item["important"] as? Bool == true ? 1 : 0,
                             notes: item["notes"] as? String ?? "", estimate: item["estimate"] as? Int ?? 0,
                             time: (item["time"] as? String).flatMap { $0.isEmpty ? nil : $0 }, recurring: recurring)
            t.id = await ctx.memory.addTodo(t)
            await remind(t, ctx: ctx)
            added.append(describe(t))
        }
        await ctx.memory.materializeRecurring()
        await publish(ctx)
        return "Aggiunte \(added.count):\n" + added.joined(separator: "\n")
    }

    static let list = ElioTool(
        name: "todo_list",
        description: "La to-do list: oggi (con quelle rimaste dai giorni scorsi), domani, prima o poi e le ricorrenti. Con day solo quel giorno.",
        properties: ["day": prop("oggi, domani, yyyy-MM-dd, prima o poi (opzionale)")]
    ) { args, ctx in
        if let raw = args["day"] as? String, !raw.isEmpty {
            guard let day = TodoDay.parse(raw) else { throw ToolError("Giorno non valido") }
            let items = await ctx.memory.todos(day: day)
            return items.isEmpty ? "Niente in lista." : items.map(describe).joined(separator: "\n")
        }
        let b = await ctx.memory.todoBoard()
        let done = b.today.filter(\.done).count
        var out = ["Oggi (\(done)/\(b.today.count) fatte):"] + (b.today.isEmpty ? ["- niente"] : b.today.map { "- " + describe($0) })
        if !b.overdue.isEmpty { out += ["Rimaste dai giorni scorsi:"] + b.overdue.map { "- " + describe($0) + " (\($0.day ?? ""))" } }
        if !b.tomorrow.isEmpty { out += ["Domani:"] + b.tomorrow.map { "- " + describe($0) } }
        if !b.someday.isEmpty { out += ["Prima o poi:"] + b.someday.map { "- " + describe($0) } }
        if !b.recurring.isEmpty { out += ["Ricorrenti:"] + b.recurring.map { "- " + describe($0) } }
        return out.joined(separator: "\n")
    }

    static let done = ElioTool(
        name: "todo_done",
        description: """
        Spunta (o toglie la spunta a) una voce della to-do list: per id, o per testo ("ho mandato la mail a Rosario" → \
        query "mail Rosario"). undo: true per rimetterla da fare.
        """,
        properties: ["id": prop("Id della voce", type: "integer"), "query": prop("Parole della voce, se non sai l'id"),
                     "undo": prop("Rimetti da fare", type: "boolean")]
    ) { args, ctx in
        var target: TodoItem?
        if let id = args["id"] as? Int { target = await ctx.memory.todo(id) }
        if target == nil, let q = args["query"] as? String { target = await ctx.memory.findTodos(q).first { $0.done == (args["undo"] as? Bool == true) } }
        guard var t = target else { throw ToolError("Voce non trovata: usa todo_list") }
        let undo = args["undo"] as? Bool == true
        t.done = !undo
        t.doneAt = undo ? nil : Date()
        if t.done { t.focus = false }
        await ctx.memory.updateTodo(t)
        await remind(t, ctx: ctx)
        await publish(ctx)
        let left = await ctx.memory.todoBoard().today.filter { !$0.done }.count
        return undo ? "Rimessa da fare: \(t.text)." : "Fatto: \(t.text). Ne restano \(left) per oggi."
    }

    static let update = ElioTool(
        name: "todo_update",
        description: """
        Modifica una voce: testo, giorno (sposta a domani…), importante, orario, stima, note, focus (la cosa su cui lavora ora), \
        position (ordine: 1 = prima). Per riordinare la giornata chiama più volte con position.
        """,
        properties: [
            "id": prop("Id", type: "integer"), "text": prop("Nuovo testo"), "day": prop("Nuovo giorno"),
            "important": prop("Importante", type: "boolean"), "time": prop("HH:mm, vuoto per toglierlo"),
            "estimate": prop("Minuti", type: "integer"), "notes": prop("Note"), "focus": prop("In corso ora", type: "boolean"),
            "position": prop("Ordine nella giornata", type: "integer"),
        ],
        required: ["id"]
    ) { args, ctx in
        guard let id = args["id"] as? Int, var t = await ctx.memory.todo(id) else { throw ToolError("Voce non trovata") }
        if let s = args["text"] as? String, !s.isEmpty { t.text = s }
        if let raw = args["day"] as? String {
            guard let day = TodoDay.parse(raw) else { throw ToolError("Giorno non valido") }
            t.day = day
        }
        if let b = args["important"] as? Bool { t.priority = b ? 1 : 0 }
        if let s = args["time"] as? String { t.time = s.isEmpty ? nil : s }
        if let n = args["estimate"] as? Int { t.estimate = n }
        if let s = args["notes"] as? String { t.notes = s }
        if let p = args["position"] as? Int { t.position = p }
        await ctx.memory.updateTodo(t)
        if let f = args["focus"] as? Bool { await ctx.memory.setFocus(f ? t.id : nil) }
        if args["time"] != nil || args["day"] != nil { await remind(t, ctx: ctx) }
        await publish(ctx)
        return "Aggiornata: \(describe(t))."
    }

    static let remove = ElioTool(
        name: "todo_remove",
        description: "Toglie una voce dalla to-do list (per una ricorrente toglie anche le sue copie).",
        properties: ["id": prop("Id", type: "integer")],
        required: ["id"]
    ) { args, ctx in
        guard let id = args["id"] as? Int else { throw ToolError("Serve l'id") }
        if let t = await ctx.memory.todo(id) { await unremind(t, ctx: ctx) }
        let ok = await ctx.memory.deleteTodo(id)
        await publish(ctx)
        return ok ? "Tolta." : "Non trovata."
    }

    static let carryOver = ElioTool(
        name: "todo_carry_over",
        description: "Porta a oggi le voci non finite dei giorni scorsi.",
        properties: [:]
    ) { _, ctx in
        let n = await ctx.memory.carryOverTodos()
        await publish(ctx)
        return n == 0 ? "Niente da riportare." : "Ho portato a oggi \(n) voci rimaste indietro."
    }

    /// For the dashboard: the whole board as JSON, plus quick actions without going through Claude.
    static let board = ElioTool(
        name: "todo_board",
        description: "Uso interno dell'app: la to-do list in JSON; action toggle/add/remove/focus/tomorrow/today/important/carry.",
        properties: ["action": prop("Azione (opzionale)"), "id": prop("Id", type: "integer"), "text": prop("Testo per add")]
    ) { args, ctx in
        try await quickAction(args, ctx: ctx)
        return await ctx.memory.todoBoard().jsonString()
    }

    /// The one-tap actions of the dashboard and the phone.
    public static func quickAction(_ args: [String: Any], ctx: ToolContext) async throws {
        guard let action = args["action"] as? String else { return }
        let id = (args["id"] as? Int) ?? Int(args["id"] as? String ?? "")
        let today = TodoDay.key()
        switch action {
        case "add":
            // "!" in front = important; "@domani" / "@prima o poi" picks the day; "18:30" at the end sets a time.
            var text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            var priority = 0
            if text.hasPrefix("!") { priority = 1; text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            var day: String? = today
            if let r = text.range(of: #"@(oggi|domani|dopodomani|prima o poi|\w+)"#, options: .regularExpression) {
                if let parsed = TodoDay.parse(String(text[r].dropFirst())) { day = parsed; text.removeSubrange(r) }
            }
            var time: String?
            if let r = text.range(of: #"\b([01]?\d|2[0-3])[:.][0-5]\d\s*$"#, options: .regularExpression) {
                time = text[r].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ":")
                text.removeSubrange(r)
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            var t = TodoItem(text: text, day: day, priority: priority, time: time)
            t.id = await ctx.memory.addTodo(t)
            await remind(t, ctx: ctx)
        case "carry":
            _ = await ctx.memory.carryOverTodos()
        default:
            guard let id, var t = await ctx.memory.todo(id) else { return }
            switch action {
            case "toggle":
                t.done.toggle(); t.doneAt = t.done ? Date() : nil
                if t.done { t.focus = false }
            case "important": t.priority = t.priority > 0 ? 0 : 1
            case "tomorrow": t.day = TodoDay.key(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
            case "today": t.day = today
            case "someday": t.day = nil
            case "remove":
                await unremind(t, ctx: ctx)
                _ = await ctx.memory.deleteTodo(id)
                await publish(ctx)
                return
            case "focus":
                await ctx.memory.setFocus(t.focus ? nil : t.id)
                await publish(ctx)
                return
            case "up", "down":
                // Swap with the neighbour in the same day.
                let list = await ctx.memory.todos(day: t.day).filter { $0.done == t.done && $0.priority == t.priority }
                guard let i = list.firstIndex(where: { $0.id == t.id }) else { return }
                let j = action == "up" ? i - 1 : i + 1
                guard list.indices.contains(j) else { return }
                var other = list[j]
                // Positions may be equal (old rows): renumber the whole day first.
                for (k, var item) in list.enumerated() where item.position != k { item.position = k; await ctx.memory.updateTodo(item) }
                t.position = j; other.position = i
                await ctx.memory.updateTodo(other)
            default: return
            }
            await ctx.memory.updateTodo(t)
            if ["toggle", "tomorrow", "today", "someday"].contains(action) { await remind(t, ctx: ctx) }
        }
        await publish(ctx)
    }
}
