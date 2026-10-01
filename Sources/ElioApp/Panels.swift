import AppKit
import ElioCore
import ElioVoice
import SwiftUI

// MARK: - Confirmation

struct ConfirmCard: View {
    let request: ConfirmRequest
    let answer: (Bool) -> Void

    private var danger: Bool { request.risk == .dangerous }
    private var accent: Color { danger ? Color(red: 1, green: 0.42, blue: 0.38) : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: danger ? "exclamationmark.shield.fill" : "hand.raised.fill")
                Text(danger ? "CONFERMA ESPLICITA" : "CONFERMA").tracking(2)
            }
            .font(Theme.mono).foregroundStyle(accent)

            Text(request.detail)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text)
                .lineLimit(6).textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))

            Text(danger ? "Di' \"confermo\" oppure premi il pulsante." : "Di' \"sì\" o \"no\", oppure usa i pulsanti.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim)

            HStack {
                Button("Annulla") { answer(false) }
                    .buttonStyle(HUDButton(color: Theme.dim))
                Spacer()
                Button(danger ? "Confermo" : "Procedi") { answer(true) }
                    .buttonStyle(HUDButton(color: accent, filled: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.5)))
    }
}

struct HUDButton: ButtonStyle {
    let color: Color
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(filled ? Color.black : color)
            .background(RoundedRectangle(cornerRadius: 8).fill(filled ? color : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(filled ? 0 : 0.5)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Workflows

struct WorkflowRow: View {
    let task: TaskInfo
    var expanded = false
    /// pause / resume / stop
    var control: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(status: task.status)
                Text(task.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(task.project ?? "").font(Theme.mono).foregroundStyle(Theme.dim)
                if let control, [.running, .waitingConfirmation, .paused].contains(task.status) {
                    TaskControls(status: task.status, control: control)
                }
            }
            if expanded {
                ForEach(Array(task.steps.suffix(8).enumerated()), id: \.offset) { _, step in
                    Text(step).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                        .lineLimit(1).padding(.leading, 16)
                }
                if let summary = task.summary, task.status != .running {
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(4).padding(.leading, 16)
                }
            } else if let last = task.steps.last, task.status == .running || task.status == .waitingConfirmation {
                Text(last).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                    .lineLimit(1).padding(.leading, 16)
            }
        }
    }
}

struct StatusDot: View {
    let status: TaskInfo.Status
    @State private var pulse = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color, radius: pulse ? 5 : 1)
            .onAppear {
                guard status == .running || status == .waitingConfirmation else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
            }
    }

    private var color: Color {
        switch status {
        case .running: Theme.accent
        case .waitingConfirmation: .orange
        case .paused: Theme.dim
        case .done: .green
        case .failed: .red
        case .cancelled: Theme.dim
        }
    }
}

// MARK: - Diff viewer

struct DiffFile: Identifiable {
    let id = UUID()
    var path: String
    var lines: [DiffLine] = []
    var added: Int { lines.filter { $0.kind == .add }.count }
    var removed: Int { lines.filter { $0.kind == .del }.count }
}

struct DiffLine: Identifiable {
    enum Kind { case add, del, context, hunk }
    let id = UUID()
    let kind: Kind
    let text: String
    let old: Int?
    let new: Int?
}

