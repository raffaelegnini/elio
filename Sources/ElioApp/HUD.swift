import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// Floating, non-activating panel in the top-right corner. Appears when Elio is engaged.
@MainActor
final class HUDController {
    private var panel: HUDPanel?
    private var hideTask: Task<Void, Never>?
    private var pinned = false

    func attach(_ loop: VoiceLoop, openReview: @escaping (DiffPayload) -> Void) {
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560))
        let host = NSHostingView(rootView: HUDView(loop: loop, close: { [weak self] in self?.hide() }, openReview: openReview))
        host.wantsLayer = true
        host.layer?.cornerRadius = 22
        host.layer?.masksToBounds = true
        panel.contentView = host
        self.panel = panel
    }

    func show(pinned: Bool) {
        guard let panel else { return }
        hideTask?.cancel()
        self.pinned = self.pinned || pinned
        if !panel.isVisible {
            position(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
    }

    func scheduleHide(after seconds: Double) {
        guard !pinned else { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { hide() }
        }
    }

    func hide() {
        pinned = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in panel.orderOut(nil) }
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 12))
    }
}

final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}

struct HUDView: View {
    let loop: VoiceLoop
    let close: () -> Void
    let openReview: (DiffPayload) -> Void
    @State private var input = ""
    @State private var attachments = PendingAttachments()

    var body: some View {
        VStack(spacing: 0) {
            header
            LiveOrb(loop: loop)
                .frame(height: 210)
                .contentShape(Circle())
                .onTapGesture { loop.activate() }
            status
            activity
            conversation
            inputBar
        }
        .background(
            ZStack {
                VisualEffect()
                Theme.panel
                LinearGradient(colors: [Theme.tint(loop.state).opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.line, lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(loop.connected ? Theme.accent : .red).frame(width: 6, height: 6)
                .shadow(color: loop.connected ? Theme.accent : .red, radius: 4)
            Text(Brand.shared.dotted).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(3)
                .foregroundStyle(Theme.text)
            Spacer()
            Text(loop.charactersThisSession > 0 ? "\(loop.charactersThisSession) CHR" : "")
                .font(Theme.mono).foregroundStyle(Theme.dim)
            Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: {
                Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help("Impostazioni")
            Button { loop.setMuted(!loop.muted) } label: {
                Image(systemName: loop.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(loop.muted ? Theme.tint(.muted) : Theme.dim)
            }
            .buttonStyle(.plain)
            .help(loop.muted ? "Riattiva microfono (⌥⌘M)" : "Silenzia microfono (⌥⌘M)")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 14)
    }

    private var status: some View {
        VStack(spacing: 6) {
            Text(loop.state.label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2.5)
                .foregroundStyle(Theme.tint(loop.state))
            Text(loop.partial.isEmpty ? hint : loop.partial)
                .font(.system(size: 13)).foregroundStyle(loop.partial.isEmpty ? Theme.dim : Theme.text)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(minHeight: 34)
            if let err = loop.lastError {
                Text(err).font(Theme.mono).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
    }

    /// Pending confirmations, running workflows and a fresh diff, above the conversation.
    @ViewBuilder
    private var activity: some View {
        VStack(spacing: 8) {
            BusyBar(loop: loop)
            if let q = loop.questions.first {
                QuestionCard(question: q) { loop.answer(q, text: $0) }
            }
            if let req = loop.confirmations.first {
                ConfirmCard(request: req) { loop.answer(req, approved: $0) }
            }
            let running = loop.tasks.filter { [.running, .waitingConfirmation, .paused].contains($0.status) }
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WORKFLOW ATTIVI").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
                    ForEach(running) { t in WorkflowRow(task: t, control: { loop.controlTask(t.id, $0) }) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
            }
            if let diff = loop.diffs.first {
                Button { openReview(diff) } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                        Text("Diff pronto: \(diff.title)").lineLimit(1)
                        Spacer()
                        Text("Apri revisione").fontWeight(.semibold)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.2), value: loop.confirmations.count)
    }

    private var hint: String {
        if loop.muted { return "Microfono spento — ⌥⌘M per riattivarlo" }
        return loop.alwaysListening ? "Di' \"\(Brand.shared.name)…\" oppure ⌥⌘J" : "Premi ⌥⌘J per parlare"
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(loop.turns.suffix(12)) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: loop.turns.last?.text) {
                if let id = loop.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.15)))
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentChips(pending: attachments)
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                TextField("Scrivi a \(Brand.shared.name)…", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .onSubmit {
                        loop.submit(text: input, attachments: attachments.take())
                        input = ""
                    }
                AttachButton(pending: attachments)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .onDrop(of: [.fileURL], isTargeted: nil) { attachments.drop($0) }
        .padding(12)
    }
}

struct TurnRow: View {
    let turn: VoiceLoop.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(Theme.mono).tracking(1.5).foregroundStyle(color)
                if let ms = turn.latencyMs, let route = turn.route {
                    Text("· \(route.rawValue) \(ms)ms").font(Theme.mono).foregroundStyle(Theme.dim.opacity(0.7))
                }
            }
            if turn.role == "card" {
                MarkdownText(text: turn.text)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            } else {
                SecretAwareText(text: turn.text.isEmpty ? "…" : turn.text,
                                color: turn.role == "user" ? Theme.dim : Theme.text)
            }
        }
    }

    private var label: String {
        switch turn.role {
        case "user": "TU"
        case "event": "AVVISO"
        case "card": "SCHEDA"
        default: Brand.shared.name.uppercased()
        }
    }

    private var color: Color {
        switch turn.role {
        case "user": Theme.dim
        case "event": .orange
        default: Theme.accent
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
