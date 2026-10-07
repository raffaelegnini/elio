import Foundation

/// How loudly Elio tells the user something.
/// - message: not urgent — goes to the Messages inbox on the phone, to read or listen to later.
/// - notify: said on the Mac (or the phone, wherever the user is); pushed to the phone if they're away
///   or don't react within a couple of minutes.
/// - call: something they asked to be called for (the meeting break is over): the Mac rings and speaks,
///   the iPhone app rings like a phone call (PhoneCalls), or the phone gets urgent pushes until they're back.
public enum Urgency: String, Codable, Sendable, CaseIterable {
    case message, notify, call
}

/// A low-priority message in the phone's inbox. The audio is synthesized on demand by the phone (/tts).
public struct InboxMessage: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    public var source: String?
    public var date: Date
    public var read = false
}

/// The Messages inbox, kept in Application Support (last 200).
public actor MessageBox {
    public static let shared = MessageBox()
    static let file = ElioPaths.support.appendingPathComponent("messages.json")
    private var items: [InboxMessage]

    init() {
        items = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder.iso.decode([InboxMessage].self, from: $0) } ?? []
    }

    public func all() -> [InboxMessage] { items }
    public var unread: Int { items.filter { !$0.read }.count }

    @discardableResult
    public func add(title: String, text: String, source: String?) -> InboxMessage {
        let m = InboxMessage(id: String(UUID().uuidString.prefix(8)).lowercased(), title: title, text: text,
                             source: source, date: Date())
        items.insert(m, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        save()
        return m
    }

    /// action: read, unread, delete, readAll, clearRead.
    public func apply(action: String, id: String?) {
        switch action {
        case "read": if let i = items.firstIndex(where: { $0.id == id }) { items[i].read = true }
        case "unread": if let i = items.firstIndex(where: { $0.id == id }) { items[i].read = false }
        case "delete": items.removeAll { $0.id == id }
        case "readAll": for i in items.indices { items[i].read = true }
        case "clearRead": items.removeAll(where: \.read)
        default: return
        }
        save()
    }

    private func save() {
        try? JSONEncoder.iso.encode(items).write(to: Self.file, options: .atomic)
    }
}

/// One entry point for everything Elio has to tell the user on its own (monitors, agents, reminders
/// that asked for it): picks the channel from the urgency. Escalation to the phone when the user is at
/// the Mac but not reacting lives in PhoneNotifier, which sees every spoken event.
public actor Alerts {
    public static let shared = Alerts()
    private var broadcast: (@Sendable (ServerMessage) -> Void)?
    /// Last time the phone acknowledged a call (opened the app / tapped the notification).
    private var lastAck = Date.distantPast

    public func start(broadcast: @escaping @Sendable (ServerMessage) -> Void) {
        self.broadcast = broadcast
    }

    /// The phone saw it: stop ringing.
    public func acknowledge() { lastAck = Date() }
    public var lastAcknowledged: Date { lastAck }

    /// Events from outside the alert paths (a call answered on the phone).
    public func emit(_ message: ServerMessage) { broadcast?(message) }

    /// `phone`: the user asked to get it on the phone, whatever they're doing.
    public func send(_ text: String, title: String, urgency: Urgency, source: String? = nil, phone: Bool = false) async {
        let clean = String(SecretFilter.redact(text).prefix(2000))
        switch urgency {
        case .message:
            let m = await MessageBox.shared.add(title: title, text: clean, source: source)
            broadcast?(ServerMessage(type: .event, text: title, lang: .it, kind: "message", payload: m.jsonString(), speak: false))
            let n = await MessageBox.shared.unread
            // One quiet notification that gets replaced, not one per message.
            PhonePush.send(title: n > 1 ? "\(n) messaggi da Elio" : "Messaggio da Elio", body: title,
                           tag: "messages", urgency: "low", badge: n)
        case .notify:
            broadcast?(ServerMessage(type: .event, text: clean, lang: .it, kind: "watch", speak: true))
            if phone { PhonePush.send(title: title, body: String(clean.prefix(400)), tag: "watch-\(UUID().uuidString.prefix(6))") }
        case .call:
            let started = Date()
            broadcast?(ServerMessage(type: .event, text: clean, lang: .it, kind: "alarm", speak: true))
            let tag = "call-\(UUID().uuidString.prefix(6))"
            // The native iPhone app rings for real (CallKit): no repeated pushes then.
            // Quiet hours (unless `phone`) or no app that can ring: urgent notifications as before.
            if await PhoneCalls.shared.start(text: clean, title: title, phone: phone, at: started) != nil { return }
            // Rings on the phone too, right away, then again while nobody reacts (Mac untouched, phone not opened).
            Task {
                for attempt in 0..<4 {
                    if attempt > 0 {
                        try? await Task.sleep(for: .seconds(60))
                        let back = PhoneNotifier.idleSeconds < Date().timeIntervalSince(started) - 5
                        let acked = await self.lastAck > started
                        if back || acked { return }
                    }
                    PhonePush.send(title: attempt == 0 ? title : "\(title) (ancora)", body: String(clean.prefix(400)),
                                   tag: tag, urgency: "high")
                }
            }
        }
    }
}

// MARK: - Tools

public enum AlertTools {
    static let message = ElioTool(
        name: "message_send",
        description: """
        Lascia un messaggio nella casella Messaggi dell'app sul telefono, da leggere o ascoltare (audio) con calma più \
        tardi. Per cose poco importanti che non meritano di interrompere: riassunti, esiti non urgenti, "quando hai un \
        momento". Scrivi il testo come lo diresti a voce: verrà anche letto ad alta voce. Non parla sul Mac.
        """,
        properties: ["title": prop("Titolo breve (5-8 parole)"), "text": prop("Il messaggio, discorsivo")],
        required: ["title", "text"]
    ) { args, _ in
        let title = args["title"] as? String ?? "Messaggio"
        await Alerts.shared.send(args["text"] as? String ?? "", title: title, urgency: .message, source: "elio")
        return "Messaggio lasciato nella casella: \(title)."
    }

    static let notify = ElioTool(
        name: "notify_user",
        description: """
        Avvisa l'utente adesso. urgency: notify (lo dici sul Mac, o sul telefono se è via o non risponde entro due \
        minuti), call (squilla sul Mac e chiama l'app iPhone, o notifica urgente ripetuta sul telefono finché non risponde: \
        solo se ha chiesto "chiamami"/"avvisami subito"), message (casella Messaggi, da sentire dopo). phone = true se ha chiesto di riceverlo \
        sul telefono.
        """,
        properties: ["text": prop("Cosa dire"), "title": prop("Titolo breve della notifica"),
                     "urgency": prop("message, notify o call"), "phone": prop("Anche sul telefono", type: "boolean")],
        required: ["text"]
    ) { args, _ in
        let urgency = Urgency(rawValue: args["urgency"] as? String ?? "") ?? .notify
        await Alerts.shared.send(args["text"] as? String ?? "", title: args["title"] as? String ?? "Elio", urgency: urgency,
                                 source: "elio", phone: args["phone"] as? Bool ?? false)
        return "Avviso inviato (\(urgency.rawValue))."
    }
}
