import Foundation
import Testing
@testable import ElioCore

struct WorkflowTests {
    private func tempMemory() throws -> Memory {
        try Memory(path: FileManager.default.temporaryDirectory.appendingPathComponent("elio-test-\(UUID().uuidString).sqlite"))
    }

    @Test func tasteRulesRoundTrip() async throws {
        let memory = try tempMemory()
        let id = await memory.addTasteRule(TasteRule(domain: "design", rule: "Niente gradienti viola-blu",
                                                     bad: "linear-gradient(#7c3aed, #2563eb)", good: "colore pieno del brand"))
        await memory.bumpTasteHits([id, id])
        let rules = await memory.tasteRules()
        #expect(rules.count == 1)
        #expect(rules[0].hits == 1)   // one review = one hit, however many files
        #expect(rules[0].severity == "fix")
        #expect(await memory.deleteTasteRule(id))
        #expect(await memory.tasteRules().isEmpty)
    }

    @Test func promptBlockGroupsByDomainAndFilters() {
        let rules = [TasteRule(id: 1, domain: "design", rule: "Niente glassmorphism", bad: "backdrop-filter ovunque"),
                     TasteRule(id: 2, domain: "git", rule: "Commit in inglese, imperativo"),
                     TasteRule(id: 3, domain: "generale", rule: "Niente emoji nel codice")]
        let all = Taste.promptBlock(rules)
        #expect(all.contains("[design]") && all.contains("#1 Niente glassmorphism") && all.contains("no: backdrop-filter"))
        let design = Taste.promptBlock(rules, domain: "design")
        #expect(design.contains("#1") && design.contains("#3") && !design.contains("#2"))
        #expect(Taste.promptBlock([]).isEmpty)
    }

    @Test func workflowEventsAndAgentsPersist() async throws {
        let memory = try tempMemory()
        await memory.saveWorkflow(WorkflowRecord(id: "sq1", kind: "squad", title: "Export CSV", project: "shop"))
        await memory.addWorkflowEvent(WorkflowEvent(workflow: "sq1", kind: .autoDecision, actor: "elio", text: "ISO 8601",
                                                    data: "{\"question\":\"Formato date?\"}"))
        var a = TaskInfo(id: "t1", title: "backend: API", project: "shop", status: .done)
        a.member = "backend"
        await memory.saveWorkflowAgent("sq1", key: "backend", a)
        a.id = "t2"   // resumed run: same agent row
        await memory.saveWorkflowAgent("sq1", key: "backend", a)
        await memory.saveWorkflow(WorkflowRecord(id: "sq1", kind: "squad", title: "Export CSV", project: nil,
                                                 endedAt: Date(), status: "done", summary: "Fatto"))

        let wf = try #require(await memory.workflow("sq1"))
        #expect(wf.status == "done" && wf.summary == "Fatto" && wf.endedAt != nil)
        #expect(await memory.workflowEvents("sq1").map(\.kind) == [.autoDecision])
        #expect(await memory.workflowAgents("sq1").map(\.id) == ["t2"])
    }

    @Test func silentModeMutesOnlyChatter() {
        let previous = Attention.mode
        defer { Attention.set(previous, persist: false) }
        Attention.set(.silent, persist: false)
        let progress = ServerMessage(type: .event, text: "Ho finito il backend", kind: "progress", speak: true)
        let question = ServerMessage(type: .event, text: "Posso procedere?", kind: "question", speak: true)
        let alert = ServerMessage(type: .event, text: "Si è fermato", kind: "workflowAlert", speak: true)
        #expect(Attention.shape(progress).speak == false)
        #expect(Attention.shape(question).speak == true)
        #expect(Attention.shape(alert).speak == true)
        Attention.set(.talking, persist: false)
        #expect(Attention.shape(progress).speak == true)
    }

    @Test func modeMessageDecodes() throws {
        let msg = try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"mode","text":"silent"}"#.utf8))
        guard case .mode(let m) = msg else { Issue.record("not a mode message"); return }
        #expect(m == "silent")
    }
}

struct TodoTests {
    private func tempMemory() throws -> Memory {
        try Memory(path: FileManager.default.temporaryDirectory.appendingPathComponent("elio-todo-\(UUID().uuidString).sqlite"))
    }

    @Test func boardCarryOverAndRecurring() async throws {
        let memory = try tempMemory()
        let today = TodoDay.key()
        let yesterday = TodoDay.key(Date().addingTimeInterval(-86400))
        _ = await memory.addTodo(TodoItem(text: "Mail a Rosario", day: yesterday))
        let done = await memory.addTodo(TodoItem(text: "Standup", day: yesterday))
        var d = try #require(await memory.todo(done)); d.done = true; await memory.updateTodo(d)
        _ = await memory.addTodo(TodoItem(text: "Leggere il report", day: nil))
        _ = await memory.addTodo(TodoItem(text: "Timbrare", day: nil, recurring: "daily"))

        var board = await memory.todoBoard()
        #expect(board.overdue.map(\.text) == ["Mail a Rosario"])
        #expect(board.someday.map(\.text) == ["Leggere il report"])
        #expect(board.today.map(\.text) == ["Timbrare"])          // recurring instance created once
        board = await memory.todoBoard()
        #expect(board.today.count == 1)

        #expect(await memory.carryOverTodos(to: today) == 1)
        board = await memory.todoBoard()
        #expect(board.overdue.isEmpty)
        #expect(Set(board.today.map(\.text)) == ["Timbrare", "Mail a Rosario"])
        #expect(await memory.findTodos("ho scritto la mail a rosario").first?.text == "Mail a Rosario")
    }

    @Test func parsesDays() {
        #expect(TodoDay.parse("oggi") == .some(TodoDay.key()))
        #expect(TodoDay.parse("prima o poi") == .some(nil))
        #expect(TodoDay.parse("2026-12-24") == .some("2026-12-24"))
        #expect(TodoDay.parse("boh") == nil)
    }
}
