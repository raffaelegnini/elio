import ElioCore
import ElioVoice
import SwiftUI

/// The neural network fills the window; agenda, workflows, activity and the console
/// float above it as frosted glass cards that sharpen on hover.
struct DashboardView: View {
    let loop: VoiceLoop
    let state: DashboardState
    @State private var input = ""
    @State private var agenda: [AgendaItem] = []
    @State private var agendaNote: String?
    @State private var reminders: [String] = []

    var body: some View {
        ZStack {
            Backdrop(tint: Theme.tint(loop.state))
            NeuralGraphView(loop: loop, chrome: EdgeInsets(top: 92, leading: 336, bottom: 170, trailing: 376))

            VStack(spacing: 0) {
                header
                    .background(.ultraThinMaterial.opacity(0.85))
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 0) {
                leftColumn.frame(width: 300)
                Spacer(minLength: 0)
                rightColumn.frame(width: 340)
            }
            .padding(.top, 104).padding(.horizontal, 18).padding(.bottom, 180)

            VStack {
                Spacer()
                if let running = runningTask, state.theater == nil {
                    AgentTheater(loop: loop, taskId: running.id, compact: true)
                        .frame(width: 640, height: 230)
                        .glassCard()
                        .overlay(alignment: .topTrailing) {
                            Text("APRI ↗").font(Theme.mono).foregroundStyle(Theme.accent).padding(12)
                        }
                        .onTapGesture { state.theater = running.id }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                console
            }
            .padding(.bottom, 18)
            .animation(.easeInOut(duration: 0.3), value: runningTask?.id)

            if let id = state.theater {
                VStack(spacing: 0) {
                    HStack {
                        Text("AGENTE · LIVE").font(Theme.mono).tracking(3).foregroundStyle(Theme.accent)
                        Spacer()
                        Button("Chiudi") { state.theater = nil }.buttonStyle(HUDButton(color: Theme.dim))
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                    AgentTheater(loop: loop, taskId: id)
                }
                .glassCard()
                .padding(.horizontal, 80).padding(.top, 100).padding(.bottom, 40)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }

            if let diff = state.reviewing {
                review(diff)
                    .background(.ultraThinMaterial)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await refreshLoop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Brand.shared.dotted).font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(5)
                    .foregroundStyle(Theme.text)
                Text("DNA Factory · assistente personale").font(Theme.mono).foregroundStyle(Theme.dim)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .font(.system(size: 30, weight: .light, design: .monospaced)).foregroundStyle(Theme.text)
                    Text(ctx.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "it_IT"))))
                        .font(Theme.mono).tracking(1.5).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Chip(label: "DAEMON", on: loop.connected)
                Chip(label: loop.muted ? "MIC OFF" : "MIC", on: !loop.muted && loop.state != .off,
                     warn: loop.muted, help: loop.inputDevice)
                Chip(label: "CLAUDE", on: loop.connected)
                Chip(label: "VOCE \(loop.charactersThisSession)", on: true, help: "Caratteri ElevenLabs in questa sessione")
                RoutineButton(title: "BRIEFING", icon: "sunrise.fill") { loop.submit(text: "briefing") }
                RoutineButton(title: "RECAP", icon: "moon.stars.fill") { loop.submit(text: "recap della giornata") }
                HeaderButton(icon: "clock.arrow.circlepath", help: "Archivio (⌥⌘A)") {
                    NotificationCenter.default.post(name: .openArchive, object: nil)
                }
                HeaderButton(icon: "gearshape", help: "Impostazioni (⌘,)") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                Button { loop.setMuted(!loop.muted) } label: {
                    Image(systemName: loop.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 30, height: 30)
                        .foregroundStyle(loop.muted ? Theme.tint(.muted) : Theme.accent)
                        .background(Circle().strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
                .help("⌥⌘M")
            }
        }
        .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 14)
    }

    // MARK: - Columns

    private var leftColumn: some View {
        VStack(spacing: 16) {
            GlassPanel(title: "AGENDA DI OGGI", trailing: agenda.isEmpty ? nil : "\(agenda.count)") {
                if agenda.isEmpty {
                    Text(agendaNote ?? "Nessun impegno").font(.system(size: 12)).foregroundStyle(Theme.dim)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(agenda) { AgendaRow(item: $0) }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            GlassPanel(title: "PROMEMORIA", trailing: reminders.isEmpty ? nil : "\(reminders.count)") {
                if reminders.isEmpty {
                    Text("Nessun promemoria").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                ForEach(reminders, id: \.self) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bell").font(.system(size: 10)).foregroundStyle(Theme.accent).padding(.top, 2)
                        Text(r).font(.system(size: 12)).foregroundStyle(Theme.text)
                    }
                }
            }
            .frame(maxHeight: 200)
            Spacer(minLength: 0)
        }
    }

    private var console: some View {
        VStack(spacing: 10) {
            if let q = loop.questions.first {
                QuestionCard(question: q) { loop.answer(q, text: $0) }.frame(maxWidth: 560)
            }
            if let req = loop.confirmations.first {
                ConfirmCard(request: req) { loop.answer(req, approved: $0) }.frame(maxWidth: 520)
            }
            VStack(spacing: 8) {
                Text(loop.state.label.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(4)
                    .foregroundStyle(Theme.tint(loop.state))
                SecretAwareText(text: loop.partial.isEmpty ? lastReply : loop.partial, font: .system(size: 14),
                                color: loop.partial.isEmpty ? Theme.dim : Theme.text)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .frame(maxWidth: 560)
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
                    TextField("Scrivi a \(Brand.shared.name)…", text: $input)
                        .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.text)
                        .onSubmit { loop.submit(text: input); input = "" }
                    Text("⌥⌘J per parlare").font(Theme.mono).foregroundStyle(Theme.dim)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            }
            .padding(16)
            .frame(width: 600)
            .glassCard()
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 16) {
            GlassPanel(title: "WORKFLOW", trailing: runningCount > 0 ? "\(runningCount) attivi" : nil) {
                if loop.tasks.isEmpty {
                    Text("Nessun agente al lavoro").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                ForEach(loop.tasks.reversed().prefix(4)) { t in
                    WorkflowRow(task: t, expanded: true)
                        .contentShape(Rectangle())
                        .onTapGesture { state.theater = t.id }
                }
            }
            .frame(maxHeight: 260)
            GlassPanel(title: "ATTIVITÀ NEURALE", trailing: nil) {
                if loop.activity.isEmpty {
                    Text("In attesa…").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(loop.activity.reversed().prefix(14)) { ActivityRow(item: $0) }
                    }
                }
                .scrollIndicators(.never)
            }
            if !loop.diffs.isEmpty {
                GlassPanel(title: "DA REVISIONARE", trailing: "\(loop.diffs.count)") {
                    ForEach(Array(loop.diffs.prefix(3).enumerated()), id: \.offset) { _, d in
                        Button { state.reviewing = d } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
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
        }
    }

    private func review(_ diff: DiffPayload) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("REVISIONE").font(Theme.mono).tracking(3).foregroundStyle(Theme.accent)
                Spacer()
                Button("Chiudi") { state.reviewing = nil }.buttonStyle(HUDButton(color: Theme.dim))
            }
            .padding(.horizontal, 24).padding(.bottom, 10)
            DiffView(payload: diff)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private var runningTask: TaskInfo? {
        loop.tasks.last { $0.status == .running || $0.status == .waitingConfirmation }
    }

    private var runningCount: Int {
        loop.tasks.filter { $0.status == .running || $0.status == .waitingConfirmation }.count
    }

    private var lastReply: String {
        loop.turns.last(where: { $0.role == "elio" || $0.role == "event" })?.text ?? "Di' \"\(Brand.shared.name)…\" oppure scrivi qui sotto."
    }

    // MARK: - Data

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(120))
        }
    }

    private func refresh() async {
        let (cal, calError) = await loop.callTool("calendar_events")
        if calError {
            agenda = []
            agendaNote = cal.contains("permesso") ? "Serve il permesso Calendari per Elio" : "Agenda non disponibile"
        } else {
            agenda = AgendaItem.parse(cal)
            agendaNote = nil
        }
        let (rem, remError) = await loop.callTool("list_reminders")
        reminders = remError ? [] : rem.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
    }
}

