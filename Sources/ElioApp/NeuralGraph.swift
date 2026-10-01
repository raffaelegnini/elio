import ElioCore
import ElioVoice
import SwiftUI

/// A living, navigable map of what Elio knows: core → capabilities → memories, projects,
/// events, reminders, agents. Force-directed physics keeps it gently moving; nodes light up
/// when their capability is in use. Drag to pan, pinch to zoom, drag a node to move it, click to inspect.
@MainActor
final class GraphModel {
    struct Node: Identifiable {
        let id: String
        var label: String
        var detail: String
        var kind: Kind
        var capability: Capability?
        var pos: CGPoint
        var vel: CGVector = .zero
        var pinned = false
        var born = Date()

        enum Kind { case core, capability, leaf }

        var radius: CGFloat {
            switch kind { case .core: 26; case .capability: 15; case .leaf: 5.5 }
        }
    }

    struct Edge: Hashable { let a: String; let b: String }

    private(set) var nodes: [String: Node] = [:]
    var lastTick = Date()
    private(set) var edges: Set<Edge> = []

    init() {
        nodes["core"] = Node(id: "core", label: "CORE", detail: "Nucleo: conversazione con Claude", kind: .core,
                             capability: nil, pos: .zero, pinned: true)
        for (i, cap) in Capability.allCases.enumerated() {
            let a = Double(i) / Double(Capability.allCases.count) * 2 * .pi
            nodes[cap.rawValue] = Node(id: cap.rawValue, label: cap.label, detail: Self.capabilityDetail(cap),
                                       kind: .capability, capability: cap, pos: CGPoint(x: cos(a) * 160, y: sin(a) * 160))
            edges.insert(Edge(a: "core", b: cap.rawValue))
        }
    }

    /// Replaces the leaves of one capability, keeping positions of nodes that survive.
    func setLeaves(_ cap: Capability, _ items: [(id: String, label: String, detail: String)]) {
        let prefix = "\(cap.rawValue):"
        let keep = Set(items.map { prefix + $0.id })
        for id in nodes.keys where id.hasPrefix(prefix) && !keep.contains(id) {
            nodes[id] = nil
            edges = edges.filter { $0.a != id && $0.b != id }
        }
        guard let parent = nodes[cap.rawValue] else { return }
        for item in items {
            let id = prefix + item.id
            if nodes[id] != nil {
                nodes[id]?.label = item.label
                nodes[id]?.detail = item.detail
                continue
            }
            let jitter = CGPoint(x: .random(in: -40...40), y: .random(in: -40...40))
            nodes[id] = Node(id: id, label: item.label, detail: item.detail, kind: .leaf, capability: cap,
                             pos: CGPoint(x: parent.pos.x * 1.4 + jitter.x, y: parent.pos.y * 1.4 + jitter.y))
            edges.insert(Edge(a: cap.rawValue, b: id))
        }
    }

    /// One physics step: repulsion, springs, gentle drift ("breathing").
    func step(dt: CGFloat, time: Double) {
        let ids = Array(nodes.keys)
        var force: [String: CGVector] = [:]
        for id in ids { force[id] = .zero }

        for i in 0..<ids.count {
            guard let a = nodes[ids[i]] else { continue }
            for j in (i + 1)..<ids.count {
                guard let b = nodes[ids[j]] else { continue }
                var dx = a.pos.x - b.pos.x, dy = a.pos.y - b.pos.y
                var d2 = dx * dx + dy * dy
                if d2 < 1 { dx = .random(in: -1...1); dy = .random(in: -1...1); d2 = 1 }
                let strength: CGFloat = (a.kind == .leaf && b.kind == .leaf) ? 900 : 5200
                let f = strength / d2
                let d = sqrt(d2)
                force[ids[i]]!.dx += dx / d * f; force[ids[i]]!.dy += dy / d * f
                force[ids[j]]!.dx -= dx / d * f; force[ids[j]]!.dy -= dy / d * f
            }
        }
        for e in edges {
            guard let a = nodes[e.a], let b = nodes[e.b] else { continue }
            let rest: CGFloat = (a.kind == .core || b.kind == .core) ? 170 : 70
            let dx = b.pos.x - a.pos.x, dy = b.pos.y - a.pos.y
            let d = max(sqrt(dx * dx + dy * dy), 0.1)
            let f = (d - rest) * 0.06
            force[e.a]!.dx += dx / d * f; force[e.a]!.dy += dy / d * f
            force[e.b]!.dx -= dx / d * f; force[e.b]!.dy -= dy / d * f
        }
        for id in ids {
            guard var n = nodes[id], !n.pinned else { continue }
            var f = force[id]!
            // Weak gravity to the centre and a slow swirl so the network never freezes.
            f.dx += -n.pos.x * 0.004 + CGFloat(sin(time * 0.3 + Double(id.hashValue % 97))) * 0.25
            f.dy += -n.pos.y * 0.004 + CGFloat(cos(time * 0.27 + Double(id.hashValue % 89))) * 0.25
            n.vel.dx = (n.vel.dx + f.dx * dt) * 0.86
            n.vel.dy = (n.vel.dy + f.dy * dt) * 0.86
            let speed = hypot(n.vel.dx, n.vel.dy)
            if speed > 40 { n.vel.dx *= 40 / speed; n.vel.dy *= 40 / speed }
            n.pos.x += n.vel.dx * dt
            n.pos.y += n.vel.dy * dt
            nodes[id] = n
        }
    }

