import Charts
import ElioCore
import ElioVoice
import SwiftUI

/// The workflow report inside the app (the same data as the HTML report): headline numbers, the agents'
/// timeline with the moments that mattered, cost, pace, activity and which of the user's tastes were broken.
struct MissionReportView: View {
    let loop: VoiceLoop
    let workflowId: String
    @State private var report: WorkflowReport?
    @State private var error: String?

    var body: some View {
        Group {
            if let r = report {
                ScrollView { content(r).padding(.bottom, 20) }.scrollIndicators(.never)
            } else {
                VStack { Spacer(); Text(error ?? "Carico il report…").foregroundStyle(Theme.dim); Spacer() }.frame(maxWidth: .infinity)
            }
        }
        .task(id: workflowId) {
            while !Task.isCancelled {
                await load()
                // Live while the mission runs; once it's over, once is enough.
                if report?.workflow.endedAt != nil { break }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func load() async {
        let (json, err) = await loop.callTool("workflow_report_json", ["id": workflowId])
        if !err, let r = WorkflowReport.fromJSON(json) { report = r; error = nil } else if report == nil { error = "Report non disponibile." }
    }

    // MARK: Layout

    @ViewBuilder private func content(_ r: WorkflowReport) -> some View {
        let agents = r.agents.sorted { ($0.info.startedAt, $0.info.member ?? "") < ($1.info.startedAt, $1.info.member ?? "") }
        let colors = Dictionary(uniqueKeysWithValues: agents.enumerated().map { ($0.element.info.member ?? "main", AgentPalette.colors[$0.offset % AgentPalette.colors.count]) })
        VStack(alignment: .leading, spacing: 14) {
            kpis(r)
            card("TIMELINE DEGLI AGENTI") { timeline(r, agents: agents, colors: colors) }
            HStack(alignment: .top, spacing: 14) {
                card("COSTO PER AGENTE") { costs(agents, colors: colors) }
                card("RITMO · AZIONI AL MINUTO") { pace(r) }
            }
            card("ATTIVITÀ PER AGENTE") { activity(agents, colors: colors) }
            HStack(alignment: .top, spacing: 14) {
                card("DECISIONI PRESE PER TE") { decisions(r) }
                card("IL TUO GUSTO, APPLICATO") { taste(r) }
            }
            HStack {
                Spacer()
                Button("Apri il report completo nel browser") { Task { _ = await loop.callTool("workflow_report", ["id": workflowId]) } }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func card(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Rectangle().fill(Theme.accent).frame(width: 3, height: 10)
                Text(title).font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    // MARK: Numbers

    private func kpis(_ r: WorkflowReport) -> some View {
        let start = r.workflow.startedAt, end = r.workflow.endedAt ?? r.generatedAt
        let cost = r.agents.compactMap(\.info.costUSD).reduce(0, +)
        let tokens = r.agents.reduce(0) { $0 + ($1.info.tokensIn ?? 0) + ($1.info.tokensOut ?? 0) }
        let decisions = r.events.filter { $0.kind == .autoDecision }.count
        let asked = r.events.filter { $0.kind == .question }.count - decisions
        let corrections = r.events.filter { $0.kind == .tasteCorrection }.count
        let confirms = r.events.filter { $0.kind == .confirm }.count
        return HStack(spacing: 10) {
            kpi("DURATA", Duration.seconds(end.timeIntervalSince(start)).formatted(.units(allowed: [.hours, .minutes], width: .narrow)), "\(r.agents.count) agenti")
            kpi("COSTO API", String(format: "$%.2f", cost), "equivalente")
            kpi("TOKEN", UsageMeter.format(tokens), "input + output")
            kpi("DECISO DA ELIO", "\(decisions)", "\(max(0, asked)) chieste a te")
            kpi("CORREZIONI", "\(corrections)", "sui tuoi gusti")
            kpi("CONFERME", "\(confirms)", "richieste a te")
        }
    }

    private func kpi(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(Theme.dim)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
            Text(sub).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    // MARK: Charts

    private struct Mark: Identifiable {
        let id = UUID(); let agent: String; let at: Date; let label: String; let symbol: String; let color: Color
    }

    private func timeline(_ r: WorkflowReport, agents: [WorkflowReport.AgentStats], colors: [String: Color]) -> some View {
        let now = r.generatedAt
        let marks: [Mark] = r.events.compactMap { e in
            let agent = agentOf(e) ?? ""
            guard agents.contains(where: { ($0.info.member ?? "main") == agent }) else { return nil }
            switch e.kind {
            case .autoDecision: return Mark(agent: agent, at: e.ts, label: "Deciso da Elio: \(e.text)", symbol: "circle", color: Theme.accent)
            case .question: return Mark(agent: agent, at: e.ts, label: "Domanda: \(e.text)", symbol: "diamond", color: Color(hex: "#FF9F43"))
            case .tasteCorrection: return Mark(agent: agent, at: e.ts, label: "Correzione di gusto", symbol: "triangle", color: Color(hex: "#FF9F43"))
            case .agentFailed, .alert: return Mark(agent: agent, at: e.ts, label: e.text, symbol: "xmark", color: Color(hex: "#FF6B61"))
            case .confirm: return Mark(agent: agent, at: e.ts, label: "Conferma: \(e.text)", symbol: "square", color: Theme.dim)
            default: return nil
            }
        }
        return Chart {
            ForEach(agents, id: \.info.id) { a in
                let name = a.info.member ?? "main"
                let running = a.info.isActive
                BarMark(xStart: .value("Inizio", a.info.startedAt), xEnd: .value("Fine", running ? now : (a.info.endedAt ?? now)),
                        y: .value("Agente", name), height: 12)
                    .foregroundStyle((colors[name] ?? Theme.accent).opacity(running ? 0.6 : 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            ForEach(marks) { m in
                PointMark(x: .value("Quando", m.at), y: .value("Agente", m.agent))
                    .symbol(symbol(m.symbol))
                    .symbolSize(70)
                    .foregroundStyle(m.color)
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
            AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.dim)
        } }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.text) } }
        .frame(height: CGFloat(max(agents.count, 1)) * 34 + 30)
    }

    private func symbol(_ name: String) -> BasicChartSymbolShape {
        switch name {
        case "diamond": .diamond
        case "triangle": .triangle
        case "square": .square
        case "xmark": .cross
        default: .circle
        }
    }

    private func agentOf(_ e: WorkflowEvent) -> String? {
        if let data = e.data, let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
           let agent = obj["agent"] as? String { return agent }
        return e.actor == "elio" ? "elio" : e.actor
    }

    private func costs(_ agents: [WorkflowReport.AgentStats], colors: [String: Color]) -> some View {
        let rows = agents.map { (name: $0.info.member ?? "main", cost: $0.info.costUSD ?? 0) }.sorted { $0.cost > $1.cost }
        return Chart(rows, id: \.name) { row in
            BarMark(x: .value("Costo", row.cost), y: .value("Agente", row.name), height: 12)
                .foregroundStyle(Color(hex: "#3987e5"))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .annotation(position: .trailing) {
                    Text(String(format: "$%.2f", row.cost)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.text) } }
        .frame(height: CGFloat(max(rows.count, 1)) * 28 + 10)
    }

    private func pace(_ r: WorkflowReport) -> some View {
        var bins: [Int: Int] = [:]
        for a in r.agents { for (minute, n) in a.timeline { bins[minute, default: 0] += n } }
        let points = bins.keys.sorted().map { (date: r.workflow.startedAt.addingTimeInterval(Double($0) * 60), n: bins[$0] ?? 0) }
        return Group {
            if points.isEmpty {
                Text("Nessuna attività registrata.").font(.system(size: 12)).foregroundStyle(Theme.dim)
            } else {
                Chart(points, id: \.date) { p in
                    AreaMark(x: .value("Minuto", p.date), y: .value("Azioni", p.n))
                        .foregroundStyle(Color(hex: "#3987e5").opacity(0.15)).interpolationMethod(.monotone)
                    LineMark(x: .value("Minuto", p.date), y: .value("Azioni", p.n))
                        .foregroundStyle(Color(hex: "#3987e5")).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.dim)
                } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06)); AxisValueLabel().foregroundStyle(Theme.dim)
                } }
                .frame(height: 140)
            }
        }
    }

    private func activity(_ agents: [WorkflowReport.AgentStats], colors: [String: Color]) -> some View {
        let cols: [(String, String)] = [("command", "Comandi"), ("edit", "Modifiche"), ("write", "Nuovi"), ("read", "Letture"), ("search", "Ricerche")]
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("AGENTE")
                ForEach(cols, id: \.0) { Text($0.1.uppercased()).gridColumnAlignment(.trailing) }
                Text("FILE").gridColumnAlignment(.trailing)
                Text("LAVORO").gridColumnAlignment(.trailing)
                Text("TOKEN").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim)
            ForEach(agents, id: \.info.id) { a in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(colors[a.info.member ?? "main"] ?? Theme.accent).frame(width: 7, height: 7)
                        Text(a.info.member ?? "agente").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    ForEach(cols, id: \.0) { c in Text(a.activity[c.0].map(String.init) ?? "·") }
                    Text("\(a.files.count)")
                    Text(Duration.seconds(a.info.activeSeconds ?? 0).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                    Text(UsageMeter.format((a.info.tokensIn ?? 0) + (a.info.tokensOut ?? 0)))
                }
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.9))
            }
        }
    }

    private func decisions(_ r: WorkflowReport) -> some View {
        let list = r.events.filter { $0.kind == .autoDecision }.suffix(8)
        return VStack(alignment: .leading, spacing: 8) {
            if list.isEmpty { Text("Nessuna: gli agenti non hanno avuto dubbi.").font(.system(size: 12)).foregroundStyle(Theme.dim) }
            ForEach(Array(list), id: \.ts) { e in
                let q = (try? JSONSerialization.jsonObject(with: Data((e.data ?? "{}").utf8)) as? [String: Any])?["question"] as? String
                VStack(alignment: .leading, spacing: 2) {
                    if let q { Text(q).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(2) }
                    Text("→ \(e.text)").font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(3)
                }
            }
        }
    }

    private func taste(_ r: WorkflowReport) -> some View {
        var byRule: [Int: Int] = [:]
        for e in r.events where e.kind == .tasteViolation {
            if let obj = try? JSONSerialization.jsonObject(with: Data((e.data ?? "{}").utf8)) as? [String: Any], let rule = obj["rule"] as? Int {
                byRule[rule, default: 0] += 1
            }
        }
        let rules = Dictionary(r.taste.map { ($0.id, $0.rule) }, uniquingKeysWith: { a, _ in a })
        let rows = byRule.map { (rule: rules[$0.key] ?? "Regola #\($0.key)", n: $0.value) }.sorted { $0.n > $1.n }
        let ok = r.events.filter { $0.kind == .tasteOk }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(ok) revisioni senza problemi · \(rows.reduce(0) { $0 + $1.n }) violazioni")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            if rows.isEmpty {
                Text(r.taste.isEmpty ? "Non mi hai ancora insegnato i tuoi gusti." : "Nessuna regola violata.").font(.system(size: 12)).foregroundStyle(Theme.dim)
            } else {
                Chart(rows, id: \.rule) { row in
                    BarMark(x: .value("Volte", row.n), y: .value("Regola", String(row.rule.prefix(40))), height: 10)
                        .foregroundStyle(Color(hex: "#FF9F43")).clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.text) } }
                .frame(height: CGFloat(rows.count) * 24 + 10)
            }
        }
    }
}
