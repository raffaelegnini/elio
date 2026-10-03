import ElioCore
import ElioVoice
import SwiftUI

/// What an agent is doing, in words: its own plan step first ("Scrivo i test dell'export"), else the
/// description of the command it runs, else what the last tool means. Never a raw shell line.
enum AgentActivity {
    static func now(_ t: TaskInfo, log: [TaskLogEntry]) -> String {
        if t.status == .waitingConfirmation { return "Aspetta la tua conferma" }
        if t.status == .paused { return "In pausa" }
        if let step = t.plan?.first(where: { $0.status == "in_progress" }) { return step.active ?? step.text }
        if let last = log.last(where: { $0.kind != .output && $0.kind != .say }) {
            switch last.kind {
            case .command:
                let d = last.body.trimmingCharacters(in: .whitespaces)
                return d.isEmpty ? "Esegue un comando" : d.prefix(1).uppercased() + d.dropFirst()
            case .edit: return "Modifica \(file(last.title))"
            case .write: return "Scrive \(file(last.title))"
            case .read: return "Legge \(file(last.title))"
            case .search: return "Cerca nel codice"
            case .ask: return "Fa una domanda"
            default: break
            }
        }
        if let said = t.lastMessage, !said.isEmpty { return String(said.prefix(140)) }
        return t.isActive ? "Si mette al lavoro…" : (t.summary.map { String($0.prefix(140)) } ?? "")
    }

    static func file(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Completed / total steps of the agent's plan.
    static func progress(_ t: TaskInfo) -> (done: Int, total: Int)? {
        guard let plan = t.plan, !plan.isEmpty else { return nil }
        return (plan.filter { $0.status == "completed" }.count, plan.count)
    }
}

/// Mission control for a team of agents: on top what each one is doing right now and what has been done,
/// below the agents with their plans, on the side the board, Elio's decisions and the costs.
struct SquadView: View {
    let loop: VoiceLoop
    let state: DashboardState
    /// Off only for snapshots (ImageRenderer doesn't draw scroll view content).
    var scrolls = true
    @State private var selected: String?
    @State private var sideTab: SideTab = .board
    @State private var showBrief = false

    enum SideTab: String, CaseIterable { case board = "Bacheca", decisions = "Decisioni", costs = "Costi" }

    private var squad: SquadInfo? {
        if let id = selected, let s = loop.squads.first(where: { $0.id == id }) { return s }
        return loop.squads.last(where: { $0.endedAt == nil }) ?? loop.squads.last
    }

    /// Lead first, then scout, then members in start order.
    private func members(_ s: SquadInfo) -> [TaskInfo] {
        let all = loop.tasks.filter { $0.squad == s.id }
        // One card per agent: a resumed agent has a new task id; keep the latest run.
        var byName: [String: TaskInfo] = [:]
        for t in all.sorted(by: { $0.startedAt < $1.startedAt }) { byName[t.member ?? t.id] = t }
        // Stable order (colours follow it): lead, scout, then members by start time and name.
        return byName.values.sorted {
            (rank($0), $0.startedAt.timeIntervalSince1970, $0.member ?? "") < (rank($1), $1.startedAt.timeIntervalSince1970, $1.member ?? "")
        }
    }

    private func rank(_ t: TaskInfo) -> Int { t.kind == "lead" ? 0 : t.kind == "scout" ? 1 : 2 }

