import Foundation
import Observation

/// Workflow (api/workflows): agents at work on the Mac, with their progress and controls.
@Observable
final class WorkflowModel {
    private(set) var items: [WorkflowItem] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// "talking" or "silent".
    var mode = "talking"
    var visible = false

    @ObservationIgnored weak var client: ElioClient?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    func load() async {
        guard let client else { return }
        do {
            let feed = try await client.get("api/workflows", as: WorkflowFeed.self)
            items = feed.workflows ?? []
            if let m = feed.mode { mode = m == "silent" ? "silent" : "talking" }
            loaded = true
            error = nil
        } catch {
            self.error = "Non riesco a leggere i workflow dal Mac."
        }
    }

    /// Task/squad events: refresh shortly after, only while the tab is on screen.
    func refreshSoon() {
        guard visible else { return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    func setMode(_ m: String) {
        mode = m
        client?.send(.mode(m))
    }

    func control(_ agentId: String, _ action: String) {
        client?.send(.taskControl(agentId, action))
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await load()
        }
    }
}