// MARK: - Pieces

struct AgendaItem: Identifiable {
    let id = UUID()
    let time: String
    let title: String
    let calendar: String
    let meet: Bool

    /// Parses `calendar_events` lines: "- 09:30–10:00 Title [Calendar] (Google Meet)".
    static func parse(_ text: String) -> [AgendaItem] {
        text.split(separator: "\n").compactMap { raw in
            guard raw.hasPrefix("- ") else { return nil }
            var line = String(raw.dropFirst(2))
            let meet = line.contains("(Google Meet)")
            line = line.replacingOccurrences(of: " (Google Meet)", with: "")
            var calendar = ""
            if let open = line.lastIndex(of: "["), let close = line.lastIndex(of: "]"), open < close {
                calendar = String(line[line.index(after: open)..<close])
                line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            }
            let time: String
            if line.hasPrefix("tutto il giorno") {
                time = "tutto il giorno"
                line = String(line.dropFirst("tutto il giorno".count)).trimmingCharacters(in: .whitespaces)
            } else {
                let parts = line.split(separator: " ", maxSplits: 1)
                time = parts.first.map(String.init) ?? ""
                line = parts.count > 1 ? String(parts[1]) : ""
            }
            return AgendaItem(time: time, title: line, calendar: calendar, meet: meet)
        }
    }
}

