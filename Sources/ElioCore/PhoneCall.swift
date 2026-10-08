import Foundation

/// A real phone call from Elio: a PushKit VoIP push makes the native iPhone app ring through CallKit.
public struct PhoneCall: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ringing, answered, declined, ended, missed }

    public var id: String
    /// Why it rings (the alert title: "Fine pausa", "Monitor"…).
    public var title: String
    /// What Elio says when the user answers.
    public var text: String
    public var startedAt: Date
    public var status: Status
    /// 1 for the first ring, 2 for the retry.
    public var attempt: Int
    /// The user asked for it on the phone explicitly: rings even in the quiet hours.
    public var phone: Bool
}

/// Rings the native app, follows the call (answered, declined, ended, unanswered) and falls back to an urgent
/// push + inbox message when nobody picks up. One retry after two minutes if the first ring goes unanswered.
public actor PhoneCalls {
    public static let shared = PhoneCalls()

    public static let answerTimeout: TimeInterval = 45
    public static let retryDelay: TimeInterval = 120

    /// Sends the VoIP push; returns how many devices Apple accepted it for.
    typealias Ringer = @Sendable (PhoneCall) async -> Int
    /// Nobody answered (or they declined): urgent notification + message in the inbox.
    typealias Fallback = @Sendable (PhoneCall) async -> Void

    private var calls: [String: PhoneCall] = [:]
    private let ring: Ringer
    private let fallback: Fallback
    private let canRing: @Sendable () -> Bool
    private let timeout: TimeInterval
    private let retry: TimeInterval

    init(ring: Ringer? = nil, fallback: Fallback? = nil, canRing: (@Sendable () -> Bool)? = nil,
         timeout: TimeInterval = PhoneCalls.answerTimeout, retry: TimeInterval = PhoneCalls.retryDelay) {
        self.ring = ring ?? { call in
            await APNs.shared.sendCall(id: call.id, title: ElioConfig.load().assistantName, text: call.text, reason: call.title)
        }
        self.fallback = fallback ?? { call in await PhoneCalls.defaultFallback(call) }
        self.canRing = canRing ?? { APNs.shared.canCall }
        self.timeout = timeout
        self.retry = retry
    }

    /// No calls in the quiet hours unless the user explicitly asked for it on the phone.
    public static func mayRing(at date: Date = Date(), phone: Bool, quietStart: String, quietEnd: String,
                               calendar: Calendar = .current) -> Bool {
        phone || !IdlePolicy.inQuietHours(date, start: quietStart, end: quietEnd, calendar: calendar)
    }

    /// Rings the phone app. Nil when there's no app that can ring, it's quiet hours, or Apple refused:
    /// the caller then falls back to plain notifications.
    @discardableResult
    public func start(text: String, title: String, phone: Bool = false, at date: Date = Date()) async -> PhoneCall? {
        guard canRing() else { return nil }
        let cfg = ElioConfig.load()
        guard Self.mayRing(at: date, phone: phone, quietStart: cfg.quietStart, quietEnd: cfg.quietEnd) else { return nil }
        let call = PhoneCall(id: Self.newId(), title: title, text: text, startedAt: date, status: .ringing, attempt: 1, phone: phone)
        return await dial(call) ? calls[call.id] : nil
    }

    public func call(_ id: String) -> PhoneCall? { calls[id] }

    /// The user picked up on the phone: stop every other ringing (Mac included).
    public func answer(_ id: String) async -> PhoneCall? {
        guard var call = calls[id] else { return nil }
        call.status = .answered
        calls[id] = call
        await Alerts.shared.acknowledge()
        await Alerts.shared.emit(ServerMessage(type: .event, text: call.text, lang: .it, kind: "callAnswered",
                                               payload: call.jsonString(), speak: false))
        return call
    }

    /// Declined: no more rings, but it must not get lost.
    public func decline(_ id: String) async -> PhoneCall? {
        guard var call = calls[id], call.status == .ringing || call.status == .answered else { return calls[id] }
        call.status = .declined
        calls[id] = call
        await Alerts.shared.acknowledge()
        await fallback(call)
        return call
    }

    public func end(_ id: String) -> PhoneCall? {
        guard var call = calls[id] else { return nil }
        if call.status != .declined && call.status != .missed { call.status = .ended }
        calls[id] = call
        return call
    }

    private func dial(_ call: PhoneCall) async -> Bool {
        calls[call.id] = call
        prune()
        guard await ring(call) > 0 else {
            calls[call.id]?.status = .missed
            return false
        }
        let timeout = self.timeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.unanswered(call.id)
        }
        return true
    }

    /// 45 s without an answer: retry once two minutes later (unless the user reacted meanwhile), then give up.
    func unanswered(_ id: String) async {
        guard var call = calls[id], call.status == .ringing else { return }
        call.status = .missed
        calls[id] = call
        guard call.attempt == 1 else { return await fallback(call) }
        let retry = self.retry
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(retry))
            await self?.redial(call)
        }
    }

    private func redial(_ missed: PhoneCall) async {
        let acked = await Alerts.shared.lastAcknowledged > missed.startedAt
        let back = PhoneNotifier.idleSeconds < Date().timeIntervalSince(missed.startedAt) - 5
        if acked || back { return }
        // Another call is ringing or in progress (a newer alert, a test): a retry now would land on top of it.
        if calls.values.contains(where: { $0.id != missed.id && ($0.status == .ringing || $0.status == .answered) }) { return }
        let cfg = ElioConfig.load()
        guard canRing(), Self.mayRing(phone: missed.phone, quietStart: cfg.quietStart, quietEnd: cfg.quietEnd) else {
            return await fallback(missed)
        }
        let call = PhoneCall(id: Self.newId(), title: missed.title, text: missed.text, startedAt: Date(),
                             status: .ringing, attempt: 2, phone: missed.phone)
        if !(await dial(call)) { await fallback(call) }
    }

    private func prune() {
        let old = Date().addingTimeInterval(-24 * 3600)
        calls = calls.filter { $0.value.startedAt > old }
    }

    static func newId() -> String { UUID().uuidString.lowercased() }

    static func defaultFallback(_ call: PhoneCall) async {
        await MessageBox.shared.add(title: call.title, text: call.text, source: "call")
        PhonePush.send(title: call.status == .declined ? call.title : "\(call.title) (chiamata persa)",
                       body: String(call.text.prefix(400)), tag: "call-\(call.id.prefix(6))", urgency: "high")
    }
}

// MARK: - Tool

public enum CallTools {
    static let call = ElioTool(
        name: "call_user",
        description: """
        Chiama l'utente adesso: squilla il Mac e, se c'è l'app iPhone, il telefono squilla come una vera chiamata \
        (risponde e senti il testo). Per "chiamami", "chiamami quando…" già scattato. Per "chiamami tra 10 minuti" o \
        "quando finisce…" crea invece un monitor con urgency call. Nelle ore di silenzio non chiama il telefono, a meno \
        che l'utente abbia chiesto esplicitamente di chiamarlo anche di notte (phone = true).
        """,
        properties: ["text": prop("Cosa dirgli quando risponde"), "reason": prop("Motivo in poche parole (es. Fine pausa)"),
                     "phone": prop("Chiama il telefono anche nelle ore di silenzio", type: "boolean")],
        required: ["text"]
    ) { args, _ in
        let reason = (args["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Elio"
        await Alerts.shared.send(args["text"] as? String ?? "", title: reason, urgency: .call, source: "elio",
                                 phone: args["phone"] as? Bool ?? false)
        return "Chiamata avviata (\(reason))."
    }
}
