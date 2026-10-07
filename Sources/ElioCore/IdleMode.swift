import Foundation

/// Rest mode ("modalità riposo"): the Mac stays awake for background work with the screen off or dim, and
/// Elio keeps quiet. What may still wake it up, and what it tells the user when they're back, is decided
/// here (pure logic, so it can be tested); the app does the waking, the daemon pushes to the phone.
public enum IdlePolicy {
    public enum Decision: Equatable, Sendable {
        /// Wake the screen, ring and say it: something the user must know now and it's not the middle of the night.
        case wake
        /// Not said aloud: shown, pushed to the phone (PhoneNotifier treats rest as away), kept for the return summary.
        case hold
        /// Nothing worth holding (live data, tool activity, state updates).
        case ignore
    }

    /// Kinds that justify waking the Mac outside the quiet hours: a "call me" alarm, a broken workflow, an agent
    /// blocked on a confirmation or a question.
    static let urgent: Set<String> = ["alarm", "workflowAlert", "confirm", "question"]
    /// Silent kinds still worth mentioning on return.
    static let notable: Set<String> = ["message", "alarm", "confirm", "question", "workflowAlert", "taskDone", "squadDone",
                                       "watch", "reminder", "timer", "meeting"]

    /// Minutes after midnight of "HH:mm" (nil if malformed).
    public static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Whether `date` falls in [start, end), which may span midnight (23:00–07:30). Equal or malformed bounds: never.
    public static func inQuietHours(_ date: Date, start: String, end: String, calendar: Calendar = .current) -> Bool {
        guard let s = minutes(start), let e = minutes(end), s != e else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }

    /// What to do with an event that arrives while the Mac is at rest.
    public static func decide(kind: String?, speak: Bool, at date: Date, quietStart: String, quietEnd: String,
                              calendar: Calendar = .current) -> Decision {
        guard let kind else { return .ignore }
        if urgent.contains(kind) {
            // Not spoken means the daemon sent it to the phone, where the user is talking from: no need to ring here.
            return speak && !inQuietHours(date, start: quietStart, end: quietEnd, calendar: calendar) ? .wake : .hold
        }
        return speak || notable.contains(kind) ? .hold : .ignore
    }

    public static func decide(_ message: ServerMessage, at date: Date = Date(), config: ElioConfig) -> Decision {
        guard message.type == .event else { return .ignore }
        return decide(kind: message.kind, speak: message.speak == true, at: date,
                      quietStart: config.quietStart, quietEnd: config.quietEnd)
    }
}

/// The one line Elio says when the user comes back, built from what happened while the Mac was at rest.
public enum IdleSummary {
    public struct Event: Sendable, Equatable {
        public var kind: String
        public var text: String
        public init(kind: String, text: String) { self.kind = kind; self.text = text }
    }

    /// Nil when nothing happened: then Elio says nothing at all.
    public static func line(_ events: [Event], addressAs: String) -> String? {
        guard !events.isEmpty else { return nil }
        let hello = "Bentornato, \(addressAs)"
        if events.count == 1, let only = events.first {
            let text = only.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 160 {
                let lead = switch group(only.kind) {
                case "message": "Mentre era via le ho lasciato un messaggio"
                case "confirm": "C'è una richiesta che aspetta lei"
                default: "Mentre era via"
                }
                return "\(hello). \(lead): \(text)\(".!?…".contains(text.last!) ? "" : ".")"
            }
        }
        var counts: [String: Int] = [:]
        for e in events { counts[group(e.kind), default: 0] += 1 }
        let order = ["alarm", "workflowAlert", "confirm", "message", "watch", "taskDone", "reminder", "other"]
        let parts = order.compactMap { g in counts[g].map { phrase(g, $0) } }
        return "\(hello): \(join(parts))."
    }

    static func group(_ kind: String) -> String {
        switch kind {
        case "alarm": "alarm"
        case "workflowAlert": "workflowAlert"
        case "confirm", "question": "confirm"
        case "message": "message"
        case "watch": "watch"
        case "taskDone", "squadDone": "taskDone"
        case "reminder", "timer", "meeting": "reminder"
        default: "other"
        }
    }

    static func phrase(_ group: String, _ n: Int) -> String {
        let k = number(n)
        switch group {
        case "alarm": return n == 1 ? "un avviso urgente" : "\(k) avvisi urgenti"
        case "workflowAlert": return n == 1 ? "un problema in un workflow" : "\(k) problemi nei workflow"
        case "confirm": return n == 1 ? "una richiesta che aspetta lei" : "\(k) richieste che aspettano lei"
        case "message": return n == 1 ? "un messaggio nella casella" : "\(k) messaggi nella casella"
        case "watch": return n == 1 ? "un monitor è scattato" : "\(k) avvisi dai monitor"
        case "taskDone": return n == 1 ? "un lavoro finito" : "\(k) lavori finiti"
        case "reminder": return n == 1 ? "un promemoria" : "\(k) promemoria"
        default: return n == 1 ? "un altro avviso" : "\(k) altri avvisi"
        }
    }

    static func number(_ n: Int) -> String {
        let words = ["zero", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci"]
        return n < words.count ? words[n] : String(n)
    }

    static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " e " + parts.last!
    }
}

// MARK: - Tool

public enum IdleTools {
    static let mode = ElioTool(
        name: "idle_mode",
        description: """
        Modalità riposo del Mac: on = schermo spento (o al minimo), Mac sveglio per il lavoro in background, tu non parli \
        ad alta voce (avvisi sul telefono; solo le cose urgenti fuori dalle ore di silenzio lo svegliano). off = esci dal \
        riposo. Per "mettiti a riposo", "vado via", "spegni lo schermo ma resta sveglio". Senza on restituisce lo stato.
        """,
        properties: ["on": prop("true per entrare in riposo, false per uscire (opzionale)", type: "boolean")]
    ) { args, ctx in
        let raw = args["on"]
        let on: Bool? = (raw as? Bool) ?? (raw as? String).map { ["true", "on", "sì", "si", "1"].contains($0.lowercased()) }
        guard let on else { return Presence.idle ? "Il Mac è a riposo." : "Il Mac non è a riposo." }
        // The app does the switching (screen, assertion, voice) and then reports the new state.
        ctx.broadcast(ServerMessage(type: .event, text: on ? "on" : "off", kind: "idleRequest"))
        return on ? "Metto il Mac a riposo tra qualche secondo: schermo spento, resto sveglio e lavoro in silenzio."
                  : "Esco dal riposo."
    }
}
