import Foundation
import Testing
@testable import ElioCore

struct ActivityTextTests {
    @Test(arguments: [
        ("Bash", #"{"command":"git status","description":"controllare lo stato del repository"}"#, "Controllare lo stato del repository"),
        ("Bash", #"{"command":"cd /Users/me/dev/app && npm run build --silent"}"#, "Eseguo npm run build"),
        ("Read", #"{"file_path":"/Users/me/dev/app/Sources/Main.swift"}"#, "Leggo Main.swift"),
        ("Grep", #"{"pattern":"TODO","path":"/Users/me/dev/app"}"#, "Cerco «TODO» in app"),
        ("Glob", #"{"pattern":"**/*.swift"}"#, "Cerco file «**/*.swift»"),
        ("Edit", #"{"file_path":"/tmp/a/config.json","old_string":"x","new_string":"y"}"#, "Modifico config.json"),
        ("Write", #"{"file_path":"/tmp/a/note.md","content":"..."}"#, "Scrivo note.md"),
        ("WebSearch", #"{"query":"meteo Napoli domani"}"#, "Cerco sul web «meteo Napoli domani»"),
        ("WebFetch", #"{"url":"https://www.apple.com/it/iphone/","prompt":"prezzi"}"#, "Apro apple.com"),
        ("mcp__elio__slack_send", ##"{"to":"#deploy","text":"fatto"}"##, "Scrivo su Slack a #deploy"),
        ("slack_mentions", #"{}"#, "Cerco le menzioni su Slack"),
        ("mail_search", #"{"query":"from:luca fattura"}"#, "Cerco nella posta «from:luca fattura»"),
        ("calendar_events", #"{"from":"2026-10-08"}"#, "Leggo l'agenda (2026-10-08)"),
        ("lookup", #"{"query":"Marco"}"#, "Cerco in rubrica «Marco»"),
        ("mcp__claude-in-chrome__navigate", #"{"url":"https://app.teamwork.com/projects"}"#, "Browser: apro app.teamwork.com"),
        ("mcp__teamwork__list_tasks", #"{}"#, "Teamwork: list tasks"),
        ("some_new_tool", #"{}"#, "Uso some new tool"),
    ])
    func describesEachTool(tool: String, input: String, expected: String) {
        #expect(ActivityText.describe(tool: tool, inputJSON: input) == expected)
    }

    @Test func longInputsAreTruncatedToOneLine() {
        let query = String(repeating: "parola ", count: 40)
        let line = ActivityText.describe(tool: "WebSearch", inputJSON: #"{"query":"\#(query)"}"#)
        #expect(line.count <= ActivityText.maxLength)
        #expect(line.contains("…"))
        let multi = ActivityText.describe(tool: "Bash", input: ["description": "riga uno\nriga due\n" + String(repeating: "x ", count: 80)])
        #expect(!multi.contains("\n"))
        #expect(multi.count <= ActivityText.maxLength)
    }

    @Test func secretsAreRedacted() {
        let token = "xoxp-1234567890-abcdefghij-0987654321"
        let bash = ActivityText.describe(tool: "Bash", input: ["command": "curl -H 'Authorization: Bearer \(token)' https://x.io"])
        #expect(!bash.contains("0987654321"))
        let desc = ActivityText.describe(tool: "Bash", input: ["description": "salvare il token \(token) nel portachiavi"])
        #expect(!desc.contains(token))
        let search = ActivityText.describe(tool: "WebSearch", input: ["query": "password: Sup3rS3gr3ta! " + String(repeating: "a", count: 50)])
        #expect(!search.contains("Sup3r"))
        let err = ActivityText.outcome(tool: "Bash", result: "Error: invalid token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789\nmore", isError: true)
        #expect(err?.hasPrefix("errore: ") == true)
        #expect(err?.contains("ghp_") == false)
    }

    @Test func outcomes() {
        #expect(ActivityText.outcome(tool: "Grep", result: "a.swift\nb.swift\nc.swift", isError: false) == "3 risultati")
        #expect(ActivityText.outcome(tool: "Grep", result: "Found 12 files\na\nb", isError: false) == "12 risultati")
        #expect(ActivityText.outcome(tool: "Glob", result: "No files found", isError: false) == "nessun risultato")
        #expect(ActivityText.outcome(tool: "Read", result: "1\n2\n", isError: false) == "2 righe")
        #expect(ActivityText.outcome(tool: "slack_dms", result: "Marco: ciao", isError: false) == nil)
        #expect(ActivityText.outcome(tool: "Bash", result: "", isError: true) == "errore")
    }
}

struct ThinkingThrottleTests {
    @Test func sendsAtMostEveryInterval() {
        var t = ThinkingThrottle(interval: 0.3)
        let t0 = Date()
        #expect(t.push("Devo ", now: t0) == "Devo ")                         // first delta goes out right away
        #expect(t.push("controllare ", now: t0.addingTimeInterval(0.1)) == nil)
        #expect(t.push("Slack.", now: t0.addingTimeInterval(0.2)) == nil)
        #expect(t.push(" Poi", now: t0.addingTimeInterval(0.35)) == "Devo controllare Slack. Poi")
        #expect(t.push(" la mail", now: t0.addingTimeInterval(0.4)) == nil)
        #expect(t.flush(now: t0.addingTimeInterval(0.45)) == "Devo controllare Slack. Poi la mail")
        #expect(t.flush(now: t0.addingTimeInterval(0.9)) == nil)               // nothing new
        #expect(t.push("", now: t0.addingTimeInterval(1)) == nil)
    }

    @Test func sendsARedactedTail() {
        var t = ThinkingThrottle(interval: 0.3, tailLength: 50)
        let t0 = Date()
        _ = t.push(String(repeating: "pensiero lungo ", count: 20), now: t0)
        // A token split across two deltas is still caught: the whole text is filtered.
        _ = t.push("il token è xoxp-12345", now: t0.addingTimeInterval(0.1))
        let out = t.push("67890-abcdefghij-0987654321 ok", now: t0.addingTimeInterval(0.5)) ?? ""
        #expect(out.hasPrefix("…"))
        #expect(out.count <= 51)
        #expect(!out.contains("0987654321"))
    }
}

struct TurnFeedTests {
    @Test func phasesAndToolLines() {
        final class Box: @unchecked Sendable { var messages: [ServerMessage] = [] }
        let box = Box()
        var feed = TurnFeed(requestId: "r1") { box.messages.append($0) }
        feed.setPhase("capisco")
        feed.handle(.thinking(""))
        feed.handle(.toolCall(name: "WebSearch", id: "t1", input: nil))
        feed.handle(.toolCall(name: "WebSearch", id: "t1", input: #"{"query":"meteo"}"#))
        feed.handle(.toolCall(name: "mcp__elio__slack_dms", id: "t2", input: "{}"))   // reported by the server
        feed.handle(.toolResult(id: "t1", text: "…", isError: false))
        feed.handle(.delta("Domani piove."))
        feed.finish()
        let phases = box.messages.filter { $0.kind == "phase" }.compactMap(\.text)
        #expect(phases == ["capisco", "penso", "strumenti", "penso", "rispondo", "fine"])
        let lines = box.messages.filter { $0.kind == "activity" }
        #expect(lines.map(\.id) == ["t1", "t1", "t1"])
        #expect(lines[1].text == "Cerco sul web «meteo»")
        #expect(lines[2].payload?.contains("\"phase\":\"end\"") == true)
    }
}
