import AppKit
import Observation
import JarvisCore
import JarvisVoice
import ServiceManagement
import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(delegate: delegate)
        } label: {
            MenuIcon(delegate: delegate)
        }
    }
}

/// Both views observe the delegate: `loop` is created after the first render,
/// and a plain `let` would leave the menu stuck on its initial (empty) state.
struct MenuIcon: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Image(systemName: delegate.menuIcon)
    }
}

struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        if let loop = delegate.loop {
            Text("Stato: \(loop.state.label)")
            Text(loop.connected ? "Daemon connesso" : "Daemon non raggiungibile")
            Divider()
            Button("Parla con Jarvis  ⌥⌘J") { delegate.activate() }
            Button(loop.muted ? "Riattiva microfono  ⌥⌘M" : "Silenzia microfono  ⌥⌘M") { loop.setMuted(!loop.muted) }
            Button("Mostra HUD") { delegate.hud.show(pinned: true) }
            Button("Dashboard  ⌥⌘D") { delegate.showDashboard() }
            if !loop.diffs.isEmpty {
                Button("Revisione ultimo diff") { delegate.showDashboard(review: loop.diffs.first) }
            }
            Picker("Voce", selection: Binding(get: { loop.voiceId }, set: { loop.setVoice($0) })) {
                ForEach(VoiceLoop.voices, id: \.id) { Text($0.name).tag($0.id) }
            }
            Menu("Telefono") {
                Text(PhoneSetup.status(config: JarvisConfig.load()))
                Button("Pubblica su Tailscale e copia link di accoppiamento") {
                    try? PhoneSetup.publish(config: JarvisConfig.load())
                    if let url = PhoneSetup.pairingURL() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                .disabled(PhoneSetup.tailscaleCLI == nil)
            }
            Divider()
            Toggle("Ascolto sempre attivo (\"Jarvis…\")", isOn: Binding(
                get: { loop.alwaysListening }, set: { loop.alwaysListening = $0 }))
            Toggle("Avvia al login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
            Divider()
        }
        Button("Esci") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private(set) var loop: VoiceLoop?
    let hud = HUDController()
    let dashboardState = DashboardState()
    private var dashboard: NSWindow?
    private var hotKey: HotKey?
    private var dashboardKey: HotKey?
    private var muteKey: HotKey?

    private static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    private var observer: Task<Void, Never>?

    var menuIcon: String {
        switch loop?.state {
        case .speaking: "waveform.circle.fill"
        case .thinking: "brain.head.profile"
        case .hearing: "ear.fill"
        case .muted: "mic.slash.circle"
        case .off, nil: "circle.slash"
        default: "circle.hexagongrid.circle"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let config = JarvisConfig.load()
        guard let token = try? AuthToken.loadOrCreate() else { return }
        let loop = VoiceLoop(config: config, token: token)
        self.loop = loop
        objectWillChange.send()
        hud.attach(loop, openReview: { [weak self] diff in self?.showDashboard(review: diff) })

        hotKey = HotKey(keyCode: 38 /* J */, modifiers: [.option, .command]) { [weak self] in
            self?.activate()
        }
        // The menu bar icon can hide behind the notch: ⌥⌘D always opens the dashboard.
        dashboardKey = HotKey(keyCode: 2 /* D */, modifiers: [.option, .command]) { [weak self] in
            self?.showDashboard()
        }
        muteKey = HotKey(keyCode: 46 /* M */, modifiers: [.option, .command]) { [weak self] in
            guard let loop = self?.loop else { return }
            loop.setMuted(!loop.muted)
            self?.hud.show(pinned: false)
            self?.hud.scheduleHide(after: 2.5)
        }
        // Opened by hand (not at login): show the dashboard right away.
        if !Self.launchedAtLogin { showDashboard() }
        Task { await loop.start() }
        observeState(loop)
    }

    func activate() {
        hud.show(pinned: false)
        loop?.activate()
    }

    func showDashboard(review: DiffPayload? = nil) {
        guard let loop else { return }
        if let review { dashboardState.reviewing = review }
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.bg)
            window.contentView = NSHostingView(rootView: DashboardView(loop: loop, state: dashboardState))
            window.center()
            window.setFrameAutosaveName("JarvisDashboard")
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Shows the HUD while Jarvis is engaged, hides it a few seconds after.
    private func observeState(_ loop: VoiceLoop) {
        withObservationTracking {
            _ = loop.state
            _ = loop.confirmations.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                if !loop.confirmations.isEmpty {
                    // Never let a pending confirmation disappear from view.
                    self.hud.show(pinned: true)
                } else {
                    switch loop.state {
                    case .hearing, .thinking, .speaking: self.hud.show(pinned: false)
                    case .listening, .idle, .muted: self.hud.scheduleHide(after: 6)
                    case .off: break
                    }
                }
                self.observeState(loop)
            }
        }
    }
}

extension VoiceLoop.State {
    var label: String {
        switch self {
        case .idle: "in attesa"
        case .listening: "in ascolto"
        case .hearing: "ti sento"
        case .thinking: "elaboro"
        case .speaking: "parlo"
        case .muted: "microfono spento"
        case .off: "spento"
        }
    }
}

@MainActor
@Observable
final class DashboardState {
    var reviewing: DiffPayload?
}
