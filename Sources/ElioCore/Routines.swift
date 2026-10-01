import Foundation

/// Proactive behaviour: morning brief, meeting prep, overnight recap.
public actor Routines {
    private let config: ElioConfig
    private let memory: Memory
    private weak var brain: Brain?
    private var announcedMeetings: Set<String> = []
    private var loop: Task<Void, Never>?
    private var unlockObserver: NSObjectProtocol?

    public init(config: ElioConfig, memory: Memory) {
        self.config = config
        self.memory = memory
    }

    public func start(brain: Brain) {
        self.brain = brain
        // First unlock of the day ≈ "I've arrived at work".
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.maybeBrief(trigger: .unlock) }
        }
        loop = Task {
            while !Task.isCancelled {
                await self.maybeBrief(trigger: .clock)
                await self.maybeRecap()
                await self.watchMeetings()
                await self.watchMissedMeetings()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    enum Trigger { case unlock, clock, manual }

    // MARK: - Morning brief

    func maybeBrief(trigger: Trigger) async {
        let now = Date()
        let cal = Calendar.current
        let today = Self.dayKey(now)
        guard await memory.get("routine.brief.last") != today else { return }
        let weekday = cal.component(.weekday, from: now)
        guard (2...6).contains(weekday) else { return }  // Mon–Fri
        guard let earliest = Self.time(config.briefEarliest, on: now),
              let latest = Self.time(config.briefLatest, on: now) else { return }
        switch trigger {
        case .unlock: guard now >= earliest else { return }
        case .clock: guard now >= latest, now < latest.addingTimeInterval(3 * 3600) else { return }
        case .manual: break
        }
        await memory.set("routine.brief.last", today)
        await runBrief()
    }

    public func runBrief() async {
        // The app plays the opening theme while Claude prepares the brief.
        await brain?.publish(ServerMessage(type: .event, kind: "briefStart"))
        await brain?.runRoutine(kind: "brief", prompt: """
        [routine: briefing] Raffaele ha appena iniziato la giornata. L'app lo ha GIÀ salutato e gli ha detto che gli fai \
        un riassunto: non salutare, non dire "ecco il briefing", entra subito nel contenuto.
        Racconta MENTRE raccogli, una sezione alla volta: chiama uno strumento e subito dopo dì in una frase cosa hai \
        trovato, poi passa al successivo. Ordine: calendar_events di oggi → list_reminders → night_recap e list_tasks → \
        slack_mentions e slack_dms delle ultime 16 ore (se Slack non è collegato, salta). Frasi brevi e parlate, \
        niente elenchi né markdown nel testo. Al massimo sei frasi in tutto.
        Alla fine mostra il dettaglio con show_on_screen (titolo "Briefing di oggi": agenda con orari, promemoria, \
        lavori notturni e branch da revisionare, menzioni e DM importanti) e chiama slack_clock_in.
        """)
    }

    // MARK: - Day recap

    func maybeRecap() async {
        guard !config.recapTime.isEmpty, let at = Self.time(config.recapTime, on: Date()) else { return }
        let now = Date()
        guard (2...6).contains(Calendar.current.component(.weekday, from: now)),
              now >= at, now < at.addingTimeInterval(3600),
              await memory.get("routine.recap.last") != Self.dayKey(now) else { return }
        await runRecap()
    }

    public func runRecap() async {
        await memory.set("routine.recap.last", Self.dayKey(Date()))
        await brain?.publish(ServerMessage(type: .event, kind: "recapStart"))
        await brain?.runRoutine(kind: "recap", prompt: """
        [routine: recap] Raffaele chiude la giornata. L'app lo ha GIÀ salutato e gli ha detto che gli fai il riassunto: \
        non salutare, entra subito nel contenuto. Racconta MENTRE raccogli, una frase dopo ogni strumento: \
        day_summary → calendar_events di oggi e di domani → slack_mentions e slack_dms di oggi (se c'è Slack) → list_tasks. \
        Frasi brevi e parlate, al massimo cinque in tutto: fatto, in sospeso, primo impegno di domani.
        Alla fine show_on_screen (titolo "Recap di oggi": fatto, in sospeso, domani).
        """)
    }

    // MARK: - Missed meetings

    private var nudged: Set<String> = []

    /// A Meet started 3 minutes ago and Raffaele seems not to be in it (away from the Mac,
    /// or no Meet tab open in Chrome): nudge him, on the phone too when away.
    func watchMissedMeetings() async {
        guard config.nudgeMissedMeetings, CalendarTools.isAuthorized else { return }
        let now = Date()
        guard let events = try? await CalendarTools.events(from: now.addingTimeInterval(-600), to: now) else { return }
        for e in events where !e.allDay && e.meetURL != nil {
            let late = now.timeIntervalSince(e.start)
            let key = "\(e.title)|\(e.start.timeIntervalSince1970)"
            guard late >= 180, late < 600, e.end > now, !nudged.contains(key) else { continue }
            let away = PhoneNotifier.idleSeconds > 120
            let code = e.meetURL?.lastPathComponent ?? ""
            let tabOpen = Self.chromeHasTab(containing: code)
            guard away || !tabOpen else { continue }
            nudged.insert(key)
            await brain?.announce(kind: "nudge", text: "\(config.addressAs), il meeting \(e.title) è iniziato da \(Int(late / 60)) minuti.")
        }
    }

    static func chromeHasTab(containing code: String) -> Bool {
        guard !code.isEmpty, NSRunningApplicationIsChromeRunning() else { return false }
        let script = "tell application \"Google Chrome\" to get URL of tabs of windows"
        let out = (try? shell("/usr/bin/osascript", ["-e", script])) ?? ""
        return out.contains(code)
    }

    // MARK: - Meetings

    func watchMeetings() async {
        let lead = TimeInterval(config.meetingLeadMinutes * 60)
        guard lead > 0, CalendarTools.isAuthorized else { return }
        let now = Date()
        guard let events = try? await CalendarTools.events(from: now, to: now.addingTimeInterval(lead + 60)) else { return }
        for e in events where !e.allDay && e.meetURL != nil {
            let key = "\(e.title)|\(e.start.timeIntervalSince1970)"
            guard !announcedMeetings.contains(key), e.start.timeIntervalSince(now) <= lead + 30 else { continue }
            announcedMeetings.insert(key)
            if let url = e.meetURL { try? MeetingTools.open(url) }
            let minutes = max(1, Int((e.start.timeIntervalSince(now) / 60).rounded()))
            await brain?.announce(kind: "meeting",
                                  text: "Tra \(minutes == 1 ? "un minuto" : "\(minutes) minuti") hai \(e.title). Ti ho aperto il Meet, devi solo entrare.")
        }
        if announcedMeetings.count > 200 { announcedMeetings.removeAll() }
    }

    // MARK: - Helpers

    public static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func time(_ hhmm: String, on day: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
}

public enum RoutineTools {
    static let brief = ElioTool(
        name: "night_recap",
        description: "Lavori in background terminati dalle 18 di ieri (stanotte) e task programmati ancora da eseguire. Usalo per il recap del mattino."
    ) { _, ctx in
        let cal = Calendar.current
        let since = cal.date(bySettingHour: 18, minute: 0, second: 0,
                             of: cal.date(byAdding: .day, value: -1, to: Date())!)!
        let done = await ctx.memory.tasksEnded(since: since)
        let pending = await ctx.memory.scheduledTasks(dueBefore: nil)
        var lines: [String] = []
        lines.append(done.isEmpty ? "Nessun lavoro completato stanotte." : "Lavori completati:")
        for t in done {
            lines.append("- [\(t.status.rawValue)] \(t.title) (\(t.project ?? "")): \(t.summary.map { String($0.prefix(400)) } ?? "")")
        }
        if !pending.isEmpty {
            lines.append("Programmati:")
            for p in pending { lines.append("- \(p.title) alle \(p.at)") }
        }
        return lines.joined(separator: "\n")
    }
}

func NSRunningApplicationIsChromeRunning() -> Bool {
    let out = (try? shell("/usr/bin/pgrep", ["-x", "Google Chrome"])) ?? ""
    return !out.isEmpty
}

public enum RoutineControl {
    static let run = ElioTool(
        name: "run_routine",
        description: "Avvia il briefing del mattino (brief) o il recap della giornata (recap) con la sua presentazione. Rispondi solo con una frase di riscontro: il contenuto lo dice la routine.",
        properties: ["which": prop("brief oppure recap")],
        required: ["which"]
    ) { args, ctx in
        let which = args["which"] as? String ?? "brief"
        ctx.broadcast(ServerMessage(type: .event, kind: "runRoutine", payload: "{\"which\":\"\(which)\"}"))
        await ctx.startRoutine(which)
        return "Avviato: parte appena finisci questa risposta."
    }
}

public enum DayTools {
    static let summary = ElioTool(
        name: "day_summary",
        description: "Cosa è successo oggi: lavori degli agenti conclusi, promemoria scattati, numero di richieste fatte all'assistente."
    ) { _, ctx in
        let start = Calendar.current.startOfDay(for: Date())
        let tasks = await ctx.memory.tasksEnded(since: start)
        let reminders = await ctx.memory.remindersFired(since: start)
        let messages = await ctx.memory.recentMessages(limit: 400).filter { $0.ts >= start && $0.role == "user" }
        var lines = ["Richieste di oggi: \(messages.count)."]
        lines.append(tasks.isEmpty ? "Nessun lavoro degli agenti concluso oggi." : "Lavori conclusi:")
        for t in tasks { lines.append("- [\(t.status.rawValue)] \(t.title) (\(t.project ?? "")): \(t.summary.map { String($0.prefix(300)) } ?? "")") }
        if !reminders.isEmpty { lines.append("Promemoria di oggi: " + reminders.joined(separator: "; ")) }
        let topics = messages.suffix(30).map { "- " + String($0.text.prefix(100)) }
        if !topics.isEmpty { lines.append("Ultime richieste:\n" + topics.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }
}
