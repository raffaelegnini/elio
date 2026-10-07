import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// The first minutes of rest mode: a full-screen "Elio a riposo" page instead of a black screen right away.
/// It opens like an old screen switching off (the picture folds into a line, then a dot), then a sleeping orb
/// breathes slowly with the time and what's going on in the background. After a few minutes the display sleeps.
/// Any input ends rest mode (IdleMode watches it), which closes this too.
@MainActor
final class RestScreen {
    static let shared = RestScreen()
    private var windows: [NSWindow] = []

    func show(loop: VoiceLoop, held: @escaping () -> Int) {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.isOpaque = true
            w.backgroundColor = .black
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.hidesOnDeactivate = false
            w.ignoresMouseEvents = false
            // Time and status on every display: "main" is whichever has the key window, not the one in front of you.
            w.contentView = NSHostingView(rootView: RestView(loop: loop, held: held, showInfo: true))
            w.setFrame(screen.frame, display: true)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; w.animator().alphaValue = 1 }
            windows.append(w)
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func hide() {
        let closing = windows
        windows = []
        for w in closing {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) })
        }
    }
}

private struct RestView: View {
    let loop: VoiceLoop
    let held: () -> Int
    let showInfo: Bool
    @State private var opened = Date()

    private var agents: Int { loop.tasks.filter(\.isActive).count }

    var body: some View {
        // 12 fps is plenty for a slow breath; the "switching off" intro runs smoother for its first second.
        TimelineView(.animation(minimumInterval: 1 / 12)) { ctx in
            let t = ctx.date.timeIntervalSince(opened)
            ZStack {
                Color.black
                Canvas { g, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    if t < 0.9 {
                        // Old-screen switch-off: a bright band folds into a line, then shrinks into a dot.
                        let p = t / 0.9
                        let h = max(2, size.height * 0.6 * pow(1 - min(p * 2, 1), 2))
                        let w = p < 0.5 ? size.width * 0.8 : max(6, size.width * 0.8 * (1 - (p - 0.5) * 2))
                        g.fill(Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: h / 2),
                               with: .color(Color(hex: "#FFD360").opacity(0.85 - p * 0.4)))
                    } else {
                        // Sleeping orb: a slow breath (about 5 s) and a faint halo.
                        let breath = (sin((t - 0.9) * 2 * .pi / 5) + 1) / 2
                        let fadeIn = min(1, (t - 0.9) / 1.5)
                        let r = 46 + 10 * breath
                        for (scale, alpha) in [(3.2, 0.05), (2.0, 0.10), (1.0, 0.55)] {
                            let rr = r * scale
                            g.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .radialGradient(Gradient(colors: [Color(hex: "#8FB4FF").opacity(alpha * (0.6 + 0.4 * breath) * fadeIn), .clear]),
                                                         center: c, startRadius: 0, endRadius: rr))
                        }
                    }
                }
                if showInfo && t > 1.2 {
                    VStack(spacing: 10) {
                        Spacer()
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.system(size: 64, weight: .thin, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                        Text("\(Brand.shared.name) è a riposo").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        Text(statusLine).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.4))
                        Spacer().frame(height: 40)
                        Text("Muovi il mouse o di' «\(Brand.shared.name)» per tornare").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.28))
                            .padding(.bottom, 48)
                    }
                    .opacity(min(1, (t - 1.2) / 1.0))
                }
            }
        }
        .ignoresSafeArea()
    }

    private var statusLine: String {
        var parts: [String] = []
        if agents > 0 { parts.append(agents == 1 ? "un agente al lavoro" : "\(agents) agenti al lavoro") }
        let n = held()
        if n > 0 { parts.append(n == 1 ? "un avviso per te" : "\(n) avvisi per te") }
        return parts.isEmpty ? "Nessun lavoro in corso. Il Mac resta sveglio per i monitor." : parts.joined(separator: " · ")
    }
}
