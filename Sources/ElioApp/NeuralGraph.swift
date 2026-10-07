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
        /// Project technology (coloured only if the user wants it).
        var stack: String?
        /// Fixed place in a laid-out tree: the node glides there and stays (no physics).
        var target: CGPoint?
        /// Shown but not in use (an integration that isn't connected).
        var dim = false

        /// group: a folder of projects (dev → DNA → magento…), between a capability and its leaves.
        enum Kind { case core, capability, group, leaf }

        var radius: CGFloat {
            switch kind { case .core: 26; case .capability: 15; case .group: 9; case .leaf: 5.5 }
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
    func setLeaves(_ cap: Capability, _ items: [(id: String, label: String, detail: String)], dimmed: Set<String> = []) {
        let prefix = "\(cap.rawValue):"
        let keep = Set(items.map { prefix + $0.id })
        for id in nodes.keys where id.hasPrefix(prefix) && !keep.contains(id) {
            nodes[id] = nil
            edges = edges.filter { $0.a != id && $0.b != id }
        }
        guard nodes[cap.rawValue] != nil else { return }
        // Like CODICE: the capability stays on its ring, pinned, and its leaves fan outwards, away from the core
        // (free physics pulled them towards the centre, over the core and the other branches).
        let home = Self.homePosition(cap)
        nodes[cap.rawValue]?.pos = home
        nodes[cap.rawValue]?.pinned = true
        let direction = atan2(home.y, home.x)
        // Wider fan with more leaves, never past ~100°: neighbouring branches keep their own sector.
        let cone = min(Double.pi * 0.55, 1.0 + Double(items.count) * 0.08)
        let golden = 2.39996323
        for (i, item) in items.enumerated() {
            let id = prefix + item.id
            // Sunflower spiral folded into the cone: evenly spaced, organic, stable per leaf.
            let j = Self.noise(id)
            let dist = 62 + 24 * sqrt(Double(i) + 1) + (j - 0.5) * 10
            let u = (Double(i) * golden / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            let a = direction + (u - 0.5) * cone
            let target = CGPoint(x: home.x + cos(a) * dist, y: home.y + sin(a) * dist)
            if nodes[id] == nil {
                nodes[id] = Node(id: id, label: item.label, detail: item.detail, kind: .leaf, capability: cap, pos: home)
                edges.insert(Edge(a: cap.rawValue, b: id))
            }
            nodes[id]?.label = item.label
            nodes[id]?.detail = item.detail
            nodes[id]?.dim = dimmed.contains(item.id)
            nodes[id]?.target = target
        }
    }

    /// Replaces a capability's subtree with a folder hierarchy: capability → dev → DNA → magento → repos,
    /// laid out as an ordered fan pointing away from the core in the capability's direction (no overlaps:
    /// each branch gets an angular slice proportional to its projects, each level its own ring).
    func setTree(_ cap: Capability, _ roots: [ProjectNode]) {
        let prefix = "\(cap.rawValue):"
        guard let capNode = nodes[cap.rawValue] else { return }
        // The capability stays where it was, pinned: the tree hangs from it.
        let home = Self.homePosition(cap)
        nodes[cap.rawValue]?.pos = home
        nodes[cap.rawValue]?.pinned = true
        _ = capNode
        let direction = atan2(home.y, home.x)
        let base = hypot(home.x, home.y)

        // Weight = room a branch needs on the arc: each folder 1, plus a bit per cluster of projects.
        func weight(_ n: ProjectNode) -> Double {
            if n.isRepo { return 0 }
            let repos = n.children.filter(\.isRepo).count
            return 1 + Double(repos) * 0.14 + n.children.filter { !$0.isRepo }.reduce(0) { $0 + weight($1) }
        }
        let total = roots.reduce(0) { $0 + weight($1) }
        // Narrow and long: the tree grows away from the core rather than sideways.
        let wedge = min(Double.pi * 0.55, max(Double.pi / 5, total * 0.06))
        let ring: CGFloat = 115

        var placed: [(node: ProjectNode, parent: String, pos: CGPoint)] = []
        func layout(_ n: ProjectNode, parent: String, depth: Int, from a0: Double, to a1: Double) {
            // A little organic irregularity, stable for each folder.
            let h = Self.noise(n.path)
            let angle = (a0 + a1) / 2 + (h - 0.5) * (a1 - a0) * 0.25
            let r = base + ring * CGFloat(depth + 1) + CGFloat(h - 0.5) * 30
            let me = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            placed.append((n, parent, me))
            let id = prefix + n.path
            let folders = n.children.filter { !$0.isRepo }
            let repos = n.children.filter(\.isRepo)
            // Projects: a loose spray in front of their folder (sunflower spiral inside a cone, with jitter),
            // like dendrites, not rows.
            let cone = min(Double.pi * 0.6, max(1.3, (a1 - a0) * 2.2))
            // Phyllotaxis (sunflower) inside a forward cone: natural-looking, evenly spaced, no overlaps.
            let golden = 2.39996323
            for (i, c) in repos.enumerated() {
                let j = Self.noise(c.path)
                let dist = 24 + 16 * sqrt(Double(i) + 1) + (j - 0.5) * 8
                // Golden-angle sequence folded into the cone.
                let u = (Double(i) * golden / (2 * .pi)).truncatingRemainder(dividingBy: 1)
                let a = angle + (u - 0.5) * cone
                placed.append((c, id, CGPoint(x: me.x + cos(a) * dist, y: me.y + sin(a) * dist)))
            }
            let folderWeight = folders.reduce(0) { $0 + weight($1) }
            var a = a0
            for c in folders {
                let share = (a1 - a0) * weight(c) / max(folderWeight, 0.001)
                layout(c, parent: id, depth: depth + 1, from: a, to: a + share)
                a += share
            }
        }
        var a = direction - wedge / 2
        for root in roots {
            let share = wedge * weight(root) / max(total, 0.001)
            layout(root, parent: cap.rawValue, depth: 0, from: a, to: a + share)
            a += share
        }

        let keep = Set(placed.map { prefix + $0.node.path })
        for id in nodes.keys where id.hasPrefix(prefix) && !keep.contains(id) { nodes[id] = nil }
        edges = edges.filter { !$0.b.hasPrefix(prefix) }
        for (n, parent, pos) in placed {
            let id = prefix + n.path
            let detail = n.isRepo
                ? "\(n.stack.map { $0.uppercased() + " · " } ?? "")\(n.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                : "\(n.repoCount) progetti · \(n.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
            if nodes[id] == nil {
                nodes[id] = Node(id: id, label: n.name, detail: detail, kind: n.isRepo ? .leaf : .group,
                                 capability: cap, pos: home)
            }
            nodes[id]?.label = n.name
            nodes[id]?.detail = detail
            nodes[id]?.stack = n.stack
            nodes[id]?.target = pos
            edges.insert(Edge(a: parent, b: id))
        }
    }

    /// Snapshots: no "just born" glow.
    func ageAll() { for id in nodes.keys { nodes[id]?.born = .distantPast } }

    /// Stable pseudo-random 0…1 per string (organic but repeatable layout).
    static func noise(_ s: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 10_000) / 10_000
    }

    /// Where a capability sits on the ring around the core.
    static func homePosition(_ cap: Capability) -> CGPoint {
        let i = Capability.allCases.firstIndex(of: cap) ?? 0
        let a = Double(i) / Double(Capability.allCases.count) * 2 * .pi
        return CGPoint(x: cos(a) * 160, y: sin(a) * 160)
    }

    /// One physics step: repulsion, springs, gentle drift ("breathing").
    /// Works on flat arrays (no dictionary lookups or Node copies in the O(n²) loop): it runs every frame.
    func step(dt: CGFloat, time: Double) {
        let ids = Array(nodes.keys)
        let count = ids.count
        var index: [String: Int] = [:]
        index.reserveCapacity(count)
        var px = [CGFloat](repeating: 0, count: count), py = px
        var leaf = [Bool](repeating: false, count: count), free = leaf
        var kinds = [Node.Kind](repeating: .leaf, count: count)
        for (i, id) in ids.enumerated() {
            let n = nodes[id]!
            index[id] = i
            px[i] = n.pos.x; py[i] = n.pos.y
            leaf[i] = n.kind == .leaf
            free[i] = n.target == nil
            kinds[i] = n.kind
        }
        var fx = [CGFloat](repeating: 0, count: count), fy = fx

        let freeIdx = (0..<count).filter { free[$0] }
        for a in 0..<freeIdx.count {
            let i = freeIdx[a]
            for b in (a + 1)..<freeIdx.count {
                let j = freeIdx[b]
                var dx = px[i] - px[j], dy = py[i] - py[j]
                var d2 = dx * dx + dy * dy
                if d2 < 1 { dx = .random(in: -1...1); dy = .random(in: -1...1); d2 = 1 }
                let strength: CGFloat = (leaf[i] && leaf[j]) ? 500 : (leaf[i] || leaf[j]) ? 1800 : 5200
                let d = sqrt(d2)
                let f = strength / d2 / d
                fx[i] += dx * f; fy[i] += dy * f
                fx[j] -= dx * f; fy[j] -= dy * f
            }
        }
        for e in edges {
            guard let i = index[e.a], let j = index[e.b], free[i], free[j] else { continue }
            let rest: CGFloat = (kinds[i] == .core || kinds[j] == .core) ? 170
                : kinds[j] == .group ? 75 : kinds[i] == .group ? 42 : 70
            let dx = px[j] - px[i], dy = py[j] - py[i]
            let d = max(sqrt(dx * dx + dy * dy), 0.1)
            let f = (d - rest) * 0.06 / d
            fx[i] += dx * f; fy[i] += dy * f
            fx[j] -= dx * f; fy[j] -= dy * f
        }
        let ease = min(1, 0.12 * dt * 8)
        for (i, id) in ids.enumerated() {
            guard var n = nodes[id], !n.pinned else { continue }
            if let target = n.target {
                // Laid-out tree: ease towards the slot, with a slow individual drift so it feels alive.
                let ph = Self.noise(id) * 6.28
                let wob = n.kind == .leaf ? 3.0 : 1.6
                let tx = target.x + CGFloat(sin(time * 0.6 + ph) * wob)
                let ty = target.y + CGFloat(cos(time * 0.5 + ph * 1.3) * wob)
                n.pos.x += (tx - n.pos.x) * ease
                n.pos.y += (ty - n.pos.y) * ease
                nodes[id] = n
                continue
            }
            // Weak gravity to the centre and a slow swirl so the network never freezes.
            let seed = Self.noise(id)
            let gx = fx[i] - n.pos.x * 0.004 + CGFloat(sin(time * 0.3 + seed * 97)) * 0.25
            let gy = fy[i] - n.pos.y * 0.004 + CGFloat(cos(time * 0.27 + seed * 89)) * 0.25
            n.vel.dx = (n.vel.dx + gx * dt) * 0.86
            n.vel.dy = (n.vel.dy + gy * dt) * 0.86
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
        case .integrazioni: "Slack, posta, Spotify e i servizi che hai collegato (API e MCP)"
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
    /// Snapshots pass a pre-simulated model and skip loading.
    var preset: GraphModel?
    var presetZoom: (scale: CGFloat, offset: CGSize)?
    @State private var model = GraphModel()
    @Environment(\.animationsLive) private var animationsLive

    @Environment(\.animationFPS) private var fps
    @Environment(\.liveLayers) private var liveLayers
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var scaleStart: CGFloat = 1
    @State private var dragging: String?
    @State private var selected: String?
    /// Neuron under the pointer: highlighted, with its details shown next to it.
    @State private var hovered: String?
    @State private var hoverStart = Date()

    private var active: Set<Capability> { Set(loop.activeTools.map(Capability.of)) }
    /// Integrations in use right now ("mail" lights Gmail and Mail).
    private var activeIntegrations: Set<String> {
        var out = Set<String>()
        for tool in loop.activeTools {
            guard let id = Capability.integration(of: tool) else { continue }
            if id == "mail" { out.formUnion(["gmail", "applemail"]) } else { out.insert(id) }
        }
        return out
    }

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
                Group {
                    if liveLayers {
                        VectorLayer(fps: animationsLive ? fps : 0) { t in frame(center: center, t: t, step: true) }
                    } else {
                        Canvas { ctx, _ in frame(center: center, t: Date().timeIntervalSinceReferenceDate, step: false).draw(in: &ctx) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(center: center))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { scale = min(3, max(0.35, scaleStart * $0.magnification)) }
                    .onEnded { _ in scaleStart = scale })
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p):
                        let id = model.node(at: toWorld(p, center: center))?.id
                        if id != hovered {
                            hovered = id
                            hoverStart = Date()
                            if id != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                        }
                    case .ended:
                        hovered = nil
                        NSCursor.arrow.set()
                    }
                }
                .onTapGesture(coordinateSpace: .local) { p in
                    // Hover shows details; a click on the core talks to Elio, elsewhere pins/unpins the card.
                    let id = model.node(at: toWorld(p, center: center))?.id
                    if id == "core" { loop.activate(); return }
                    selected = selected == id ? nil : id
                }

                // The living orb sits on the core.
                LiveOrb(loop: loop)
                    .frame(width: 120 * scale, height: 120 * scale)
                    .position(center)
                    .allowsHitTesting(false)

                controls
                    .padding(.top, chrome.top).padding(.leading, chrome.leading + 6)

                if let id = hovered ?? selected, id != "core", let node = model.nodes[id] {
                    let p = CGPoint(x: center.x + node.pos.x * scale, y: center.y + node.pos.y * scale)
                    let flip = p.x + 320 > geo.size.width - chrome.trailing
                    Inspector(node: node, close: { selected = nil; hovered = nil })
                        .frame(width: 280)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: flip ? p.x - 170 : p.x + 170, y: min(max(p.y, chrome.top + 80), geo.size.height - chrome.bottom - 40))
                        .allowsHitTesting(selected == id)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .animation(.easeOut(duration: 0.15), value: id)
                } else if hovered == "core" {
                    Text("Clic per parlare con \(Brand.shared.name)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.panel))
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4)))
                        .position(x: center.x, y: center.y + 78 * scale)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .task {
            if let preset {
                model = preset
                if let z = presetZoom { scale = z.scale; scaleStart = z.scale; offset = z.offset }
                return
            }
            await refreshLoop()
        }
        .onChange(of: loop.activity.count) { refreshSoon() }
    }

    // MARK: - Drawing

    /// One frame of the network: physics step, then everything as batched paths, glows and cached images.
    private func frame(center: CGPoint, t: Double, step: Bool) -> VectorFrame {
        if step {
            let now = Date(timeIntervalSinceReferenceDate: t)
            let dt = CGFloat(min(now.timeIntervalSince(model.lastTick), 1.0 / 30))
            model.lastTick = now
            model.step(dt: max(dt, 1.0 / 120) * 8, time: t)
        }
        var f = VectorFrame()
        let tint = Theme.tint(loop.state)
        let dark = loop.routineMode
        let lit = litAt
        let offColor = Color(hex: "#3A3935")
        let now = Date()
        func isOff(_ n: GraphModel.Node) -> Bool {
            guard dark, let cap = n.capability else { return false }
            return lit[cap] == nil
        }
        /// 0…1 flash right after a capability lights up.
        func flash(_ n: GraphModel.Node) -> Double {
            guard dark, let cap = n.capability, let at = lit[cap] else { return 0 }
            let dt = now.timeIntervalSince(at)
            return dt < 1.6 ? 1 - dt / 1.6 : 0
        }
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }
        let active = self.active, integrations = activeIntegrations
        /// A node is lit while its capability works; an integration only while that integration is used.
        func isOn(_ n: GraphModel.Node) -> Bool {
            guard let cap = n.capability, active.contains(cap) else { return false }
            if cap == .integrazioni, n.kind == .leaf {
                return integrations.contains(String(n.id.dropFirst("integrazioni:".count)))
            }
            return true
        }
        // Quantised paints: alpha to 1%, width to 0.1 pt; invisible steps, few batches.
        func ink(_ c: Color, _ alpha: Double, width: CGFloat = 0) -> Ink {
            Ink(c, opacity: (alpha * 100).rounded() / 100, width: width)
        }

        // Synapses.
        for e in model.edges {
            guard let a = model.nodes[e.a], let b = model.nodes[e.b] else { continue }
            // Synapses of the hovered neuron light up too.
            let on = isOn(b) || (hovered != nil && (e.a == hovered || e.b == hovered))
            let pa = screen(a.pos), pb = screen(b.pos)
            let path = CGMutablePath()
            path.move(to: pa)
            if b.target != nil {
                // Tree synapses bend slightly, each its own way.
                let bend = CGFloat(GraphModel.noise(e.b) - 0.5) * 0.45
                let mx = (pa.x + pb.x) / 2 - (pb.y - pa.y) * bend, my = (pa.y + pb.y) / 2 + (pb.x - pa.x) * bend
                path.addQuadCurve(to: pb, control: CGPoint(x: mx, y: my))
            } else {
                path.addLine(to: pb)
            }
            if isOff(b) {
                f.add(path, ink(offColor, 0.35, width: 0.6), .back)
                continue
            }
            let base = b.kind == .leaf ? (b.dim ? 0.05 : 0.10) : 0.22
            let fl = flash(b)
            f.add(path, ink(tint, on ? 0.75 : base + fl * 0.6, width: on ? 1.6 : (b.kind == .leaf ? 0.6 : 1) + fl * 1.5), .back)
            if on {
                // Signal travelling along the synapse.
                let k = (t * 1.4 + GraphModel.noise(e.b)).truncatingRemainder(dividingBy: 1)
                f.circle(CGPoint(x: pa.x + (pb.x - pa.x) * k, y: pa.y + (pb.y - pa.y) * k), 2.5, Ink(.white), .front)
            }
        }

        // Thinking between tool calls: the core is visibly at work (a breathing halo of sparks and impulses
        // shooting out along the synapses), so the network never looks frozen while Claude reasons.
        if loop.phase == "penso" || loop.phase == "capisco" {
            let core = screen(.zero)
            let ring = 66 * scale
            for k in 0..<12 {
                let a = t * 1.6 + Double(k) * .pi / 6
                let rr = ring + CGFloat(sin(t * 2.4 + Double(k) * 1.3)) * 6 * scale
                let alpha = 0.3 + 0.5 * (0.5 + 0.5 * sin(t * 3 + Double(k)))
                f.circle(CGPoint(x: core.x + cos(a) * rr, y: core.y + sin(a) * rr), 1.8, ink(tint, alpha), .front)
            }
            let caps = Capability.allCases, period = 0.32, life = 1.1
            for back in 0..<4 {
                let slot = (t / period).rounded(.down) - Double(back)
                let age = (t - slot * period) / life
                guard age >= 0, age < 1 else { continue }
                let cap = caps[Int(GraphModel.noise("spark\(slot)") * Double(caps.count)) % caps.count]
                guard let n = model.nodes[cap.rawValue], !isOff(n) else { continue }
                let p = screen(n.pos)
                let e = CGFloat(1 - (1 - age) * (1 - age))   // fast out of the core, slowing down
                let q = CGPoint(x: core.x + (p.x - core.x) * e, y: core.y + (p.y - core.y) * e)
                f.circle(q, 2.2, ink(.white, 0.9 * (1 - age)), .front)
                f.glows.append(Glow(center: q, radius: 10, colors: [ink(tint, 0.5 * (1 - age)).cgColor, Ink(tint, opacity: 0).cgColor]))
            }
        }
        // Capabilities whose tool just finished: a fading ring (green-ish tint for ok, red for errors).
        var afterglow: [Capability: (k: Double, ok: Bool)] = [:]
        for step in loop.activityTrail {
            guard let end = step.ended else { continue }
            let dt = now.timeIntervalSince(end)
            guard dt < 1.4 else { continue }
            let cap = Capability.of(tool: step.tool)
            let k = 1 - dt / 1.4
            if k > (afterglow[cap]?.k ?? 0) { afterglow[cap] = (k, step.ok) }
        }

        // Neurons. Labels are collected and placed last, without overlaps: hovered first, then
        // capabilities, folders, projects; a label that would cover another one is skipped.
        var labels: [(priority: Int, spec: ImageSpec, at: CGPoint, anchor: UnitPoint)] = []
        for node in model.nodes.values where node.kind != .core {
            let p = screen(node.pos)
            if isOff(node) {
                // Dormant neuron: dark, no glow, no label for leaves.
                let r = node.radius * zoomFactor(node)
                f.circle(p, r, Ink(node.kind == .leaf ? offColor : Theme.bg))
                if node.kind == .capability {
                    f.circle(p, r, Ink(offColor, width: 1), .front)
                    f.images.append(PlacedImage(spec: labelSpec(node, color: offColor), point: CGPoint(x: p.x, y: p.y + r + 9)))
                }
                continue
            }
            let fl = flash(node)
            if fl > 0 {
                // Ignition: an expanding ring as the neuron comes alive.
                f.circle(p, node.radius * zoomFactor(node) * (1 + (1 - fl) * 3), ink(tint, fl, width: 2), .front)
            }
            let on = isOn(node)
            let fresh = now.timeIntervalSince(node.born) < 3
            let isHovered = node.id == hovered
            let isSelected = node.id == selected || isHovered
            // Hover: the neuron swells smoothly and glows.
            let grow = isHovered ? 1 + 0.3 * min(1, now.timeIntervalSince(hoverStart) / 0.15) : 1
            let r = node.radius * zoomFactor(node) * grow * (on && node.kind == .capability ? 1.15 + 0.08 * sin(t * 8) : 1)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            if on || fresh || isSelected || node.kind == .capability {
                let g = r * (on || fresh || isHovered ? 3.2 : 2.2)
                let alpha = on || fresh ? 0.45 : isHovered ? 0.35 : 0.12
                f.glows.append(Glow(center: p, radius: g, colors: [Ink(tint, opacity: alpha).cgColor, Ink(tint, opacity: 0).cgColor]))
            }
            let leafColor = node.stack != nil && Brand.shared.stackColors ? StackBadge.rawColor(node.stack) : tint
            if node.kind == .leaf {
                f.circle(p, r, node.dim && !on && !isHovered ? ink(Theme.dim, 0.45) : ink(leafColor, on || isHovered ? 1 : 0.8))
            } else {
                f.circle(p, r, Ink(Theme.bg))
            }
            if node.kind == .group {
                // Folder: ring + small folder glyph.
                f.circle(p, r, ink(tint, isSelected ? 1 : 0.55, width: isSelected ? 1.8 : 1), .front)
                f.images.append(PlacedImage(spec: ImageSpec(key: "I|folder.fill|\(tint.description)",
                                                             content: .symbol("folder.fill", color: NSColor(tint.opacity(0.9)))),
                                            rect: rect.insetBy(dx: r * 0.45, dy: r * 0.45), stratum: .icons))
            }
            if node.kind == .capability {
                f.circle(p, r, ink(tint, on ? 1 : 0.6, width: isSelected ? 2.2 : 1.2), .front)
                if on {
                    // The working capability sends out sonar rings.
                    for j in 0..<2 {
                        let k = (t * 1.2 + Double(j) * 0.5).truncatingRemainder(dividingBy: 1)
                        f.circle(p, r * (1 + CGFloat(k) * 1.6), ink(tint, 0.55 * (1 - k), width: 1.2), .front)
                    }
                } else if let cap = node.capability, let a = afterglow[cap] {
                    f.circle(p, r * (1 + CGFloat(1 - a.k) * 1.2), ink(a.ok ? tint : Color(hex: "#FF6B61"), a.k * 0.8, width: 1.5), .front)
                }
                if let cap = node.capability {
                    let color: Color = on ? .white : tint
                    f.images.append(PlacedImage(spec: ImageSpec(key: "I|\(cap.icon)|\(color.description)", content: .symbol(cap.icon, color: NSColor(color))),
                                                rect: rect.insetBy(dx: r * 0.42, dy: r * 0.42), stratum: .icons))
                }
            }
            if isSelected { f.circle(p, r + 5, Ink(.white, opacity: 0.8, width: 1), .front) }

            if labelled(node) {
                let priority = isSelected ? 0 : node.kind == .capability ? 1 : node.kind == .group ? 2 : 3
                let spec = labelSpec(node, color: on || isSelected ? Theme.text : Theme.dim)
                // Folder names sit on the side facing the core: their projects fan out the other way.
                if node.kind == .group {
                    let len = max(hypot(node.pos.x, node.pos.y), 1)
                    let ux = node.pos.x / len, uy = node.pos.y / len
                    labels.append((priority, spec, CGPoint(x: p.x - ux * (r + 5), y: p.y - uy * (r + 5)),
                                   UnitPoint(x: 0.5 + 0.5 * ux, y: 0.5 + 0.5 * uy)))
                } else {
                    labels.append((priority, spec, CGPoint(x: p.x, y: p.y + r + 9), .center))
                }
            }
        }
        var taken: [CGRect] = []
        for label in labels.sorted(by: { $0.priority < $1.priority }) {
            if label.priority > 0, taken.count > 60 { break }   // enough labels on screen
            let size = ImageCache.shared.size(label.spec)
            let rect = CGRect(x: label.at.x - size.width * label.anchor.x, y: label.at.y - size.height * label.anchor.y,
                              width: size.width, height: size.height).insetBy(dx: -3, dy: -1)
            if label.priority > 0, taken.contains(where: { $0.intersects(rect) }) { continue }
            taken.append(rect)
            f.images.append(PlacedImage(spec: label.spec, point: label.at, anchor: label.anchor))
        }
        return f
    }

    private func labelSpec(_ node: GraphModel.Node, color: Color) -> ImageSpec {
        let string = node.kind == .capability ? node.label : String(node.label.prefix(28))
        let size: CGFloat = node.kind == .capability ? 9.5 : node.kind == .group ? 8.5 : 9
        return ImageSpec(key: "L|\(size)|\(color.description)|\(string)", content: .text(string, size: size, color: NSColor(color)))
    }

    /// Capabilities, folders and integrations always; projects and memories when zoomed in or pointed at.
    private func labelled(_ node: GraphModel.Node) -> Bool {
        node.kind == .capability || node.kind == .group || node.capability == .integrazioni
            || scale > 1.25 || node.id == hovered || node.id == selected
    }


    /// Dots of projects stay small when zooming in, so zooming separates them instead of merging them.
    private func zoomFactor(_ n: GraphModel.Node) -> CGFloat {
        n.kind == .leaf ? min(max(scale, 0.6), 1.1) : max(scale, 0.6)
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
        async let projects = loop.callTool("project_tree")
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
        if !pErr, let tree = [ProjectNode].fromJSON(p) {
            model.setTree(.codice, tree)
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
        await refreshIntegrations()
        model.setLeaves(.agenti, loop.tasks.suffix(8).map { t in
            (t.id, t.title, "\(t.status.rawValue) · \(t.project ?? "")\n\(t.summary ?? t.steps.last ?? "")")
        })
    }

    @State private var nativeIntegrations: (at: Date, list: [NativeIntegrations.Status])?

    /// INTEGRAZIONI branches out to every integration: the built-in ones (Slack, Gmail, Mail, Spotify; the
    /// calendar is AGENDA) and the APIs / MCP servers added over time. Not connected = dimmed.
    private func refreshIntegrations() async {
        // The native status checks Slack over the network: every 10 minutes is plenty.
        if nativeIntegrations == nil || Date().timeIntervalSince(nativeIntegrations!.at) > 600 {
            let (json, err) = await loop.callTool("integrations_native")
            if !err, let list = [NativeIntegrations.Status].fromJSON(json) { nativeIntegrations = (Date(), list) }
        }
        var items: [(id: String, label: String, detail: String)] = []
        var dimmed = Set<String>()
        for n in nativeIntegrations?.list ?? [] where n.id != "calendar" {
            items.append((n.id, n.name, n.detail))
            if !n.connected { dimmed.insert(n.id) }
        }
        for i in IntegrationStore.load() {
            // `enabled` only: readiness needs the Keychain, which belongs to the daemon.
            items.append((i.id, i.name, "\(i.kind == .mcp ? "Server MCP" : "API REST")\(i.enabled ? "" : " · disattivata")\(i.notes.isEmpty ? "" : "\n" + String(i.notes.prefix(200)))"))
            if !i.enabled { dimmed.insert(i.id) }
        }
        model.setLeaves(.integrazioni, items, dimmed: dimmed)
    }

    private func lines(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

/// Style key for batching synapses (alpha in %, width in tenths of a point).
private struct EdgeStyle: Hashable {
    let off: Bool
    let alpha: Int
    let width: Int
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
