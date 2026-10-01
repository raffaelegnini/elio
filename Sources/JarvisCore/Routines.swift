import Foundation

/// Proactive behaviour: morning brief, meeting prep, overnight recap.
public actor Routines {
    private let config: JarvisConfig
    private let memory: Memory
    private weak var brain: Brain?
    private var announcedMeetings: Set<String> = []
    private var loop: Task<Void, Never>?
    private var unlockObserver: NSObjectProtocol?

    public init(config: JarvisConfig, memory: Memory) {
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
                await self.watchMeetings()
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
        await brain?.runRoutine(kind: "brief", prompt: """
        [routine: briefing del mattino] Raffaele ha appena iniziato la giornata lavorativa. Prepara il briefing:
        1. calendar_events per oggi; 2. list_reminders; 3. night_recap per i lavori fatti stanotte; 4. list_tasks.
        Poi mostra il dettaglio con show_on_screen (titolo "Briefing di oggi": agenda completa con orari, promemoria, \
        esito dei lavori notturni con i branch da revisionare).
        A voce: saluto breve, quanti meeting e qual è il primo, cose da ricordare, esito dei lavori notturni. Massimo cinque frasi.
        Ricordagli il clock in su Slack (scrivere "buongiorno" nel canale): non è ancora integrato, quindi suggeriscilo soltanto.
        """)
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

    static func dayKey(_ d: Date) -> String {
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
    static let brief = JarvisTool(
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
