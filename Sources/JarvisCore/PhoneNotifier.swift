import CoreGraphics
import Foundation

/// Sends Jarvis's spoken events to the phone through ntfy (ntfy.sh, app on iPhone)
/// — only when Raffaele is away from the Mac (screen locked or idle), to avoid duplicates.
public final class PhoneNotifier: @unchecked Sendable {
    private let topic: String
    private let lock = NSLock()
    private var screenLocked = false
    private var observers: [NSObjectProtocol] = []
    static let kinds: Set<String> = ["reminder", "taskDone", "confirm", "meeting", "brief", "timer"]

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

    public var isAway: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return lock.withLock { screenLocked } || idle > 300
    }

    public func handle(_ message: ServerMessage) {
        guard message.type == .event, message.speak == true, let kind = message.kind,
              Self.kinds.contains(kind), let text = message.text, isAway else { return }
        let title: String = switch kind {
        case "confirm": "Jarvis chiede conferma"
        case "taskDone": "Task completato"
        case "reminder": "Promemoria"
        case "meeting": "Meeting"
        case "brief": "Briefing"
        default: "Jarvis"
        }
        var req = URLRequest(url: URL(string: "https://ntfy.sh/\(topic)")!)
        req.httpMethod = "POST"
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue(kind == "confirm" ? "high" : "default", forHTTPHeaderField: "Priority")
        req.setValue("robot", forHTTPHeaderField: "Tags")
        req.httpBody = Data(String(text.prefix(400)).utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
}
