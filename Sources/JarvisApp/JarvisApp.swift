import AppKit
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
            Image(systemName: delegate.menuIcon)
        }
        Window("Jarvis", id: "dashboard") {
            if let loop = delegate.loop {
                DashboardView(loop: loop)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
    }
}

struct MenuContent: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let loop = delegate.loop {
            Text("Stato: \(loop.state.label)")
            Text(loop.connected ? "Daemon connesso" : "Daemon non raggiungibile")
            Divider()
            Button("Parla con Jarvis  ⌥⌘J") { delegate.activate() }
            Button("Mostra HUD") { delegate.hud.show(pinned: true) }
            Button("Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate()
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
    private var hotKey: HotKey?
    private var observer: Task<Void, Never>?

    var menuIcon: String {
        switch loop?.state {
        case .speaking: "waveform.circle.fill"
        case .thinking: "brain.head.profile"
        case .hearing: "ear.fill"
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
        hud.attach(loop)

        hotKey = HotKey(keyCode: 38 /* J */, modifiers: [.option, .command]) { [weak self] in
            self?.activate()
        }
        Task { await loop.start() }
        observeState(loop)
    }

    func activate() {
        hud.show(pinned: false)
        loop?.activate()
    }

    /// Shows the HUD while Jarvis is engaged, hides it a few seconds after.
    private func observeState(_ loop: VoiceLoop) {
        withObservationTracking {
            _ = loop.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                switch loop.state {
                case .hearing, .thinking, .speaking: self.hud.show(pinned: false)
                case .listening, .idle: self.hud.scheduleHide(after: 6)
                case .off: break
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
        case .off: "spento"
        }
    }
}