private struct AgendaRow: View {
    let item: AgendaItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.time).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.calendar).font(.system(size: 10)).foregroundStyle(Theme.dim)
                    if item.meet {
                        Label("Meet", systemImage: "video.fill").font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let item: VoiceLoop.ToolActivity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Capability.of(tool: item.name).icon)
                .font(.system(size: 10)).frame(width: 14)
                .foregroundStyle(item.running ? Theme.accent : (item.ok ? Theme.dim : .orange))
            Text(Capability.describe(tool: item.name)).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            if item.running {
                ProgressView().controlSize(.mini)
            } else {
                Text(item.ms.map { "\($0)ms" } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                Image(systemName: item.ok ? "checkmark" : "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(item.ok ? .green : .orange)
            }
            Text(item.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim.opacity(0.7))
        }
    }
}

/// Frosted glass panel with HUD corner brackets.
struct GlassPanel<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Rectangle().fill(Theme.accent).frame(width: 3, height: 10)
                Text(title).font(Theme.mono).tracking(2.5).foregroundStyle(Theme.dim)
                Spacer()
                if let trailing { Text(trailing).font(Theme.mono).foregroundStyle(Theme.accent) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
        .overlay(CornerBrackets().stroke(Theme.accent.opacity(0.55), lineWidth: 1.2))
    }
}

/// See-through over the network at rest, more solid while the pointer is on it.
private struct GlassCard: ViewModifier {
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .opacity(hover ? 0.95 : 0.6)
            )
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg.opacity(hover ? 0.55 : 0.25)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Theme.accent.opacity(0.35) : Theme.line))
            .opacity(hover ? 1 : 0.88)
            .scaleEffect(hover ? 1.01 : 1)
            .shadow(color: .black.opacity(0.35), radius: hover ? 18 : 8, y: 6)
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}

private struct CornerBrackets: Shape {
    func path(in r: CGRect) -> Path {
        let l: CGFloat = 12
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + l * dx, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + l * dy))
        }
        return p
    }
}

private struct Chip: View {
    let label: String
    let on: Bool
    var warn = false
    var help: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: on ? 4 : 0)
            Text(label).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(1.2)
                .foregroundStyle(Theme.text.opacity(0.85))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.line))
        .help(help)
    }

    private var color: Color { warn ? Theme.tint(.muted) : (on ? .green : .red) }
}

/// Dark backdrop with a faint grid and a glow that follows Elio's state.
private struct Backdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Theme.bg
            Canvas { ctx, size in
                let step: CGFloat = 28
                var grid = Path()
                stride(from: 0, through: size.width, by: step).forEach { x in
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: 0, through: size.height, by: step).forEach { y in
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(Theme.accent.opacity(0.035)), lineWidth: 0.5)
            }
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

private struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 30, height: 30).foregroundStyle(Theme.accent)
                .background(Circle().strokeBorder(Theme.line))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RoutineButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).tracking(1.5)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(hover ? Color.black : Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(hover ? Theme.accent : Theme.accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
