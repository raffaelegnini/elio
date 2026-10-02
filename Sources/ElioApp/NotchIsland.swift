import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// A small orb in the menu bar, just right of the notch (the notch itself is left to apps like
/// boring.notch). It glows and pulses with Elio's state: listening, hearing, thinking, speaking,
/// waiting for an answer, muted. Click → dashboard, right-click → quick actions, hover → what's happening.
@MainActor
final class NotchIsland {
    private var panel: NSPanel?
    private var observer: Any?
    static let size: CGFloat = 26

    func attach(_ loop: VoiceLoop, openDashboard: @escaping () -> Void, openSettings: @escaping () -> Void) {
        let s = Self.size
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar so the status items can't cover it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        let host = NSHostingView(rootView: IslandView(loop: loop, openDashboard: openDashboard, openSettings: openSettings))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        self.panel = panel
        position()
        panel.orderFrontRegardless()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    /// Vertically centred in the menu bar, 10 pt right of the notch (or of the screen centre without one).
    private func position() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let barHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : (screen.frame.maxY - screen.visibleFrame.maxY)
        let notchRight = screen.auxiliaryTopRightArea.map { screen.frame.minX + $0.minX } ?? screen.frame.midX + 100
        let s = Self.size
        panel.setFrameOrigin(NSPoint(x: notchRight + 10, y: screen.frame.maxY - barHeight + (barHeight - s) / 2))
    }
}

struct IslandView: View {
    let loop: VoiceLoop
    let openDashboard: () -> Void
    let openSettings: () -> Void

    private var waiting: Bool { !loop.confirmations.isEmpty || !loop.questions.isEmpty }
    private var busy: Bool { [.hearing, .thinking, .speaking].contains(loop.state) || waiting || loop.routineMode }
    private var agents: Int { loop.tasks.filter(\.isActive).count }

    private var color: Color {
        if waiting { return Color(hex: "#FF9F43") }
        if loop.muted { return Color(hex: "#FF6B61") }
        if !loop.connected { return Color(hex: "#6E6B62") }
        return Theme.tint(loop.state)
    }

    private var tooltip: String {
        if let q = loop.questions.first { return "Aspetta una risposta: \(q.question)" }
        if let c = loop.confirmations.first { return "Aspetta conferma: \(c.title)" }
        if !loop.connected { return "\(Brand.shared.name): daemon non raggiungibile" }
        if loop.muted { return "\(Brand.shared.name): microfono spento" }
        var s = "\(Brand.shared.name): \(loop.state.label)"
        if let tool = loop.activeTools.first { s += " · \(Capability.describe(tool: tool))" }
        if agents > 0 { s += " · \(agents) agenti al lavoro" }
        return s
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !busy)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = busy ? (sin(t * (loop.state == .thinking ? 5 : 3)) + 1) / 2 : 0
            let voice = loop.state == .hearing || loop.state == .speaking ? Double(max(0, min(1, loop.level))) : 0
            ZStack {
                Circle().fill(Color.black)
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0.25)], center: .center,
                                         startRadius: 1, endRadius: 10))
                    .scaleEffect(0.42 + 0.18 * pulse + 0.25 * voice)
                    .opacity(loop.connected ? 1 : 0.4)
                Circle()
                    .strokeBorder(color.opacity(busy ? 0.6 + 0.4 * pulse : 0.45), lineWidth: 1.5)
                if loop.state == .thinking {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.radians(t * 6))
                        .padding(1)
                }
                if agents > 0 {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                        .offset(x: 9, y: -9)
                }
            }
            .shadow(color: color.opacity(busy ? 0.5 * (0.5 + pulse) : 0), radius: 4)
        }
        .frame(width: NotchIsland.size, height: NotchIsland.size)
        .contentShape(Circle())
        .onTapGesture { openDashboard() }
        .help(tooltip)
        .contextMenu {
            Button("Parla con \(Brand.shared.name)") { loop.activate() }
            Button(loop.muted ? "Riattiva microfono" : "Silenzia microfono") { loop.setMuted(!loop.muted) }
            if loop.state == .thinking || loop.state == .speaking { Button("Ferma") { loop.stopEverything() } }
            Button("Briefing di oggi") { loop.submit(text: "briefing") }
            Divider()
            Button("Dashboard") { openDashboard() }
            Button("Impostazioni") { openSettings() }
        }
    }
}
