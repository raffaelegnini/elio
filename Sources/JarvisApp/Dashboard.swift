import JarvisCore
import JarvisVoice
import SwiftUI

/// Mission control: agenda and reminders on the left, the neural core in the middle,
/// workflows, live tool activity and reviews on the right.
struct DashboardView: View {
    let loop: VoiceLoop
    let state: DashboardState
    @State private var input = ""
    @State private var agenda: [AgendaItem] = []
    @State private var agendaNote: String?
    @State private var reminders: [String] = []
    @State private var showNetwork = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if let diff = state.reviewing {
                review(diff)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    leftColumn.frame(width: 300)
                    center.frame(maxWidth: .infinity)
                    rightColumn.frame(width: 340)
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .background(Backdrop(tint: Theme.tint(loop.state)))
        .preferredColorScheme(.dark)
        .task { await refreshLoop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("J.A.R.V.I.S.").font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(5)
                    .foregroundStyle(Theme.text)
                Text("assistente personale · Raffaele").font(Theme.mono).foregroundStyle(Theme.dim)
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
                Button { loop.setMuted(!loop.muted) } label: {
                    Image(systemName: loop.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 30, height: 30)
                        .foregroundStyle(loop.muted ? Theme.tint(.muted) : Theme.cyan)
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
                        Image(systemName: "bell").font(.system(size: 10)).foregroundStyle(Theme.cyan).padding(.top, 2)
                        Text(r).font(.system(size: 12)).foregroundStyle(Theme.text)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private var center: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                if showNetwork {
                    NeuralGraphView(loop: loop)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                } else {
                    NeuralCore(loop: loop)
                }
                Picker("", selection: $showNetwork) {
                    Text("RETE").tag(true)
                    Text("NUCLEO").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(loop.state.label.uppercased())
                .font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(4)
                .foregroundStyle(Theme.tint(loop.state))
            Text(loop.partial.isEmpty ? lastReply : loop.partial)
                .font(.system(size: 14)).foregroundStyle(loop.partial.isEmpty ? Theme.dim : Theme.text)
                .multilineTextAlignment(.center).lineLimit(3)
                .frame(maxWidth: 560, minHeight: 56)
            if let req = loop.confirmations.first {
                ConfirmCard(request: req) { loop.answer(req, approved: $0) }.frame(maxWidth: 520)
            }
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").foregroundStyle(Theme.cyan)
                TextField("Scrivi a Jarvis…", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.text)
                    .onSubmit { loop.submit(text: input); input = "" }
                Text("⌥⌘J per parlare").font(Theme.mono).foregroundStyle(Theme.dim)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            .frame(maxWidth: 560)
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 16) {
            GlassPanel(title: "WORKFLOW", trailing: runningCount > 0 ? "\(runningCount) attivi" : nil) {
                if loop.tasks.isEmpty {
                    Text("Nessun agente al lavoro").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                ForEach(loop.tasks.reversed().prefix(4)) { WorkflowRow(task: $0, expanded: true) }
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
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.cyan)
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
                Text("REVISIONE").font(Theme.mono).tracking(3).foregroundStyle(Theme.cyan)
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

    private var runningCount: Int {
        loop.tasks.filter { $0.status == .running || $0.status == .waitingConfirmation }.count
    }

    private var lastReply: String {
        loop.turns.last(where: { $0.role == "jarvis" || $0.role == "event" })?.text ?? "Di' \"Jarvis…\" oppure scrivi qui sotto."
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
            agendaNote = cal.contains("permesso") ? "Serve il permesso Calendari per Jarvis" : "Agenda non disponibile"
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
            Text(item.time).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan)
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.calendar).font(.system(size: 10)).foregroundStyle(Theme.dim)
                    if item.meet {
                        Label("Meet", systemImage: "video.fill").font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.cyan)
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
                .foregroundStyle(item.running ? Theme.cyan : (item.ok ? Theme.dim : .orange))
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

/// Glass panel with HUD corner brackets.
struct GlassPanel<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Rectangle().fill(Theme.cyan).frame(width: 3, height: 10)
                Text(title).font(Theme.mono).tracking(2.5).foregroundStyle(Theme.dim)
                Spacer()
                if let trailing { Text(trailing).font(Theme.mono).foregroundStyle(Theme.cyan) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .overlay(CornerBrackets().stroke(Theme.cyan.opacity(0.55), lineWidth: 1.2))
    }
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

/// Dark backdrop with a faint grid and a glow that follows Jarvis's state.
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
                ctx.stroke(grid, with: .color(Theme.cyan.opacity(0.035)), lineWidth: 0.5)
            }
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}
