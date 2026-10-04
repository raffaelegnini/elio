import CoreGraphics
import Foundation

/// Where the user is talking to Elio from right now: the Mac or the phone. Spoken events (agents finishing,
/// reminders, confirmations, the briefing) are said on that device only — Elio must not talk in an empty
/// room on the Mac while the user is on the phone, nor from the phone while they sit at the Mac.
public enum Presence {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastRemote = Date.distantPast
    nonisolated(unsafe) private static var lastLocal = Date.distantPast

    /// A request arrived (from the phone when `remote`).
    public static func noteRequest(remote: Bool) {
        lock.withLock { if remote { lastRemote = Date() } else { lastLocal = Date() } }
    }

    /// Seconds since the last keyboard/mouse use on the Mac.
    static var macIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// The user last talked from the phone (within half an hour) and isn't using the Mac.
    public static var onPhone: Bool {
        let (remote, local) = lock.withLock { (lastRemote, lastLocal) }
        return Date().timeIntervalSince(remote) < 1800 && remote > local && macIdle > 60
    }
}
