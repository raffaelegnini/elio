import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// Elio's menu bar item: a small orb that glows and pulses with Elio's state (listening, hearing,
/// thinking, speaking, waiting for an answer, muted). A real status item, so it never fights the notch
/// or notch apps like boring.notch. Click → dashboard, right-click → full menu, hover → what's happening.
@MainActor
final class StatusOrb {
    private var item: NSStatusItem?
    private var popover: KeyablePanel?
    private weak var loop: VoiceLoop?
    private var openDashboard: () -> Void = {}
    private var menu: NSMenu?
    private let target = ClickTarget()
    static let size: CGFloat = 18
    static let width: CGFloat = 28
    /// Above the menu bar and notch apps (boring.notch sits at .mainMenu + 3), below pop-up menus.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    func attach<Menu: View>(_ loop: VoiceLoop, menu: Menu, openDashboard: @escaping () -> Void) {
        // New status items land leftmost, which on a MacBook is behind the notch: start next to the clock.
        // ⌘-drag moves it and macOS remembers the new spot under the same key.
        let positionKey = "NSStatusItem Preferred Position ElioOrb"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(200, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: Self.width)
        item.autosaveName = "ElioOrb"
        self.item = item
        self.loop = loop
        self.openDashboard = openDashboard
        self.menu = NSHostingMenu(rootView: menu)
        if let button = item.button {
            let host = PassthroughHostingView(rootView: StatusOrbView(loop: loop))
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                host.widthAnchor.constraint(equalToConstant: Self.width),
                host.heightAnchor.constraint(equalToConstant: Self.width),
            ])
            target.onClick = { [weak self] in self?.click() }
            button.target = target
            button.action = #selector(ClickTarget.clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        watchTooltip(loop)
        watchRequests(loop)
    }

    private func click() {
        guard let item, let button = item.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
        } else {
            openDashboard()
        }
    }

    private func watchTooltip(_ loop: VoiceLoop) {
        item?.button?.toolTip = withObservationTracking {
            StatusOrbView.tooltip(loop)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let loop = self.loop else { return }
                self.watchTooltip(loop)
            }
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
            p.level = Self.level
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: RequestDropdown(loop: loop))
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            p.contentView = host
            popover = p
        }
        guard let popover, let orb = item?.button?.window else { return }
        let size = popover.contentView?.fittingSize ?? NSSize(width: 380, height: 220)
        popover.setContentSize(NSSize(width: 380, height: max(120, size.height)))
        let screen = orb.screen ?? NSScreen.main
        var x = orb.frame.midX - 190
        if let s = screen { x = min(max(x, s.frame.minX + 8), s.frame.maxX - 388) }
        popover.setFrameOrigin(NSPoint(x: x, y: orb.frame.minY - popover.frame.height - 2))
        popover.orderFrontRegardless()
        // At rest the urgent ones already ring (outside the quiet hours); the rest stay silent.
        if !loop.resting { NSSound(named: "Tink")?.play() }
    }
}

struct StatusOrbView: View {
    let loop: VoiceLoop
    
    private var waiting: Bool { !loop.confirmations.isEmpty || !loop.questions.isEmpty }
    private var busy: Bool { [.hearing, .thinking, .speaking].contains(loop.state) || waiting || loop.routineMode }
    private var agents: Int { loop.tasks.filter(\.isActive).count }

    /// Moonlight: the Mac is at rest.
    static let restColor = Color(hex: "#9DB0E8")

    private var color: Color {
        if waiting { return Color(hex: "#FF9F43") }
        if loop.resting { return Self.restColor }
        if loop.muted { return Color(hex: "#FF6B61") }
        if !loop.connected { return Color(hex: "#6E6B62") }
        return Theme.tint(loop.state)
    }

    static func tooltip(_ loop: VoiceLoop) -> String {
        let agents = loop.tasks.filter(\.isActive).count
        if let q = loop.questions.first { return "Aspetta una risposta: \(q.question)" }
        if let c = loop.confirmations.first { return "Aspetta conferma: \(c.title)" }
        if !loop.connected { return "\(Brand.shared.name): daemon non raggiungibile" }
        if loop.muted, !loop.resting { return "\(Brand.shared.name): microfono spento" }
        var s = "\(Brand.shared.name): \(loop.resting ? "a riposo" : loop.state.label)"
        if let tool = loop.activeTools.first { s += " · \(Capability.describe(tool: tool))" }
        if agents > 0 { s += " · \(agents) agenti al lavoro" }
        return s
    }

    var body: some View {
        // At rest: a slow, dim breath at a few frames per second (nothing else should cost energy then).
        let resting = loop.resting && !busy
        TimelineView(.animation(minimumInterval: resting ? 1 / 6 : 1 / 30, paused: !busy && !resting)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = busy ? (sin(t * (loop.state == .thinking ? 5 : 3)) + 1) / 2 : 0
            let breath = resting ? (sin(t * 0.9) + 1) / 2 : 0
            let voice = loop.state == .hearing || loop.state == .speaking ? Double(max(0, min(1, loop.level))) : 0
            ZStack {
                Circle().fill(Color.black)
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0.25)], center: .center,
                                         startRadius: 1, endRadius: 7))
                    .scaleEffect(0.42 + 0.18 * pulse + 0.25 * voice + 0.06 * breath)
                    .opacity(loop.connected ? (resting ? 0.35 + 0.3 * breath : 1) : 0.4)
                Circle()
                    .strokeBorder(color.opacity(busy ? 0.6 + 0.4 * pulse : resting ? 0.3 : 0.45), lineWidth: 1.5)
                if loop.state == .thinking {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.radians(t * 6))
                        .padding(1)
                }
                if agents > 0 {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                        .offset(x: 6, y: -6)
                }
            }
            .shadow(color: color.opacity(busy ? 0.5 * (0.5 + pulse) : 0), radius: 4)
        }
        .frame(width: StatusOrb.size, height: StatusOrb.size)
        .frame(width: StatusOrb.width, height: StatusOrb.width)
    }
}

/// Lets clicks fall through to the status item button underneath.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ClickTarget: NSObject {
    var onClick: () -> Void = {}
    @objc func clicked() { onClick() }
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
