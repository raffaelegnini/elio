import Foundation

/// Claude token usage on this Mac, read from Claude Code's own transcripts
/// (~/.claude/projects/**/*.jsonl): every session counts, Elio's conversation and agents included.
/// Files are read incrementally (only new bytes), messages deduplicated by id.
public actor UsageMeter {
    public static let shared = UsageMeter()

    private struct Call { let at: Date; let input: Int; let output: Int; let cacheRead: Int; let cacheWrite: Int; let elio: Bool }

    private var offsets: [String: UInt64] = [:]
    private var calls: [String: Call] = [:]
    private var agentsCost: () async -> Double = { 0 }
    private var last = UsageSnapshot()

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func setAgentsCost(_ f: @escaping @Sendable () async -> Double) { agentsCost = f }

    /// Refreshes every `interval` seconds and hands the snapshot to `publish`.
    public func start(every interval: TimeInterval = 60, publish: @escaping @Sendable (UsageSnapshot) -> Void) {
        Task {
            while true {
                publish(await refresh())
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func snapshot() async -> UsageSnapshot { await refresh() }

    @discardableResult
    public func refresh() async -> UsageSnapshot {
        let since = Date().addingTimeInterval(-26 * 3600)
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let elio = dir.lastPathComponent.contains("Application-Support-Elio")
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for file in files where file.pathExtension == "jsonl" {
                    let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    guard mod > since else { continue }
                    read(file, elio: elio)
                }
            }
        }
        calls = calls.filter { $0.value.at > since }

        var s = UsageSnapshot()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let now = Date()
        let sorted = calls.values.sorted { $0.at < $1.at }
        // Claude's 5-hour windows start at the first message after the previous window ended.
        var windowStart: Date?
        for c in sorted {
            if windowStart == nil || c.at >= windowStart!.addingTimeInterval(5 * 3600) { windowStart = c.at }
        }
        if let w = windowStart, w.addingTimeInterval(5 * 3600) < now { windowStart = nil }
        for c in sorted {
            if c.at >= startOfDay {
                add(c, to: &s.today)
                if c.elio { add(c, to: &s.elioToday) }
            }
            if let w = windowStart, c.at >= w { add(c, to: &s.window5h) }
        }
        s.windowStart = windowStart
        s.agentsCostUSD = await agentsCost()
        s.updatedAt = now
        last = s
        return s
    }

    private func add(_ c: Call, to b: inout UsageSnapshot.Bucket) {
        b.input += c.input; b.output += c.output; b.cacheRead += c.cacheRead; b.cacheWrite += c.cacheWrite; b.messages += 1
    }

    private func read(_ file: URL, elio: Bool) {
        guard let h = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var from = offsets[file.path] ?? 0
        if from > size { from = 0 }
        guard size > from else { return }
        try? h.seek(toOffset: from)
        guard let data = try? h.readToEnd() else { return }
        // Only complete lines; a partial last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        offsets[file.path] = from + UInt64(lastNewline - data.startIndex + 1)
        for line in data[data.startIndex...lastNewline].split(separator: 0x0A) {
            // Cheap prefilter before JSON parsing.
            guard line.count > 50, line.firstRange(of: Data("\"usage\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any], let id = msg["id"] as? String,
                  let u = msg["usage"] as? [String: Any],
                  let ts = (obj["timestamp"] as? String).flatMap(iso.date(from:)) else { continue }
            calls[id] = Call(at: ts, input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                             cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                             cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0, elio: elio)
        }
    }

    public static func format(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}
