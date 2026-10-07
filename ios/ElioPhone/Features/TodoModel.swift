import Foundation
import Observation

/// To do (api/todos): the Mac does the work, every action answers with the whole board.
@Observable
final class TodoModel {
    enum List: String, CaseIterable, Identifiable {
        case today, tomorrow, someday
        var id: String { rawValue }
        var title: String {
            switch self { case .today: "Oggi"; case .tomorrow: "Domani"; case .someday: "Prima o poi" }
        }
    }

    private(set) var board: TodoBoard?
    private(set) var error: String?
    var list: List = .today

    @ObservationIgnored weak var client: ElioClient?

    var todayDone: Int { board?.today.filter(\.done).count ?? 0 }
    var todayTotal: Int { board?.today.count ?? 0 }

    func items(_ list: List) -> [TodoItem] {
        guard let board else { return [] }
        let all: [TodoItem] = switch list { case .today: board.today; case .tomorrow: board.tomorrow; case .someday: board.someday }
        let open = all.filter { !$0.done }
        return open.filter(\.isFocus) + open.filter { !$0.isFocus } + all.filter(\.done)
    }

    func load() async { await call(nil) }

    /// A "todos" event from the socket.
    func set(_ board: TodoBoard) { self.board = board; error = nil }

    func act(_ action: String, id: Int? = nil, text: String? = nil) {
        var body: [String: Any] = ["action": action]
        if let id { body["id"] = id }
        if let text { body["text"] = text }
        Task { await call(body) }
    }

    /// New item: without an explicit "@…" it goes to the list on screen.
    func add(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("@") {
            text += list == .tomorrow ? " @domani" : list == .someday ? " @prima o poi" : ""
        }
        act("add", text: text)
    }

    private func call(_ body: [String: Any]?) async {
        guard let client else { return }
        do {
            board = body == nil ? try await client.get("api/todos", as: TodoBoard.self)
                                : try await client.post("api/todos", json: body!, as: TodoBoard.self)
            error = nil
        } catch {
            self.error = "Non riesco a leggere la lista dal Mac."
        }
    }
}
