import CoreGraphics
import Foundation

/// Sends Elio's spoken events to the phone through ntfy (ntfy.sh, app on iPhone)
/// — only when Raffaele is away from the Mac (screen locked or idle), to avoid duplicates.
public final class PhoneNotifier: @unchecked Sendable {
    private let topic: String
    private let lock = NSLock()
    private var screenLocked = false
    private var observers: [NSObjectProtocol] = []
    static let kinds: Set<String> = ["reminder", "taskDone", "confirm", "question", "meeting", "brief", "timer", "nudge", "watch"]

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
        lock.withLock { screenLocked } || Self.idleSeconds > 300
    }

    public func handle(_ message: ServerMessage) {
        guard message.type == .event, message.speak == true, let kind = message.kind,
              Self.kinds.contains(kind), let text = message.text, isAway else { return }
        let title: String = switch kind {
        case "confirm": "Serve una conferma"
        case "question": "Una domanda per te"
        case "taskDone": "Task completato"
        case "reminder": "Promemoria"
        case "meeting": "Meeting"
        case "brief": "Briefing"
        case "watch": "Monitor"
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
