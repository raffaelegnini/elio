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

/// The "brain": a field of neurons orbiting a core, wired to their neighbours.
/// Energy follows the conversation state; the mic level makes it breathe.
struct OrbView: View {
    var state: VoiceLoop.State
    var level: Float
    @Environment(\.animationsLive) private var animationsLive

    private static let neurons: [Neuron] = (0..<64).map { Neuron(seed: $0) }

    var body: some View {
        TimelineView(.animation(minimumInterval: [.thinking, .speaking, .hearing].contains(state) ? 1.0 / 30 : 1.0 / 8,
                                paused: !animationsLive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(&ctx, size: size, t: t)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: state)
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

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2
        let tint = Theme.tint(state)
        let lvl = Double(level)
        let speed = 0.12 + energy * 0.5

        // Halo.
        let halo = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.fill(halo, with: .radialGradient(
            Gradient(colors: [tint.opacity(0.22 + lvl * 0.25), tint.opacity(0.04), .clear]),
            center: c, startRadius: 0, endRadius: r))

        // Neurons.
        var points: [(CGPoint, Double)] = []
        for n in Self.neurons {
            let angle = n.phase + t * speed * n.speed
            let wobble = sin(t * n.wobbleSpeed + n.phase) * 0.06
            let radius = r * (n.radius + wobble + lvl * 0.08 * n.radius)
            let p = CGPoint(x: c.x + cos(angle) * radius,
                            y: c.y + sin(angle) * radius * n.tilt)
            points.append((p, n.size))
        }

        // Synapses between close neurons; firing pulses when thinking.
        let maxDist = r * (0.38 + energy * 0.12)
        for i in points.indices {
            for j in (i + 1)..<points.count {
                let a = points[i].0, b = points[j].0
                let d = hypot(a.x - b.x, a.y - b.y)
                guard d < maxDist else { continue }
                let strength = 1 - d / maxDist
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let fire = state == .thinking ? (sin(t * 6 + Double(i * 7 + j)) + 1) / 2 : 0.3
                ctx.stroke(path, with: .color(tint.opacity(strength * (0.12 + 0.35 * energy * fire))),
                           lineWidth: 0.7)
            }
        }
        for (p, s) in points {
            let size = s * (1 + lvl * 0.8)
            let dot = Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
            ctx.fill(dot, with: .color(tint.opacity(0.55 + 0.45 * energy)))
        }

        // HUD rings: rotating tick arcs.
        for (k, ring) in [(0.92, 1.0), (0.80, -1.6)].enumerated() {
            let rr = r * ring.0
            let rot = t * speed * ring.1
            for seg in 0..<(k == 0 ? 3 : 5) {
                let start = rot + Double(seg) * (2 * .pi / Double(k == 0 ? 3 : 5))
                var arc = Path()
                arc.addArc(center: c, radius: rr, startAngle: .radians(start),
                           endAngle: .radians(start + (k == 0 ? 1.4 : 0.5)), clockwise: false)
                ctx.stroke(arc, with: .color(tint.opacity(0.35 + 0.3 * energy)), lineWidth: k == 0 ? 1.2 : 2.2)
            }
        }

        // Core.
        let core = r * (0.16 + lvl * 0.07 + (state == .speaking ? sin(t * 9) * 0.015 : 0))
        let coreRect = CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)
        ctx.fill(Path(ellipseIn: coreRect), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.95), tint.opacity(0.9), tint.opacity(0)]),
            center: c, startRadius: 0, endRadius: core))
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
