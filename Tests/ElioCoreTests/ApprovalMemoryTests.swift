import Testing
@testable import ElioCore

struct ApprovalMemoryTests {
    @Test func onlyTheSameActionBySameAgent() {
        let m = ApprovalMemory()
        let read: [String: Any] = ["command": "osascript -e 'tell application \"iTerm2\" to get contents of current session'", "dangerouslyDisableSandbox": true]
        #expect(!m.covers(task: "t1", tool: "Bash", input: read))
        m.remember(task: "t1", tool: "Bash", input: read)
        #expect(m.covers(task: "t1", tool: "Bash", input: ["command": "osascript  -e 'tell application \"iTerm2\" to get contents of current session' ", "dangerouslyDisableSandbox": true]))
        #expect(!m.covers(task: "t2", tool: "Bash", input: read))
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": read["command"]!]))   // inside vs outside the sandbox
        m.remember(task: "t1", tool: "Bash", input: ["command": "osascript -e 'tell application \"iTerm2\" to write text \"ls\"'"])
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": "osascript -e 'tell application \"iTerm2\" to write text \"rm -rf ~\"'"]))
        m.remember(task: "t1", tool: "Bash", input: ["command": "git status"])
        #expect(!m.covers(task: "t1", tool: "Bash", input: ["command": "git push"]))
        m.remember(task: "t1", tool: "mcp__x__send", input: ["to": "a"])
        #expect(!m.covers(task: "t1", tool: "mcp__x__send", input: ["to": "b"]))
        m.forget(task: "t1")
        #expect(!m.covers(task: "t1", tool: "Bash", input: read))
    }
}