    private func events(_ s: SquadInfo) -> [WorkflowEvent] { loop.workflowEvents[s.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let s = squad {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        hero(s)
                        if let brief = s.brief { briefCard(brief) }
                        agents(s)
                    }
                    side(s).frame(width: 340)
                }
                .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 4)
            } else {
                empty
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("MISSIONE").font(Theme.mono).tracking(3).foregroundStyle(Theme.accent)
            if let s = squad {
                Text(s.goal).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                pill(s.endedAt == nil ? "IN CORSO" : "FINITA", s.endedAt == nil ? .green : Theme.dim)
                let ms = members(s)
                Group {
                    stat(Duration.seconds((s.endedAt ?? Date()).timeIntervalSince(s.startedAt))
                        .formatted(.units(allowed: [.hours, .minutes], width: .narrow)), "clock")
                    stat("\(ms.filter(\.isActive).count)/\(ms.count) attivi", "person.3")
                    stat(String(format: "$%.2f", ms.compactMap(\.costUSD).reduce(0, +)), "dollarsign.circle")
                    stat(UsageMeter.format(ms.reduce(0) { $0 + ($1.tokensIn ?? 0) + ($1.tokensOut ?? 0) }), "bolt.fill")
                }
            }
            Spacer()
            if loop.squads.count > 1 {
                Menu {
                    ForEach(loop.squads.reversed()) { s in Button(s.goal) { selected = s.id } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let s = squad {
                Button("Report") { Task { _ = await loop.callTool("workflow_report", ["id": s.id]) } }
                    .buttonStyle(HUDButton(color: Theme.accent))
                if s.endedAt == nil {
                    Button("Ferma") { for m in members(s) where m.isActive { loop.controlTask(m.id, "stop") } }
                        .buttonStyle(HUDButton(color: Color(hex: "#FF6B61")))
                }
            }
            Button("Chiudi") { state.squadMode = false }.buttonStyle(HUDButton(color: Theme.dim))
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    private func stat(_ value: String, _ icon: String) -> some View {
        Label(value, systemImage: icon).font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.dim).labelStyle(.titleAndIcon)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.sequence").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            Text("Nessuna missione in corso").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
            Text("Chiedi a \(Brand.shared.name), per esempio: \"metti su una squadra che aggiunga l'export CSV: uno sul backend e uno sul frontend\". Usala per lavori grandi e parallelizzabili: ogni agente consuma crediti.")
                .font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Hero: now / done

    private func hero(_ s: SquadInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("ADESSO", trailing: nil)
                let active = members(s).filter(\.isActive)
                if active.isEmpty {
                    Text(s.endedAt == nil ? "In attesa…" : "Tutti hanno finito.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                ForEach(active) { m in nowRow(m) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("FATTO", trailing: nil)
                let done = doneFeed(s)
                if done.isEmpty { Text("Ancora niente: i passi completati compaiono qui.").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                scrollable {
                    VStack(alignment: .leading, spacing: 7) { ForEach(done.prefix(scrolls ? 60 : 7), id: \.id) { doneRow($0) } }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
            .clipped()
        }
        .frame(height: 240)
    }

    private func nowRow(_ m: TaskInfo) -> some View {
        let waiting = m.status == .waitingConfirmation
        let color = AgentPalette.color(m, in: members(squad!))
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
                .phaseAnimator([0.35, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.member ?? "agente").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color)
                    if let p = AgentActivity.progress(m) {
                        Text("passo \(min(p.done + 1, p.total))/\(p.total)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                }
                Text(AgentActivity.now(m, log: loop.taskLogs[m.id] ?? []))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(waiting ? Color(hex: "#FF9F43") : Theme.text)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.theater = m.id }
    }

    private struct DoneItem: Identifiable { let id: String; let at: Date; let who: String; let text: String; let kind: String }

    /// Completed plan steps, finished agents, decisions taken for the user and taste corrections — newest first.
    private func doneFeed(_ s: SquadInfo) -> [DoneItem] {
        var items: [DoneItem] = []
        for m in members(s) {
            for (i, step) in (m.plan ?? []).enumerated() where step.status == "completed" {
                items.append(DoneItem(id: "\(m.id)-\(i)", at: step.doneAt ?? m.startedAt, who: m.member ?? "agente", text: step.text, kind: "step"))
            }
        }
        for e in events(s) {
            switch e.kind {
            case .agentDone where !e.text.isEmpty:
                items.append(DoneItem(id: "e\(e.id)-\(e.ts.timeIntervalSince1970)", at: e.ts, who: e.actor, text: e.text, kind: "done"))
            case .autoDecision:
                items.append(DoneItem(id: "e\(e.id)-\(e.ts.timeIntervalSince1970)", at: e.ts, who: "elio", text: "Ha deciso per te: \(e.text)", kind: "decision"))
            case .tasteCorrection:
                let agent = (try? JSONSerialization.jsonObject(with: Data((e.data ?? "{}").utf8)) as? [String: Any])?["agent"] as? String ?? ""
                items.append(DoneItem(id: "e\(e.id)-\(e.ts.timeIntervalSince1970)", at: e.ts, who: "elio",
                                      text: "Ha chiesto a \(agent) di correggere qualcosa che non ti piacerebbe", kind: "taste"))
            case .agentFailed:
                items.append(DoneItem(id: "e\(e.id)-\(e.ts.timeIntervalSince1970)", at: e.ts, who: e.actor, text: "Si è fermato con un errore", kind: "fail"))
            default: break
            }
        }
        return items.sorted { $0.at > $1.at }
    }

    private func doneRow(_ d: DoneItem) -> some View {
        let icon = switch d.kind {
        case "step": "checkmark.circle.fill"
        case "done": "flag.checkered"
        case "decision": "sparkles"
        case "taste": "paintbrush.pointed"
        default: "exclamationmark.triangle.fill"
        }
        let tint = d.kind == "fail" ? Color(hex: "#FF6B61") : d.kind == "taste" ? Color(hex: "#FF9F43") : Theme.accent
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(d.who).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
                    Text(d.at, format: .dateTime.hour().minute()).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.dim.opacity(0.7))
                }
                Text(d.text).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(3)
            }
        }
    }

    private func briefCard(_ brief: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.2)) { showBrief.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showBrief ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("BRIEF DELLO SCOUT").font(Theme.mono).tracking(2)
                    Text("· il codice esplorato una volta per tutti").font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            if showBrief {
                scrollable { MarkdownText(text: brief).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
    }

    // MARK: Agents

    private func agents(_ s: SquadInfo) -> some View {
        let grid = LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
            ForEach(members(s)) { m in
                AgentCard(loop: loop, member: m, color: AgentPalette.color(m, in: members(s))) { state.theater = m.id }
            }
        }
        return scrollable { grid.padding(1) }
    }

    // MARK: Side: board, decisions, costs

    private func side(_ s: SquadInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(SideTab.allCases, id: \.self) { t in
                    Button { sideTab = t } label: {
                        Text(t.rawValue).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(sideTab == t ? Theme.accent.opacity(0.18) : .clear))
                            .foregroundStyle(sideTab == t ? Theme.accent : Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            switch sideTab {
            case .board: board(s)
            case .decisions: decisions(s)
            case .costs: costs(s)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
    }

    private func board(_ s: SquadInfo) -> some View {
        let msgs = loop.squadMessages.filter { $0.squad == s.id }
        return ScrollViewReader { proxy in
            scrollable {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(msgs) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(m.from).foregroundStyle(m.from == "elio" ? Theme.accent : Theme.text)
                                Image(systemName: "arrow.right").font(.system(size: 8))
                                Text(m.to).foregroundStyle(m.to == "elio" ? Theme.accent : Theme.dim)
                                Spacer()
                                Text(m.at, format: .dateTime.hour().minute()).foregroundStyle(Theme.dim)
                            }
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Text(m.text).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(8)
                                .textSelection(.enabled)
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(m.to == "elio" ? 0.07 : 0.035)))
                        .id(m.id)
                    }
                    if msgs.isEmpty { Text("Nessun messaggio.").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                }
            }
            .onChange(of: msgs.count) { if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
    }

    private func decisions(_ s: SquadInfo) -> some View {
        let wanted: Set<WorkflowEvent.Kind> = [.autoDecision, .question, .answer, .confirm, .confirmResult, .tasteViolation, .tasteCorrection]
        let list = events(s).filter { wanted.contains($0.kind) }.reversed()
        return scrollable {
            VStack(alignment: .leading, spacing: 8) {
                if list.isEmpty { Text("Nessuna decisione finora.").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                ForEach(Array(list), id: \.ts) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(label(e.kind)).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                                .foregroundStyle(e.kind == .autoDecision ? Theme.accent : e.kind == .tasteViolation || e.kind == .tasteCorrection ? Color(hex: "#FF9F43") : Theme.dim)
                            Spacer()
                            Text(e.ts, format: .dateTime.hour().minute()).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                        Text("\(e.actor): \(e.text)").font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(5)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                }
            }
        }
    }

    private func label(_ k: WorkflowEvent.Kind) -> String {
        switch k {
        case .autoDecision: "DECISO DA ELIO"
        case .question: "DOMANDA"
        case .answer: "RISPOSTA"
        case .confirm: "CONFERMA"
        case .confirmResult: "ESITO"
        case .tasteViolation: "GUSTO VIOLATO"
        case .tasteCorrection: "CORREZIONE"
        default: k.rawValue.uppercased()
        }
    }

    private func costs(_ s: SquadInfo) -> some View {
        let ms = members(s)
        let max = ms.compactMap(\.costUSD).max() ?? 0
        let total = ms.compactMap(\.costUSD).reduce(0, +)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(format: "$%.2f", total)).font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                Text("equivalente API").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            ForEach(ms) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(m.member ?? "agente").font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AgentPalette.color(m, in: ms))
                        Spacer()
                        Text(String(format: "$%.2f · %@", m.costUSD ?? 0, UsageMeter.format((m.tokensIn ?? 0) + (m.tokensOut ?? 0))))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                    GeometryReader { geo in
                        Capsule().fill(Theme.accent.opacity(0.75))
                            .frame(width: max > 0 ? geo.size.width * (m.costUSD ?? 0) / max : 0)
                    }
                    .frame(height: 4)
                }
            }
            Text("Il costo arriva quando ogni agente chiude un turno. Squadre più piccole e lo scout iniziale riducono il consumo.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String, trailing: String?) -> some View {
        HStack {
            Rectangle().fill(Theme.accent).frame(width: 3, height: 10)
            Text(text).font(Theme.mono).tracking(2.5).foregroundStyle(Theme.dim)
            Spacer()
            if let trailing { Text(trailing).font(Theme.mono).foregroundStyle(Theme.accent) }
        }
    }

    @ViewBuilder private func scrollable(@ViewBuilder _ content: () -> some View) -> some View {
        if scrolls { ScrollView { content() }.scrollIndicators(.never) } else { content() }
    }
}

/// One stable colour per agent of a mission (same order as the report).
enum AgentPalette {
    static let colors = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"].map { Color(hex: $0) }

    static func color(_ t: TaskInfo, in all: [TaskInfo]) -> Color {
        let i = all.firstIndex { $0.member == t.member } ?? 0
        return colors[i % colors.count]
    }
}

private struct AgentCard: View {
    let loop: VoiceLoop
    let member: TaskInfo
    let color: Color
    let open: () -> Void
    @State private var hover = false

    private var statusText: (String, Color) {
        switch member.status {
        case .running: ("AL LAVORO", .green)
        case .waitingConfirmation: ("ASPETTA TE", Color(hex: "#FF9F43"))
        case .paused: ("IN PAUSA", Theme.dim)
        case .done: ("FINITO", Theme.accent)
        case .failed: ("ERRORE", Color(hex: "#FF6B61"))
        case .cancelled: ("FERMATO", Theme.dim)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(member.member ?? "agente").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(member.role ?? "").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer()
                if let model = member.model, !model.contains("opus") {
                    Text(model.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08))).foregroundStyle(Theme.dim)
                        .help("Micro-modifica: gira sul modello leggero")
                }
                Text(statusText.0).font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(statusText.1)
            }
            if let p = AgentActivity.progress(member) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(color).frame(width: geo.size.width * Double(p.done) / Double(max(p.total, 1)))
                    }
                }
                .frame(height: 3)
            }
            if let plan = member.plan, !plan.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(plan.prefix(7).enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "circle.inset.filled" : "circle")
                                .font(.system(size: 9)).foregroundStyle(step.status == "pending" ? Theme.dim : color).padding(.top, 2)
                            Text(step.status == "in_progress" ? (step.active ?? step.text) : step.text)
                                .font(.system(size: 11, weight: step.status == "in_progress" ? .semibold : .regular))
                                .foregroundStyle(step.status == "completed" ? Theme.dim : Theme.text).lineLimit(1)
                        }
                    }
                }
            } else {
                Text(member.isActive ? AgentActivity.now(member, log: loop.taskLogs[member.id] ?? []) : (member.summary ?? ""))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(4)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Label(UsageMeter.format((member.tokensIn ?? 0) + (member.tokensOut ?? 0)), systemImage: "bolt.fill")
                if let c = member.costUSD { Text(String(format: "$%.2f", c)) }
                Spacer()
                if member.status == .running || member.status == .waitingConfirmation {
                    Button { loop.controlTask(member.id, "pause") } label: { Image(systemName: "pause.fill") }.buttonStyle(.plain).help("Pausa")
                    Button { loop.controlTask(member.id, "stop") } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain).help("Ferma")
                } else if member.status == .paused {
                    Button { loop.controlTask(member.id, "resume") } label: { Image(systemName: "play.fill") }.buttonStyle(.plain).help("Riprendi")
                }
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .padding(12)
        .frame(height: 200)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(member.isActive ? 0.5 : 0.15)))
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help("Apri l'attività live")
    }
}