enum DiffParser {
    static func parse(_ diff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var oldLine = 0, newLine = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                let path = line.components(separatedBy: " b/").last ?? line
                files.append(DiffFile(path: path))
            } else if line.hasPrefix("@@") {
                // @@ -12,7 +12,8 @@ context
                let nums = line.split(separator: " ")
                if nums.count > 2 {
                    oldLine = Int(nums[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
                    newLine = Int(nums[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                files[safe: files.count - 1]?.lines.append(DiffLine(kind: .hunk, text: line, old: nil, new: nil))
            } else if files.isEmpty || line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") {
                continue
            } else if line.hasPrefix("+") {
                files[files.count - 1].lines.append(DiffLine(kind: .add, text: String(line.dropFirst()), old: nil, new: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                files[files.count - 1].lines.append(DiffLine(kind: .del, text: String(line.dropFirst()), old: oldLine, new: nil))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                files[files.count - 1].lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: oldLine, new: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return files
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set { if let newValue, indices.contains(index) { self[index] = newValue } }
    }
}

struct DiffView: View {
    let payload: DiffPayload
    @State private var selected: UUID?

    private var files: [DiffFile] { DiffParser.parse(payload.diff) }

    var body: some View {
        let files = self.files
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.title).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text).padding(.bottom, 2)
                Text((payload.repo as NSString).lastPathComponent).font(Theme.mono).foregroundStyle(Theme.dim)
                    .padding(.bottom, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files) { f in
                            Button { selected = f.id } label: {
                                HStack {
                                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                                    Spacer()
                                    Text("+\(f.added)").foregroundStyle(.green)
                                    Text("−\(f.removed)").foregroundStyle(.red)
                                }
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill((selected ?? files.first?.id) == f.id ? Theme.accent.opacity(0.12) : .clear))
                            }
                            .buttonStyle(.plain)
                            .help(f.path)
                        }
                    }
                }
                Spacer()
                Text("Rivedi e crea tu la PR. Il push richiede conferma.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
            }
            .padding(16)
            .frame(width: 240)

            Rectangle().fill(Theme.line).frame(width: 1)

            if let file = files.first(where: { $0.id == (selected ?? files.first?.id) }) {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        ForEach(file.lines) { DiffLineView(line: $0) }
                    }
                    .padding(.bottom, 20)
                }
            } else {
                Text("Nessuna modifica").foregroundStyle(Theme.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(line.new.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(marker).frame(width: 22)
            Text(line.text.isEmpty ? " " : line.text).fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(fg)
        .padding(.vertical, 1)
        .background(bg)
    }

    private var marker: String {
        switch line.kind { case .add: "+"; case .del: "−"; default: "" }
    }

    private var fg: Color {
        switch line.kind {
        case .hunk: Theme.accent.opacity(0.8)
        case .context: Theme.text.opacity(0.75)
        default: Theme.text
        }
    }

    private var bg: Color {
        switch line.kind {
        case .add: Color.green.opacity(0.14)
        case .del: Color.red.opacity(0.14)
        case .hunk: Theme.accent.opacity(0.06)
        case .context: .clear
        }
    }
}

// MARK: - Markdown card

struct MarkdownText: View {
    let text: String

    var body: some View {
        let shown = SecretFilter.redact(text, with: "••••••••")
        Text((try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(shown))
            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Secrets on screen

/// Text whose secrets are masked until the user asks to see them. The clear text lives only in
/// memory: it isn't spoken, archived or sent to the phone (see SecretFilter).
struct SecretAwareText: View {
    let text: String
    var font: Font = .system(size: 13)
    var color: Color = Theme.text
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        if SecretFilter.contains(text) {
            VStack(alignment: .leading, spacing: 6) {
                Text(revealed ? SecretFilter.unwrap(text) : SecretFilter.redact(text, with: "••••••••"))
                    .font(font).foregroundStyle(color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    Text("Contiene dati riservati").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                    Button(revealed ? "Nascondi" : "Mostra") { revealed.toggle() }
                    Button(copied ? "Copiato ✓" : "Copia segreti") {
                        let secrets = SecretFilter.find(text).map { SecretFilter.unwrap(String(text[$0])) }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secrets.joined(separator: "\n"), forType: .string)
                        copied = true
                    }
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        } else {
            Text(text).font(font).foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pause / resume / stop for a background agent.
struct TaskControls: View {
    let status: TaskInfo.Status
    let control: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if status == .paused {
                ControlButton(icon: "play.fill", help: "Riprendi") { control("resume") }
            } else {
                ControlButton(icon: "pause.fill", help: "Pausa") { control("pause") }
            }
            ControlButton(icon: "stop.fill", help: "Ferma", tint: Color(hex: "#FF6B61")) { control("stop") }
        }
    }
}

struct ControlButton: View {
    let icon: String
    let help: String
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "What Elio is doing now" + a stop button, shown while it works.
struct BusyBar: View {
    let loop: VoiceLoop

    var body: some View {
        if loop.state == .thinking || loop.state == .speaking || !loop.activeTools.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(current).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer()
                Button { loop.stopEverything() } label: {
                    Label("Ferma", systemImage: "stop.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "#FF6B61"))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color(hex: "#FF6B61").opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Ferma Elio e il lavoro in corso (o di' \"basta\")")
            }
        }
    }

    private var current: String {
        if let tool = loop.activeTools.first { return Capability.describe(tool: tool) + "…" }
        return loop.state == .speaking ? "Sta parlando" : "Sta lavorando…"
    }
}
