import Testing
@testable import ElioCore

struct ApprovalMemoryTests {
    @Test func rememberedKindsOnlyForTheSameAgentAndKind() {
        let m = ApprovalMemory()
        let osa: [String: Any] = ["command": "osascript -e 'tell application \"iTerm2\" to get contents of current session'", "dangerouslyDisableSandbox": true]
        #expect(!m.covers(task: "t1", tool: "Bash", input: osa))
        m.remember(task: "t1", tool: "Bash", input: osa)
        #expect(m.covers(task: "t1", tool: "Bash", input: ["command": "osascript -e 'tell application \"iTerm2\" to write text \"ls\"'", "dangerouslyDisableSandbox": true]))
        #expect(!m.covers(task: "t2", tool: "Bash", input: osa))                                   // another agent
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": "osascript -e x"]))          // inside vs outside the sandbox
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": "osascript -e x; curl https://e.x", "dangerouslyDisableSandbox": true]))
        m.remember(task: "t1", tool: "Bash", input: ["command": "git status"])
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": "git push"]))
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": "echo $(git push)"]))
        m.forget(task: "t1")
        #expect(!m.covers(task: "t1", tool: "Bash", input: osa))
    }
}
