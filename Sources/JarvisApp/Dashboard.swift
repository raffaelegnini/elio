import JarvisCore
import JarvisVoice
import SwiftUI

/// Full window: the brain, live conversation and system status.
/// Workflows and the morning brief plug in here in later phases.
struct DashboardView: View {
    let loop: VoiceLoop
    let state: DashboardState
    @State private var input = ""

    var body: some View {
        HStack(spacing: 0) {
            if let diff = state.reviewing {
                VStack(spacing: 0) {
                    HStack {
                        Text("REVISIONE").font(Theme.mono).tracking(3).foregroundStyle(Theme.cyan)
                        Spacer()
                        Button("Chiudi") { state.reviewing = nil }.buttonStyle(HUDButton(color: Theme.dim))
                    }
                    .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)
                    DiffView(payload: diff)
                }
                .frame(maxWidth: .infinity)
            } else {
                brain
            }

            Rectangle().fill(Theme.line).frame(width: 1)
            sidebar
        }
        .background(
            ZStack {
                Theme.bg
                RadialGradient(colors: [Theme.tint(loop.state).opacity(0.10), .clear],
                               center: .init(x: 0.33, y: 0.45), startRadius: 0, endRadius: 520)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
    }

    private var brain: some View {
            VStack(spacing: 18) {
                OrbView(state: loop.state, level: loop.level)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { loop.activate() }
                Text(loop.state.label.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(4)
                    .foregroundStyle(Theme.tint(loop.state))
                Text(loop.partial.isEmpty ? " " : loop.partial)
                    .font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(2)
                    .frame(height: 44)
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.cyan)
                    TextField("Scrivi a Jarvis…", text: $input)
                        .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.text)
                        .onSubmit { loop.submit(text: input); input = "" }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                .frame(maxWidth: 560)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
    }

    private var sidebar: some View {
            VStack(alignment: .leading, spacing: 20) {
                if let req = loop.confirmations.first {
                    ConfirmCard(request: req) { loop.answer(req, approved: $0) }
                }
                Section(title: "SISTEMA") {
                    StatRow(name: "Daemon", value: loop.connected ? "online" : "offline", ok: loop.connected)
                    StatRow(name: "Microfono", value: loop.state == .off ? "spento" : "attivo", ok: loop.state != .off)
                    StatRow(name: "Wake word", value: loop.alwaysListening ? "\"Jarvis\"" : "solo ⌥⌘J", ok: true)
                    StatRow(name: "Latenza media", value: averageLatency, ok: true)
                    StatRow(name: "Voce (sessione)", value: "\(loop.charactersThisSession) caratteri", ok: true)
                }
                Section(title: "WORKFLOW") {
                    if loop.tasks.isEmpty {
                        Text("Nessun workflow").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                    ForEach(loop.tasks.reversed().prefix(5)) { WorkflowRow(task: $0, expanded: true) }
                }
                if !loop.diffs.isEmpty {
                    Section(title: "DA REVISIONARE") {
                        ForEach(Array(loop.diffs.enumerated()), id: \.offset) { _, d in
                            Button { state.reviewing = d } label: {
                                HStack {
                                    Image(systemName: "arrow.triangle.branch")
                                    Text(d.title).lineLimit(1)
                                    Spacer()
                                    Text((d.repo as NSString).lastPathComponent).foregroundStyle(Theme.dim)
                                }
                                .font(.system(size: 12)).foregroundStyle(Theme.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section(title: "CONVERSAZIONE") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(loop.turns.reversed()) { TurnRow(turn: $0) }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(24)
            .padding(.top, 10)
            .frame(width: 380)
    }

    private var averageLatency: String {
        let values = loop.turns.compactMap(\.latencyMs)
        guard !values.isEmpty else { return "—" }
        return "\(values.reduce(0, +) / values.count) ms"
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.mono).tracking(2.5).foregroundStyle(Theme.dim)
            content
        }
    }
}

private struct StatRow: View {
    let name: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Text(name).font(.system(size: 12)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(ok ? Theme.text : .orange)
        }
    }
}
