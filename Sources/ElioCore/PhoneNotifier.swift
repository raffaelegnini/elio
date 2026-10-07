import CoreGraphics
import Foundation

/// Sends Elio's spoken events to the phone (Web Push to the PWA, ntfy as a fallback) when the user is away
/// from the Mac (screen locked or idle for 5 minutes). If they're at the Mac but don't react to something
/// that needs them (a confirmation, a question, a monitor) within two minutes, it goes to the phone too.
public final class PhoneNotifier: @unchecked Sendable {
    private let topic: String
    private let lock = NSLock()
    private var screenLocked = false
    private var observers: [NSObjectProtocol] = []
    static let kinds: Set<String> = ["reminder", "taskDone", "confirm", "question", "meeting", "brief", "timer", "nudge", "watch",
                                         "workflowAlert", "squadDone"]

    public init(topic: String) {
        self.topic = topic
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.screenLocked = true }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.screenLocked = false }
        })
    }

    public static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    public var isAway: Bool {
        // Rest mode means the user is away, whatever the idle timer says: push right away.
        lock.withLock { screenLocked } || Self.idleSeconds > 300 || Presence.idle
    }

    /// Kinds worth chasing the user for when they're at the Mac but not reacting.
    static let escalated: Set<String> = ["confirm", "question", "watch", "reminder", "timer", "meeting", "workflowAlert"]
    static let escalateAfter: TimeInterval = 120

    public func handle(_ message: ServerMessage) {
        guard message.type == .event, message.speak == true, let kind = message.kind,
              Self.kinds.contains(kind), let text = message.text else { return }
        if isAway {
            push(kind: kind, text: text)
        } else if Self.escalated.contains(kind) {
            // At the Mac: wait, and push only if nobody touched keyboard or mouse, or answered by voice, since.
            let sent = Date()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.escalateAfter) { [weak self] in
                guard Self.idleSeconds >= Self.escalateAfter - 5, Presence.lastRequest < sent else { return }
                self?.push(kind: kind, text: text)
            }
        }
    }

    private func push(kind: String, text: String) {
        let title: String = switch kind {
        case "confirm": "Serve una conferma"
        case "question": "Una domanda per te"
        case "taskDone": "Task completato"
        case "reminder": "Promemoria"
        case "meeting": "Meeting"
        case "brief": "Briefing"
        case "watch": "Monitor"
        case "workflowAlert": "Problema in un workflow"
        case "squadDone": "Squadra al traguardo"
        default: "Elio"
        }
        // The phone app itself (Web Push); ntfy stays as a fallback channel.
        WebPush.shared.send(title: title, body: String(SecretFilter.redact(text).prefix(400)), tag: kind)
        guard !topic.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://ntfy.sh/\(topic)")!)
        req.httpMethod = "POST"
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue(kind == "confirm" ? "high" : "default", forHTTPHeaderField: "Priority")
        req.setValue("robot", forHTTPHeaderField: "Tags")
        req.httpBody = Data(String(SecretFilter.redact(text).prefix(400)).utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
}
