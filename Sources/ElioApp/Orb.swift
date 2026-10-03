import ElioCore
import ElioVoice
import SwiftUI

/// DNA Factory palette (dna-management-apps): ink blacks, warm greys, cream text, yellow accent.
/// The accent comes from Settings so each colleague can tune it.
@MainActor
enum Theme {
    static let bg = Color(hex: "#0E0E10")
    static let panel = Color(hex: "#1A1A1D").opacity(0.82)
    static var line: Color { accent.opacity(0.18) }
    static let text = Color(hex: "#FBF8F1")
    static let dim = Color(hex: "#9E9A8E")
    static var accent: Color { Brand.shared.accent }
    static let mono = Font.system(size: 10.5, weight: .medium, design: .monospaced)

    static func tint(_ state: VoiceLoop.State) -> Color {
        switch state {
        case .listening, .idle: accent
        case .hearing: Color(hex: "#FFE38A")
        case .thinking: Color(hex: "#FF9F43")
        case .speaking: Color(hex: "#F5C13F")
        case .muted: Color(hex: "#6E6B62")
        case .off: Color(hex: "#4A4843")
        }
    }
}

/// Off when the window showing an animation is hidden, minimised or covered: no frames are drawn.
/// (A dashboard animating at 60 fps in the background used ~75% CPU and slowed the whole Mac.)
extension EnvironmentValues {
    @Entry var animationsLive = true
    /// Frame rate for continuous animations: full when the window is being looked at, lower otherwise, 0 = paused.
    @Entry var animationFPS: Double = 30
}

/// Name and accent of the assistant, editable at runtime from Settings.
@MainActor
@Observable
final class Brand {
    static let shared = Brand()
    var name = "Elio"
    var accent = Color(hex: "#FFD360")
    var stackColors = false

    /// "ELIO" → "E.L.I.O."
    var dotted: String { name.uppercased().map(String.init).joined(separator: ".") + "." }