/// Token pill in the header: today's usage and the current 5-hour window; details on hover.
struct UsagePill: View {
    let loop: VoiceLoop

    var body: some View {
        let u = loop.usage
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
            Text(u.map { UsageMeter.format($0.window5h.fresh) } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
            Text("5H").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .fixedSize()
        .padding(.horizontal, 10).frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.line))
        .help(tooltip(u))
    }

    private func tooltip(_ u: UsageSnapshot?) -> String {
        guard let u else { return "Consumo token: in caricamento" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let reset = u.windowStart.map { "si azzera alle \(f.string(from: $0.addingTimeInterval(5 * 3600)))" } ?? "nessuna finestra attiva"
        return """
        Token Claude su questo Mac (tutte le sessioni)
        Finestra 5 ore: \(UsageMeter.format(u.window5h.fresh)) nuovi + \(UsageMeter.format(u.window5h.cacheRead)) letti dalla cache · \(u.window5h.messages) risposte · \(reset)
        Oggi: \(UsageMeter.format(u.today.fresh)) nuovi (generati \(UsageMeter.format(u.today.output))) + \(UsageMeter.format(u.today.cacheRead)) dalla cache
        Di cui Elio (conversazione): \(UsageMeter.format(u.elioToday.fresh)) nuovi
        Agenti in background: $\(String(format: "%.2f", u.agentsCostUSD)) equivalenti API
        """
    }
}
