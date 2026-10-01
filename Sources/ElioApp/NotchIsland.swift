import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// Always-visible "island" growing out of the notch (menu bar icons can be hidden behind it):
/// compact while listening, wider while hearing / thinking / speaking. Click → dashboard,
/// right-click → quick actions.
@MainActor
final class NotchIsland {
    private var panel: NSPanel?
    private var observer: Any?

    func attach(_ loop: VoiceLoop, openDashboard: @escaping () -> Void, openSettings: @escaping () -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
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

    /// Centered under the notch (or under the menu bar on screens without one).
    private func position() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let top = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : (screen.frame.maxY - screen.visibleFrame.maxY)
        let x = screen.frame.midX - panel.frame.width / 2
        let y = screen.frame.maxY - top - panel.frame.height + 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct IslandView: View {
    let loop: VoiceLoop
    let openDashboard: () -> Void
    let openSettings: () -> Void
    @State private var hover = false

    private var active: Bool {
        [.hearing, .thinking, .speaking].contains(loop.state) || !loop.confirmations.isEmpty || !loop.questions.isEmpty
    }

    private var label: String {
        if let q = loop.questions.first { return q.question }
        if let c = loop.confirmations.first { return c.title }
        if !loop.partial.isEmpty { return loop.partial }
        if let tool = loop.activeTools.first { return Capability.describe(tool: tool) + "…" }
        switch loop.state {
        case .thinking: return "Ci penso…"
        case .speaking: return loop.turns.last(where: { $0.role == "elio" })?.text ?? "…"
        case .hearing: return "Ti ascolto"
        case .muted: return "Microfono spento"
        default: return Brand.shared.name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OrbView(state: loop.state, level: loop.level)
                    .frame(width: active || hover ? 26 : 18, height: active || hover ? 26 : 18)
                if active || hover {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                    if loop.state == .thinking || loop.state == .speaking {
                        Button { loop.stopEverything() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: "#FF6B61"))
                        }
                        .buttonStyle(.plain)
                        .help("Ferma")
                    }
                }
            }
            .padding(.horizontal, active || hover ? 12 : 8)
            .frame(width: active || hover ? 340 : 64, height: active || hover ? 38 : 26)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                    .fill(Color.black)
                    .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                        .strokeBorder(Theme.tint(loop.state).opacity(active ? 0.55 : 0.2), lineWidth: 1))
                    .shadow(color: Theme.tint(loop.state).opacity(active ? 0.35 : 0), radius: 10)
            )
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.spring(duration: 0.3)) { hover = h } }
            .onTapGesture { openDashboard() }
            .contextMenu {
                Button("Parla con \(Brand.shared.name)") { loop.activate() }
                Button(loop.muted ? "Riattiva microfono" : "Silenzia microfono") { loop.setMuted(!loop.muted) }
                Button("Briefing di oggi") { loop.submit(text: "briefing") }
                Divider()
                Button("Dashboard") { openDashboard() }
                Button("Impostazioni") { openSettings() }
            }
            .animation(.spring(duration: 0.35, bounce: 0.25), value: active)
            Spacer(minLength: 0)
        }
        .frame(width: 360, height: 64, alignment: .top)
    }
}
