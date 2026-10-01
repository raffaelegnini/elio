import ElioCore
import ElioVoice
import SwiftUI

/// Squad mode: every agent of the team as a live card, the board where they talk to each other
/// and to Elio, and what the team is costing in tokens.
struct SquadView: View {
    let loop: VoiceLoop
    let state: DashboardState
    /// Off only for snapshots (ImageRenderer doesn't draw scroll view content).
    var scrolls = true
    @State private var selected: String?

    private var squad: SquadInfo? {
        if let id = selected, let s = loop.squads.first(where: { $0.id == id }) { return s }
        return loop.squads.last(where: { $0.endedAt == nil }) ?? loop.squads.last
    }

    private func members(_ s: SquadInfo) -> [TaskInfo] {
        loop.tasks.filter { $0.squad == s.id }.sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let s = squad {
                HStack(alignment: .top, spacing: 14) {
                    let grid = LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(members(s)) { m in MemberCard(loop: loop, member: m) { state.theater = m.id } }
                    }
                    .padding(2)
                    if scrolls { ScrollView { grid } } else { VStack { grid; Spacer(minLength: 0) } }
                    board(s).frame(width: 340)
                }
                .padding(16)
                footer(s)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.3.sequence").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Nessuna squadra al lavoro").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                    Text("Chiedi a \(Brand.shared.name), per esempio: \"metti su una squadra che aggiunga l'export CSV: uno sul backend, uno sul frontend e uno sui test\".")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("SQUADRA").font(Theme.mono).tracking(3).foregroundStyle(Theme.accent)
            if let s = squad {
                Text(s.goal).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(s.endedAt == nil ? "IN CORSO" : "FINITA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill((s.endedAt == nil ? Color.green : Theme.dim).opacity(0.18)))
                    .foregroundStyle(s.endedAt == nil ? .green : Theme.dim)
            }
            Spacer()
            if loop.squads.count > 1 {
                Menu {
                    ForEach(loop.squads.reversed()) { s in Button(s.goal) { selected = s.id } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let s = squad, s.endedAt == nil {
                Button("Ferma squadra") { for m in members(s) where m.isActive { loop.controlTask(m.id, "stop") } }
                    .buttonStyle(HUDButton(color: Color(hex: "#FF6B61")))
            }
            Button("Chiudi") { state.squadMode = false }.buttonStyle(HUDButton(color: Theme.dim))
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func board(_ s: SquadInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACHECA").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
            if !scrolls {
                VStack(alignment: .leading, spacing: 8) { messages(s) }
                Spacer(minLength: 0)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        messages(s)
                    }
                }
                .onChange(of: loop.squadMessages.count) {
                    if let last = loop.squadMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
    }

    @ViewBuilder
    private func messages(_ s: SquadInfo) -> some View {
                        ForEach(loop.squadMessages.filter { $0.squad == s.id }) { m in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(m.from).foregroundStyle(m.from == "elio" ? Theme.accent : Theme.text)
                                    Image(systemName: "arrow.right").font(.system(size: 8))
                                    Text(m.to).foregroundStyle(m.to == "elio" ? Theme.accent : Theme.dim)
                                    Spacer()
                                    Text(m.at, format: .dateTime.hour().minute()).foregroundStyle(Theme.dim)
                                }
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Text(m.text).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9))
                                    .textSelection(.enabled)
                            }
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(m.to == "elio" ? 0.07 : 0.035)))
                            .id(m.id)
                        }
    }

    private func footer(_ s: SquadInfo) -> some View {
        let ms = members(s)
        let tokIn = ms.compactMap(\.tokensIn).reduce(0, +), tokOut = ms.compactMap(\.tokensOut).reduce(0, +)
        let cost = ms.compactMap(\.costUSD).reduce(0, +)
        let active = ms.filter(\.isActive).count
        return HStack(spacing: 18) {
            stat("AGENTI", "\(active) attivi / \(ms.count)")
            stat("TOKEN IN", UsageMeter.format(tokIn))
            stat("TOKEN OUT", UsageMeter.format(tokOut))
            stat("COSTO API EQ.", String(format: "$%.2f", cost))
            stat("DURATA", Duration.seconds((s.endedAt ?? Date()).timeIntervalSince(s.startedAt))
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(Theme.dim)
            Text(value).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
        }
    }
}

private struct MemberCard: View {
    let loop: VoiceLoop
    let member: TaskInfo
    let open: () -> Void
    @State private var hover = false

    private var color: Color {
        switch member.status {
        case .running: .green
        case .waitingConfirmation: Color(hex: "#FF9F43")
        case .paused: Theme.dim
        case .done: Theme.accent
        case .failed: Color(hex: "#FF6B61")
        case .cancelled: Theme.dim
        }
    }

    private var statusText: String {
        switch member.status {
        case .running: "al lavoro"
        case .waitingConfirmation: "aspetta conferma"
        case .paused: "in pausa"
        case .done: "finito"
        case .failed: "fallito"
        case .cancelled: "fermato"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.2)).frame(width: 30, height: 30)
                    Text(String((member.member ?? "?").prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(color)
                }
                .overlay {
                    if member.status == .running {
                        Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 34, height: 34)
                            .phaseAnimator([0.4, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.member ?? "agente").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(member.role ?? "").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                Text(statusText.uppercased()).font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1)
                    .foregroundStyle(color)
            }
            if let step = member.steps.last {
                Text(step).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.accent.opacity(0.9))
                    .lineLimit(2)
            }
            Text(member.lastMessage ?? member.summary ?? "In avvio…")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(4)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Label(UsageMeter.format((member.tokensIn ?? 0) + (member.tokensOut ?? 0)), systemImage: "bolt.fill")
                Label("\(member.steps.count)", systemImage: "list.bullet")
                if let c = member.costUSD { Text(String(format: "$%.2f", c)) }
                Spacer()
                if member.status == .running || member.status == .waitingConfirmation {
                    Button { loop.controlTask(member.id, "pause") } label: { Image(systemName: "pause.fill") }.buttonStyle(.plain)
                    Button { loop.controlTask(member.id, "stop") } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain)
                } else if member.status == .paused {
                    Button { loop.controlTask(member.id, "resume") } label: { Image(systemName: "play.fill") }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .padding(12)
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(member.isActive ? 0.45 : 0.15)))
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
