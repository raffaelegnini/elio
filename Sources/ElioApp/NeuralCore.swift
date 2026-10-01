import ElioVoice
import SwiftUI

/// What Elio can do, as nodes around the core. A node lights up while one of its tools runs.
enum Capability: String, CaseIterable, Identifiable {
    case agenda, slack, agenti, codice, promemoria, mac, memoria

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agenda: "AGENDA"
        case .slack: "SLACK"
        case .agenti: "AGENTI"
        case .codice: "CODICE"
        case .promemoria: "PROMEMORIA"
        case .mac: "MAC"
        case .memoria: "MEMORIA"
        }
    }

    var icon: String {
        switch self {
        case .agenda: "calendar"
        case .slack: "number"
        case .agenti: "cpu"
        case .codice: "chevron.left.forwardslash.chevron.right"
        case .promemoria: "bell"
        case .mac: "macbook"
        case .memoria: "brain"
        }
    }

    static func of(tool: String) -> Capability {
        switch tool {
        case "calendar_events", "join_next_meeting": .agenda
        case let t where t.hasPrefix("slack_"): .slack
        case "start_task", "list_tasks", "cancel_task", "schedule_task", "approve": .agenti
        case "show_diff", "list_projects": .codice
        case "set_reminder", "list_reminders": .promemoria
        case "open_app", "open_url": .mac
        default: .memoria
        }
    }

    /// Readable Italian label for the activity feed.
    static func describe(tool: String) -> String {
        switch tool {
        case "calendar_events": "Legge l'agenda"
        case "join_next_meeting": "Prepara il Meet"
        case "slack_clock_in": "Clock in Slack"
        case "slack_send": "Messaggio Slack"
        case "slack_mentions": "Menzioni Slack"
        case "slack_dms": "DM Slack"
        case "start_task": "Avvia un agente"
        case "schedule_task": "Programma un agente"
        case "list_tasks": "Stato agenti"
        case "cancel_task": "Ferma un agente"
        case "approve": "Richiesta di permesso"
        case "show_diff": "Prepara il diff"
        case "list_projects": "Cerca i progetti"
        case "set_reminder": "Imposta promemoria"
        case "list_reminders": "Legge i promemoria"
        case "open_app": "Apre un'app"
        case "open_url": "Apre un link"
        case "show_on_screen": "Mostra una scheda"
        case "night_recap": "Recap della notte"
        default: tool
        }
    }
}

/// The orb plus a ring of capability nodes wired to the core.
struct NeuralCore: View {
    let loop: VoiceLoop

    private var active: Set<Capability> { Set(loop.activeTools.map(Capability.of)) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ringRadius = size * 0.43
            let tint = Theme.tint(loop.state)

            ZStack {
                // Synapses core → node, with a travelling pulse on active ones.
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, _ in
                        for (i, cap) in Capability.allCases.enumerated() {
                            let p = point(i, center: center, radius: ringRadius)
                            let on = active.contains(cap)
                            var path = Path()
                            path.move(to: center)
                            path.addLine(to: p)
                            ctx.stroke(path, with: .color(tint.opacity(on ? 0.55 : 0.10)),
                                       style: StrokeStyle(lineWidth: on ? 1.4 : 0.7, dash: on ? [] : [2, 5]))
                            if on {
                                let k = (t * 1.6 + Double(i) * 0.13).truncatingRemainder(dividingBy: 1)
                                let q = CGPoint(x: center.x + (p.x - center.x) * k, y: center.y + (p.y - center.y) * k)
                                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)),
                                         with: .color(.white.opacity(0.9)))
                            }
                        }
                        // Outer reference ring with ticks.
                        let ring = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                                          width: ringRadius * 2, height: ringRadius * 2))
                        ctx.stroke(ring, with: .color(tint.opacity(0.10)), lineWidth: 1)
                        for k in 0..<72 {
                            let a = Double(k) / 72 * 2 * .pi + t * 0.02
                            let r1 = ringRadius + 6, r2 = ringRadius + (k % 6 == 0 ? 14 : 9)
                            var tick = Path()
                            tick.move(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
                            tick.addLine(to: CGPoint(x: center.x + cos(a) * r2, y: center.y + sin(a) * r2))
                            ctx.stroke(tick, with: .color(tint.opacity(k % 6 == 0 ? 0.35 : 0.14)), lineWidth: 1)
                        }
                    }
                }

                OrbView(state: loop.state, level: loop.level)
                    .frame(width: size * 0.62, height: size * 0.62)
                    .position(center)
                    .onTapGesture { loop.activate() }

                ForEach(Array(Capability.allCases.enumerated()), id: \.element) { i, cap in
                    let dormant = loop.routineMode && !loop.litTools.keys.contains { Capability.of(tool: $0) == cap }
                    CapabilityNode(cap: cap, on: active.contains(cap), tint: dormant ? Color(hex: "#3A3935") : tint)
                        .opacity(dormant ? 0.6 : 1)
                        .position(point(i, center: center, radius: ringRadius))
                }
            }
        }
    }

    private func point(_ i: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let a = -Double.pi / 2 + Double(i) / Double(Capability.allCases.count) * 2 * .pi
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }
}

private struct CapabilityNode: View {
    let cap: Capability
    let on: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(Theme.bg)
                Circle().fill(tint.opacity(on ? 0.30 : 0.06))
                Circle().strokeBorder(tint.opacity(on ? 0.9 : 0.3), lineWidth: 1)
                Image(systemName: cap.icon).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? Color.white : tint.opacity(0.75))
            }
            .frame(width: 34, height: 34)
            .shadow(color: tint.opacity(on ? 0.9 : 0), radius: on ? 10 : 0)
            Text(cap.label).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5)
                .foregroundStyle(on ? Theme.text : Theme.dim)
        }
        .animation(.easeOut(duration: 0.25), value: on)
    }
}
