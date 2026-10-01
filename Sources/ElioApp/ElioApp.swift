import AppKit
import Observation
import ElioCore
import ElioVoice
import ServiceManagement
import SwiftUI

@main
struct ElioApp: App {
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
            Button("Parla con \(Brand.shared.name)  ⌥⌘J") { delegate.activate() }
            Button("Briefing del mattino") { loop.submit(text: "briefing") }
            Button("Recap della giornata") { loop.submit(text: "recap della giornata") }
            Button(loop.muted ? "Riattiva microfono  ⌥⌘M" : "Silenzia microfono  ⌥⌘M") { loop.setMuted(!loop.muted) }
            Button("Mostra HUD") { delegate.hud.show(pinned: true) }
            Button("Dashboard  ⌥⌘D") { delegate.showDashboard() }
            Button("Archivio  ⌥⌘A") { delegate.showArchive() }
            Button("Impostazioni…") { delegate.showSettings() }.keyboardShortcut(",")
            if !loop.diffs.isEmpty {
                Button("Revisione ultimo diff") { delegate.showDashboard(review: loop.diffs.first) }
            }
            Picker("Voce", selection: Binding(get: { loop.voiceId }, set: { loop.setVoice($0) })) {
                ForEach(VoiceLoop.voices, id: \.id) { Text($0.name).tag($0.id) }
            }
            Menu("Telefono") {
                Text(PhoneSetup.status(config: ElioConfig.load()))
                Button("Pubblica su Tailscale e copia link di accoppiamento") {
                    try? PhoneSetup.publish(config: ElioConfig.load())
                    if let url = PhoneSetup.pairingURL() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                .disabled(PhoneSetup.tailscaleCLI == nil)
            }
            Divider()
            Toggle("Ascolto sempre attivo (\"\(Brand.shared.name)…\")", isOn: Binding(
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
    private var settingsWindow: NSWindow?
    private var archiveWindow: NSWindow?
    private var archiveKey: HotKey?
    let settings = SettingsModel()
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
        let config = ElioConfig.load()
        Brand.shared.apply(config)
        WakeWord.configure(name: config.assistantName, aliases: config.wakeAliases)
        BargeIn.words.insert(config.assistantName.lowercased(), at: 0)
        guard let token = try? AuthToken.loadOrCreate() else { return }
        let loop = VoiceLoop(config: config, token: token)
        self.loop = loop
        objectWillChange.send()
        loop.onIntegrationSetup = { [weak self] id in self?.showSettings(tab: .integrations, integration: id) }
        loop.onRoutineStart = { [weak self] in self?.showDashboard(forceFront: true) }
        loop.onCard = { [weak self] card in
            // Briefing/recap details belong to the dashboard; other cards get their own window.
            if loop.routineMode, let self {
                self.dashboardState.inlineCard = card
                self.showDashboard(forceFront: true)
            } else {
                CardWindows.shared.show(title: card.title, markdown: card.body)
            }
        }
        loop.onSettingsChanged = { [weak self] cfg in
            Brand.shared.apply(cfg)
            WakeWord.configure(name: cfg.assistantName, aliases: cfg.wakeAliases)
            self?.settings.reload()
        }
        loop.onOpenView = { [weak self] view, tab, integration in
            switch view {
            case "settings":
                let tabs: [String: SettingsTab] = ["generale": .general, "voce": .voice, "cervello": .brain,
                                                   "routine": .routines, "integrazioni": .integrations, "telefono": .phone]
                self?.showSettings(tab: tabs[tab.lowercased()] ?? (integration.isEmpty ? nil : .integrations),
                                   integration: integration.isEmpty ? nil : integration)
            case "archive": self?.showArchive()
            default: self?.showDashboard()
            }
        }
        hud.attach(loop, openReview: { [weak self] diff in self?.showDashboard(review: diff) })

        hotKey = HotKey(keyCode: 38 /* J */, modifiers: [.option, .command]) { [weak self] in
            self?.activate()
        }
        // The menu bar icon can hide behind the notch: ⌥⌘D always opens the dashboard.
        dashboardKey = HotKey(keyCode: 2 /* D */, modifiers: [.option, .command]) { [weak self] in
            self?.showDashboard()
        }
        archiveKey = HotKey(keyCode: 0 /* A */, modifiers: [.option, .command]) { [weak self] in self?.showArchive() }
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        NotificationCenter.default.addObserver(forName: .openArchive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showArchive() }
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

    func showArchive() {
        guard let loop else { return }
        // Fresh view each time: the archive reloads from disk when opened.
        let window = archiveWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(Theme.bg)
            w.center()
            return w
        }()
        window.contentView = NSHostingView(rootView: ArchiveView(loop: loop))
        archiveWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showSettings(tab: SettingsTab? = nil, integration: String? = nil) {
        settings.reload()
        if let tab { settings.tab = tab }
        if let integration { settings.selectedIntegration = integration }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.bg)
            window.contentView = NSHostingView(rootView: SettingsView(model: settings, loop: loop))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showDashboard(review: DiffPayload? = nil, forceFront: Bool = false) {
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
            window.setFrameAutosaveName("ElioDashboard")
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // macOS won't let a background app take focus; for briefing/recap show it on top anyway.
        if forceFront { dashboard?.orderFrontRegardless() }
    }

    /// Shows the HUD while Elio is engaged, hides it a few seconds after.
    private func observeState(_ loop: VoiceLoop) {
        withObservationTracking {
            _ = loop.state
            _ = loop.confirmations.count
            _ = loop.questions.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                if self.dashboard?.isKeyWindow == true {
                    // Talking from the dashboard: it already shows everything.
                    self.hud.hide()
                } else if !loop.confirmations.isEmpty || !loop.questions.isEmpty {
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
    /// Agent whose live activity is open full-size.
    var theater: String?
    /// Briefing / recap details shown inside the dashboard.
    var inlineCard: CardPayload?
}

extension Notification.Name {
    static let openSettings = Notification.Name("elio.openSettings")
    static let openArchive = Notification.Name("elio.openArchive")
}
