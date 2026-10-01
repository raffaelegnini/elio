import ElioCore
import ElioVoice
import SwiftUI

/// Live view of a background agent: what it thinks, which commands it runs and their output,
/// which files it reads and the code it writes — streamed like a mission-control terminal.
struct AgentTheater: View {
    let loop: VoiceLoop
    let taskId: String
    var compact = false

    private var task: TaskInfo? { loop.tasks.first { $0.id == taskId } }
    private var entries: [TaskLogEntry] { loop.taskLogs[taskId] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(compact ? Array(entries.suffix(12)) : entries) { e in
                            LogLine(entry: e).id(e.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if task?.status == .running { Cursor() }
                    }
                    .padding(14)
                    .animation(.easeOut(duration: 0.25), value: entries.count)
                }
                .scrollIndicators(.never)
                .onChange(of: entries.count) { if let last = entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
        }
        .background(Scanlines().opacity(0.5))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let task { StatusDot(status: task.status) }
            VStack(alignment: .leading, spacing: 1) {
                Text(task?.title ?? "Agente").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(task?.project ?? "") · \(entries.count) eventi").font(Theme.mono).foregroundStyle(Theme.dim)
            }
            Spacer()
            if let task, task.status == .running || task.status == .waitingConfirmation {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(task.startedAt)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct LogLine: View {
    let entry: TaskLogEntry

    var body: some View {
        switch entry.kind {
        case .say:
            HStack(alignment: .top, spacing: 8) {
                Text("›").foregroundStyle(Theme.accent)
                Text(entry.title).foregroundStyle(Theme.text.opacity(0.9))
            }
            .font(.system(size: 12.5))
        case .command:
            VStack(alignment: .leading, spacing: 2) {
                Text("$ " + entry.title).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent).textSelection(.enabled)
                if !entry.body.isEmpty { Text(entry.body).font(.system(size: 10.5)).foregroundStyle(Theme.dim) }
            }
        case .output:
            Text(entry.body).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                .textSelection(.enabled)
        case .edit, .write:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: entry.kind == .write ? "doc.badge.plus" : "pencil.line")
                    Text(entry.title).lineLimit(1)
                }
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 5)
                if let removed = entry.removed, !removed.isEmpty { codeBlock(removed, sign: "−", color: .red) }
                if let added = entry.added, !added.isEmpty { codeBlock(added, sign: "+", color: .green) }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        case .read, .search, .info:
            HStack(spacing: 6) {
                Image(systemName: entry.kind == .read ? "doc.text" : entry.kind == .search ? "magnifyingglass" : "circle.dotted")
                Text(entry.title).lineLimit(1)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
        case .ask:
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                Text(entry.title)
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(hex: "#FF9F43"))
        }
    }

    private func codeBlock(_ text: String, sign: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(18).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(sign).foregroundStyle(color.opacity(0.9)).frame(width: 10)
                    Text(String(line).isEmpty ? " " : String(line)).foregroundStyle(Theme.text.opacity(0.9))
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.10))
            }
        }
        .padding(.bottom, 4)
    }
}

private struct Cursor: View {
    @State private var on = true
    var body: some View {
        Rectangle().fill(Theme.accent).frame(width: 8, height: 14).opacity(on ? 1 : 0.1)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false } }
    }
}

/// Faint horizontal scanlines for the terminal look.
private struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Theme.accent.opacity(0.025)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

struct QuestionCard: View {
    let question: QuestionRequest
    let answer: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                Text("DOMANDA").tracking(2)
                Spacer()
                Text(question.from).lineLimit(1)
            }
            .font(Theme.mono).foregroundStyle(Color(hex: "#FF9F43"))
            Text(question.question).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Rispondi (o dillo a voce)…", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .onSubmit { answer(text); text = "" }
                Button("Invia") { answer(text); text = "" }.buttonStyle(HUDButton(color: Color(hex: "#FF9F43"), filled: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#FF9F43").opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: "#FF9F43").opacity(0.5)))
    }
}
