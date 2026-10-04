import ElioCore
import ElioVoice
import SwiftUI

/// Everything about one agent: who it is, what it was asked, what it has done, the files it touched
/// (open them in the IDE) and its terminal, live.
struct AgentDetailView: View {
    let loop: VoiceLoop
    let taskId: String
    let close: () -> Void
    /// Log of earlier runs (a resumed agent has one task id per run), loaded from the archive.
    @State private var history: [TaskLogEntry] = []

    private var task: TaskInfo? { loop.tasks.first { $0.id == taskId } }

    /// This run's live log plus what the archive has for the earlier ones.
    private var log: [TaskLogEntry] {
        let live = loop.taskLogs[taskId] ?? []
        let liveIds = Set(live.map(\.id))
        return history.filter { !liveIds.contains($0.id) } + live
    }

    /// Files it edited or created, most edited first.
    private var files: [(path: String, edits: Int, created: Bool)] {
        var count: [String: (Int, Bool)] = [:]
        for e in log where e.kind == .edit || e.kind == .write {
            let path = e.title.replacingOccurrences(of: #" \(\d+ modifiche\)$"#, with: "", options: .regularExpression)
            guard !path.isEmpty else { continue }
            let old = count[path] ?? (0, false)
            count[path] = (old.0 + 1, old.1 || e.kind == .write)
        }
        return count.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.edits > $1.edits }
    }

    private var commands: [TaskLogEntry] { log.filter { $0.kind == .command } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("RUOLO") {
                            Text(task?.role ?? (task?.kind == "mac" ? "Agente sul Mac" : "Agente di codice"))
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        }
                        section("COMPITO") {
                            Text(task?.task ?? task?.title ?? "—").font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.9))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        section("COSA HA FATTO") { done }
                        section("FILE TOCCATI · \(files.count)") { filesList }
                        if !commands.isEmpty {
                            section("COMANDI · \(commands.count)") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(commands.suffix(12).reversed()) { c in
                                        VStack(alignment: .leading, spacing: 1) {
                                            if !c.body.isEmpty {
                                                Text(c.body.prefix(1).uppercased() + c.body.dropFirst()).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                                            }
                                            Text("$ " + c.title).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(width: 400)
                Rectangle().fill(Theme.line).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("TERMINALE").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
                        Spacer()
                        Button("Scrivigli o apri una shell nell'IDE ↗") {
                            IDEWindowController.shared.showAgent(loop: loop, taskId: taskId, cwd: task?.cwd)
                        }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    AgentTheater(loop: loop, taskId: taskId)
                }
            }
        }
        .task { await loadHistory() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let task { StatusDot(status: task.status) }
            VStack(alignment: .leading, spacing: 2) {
                Text(task?.member ?? task?.title ?? "Agente").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text([task?.project, task?.model.map { $0.uppercased() }, task.map { stats($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.mono).foregroundStyle(Theme.dim)
            }
            Spacer()
            if let task, [.running, .waitingConfirmation, .paused].contains(task.status) {
                TaskControls(status: task.status) { loop.controlTask(task.id, $0) }
            }
            if let cwd = task?.cwd {
                Button("Apri nell'IDE") { IDEWindowController.shared.show(loop: loop, path: cwd) }.buttonStyle(HUDButton(color: Theme.accent))
            }
            Button("Chiudi", action: close).buttonStyle(HUDButton(color: Theme.dim))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func stats(_ t: TaskInfo) -> String {
        let tok = UsageMeter.format((t.tokensIn ?? 0) + (t.tokensOut ?? 0))
        let secs = t.activeSeconds ?? (t.endedAt ?? Date()).timeIntervalSince(t.startedAt)
        let time = Duration.seconds(secs).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return "\(time) · \(tok) token\(t.costUSD.map { String(format: " · $%.2f", $0) } ?? "")"
    }

    @ViewBuilder private var done: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = task?.plan, !plan.isEmpty {
                ForEach(Array(plan.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "circle.inset.filled" : "circle")
                            .font(.system(size: 11)).foregroundStyle(step.status == "pending" ? Theme.dim : Theme.accent).padding(.top, 1)
                        Text(step.status == "in_progress" ? (step.active ?? step.text) : step.text)
                            .font(.system(size: 12.5, weight: step.status == "in_progress" ? .semibold : .regular))
                            .foregroundStyle(step.status == "pending" ? Theme.dim : Theme.text)
                    }
                }
            }
            if let summary = task?.summary, !summary.isEmpty {
                MarkdownText(text: summary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } else if task?.plan?.isEmpty ?? true {
                Text(task?.isActive == true ? AgentActivity.now(task!, log: log) : "Nessun riepilogo.").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
    }

    @ViewBuilder private var filesList: some View {
        if files.isEmpty {
            Text("Ancora nessun file modificato.").font(.system(size: 12)).foregroundStyle(Theme.dim)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(files, id: \.path) { f in
                    Button {
                        let full = resolve(f.path)
                        IDEWindowController.shared.show(loop: loop, path: full)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: f.created ? "plus.square" : "pencil").font(.system(size: 10))
                                .foregroundStyle(f.created ? .green : Theme.accent).frame(width: 14)
                            Text((f.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                            Text((f.path as NSString).deletingLastPathComponent).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("\(f.edits)×").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Apri nell'IDE")
                }
            }
        }
    }

    /// Logs keep only the last path components ("Http/Controllers/X.php"): find the file in the agent's folder.
    private func resolve(_ path: String) -> String {
        guard let cwd = task?.cwd else { return path }
        if path.hasPrefix("/") { return path }
        let direct = (cwd as NSString).appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: direct) { return direct }
        let skip: Set<String> = ["node_modules", "vendor", ".git", ".build", "Pods", ".dart_tool", "build"]
        let e = FileManager.default.enumerator(at: URL(fileURLWithPath: cwd), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var seen = 0
        while let url = e?.nextObject() as? URL, seen < 60_000 {
            seen += 1
            if skip.contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            if url.path.hasSuffix("/" + path) { return url.path }
        }
        return cwd
    }

    private func loadHistory() async {
        guard let runs = task?.runIds, runs.count > 1 || (loop.taskLogs[taskId] ?? []).isEmpty else { return }
        var all: [TaskLogEntry] = []
        for run in runs {
            let (json, err) = await loop.callTool("history", ["section": "task_log", "task_id": run])
            if !err, let list = [TaskLogEntry].fromJSON(json) { all += list }
        }
        history = all
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Rectangle().fill(Theme.accent).frame(width: 3, height: 10)
                Text(title).font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
            }
            content()
        }
    }
}
