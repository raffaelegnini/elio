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
    private var popover: KeyablePanel?
    private weak var loop: VoiceLoop?
    static let size: CGFloat = 26
    /// Transparent room around the orb so its glow isn't clipped into a square by the window edge.
    static let canvas: CGFloat = 44

    func attach(_ loop: VoiceLoop, openDashboard: @escaping () -> Void, openSettings: @escaping () -> Void) {
        let s = Self.canvas
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
        self.loop = loop
        watchRequests(loop)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    // MARK: Confirmation drop-down

    /// A pending confirmation or question opens a small card right under the orb (the exact message,
    /// Conferma / Annulla, or a reply field), wherever you are; it closes when answered.
    private func watchRequests(_ loop: VoiceLoop) {
        withObservationTracking {
            _ = loop.confirmations.count
            _ = loop.questions.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let loop = self.loop else { return }
                self.updatePopover(loop)
                self.watchRequests(loop)
            }
        }
    }

    private func updatePopover(_ loop: VoiceLoop) {
        guard !loop.confirmations.isEmpty || !loop.questions.isEmpty else {
            popover?.orderOut(nil)
            return
        }
        if popover == nil {
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: RequestDropdown(loop: loop))
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            p.contentView = host
            popover = p
        }
        guard let popover, let orb = panel else { return }
        let size = popover.contentView?.fittingSize ?? NSSize(width: 380, height: 220)
        popover.setContentSize(NSSize(width: 380, height: max(120, size.height)))
        let screen = orb.screen ?? NSScreen.main
        var x = orb.frame.midX - 190
        if let s = screen { x = min(max(x, s.frame.minX + 8), s.frame.maxX - 388) }
        popover.setFrameOrigin(NSPoint(x: x, y: orb.frame.minY - popover.frame.height - 2))
        popover.orderFrontRegardless()
        NSSound(named: "Tink")?.play()
    }

    /// Vertically centred in the menu bar, 10 pt right of the notch (or of the screen centre without one).
    private func position() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let barHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : (screen.frame.maxY - screen.visibleFrame.maxY)
        let notchRight = screen.auxiliaryTopRightArea.map { screen.frame.minX + $0.minX } ?? screen.frame.midX + 100
        let pad = (Self.canvas - Self.size) / 2
        panel.setFrameOrigin(NSPoint(x: notchRight + 10 - pad,
                                     y: screen.frame.maxY - barHeight + (barHeight - Self.size) / 2 - pad))
    }
}

struct IslandView: View {
    let loop: VoiceLoop
    let openDashboard: () -> Void
    let openSettings: () -> Void
    @State private var hover = false

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
                    .scaleEffect(0.42 + 0.18 * pulse + 0.25 * voice + (hover ? 0.12 : 0))
                    .opacity(loop.connected ? 1 : 0.4)
                Circle()
                    .strokeBorder(color.opacity(hover ? 1 : busy ? 0.6 + 0.4 * pulse : 0.45), lineWidth: hover ? 2 : 1.5)
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
            .shadow(color: color.opacity(hover ? 0.9 : busy ? 0.5 * (0.5 + pulse) : 0), radius: hover ? 6 : 4)
            .scaleEffect(hover ? 1.0 : 0.88)
        }
        .onHover { h in
            withAnimation(.spring(duration: 0.25, bounce: 0.35)) { hover = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .frame(width: NotchIsland.size, height: NotchIsland.size)
        .contentShape(Circle())
        .frame(width: NotchIsland.canvas, height: NotchIsland.canvas)
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

/// Borderless panel that can take keyboard input (reply field) without activating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The card under the orb: the oldest pending question or confirmation.
private struct RequestDropdown: View {
    let loop: VoiceLoop

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#FF9F43")).frame(width: 7, height: 7)
                Text(loop.questions.isEmpty ? "SERVE LA TUA CONFERMA" : "DOMANDA")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(Theme.dim)
                Spacer()
                let n = loop.confirmations.count + loop.questions.count
                if n > 1 { Text("+\(n - 1)").font(Theme.mono).foregroundStyle(Theme.dim) }
            }
            if let q = loop.questions.first {
                QuestionCard(question: q) { loop.answer(q, text: $0) }
            } else if let req = loop.confirmations.first {
                ConfirmCard(request: req) { loop.answer(req, approved: $0) }
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.35)))
        .preferredColorScheme(.dark)
    }
}