    func node(at world: CGPoint) -> Node? {
        nodes.values
            .filter { hypot($0.pos.x - world.x, $0.pos.y - world.y) <= $0.radius + 6 }
            .min { hypot($0.pos.x - world.x, $0.pos.y - world.y) < hypot($1.pos.x - world.x, $1.pos.y - world.y) }
    }

    func move(_ id: String, to world: CGPoint) {
        nodes[id]?.pos = world
        nodes[id]?.vel = .zero
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard id != "core" else { return }
        nodes[id]?.pinned = on
    }

    static func capabilityDetail(_ cap: Capability) -> String {
        switch cap {
        case .agenda: "Calendari Google e iCloud, Google Meet"
        case .slack: "Clock in, menzioni, DM, messaggi (con conferma)"
        case .agenti: "Agenti Claude in background sui tuoi progetti"
        case .codice: "Repository locali, diff da revisionare"
        case .promemoria: "Promemoria a voce e notifiche"
        case .mac: "App, link, controllo del Mac"
        case .memoria: "Memoria a lungo termine"
        case .browser: "Il tuo Chrome (già loggato) e il web"
        }
    }
}

struct NeuralGraphView: View {
    let loop: VoiceLoop
    /// Areas covered by floating UI: controls and inspector stay out of them.
    var chrome = EdgeInsets()
    @State private var model = GraphModel()
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var scaleStart: CGFloat = 1
    @State private var dragging: String?
    @State private var selected: String?

    private var active: Set<Capability> { Set(loop.activeTools.map(Capability.of)) }

    /// During a brief/recap: capability → when it lit up. Unlit capabilities are drawn dark.
    private var litAt: [Capability: Date] {
        var out: [Capability: Date] = [:]
        for (tool, date) in loop.litTools {
            let cap = Capability.of(tool: tool)
            out[cap] = min(out[cap] ?? date, date)
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + offset.width, y: geo.size.height / 2 + offset.height)
            ZStack(alignment: .topLeading) {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, _ in
                        let dt = CGFloat(min(timeline.date.timeIntervalSince(model.lastTick), 1.0 / 30))
                        model.lastTick = timeline.date
                        model.step(dt: max(dt, 1.0 / 120) * 8, time: t)
                        draw(&ctx, center: center, t: t)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(center: center))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { scale = min(3, max(0.35, scaleStart * $0.magnification)) }
                    .onEnded { _ in scaleStart = scale })
                .onTapGesture(coordinateSpace: .local) { p in
                    selected = model.node(at: toWorld(p, center: center))?.id
                    if selected == "core" { loop.activate() }
                }

                // The living orb sits on the core.
                OrbView(state: loop.state, level: loop.level)
                    .frame(width: 120 * scale, height: 120 * scale)
                    .position(center)
                    .allowsHitTesting(false)

                controls
                    .padding(.top, chrome.top).padding(.leading, chrome.leading + 6)

