import AppKit
import EventKit
import Foundation

/// Calendar access through EventKit: sees every account added to macOS
/// (Google work + personal, iCloud), merged like Calendar.app shows them.
public enum CalendarTools {
    static let store = EKEventStore()

    public static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return }
        guard try await store.requestFullAccessToEvents() else {
            throw ToolError("Accesso al calendario negato. Abilitalo in Impostazioni di Sistema → Privacy → Calendari per Elio.")
        }
    }

    public struct Event: Sendable {
        public let title: String
        public let start: Date
        public let end: Date
        public let allDay: Bool
        public let calendar: String
        public let location: String?
        public let meetURL: URL?
    }

    public static func events(from start: Date, to end: Date) async throws -> [Event] {
        try await ensureAccess()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                Event(title: e.title ?? "(senza titolo)", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                      calendar: e.calendar.title, location: e.location, meetURL: meetLink(e))
            }
    }

    static func meetLink(_ e: EKEvent) -> URL? {
        let haystack = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        guard let range = haystack.range(of: #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#,
                                         options: .regularExpression) else { return nil }
        return URL(string: String(haystack[range]))
    }

    static func describe(_ events: [Event]) -> String {
        guard !events.isEmpty else { return "Nessun evento." }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "it_IT")
        day.dateFormat = "EEEE d MMMM"
        var lines: [String] = []
        var lastDay = ""
        for e in events {
            let d = day.string(from: e.start)
            if d != lastDay { lines.append("## \(d)"); lastDay = d }
            let when = e.allDay ? "tutto il giorno" : "\(time.string(from: e.start))–\(time.string(from: e.end))"
            var line = "- \(when) \(e.title) [\(e.calendar)]"
            if e.meetURL != nil { line += " (Google Meet)" }
            if let loc = e.location, !loc.isEmpty, e.meetURL == nil { line += " @ \(loc)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static let events = ElioTool(
        name: "calendar_events",
        description: "Legge gli eventi di tutti i calendari (Google lavoro/personale, iCloud) in un intervallo. Usalo per agenda, impegni, meeting.",
        properties: [
            "from": prop("Inizio intervallo ISO8601 (es. 2026-10-01T00:00:00+02:00). Default: inizio di oggi."),
            "to": prop("Fine intervallo ISO8601. Default: fine di oggi."),
        ]
    ) { args, _ in
        let cal = Calendar.current
        let start = (args["from"] as? String).flatMap(parseDate) ?? cal.startOfDay(for: Date())
        let end = (args["to"] as? String).flatMap(parseDate) ?? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        return describe(try await Self.events(from: start, to: end))
    }
}

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    // Date only, local time.
    let local = DateFormatter()
    local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let d = local.date(from: s) { return d }
    local.dateFormat = "yyyy-MM-dd"
    return local.date(from: s)
}

public enum MeetingTools {
    /// Opens the Meet pre-join page: the user only has to press "Partecipa".
    public static func open(_ url: URL) throws {
        let chrome = "/Applications/Google Chrome.app"
        if FileManager.default.fileExists(atPath: chrome) {
            try shell("/usr/bin/open", ["-a", chrome, url.absoluteString])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static let joinNext = ElioTool(
        name: "join_next_meeting",
        description: "Apre la pagina di pre-ingresso del prossimo Google Meet (in corso o entro 30 minuti). Non entra nel meeting: l'utente preme Partecipa.",
        properties: ["title": prop("Opzionale: parte del titolo del meeting da aprire.")]
    ) { args, _ in
        let now = Date()
        let events = try await CalendarTools.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(12 * 3600))
        let wanted = (args["title"] as? String)?.lowercased()
        let candidates = events.filter { e in
            e.meetURL != nil && e.end > now && (wanted.map { e.title.lowercased().contains($0) } ?? true)
        }
        guard let next = candidates.first(where: { wanted != nil || $0.start <= now.addingTimeInterval(30 * 60) }),
              let url = next.meetURL else {
            return "Nessun Google Meet in corso o nei prossimi 30 minuti."
        }
        try open(url)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "Aperta la pre-join di \"\(next.title)\" delle \(f.string(from: next.start))."
    }
}
