import SwiftUI

/// Elio's presence: a slow constellation with a warm core, the PWA's orb redrawn with Canvas.
/// Color and energy follow the state; the mic level makes it breathe.
struct OrbView: View {
    let orb: AppModel.Orb
    /// Live level 0…1 (mic, or a synthetic pulse while speaking).
    let level: () -> Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Neuron { let ph, sp, rad, tilt, sz: Double }
    private static let neurons: [Neuron] = (0..<48).map { i in
        var s = Double(i * 9301 + 49297)
        // Classic seeded LCG (the PWA's version multiplied by the modulus, collapsing every neuron onto one point).
        func r() -> Double { s = (s * 9301 + 49297).truncatingRemainder(dividingBy: 233280); return s / 233280 }
        let ph = r() * 6.28
        let sp = (0.4 + r() * 0.9) * (r() > 0.5 ? 1 : -1)
        return Neuron(ph: ph, sp: sp, rad: 0.3 + r() * 0.5, tilt: 0.55 + r() * 0.45, sz: 1.2 + r() * 1.8)
    }

    @State private var smooth = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Canvas { ctx, size in
                draw(&ctx, size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double) {
        let tint = Theme.tint(orb)
        let r = min(size.width, size.height) / 2.15
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let time = t.truncatingRemainder(dividingBy: 10_000) * (reduceMotion ? 0.15 : 1)
        let energy: Double = switch orb { case .thinking: 1; case .speaking: 0.8; case .hearing: 0.75; case .offline: 0.15; case .listening: 0.35 }
        var lvl = min(1, max(0, level()))
        if orb == .speaking && !reduceMotion { lvl = max(lvl, 0.25 + 0.2 * sin(time * 7)) }

        // Halo.
        let halo = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(halo, with: .radialGradient(Gradient(colors: [tint.opacity(0.2), .clear]), center: c, startRadius: 0, endRadius: r))

        let pts: [(CGPoint, Double)] = Self.neurons.map { n in
            let a = n.ph + time * (0.12 + energy * 0.5) * n.sp
            let rr = r * (n.rad + sin(time * 0.8 + n.ph) * 0.05 + lvl * 0.08)
            return (CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr * n.tilt), n.sz)
        }
        let maxD = r * (0.38 + energy * 0.12)
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = hypot(pts[i].0.x - pts[j].0.x, pts[i].0.y - pts[j].0.y)
                guard d <= maxD else { continue }
                let fire = orb == .thinking ? (sin(time * 6 + Double(i * 7 + j)) + 1) / 2 : 0.3
                var line = Path()
                line.move(to: pts[i].0)
                line.addLine(to: pts[j].0)
                ctx.stroke(line, with: .color(tint.opacity((1 - d / maxD) * (0.1 + 0.3 * energy * fire))), lineWidth: 0.6)
            }
        }
        for (p, sz) in pts {
            let rad = sz / 2 * (1 + lvl)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad)),
                     with: .color(tint.opacity(0.5 + 0.4 * energy)))
        }
        // One thin ring, a few slow arcs: presence without the HUD.
        for s in 0..<3 {
            let start = time * (0.1 + energy * 0.4) + Double(s) * 2 * .pi / 3
            var arc = Path()
            arc.addArc(center: c, radius: r * 0.94, startAngle: .radians(start), endAngle: .radians(start + 1.2), clockwise: false)
            ctx.stroke(arc, with: .color(tint.opacity(0.25 + 0.3 * energy)), lineWidth: 1.2)
        }
        let core = r * (0.16 + lvl * 0.07 + (orb == .speaking && !reduceMotion ? sin(time * 9) * 0.015 : 0))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core)),
                 with: .radialGradient(Gradient(stops: [.init(color: .white, location: 0), .init(color: tint, location: 0.5),
                                                        .init(color: .clear, location: 1)]),
                                       center: c, startRadius: 0, endRadius: core))
    }
}