    func apply(_ config: ElioConfig) {
        name = config.assistantName
        accent = Color(hex: config.accentColor)
        stackColors = config.stackColors
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt64(s, radix: 16) ?? 0xFFD360
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// The orb bound to the voice loop. Reads the mic level in its own body, so ~12 level updates a
/// second redraw only the orb, not the view that contains it (the whole dashboard graph before).
struct LiveOrb: View {
    let loop: VoiceLoop
    var body: some View { OrbView(state: loop.state, level: loop.level) }
}

/// The "brain": a field of neurons orbiting a core, wired to their neighbours.
/// Energy follows the conversation state; the mic level makes it breathe.
///
/// Live it runs on Core Animation at the window's frame rate (60 when you look at it); each frame is a
/// handful of batched paths (synapses grouped into opacity bands, all neurons in one path).
struct OrbView: View {
    var state: VoiceLoop.State
    var level: Float
    @Environment(\.animationsLive) private var animationsLive
    @Environment(\.animationFPS) private var fps
    @Environment(\.liveLayers) private var liveLayers

    private static let neurons: [Neuron] = (0..<64).map { Neuron(seed: $0) }
    /// Synapse opacity bands: enough steps that the fade reads continuous.
    private static let bands = 10

    var body: some View {
        if liveLayers {
            GeometryReader { geo in
                let size = geo.size
                VectorLayer(fps: animationsLive ? fps : 0) { t in frame(size: size, t: t) }
            }
        } else {
            Canvas { ctx, size in frame(size: size, t: Date().timeIntervalSinceReferenceDate).draw(in: &ctx) }
        }
    }

    private var energy: Double {
        switch state {
        case .off: 0.15
        case .muted: 0.12
        case .idle, .listening: 0.35
        case .hearing: 0.75
        case .thinking: 1.0
        case .speaking: 0.8
        }
    }

    func frame(size: CGSize, t: Double) -> VectorFrame {
        var f = VectorFrame()
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2
        let tint = Theme.tint(state)
        let lvl = Double(level)
        let energy = self.energy
        let speed = 0.12 + energy * 0.5
        func cg(_ o: Double) -> CGColor { Ink(tint, opacity: o).cgColor }

        // Halo.
        f.glows.append(Glow(center: c, radius: r, colors: [cg(0.22 + lvl * 0.25), cg(0.04), cg(0)]))

        // Neurons.
        let neurons = Self.neurons
        var xs = [CGFloat](repeating: 0, count: neurons.count)
        var ys = [CGFloat](repeating: 0, count: neurons.count)
        for (i, n) in neurons.enumerated() {
            let angle = n.phase + t * speed * n.speed
            let wobble = sin(t * n.wobbleSpeed + n.phase) * 0.06
            let radius = r * (n.radius + wobble + lvl * 0.08 * n.radius)
            xs[i] = c.x + cos(angle) * radius
            ys[i] = c.y + sin(angle) * radius * n.tilt
        }

        // Synapses between close neurons, one path per opacity band.
        let maxDist = r * (0.38 + energy * 0.12)
        let maxD2 = maxDist * maxDist
        let thinking = state == .thinking
        let top = 0.47
        let inks = (0..<Self.bands).map { Ink(tint, opacity: (Double($0) + 0.5) / Double(Self.bands) * top, width: 0.7) }
        for i in 0..<neurons.count {
            for j in (i + 1)..<neurons.count {
                let dx = xs[i] - xs[j], dy = ys[i] - ys[j]
                let d2 = dx * dx + dy * dy
                guard d2 < maxD2 else { continue }
                let strength = 1 - sqrt(d2) / maxDist
                let fire = thinking ? (sin(t * 6 + Double(i * 7 + j)) + 1) / 2 : 0.3
                let alpha = strength * (0.12 + 0.35 * energy * fire)
                let band = min(Self.bands - 1, Int(alpha / top * Double(Self.bands)))
                f.segment(CGPoint(x: xs[i], y: ys[i]), CGPoint(x: xs[j], y: ys[j]), inks[band])
            }
        }

        let dotInk = Ink(tint, opacity: 0.55 + 0.45 * energy)
        let grow = 1 + lvl * 0.8
        for (i, n) in neurons.enumerated() { f.circle(CGPoint(x: xs[i], y: ys[i]), n.size * grow / 2, dotInk) }

        // HUD rings: rotating tick arcs, one path per ring.
        for (k, ring) in [(0.92, 1.0), (0.80, -1.6)].enumerated() {
            let rr = r * ring.0
            let rot = t * speed * ring.1
            let count = k == 0 ? 3 : 5
            let arcs = CGMutablePath()
            for seg in 0..<count {
                let start = rot + Double(seg) * (2 * .pi / Double(count))
                arcs.move(to: CGPoint(x: c.x + cos(start) * rr, y: c.y + sin(start) * rr))
                arcs.addArc(center: c, radius: rr, startAngle: start, endAngle: start + (k == 0 ? 1.4 : 0.5), clockwise: false)
            }
            f.add(arcs, Ink(tint, opacity: 0.35 + 0.3 * energy, width: k == 0 ? 1.2 : 2.2), .front)
        }

        // Core.
        let core = r * (0.16 + lvl * 0.07 + (state == .speaking ? sin(t * 9) * 0.015 : 0))
        f.glows.append(Glow(center: c, radius: core, colors: [CGColor(gray: 1, alpha: 0.95), cg(0.9), cg(0)]))
        return f
    }
}

private struct Neuron {
    let phase, speed, radius, tilt, size, wobbleSpeed: Double

    init(seed: Int) {
        var g = SplitMix(seed: UInt64(seed) &+ 0x9E37)
        phase = g.next() * 2 * .pi
        speed = (0.4 + g.next() * 0.9) * (g.next() > 0.5 ? 1 : -1)
        radius = 0.28 + g.next() * 0.5
        tilt = 0.55 + g.next() * 0.45
        size = 1.6 + g.next() * 2.4
        wobbleSpeed = 0.3 + g.next() * 1.2
    }
}

/// Deterministic RNG so the constellation is the same at every launch.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
