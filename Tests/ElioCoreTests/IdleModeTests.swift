import Foundation
import Testing
@testable import ElioCore

struct IdleModeTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour, minute: minute))!
    }

    @Test func quietHoursAcrossMidnight() {
        let q = { (h: Int, m: Int) in IdlePolicy.inQuietHours(self.at(h, m), start: "23:00", end: "07:30", calendar: self.calendar) }
        #expect(q(23, 0))
        #expect(q(2, 15))
        #expect(q(7, 29))
        #expect(!q(7, 30))
        #expect(!q(12, 0))
        #expect(!q(22, 59))
    }

    @Test func quietHoursSameDayAndMalformed() {
        #expect(IdlePolicy.inQuietHours(at(14, 0), start: "13:00", end: "15:00", calendar: calendar))
        #expect(!IdlePolicy.inQuietHours(at(15, 0), start: "13:00", end: "15:00", calendar: calendar))
        #expect(!IdlePolicy.inQuietHours(at(3, 0), start: "", end: "07:30", calendar: calendar))
        #expect(!IdlePolicy.inQuietHours(at(3, 0), start: "25:00", end: "07:30", calendar: calendar))
        #expect(!IdlePolicy.inQuietHours(at(3, 0), start: "07:30", end: "07:30", calendar: calendar))
        #expect(IdlePolicy.minutes(" 7:05") == 425)
    }

    @Test func urgentEventsWakeOnlyOutsideQuietHours() {
        let decide = { (kind: String, speak: Bool, h: Int) in
            IdlePolicy.decide(kind: kind, speak: speak, at: self.at(h, 0), quietStart: "23:00", quietEnd: "07:30",
                              calendar: self.calendar)
        }
        for kind in ["alarm", "workflowAlert", "confirm", "question"] {
            #expect(decide(kind, true, 15) == .wake)
            #expect(decide(kind, true, 3) == .hold)     // middle of the night: phone only
        }
        #expect(decide("confirm", false, 15) == .hold)  // the user is on the phone: it's asked there
        #expect(decide("taskDone", true, 15) == .hold)  // normal news: kept for the summary, never spoken
        #expect(decide("message", false, 15) == .hold)
        #expect(decide("watch", true, 3) == .hold)
        #expect(decide("usage", false, 15) == .ignore)
        #expect(decide("tool", false, 15) == .ignore)
        #expect(IdlePolicy.decide(kind: nil, speak: true, at: at(15, 0), quietStart: "23:00", quietEnd: "07:30") == .ignore)
    }

    @Test func returnSummary() {
        #expect(IdleSummary.line([], addressAs: "Signore") == nil)
        let one = IdleSummary.line([.init(kind: "watch", text: "La pipeline di staging è fallita")], addressAs: "Signore")
        #expect(one == "Bentornato, Signore. Mentre era via: La pipeline di staging è fallita.")
        let many = IdleSummary.line([.init(kind: "message", text: "a"), .init(kind: "message", text: "b"),
                                     .init(kind: "watch", text: "c"), .init(kind: "taskDone", text: "d"),
                                     .init(kind: "squadDone", text: "e")], addressAs: "Signore")
        #expect(many == "Bentornato, Signore: due messaggi nella casella, un monitor è scattato e due lavori finiti.")
    }

    @Test func configDecodingDefaults() throws {
        // An old config file without the rest-mode keys keeps working with the defaults.
        let old = try JSONDecoder().decode(ElioConfig.self, from: Data(#"{"userName":"Raffaele","idleMinutes":30}"#.utf8))
        #expect(old.userName == "Raffaele")
        #expect(old.idleAuto)
        #expect(old.idleMinutes == 30)
        #expect(old.idleScreen == "off")
        #expect(old.quietStart == "23:00" && old.quietEnd == "07:30")
        #expect(old.idleListen)
        let round = try JSONDecoder().decode(ElioConfig.self, from: JSONEncoder().encode(old))
        #expect(round.idleMinutes == 30)
    }

    @Test func idleMessageRoundTrip() throws {
        let data = try JSONEncoder().encode(ClientMessage.idle(true))
        #expect(String(decoding: data, as: UTF8.self).contains(#""type":"idle""#))
        guard case .idle(let on) = try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"idle","on":false}"#.utf8)) else {
            Issue.record("not decoded as idle"); return
        }
        #expect(!on)
    }
}