                if let id = selected, let node = model.nodes[id] {
                    Inspector(node: node, close: { selected = nil })
                        .frame(width: 280)
                        .padding(.top, chrome.top + 36)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .clipped()
        }
        .task { await refreshLoop() }
        .onChange(of: loop.activity.count) { refreshSoon() }
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, center: CGPoint, t: Double) {
        let tint = Theme.tint(loop.state)
        let dark = loop.routineMode
        let lit = litAt
        let offColor = Color(hex: "#3A3935")
        func isOff(_ n: GraphModel.Node) -> Bool {
            guard dark, let cap = n.capability else { return false }
            return lit[cap] == nil
        }
        /// 0…1 flash right after a capability lights up.
        func flash(_ n: GraphModel.Node) -> Double {
            guard dark, let cap = n.capability, let at = lit[cap] else { return 0 }
            let dt = Date().timeIntervalSince(at)
            return dt < 1.6 ? 1 - dt / 1.6 : 0
        }
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }

        for e in model.edges {
            guard let a = model.nodes[e.a], let b = model.nodes[e.b] else { continue }
            let on = (a.capability.map(active.contains) ?? false) || (b.capability.map(active.contains) ?? false)
            let pa = screen(a.pos), pb = screen(b.pos)
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            let base = b.kind == .leaf ? 0.10 : 0.22
            if isOff(b) {
                ctx.stroke(path, with: .color(offColor.opacity(0.35)), lineWidth: 0.6)
                continue
            }
            let f = flash(b)
            ctx.stroke(path, with: .color(tint.opacity(on ? 0.75 : base + f * 0.6)), lineWidth: on ? 1.6 : (b.kind == .leaf ? 0.6 : 1) + f * 1.5)
            if on {
                // Signal travelling along the synapse.
                let k = (t * 1.4 + Double(abs(e.b.hashValue % 100)) / 100).truncatingRemainder(dividingBy: 1)
                let q = CGPoint(x: pa.x + (pb.x - pa.x) * k, y: pa.y + (pb.y - pa.y) * k)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2.5, y: q.y - 2.5, width: 5, height: 5)), with: .color(.white))
            }
        }

        for node in model.nodes.values where node.kind != .core {
            let p = screen(node.pos)
            if isOff(node) {
                // Dormant neuron: dark, no glow, no label for leaves.
                let r = node.radius * max(scale, 0.6)
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(node.kind == .leaf ? offColor : Theme.bg))
                if node.kind == .capability {
                    ctx.stroke(Path(ellipseIn: rect), with: .color(offColor), lineWidth: 1)
                    let text = Text(node.label).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(offColor)
                    ctx.draw(text, at: CGPoint(x: p.x, y: p.y + r + 9))
                }
                continue
            }
            let f = flash(node)
            if f > 0 {
                // Ignition: an expanding ring as the neuron comes alive.
                let ring = node.radius * max(scale, 0.6) * (1 + (1 - f) * 3)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(tint.opacity(f)), lineWidth: 2)
            }
            let on = node.capability.map(active.contains) ?? false
            let fresh = Date().timeIntervalSince(node.born) < 3
            let isSelected = node.id == selected
            let r = node.radius * max(scale, 0.6) * (on && node.kind == .capability ? 1.15 + 0.08 * sin(t * 8) : 1)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            // Glow.
            if on || fresh || isSelected || node.kind == .capability {
                let g = r * (on || fresh ? 3.2 : 2.2)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - g, y: p.y - g, width: g * 2, height: g * 2)),
                         with: .radialGradient(Gradient(colors: [tint.opacity(on || fresh ? 0.45 : 0.12), .clear]),
                                               center: p, startRadius: 0, endRadius: g))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(node.kind == .leaf ? tint.opacity(on ? 1 : 0.75) : Theme.bg))
            if node.kind == .capability {
                ctx.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(on ? 1 : 0.6)), lineWidth: isSelected ? 2.2 : 1.2)
                if let cap = node.capability {
                    var icon = ctx.resolve(Image(systemName: cap.icon))
                    icon.shading = .color(on ? .white : tint)
                    ctx.draw(icon, in: rect.insetBy(dx: r * 0.42, dy: r * 0.42))
                }
            }
            if isSelected {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(.white.opacity(0.8)), lineWidth: 1)
            }

            // Labels: capabilities always, leaves when zoomed in or selected.
            if node.kind == .capability || scale > 1.25 || isSelected {
                let text = Text(node.kind == .capability ? node.label : String(node.label.prefix(28)))
                    .font(.system(size: node.kind == .capability ? 9.5 : 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(on || isSelected ? Theme.text : Theme.dim)
                ctx.draw(text, at: CGPoint(x: p.x, y: p.y + r + 9))
            }
        }
    }

    // MARK: - Interaction

    private func toWorld(_ p: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x) / scale, y: (p.y - center.y) / scale)
    }

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragging == nil {
                    if let n = model.node(at: toWorld(v.startLocation, center: center)), n.kind != .core {
                        dragging = n.id
                        model.setPinned(n.id, true)
                    } else {
                        dragging = "__pan"
                        dragStartOffset = offset
                    }
                }
                if dragging == "__pan" {
                    offset = CGSize(width: dragStartOffset.width + v.translation.width,
                                    height: dragStartOffset.height + v.translation.height)
                } else if let id = dragging {
                    model.move(id, to: toWorld(v.location, center: center))
                }
            }
            .onEnded { _ in
                if let id = dragging, id != "__pan" { model.setPinned(id, false) }
                dragging = nil
            }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Text("RETE NEURALE").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
            Text("\(model.nodes.count) nodi").font(Theme.mono).foregroundStyle(Theme.accent)
            Spacer().frame(width: 8)
            ForEach([("minus", -0.2), ("plus", 0.2)], id: \.0) { icon, delta in
                Button { withAnimation(.easeOut(duration: 0.2)) { scale = min(3, max(0.35, scale + delta)); scaleStart = scale } } label: {
                    Image(systemName: icon).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .background(Circle().strokeBorder(Theme.line))
            }
            Button { withAnimation(.easeOut(duration: 0.3)) { offset = .zero; scale = 1; scaleStart = 1 } } label: {
                Image(systemName: "scope").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .background(Circle().strokeBorder(Theme.line))
            .help("Centra")
        }
    }

    // MARK: - Data

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(90))
        }
    }

    @State private var pendingRefresh: Task<Void, Never>?

    /// A tool just ran (new memory, reminder, task…): refresh shortly after it settles.
    private func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await refresh() }
        }
    }

    private func refresh() async {
        async let facts = loop.callTool("recall")
        async let projects = loop.callTool("list_projects")
        async let agenda = loop.callTool("calendar_events")
        async let reminders = loop.callTool("list_reminders")

        let (f, fErr) = await facts
        if !fErr {
            model.setLeaves(.memoria, lines(f).compactMap { line in
                // "#12 [categoria] testo"
                guard line.hasPrefix("#"), let space = line.firstIndex(of: " ") else { return nil }
                let id = String(line[line.index(after: line.startIndex)..<space])
                let text = line[space...].replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
                return (id, text, line)
            })
        }
        let (p, pErr) = await projects
        if !pErr {
            model.setLeaves(.codice, lines(p).map { line in
                let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                let name = body.components(separatedBy: ":").first ?? body
                return (name, name, body)
            })
        }
        let (a, aErr) = await agenda
        if !aErr {
            model.setLeaves(.agenda, AgendaItem.parse(a).map { ($0.time + $0.title, $0.title, "\($0.time) · \($0.calendar)\($0.meet ? " · Meet" : "")") })
        }
        let (r, rErr) = await reminders
        if !rErr {
            model.setLeaves(.promemoria, lines(r).filter { $0.hasPrefix("- ") }.map { line in
                let body = String(line.dropFirst(2))
                return (body, body.components(separatedBy: ": ").dropFirst().joined(separator: ": "), body)
            })
        }
        model.setLeaves(.agenti, loop.tasks.suffix(8).map { t in
            (t.id, t.title, "\(t.status.rawValue) · \(t.project ?? "")\n\(t.summary ?? t.steps.last ?? "")")
        })
    }

    private func lines(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

private struct Inspector: View {
    let node: GraphModel.Node
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let cap = node.capability {
                    Image(systemName: cap.icon).foregroundStyle(Theme.accent)
                    Text(cap.label).font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            Text(node.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text(node.detail).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.8))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.4)))
    }
}
