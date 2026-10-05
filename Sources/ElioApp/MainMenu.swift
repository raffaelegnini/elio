import AppKit
import ElioCore
import ElioVoice
import ServiceManagement

/// The app's menu bar (Elio is a regular app: Dock, ⌘-Tab, menus), in Italian and complete: everything the
/// menu-bar icon and the dashboard can do, plus live lists of agents and integrations. SwiftUI installs its
/// own default menus (View, Window, Help) whenever it likes: this one is put back each time.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private var menu: NSMenu?
    private let agentsMenu = NSMenu(title: "Agenti")
    private let integrationsMenu = NSMenu(title: "Integrazioni")
    private let assistantMenu = NSMenu(title: "Assistente")
    private let elioMenu = NSMenu()
    /// Native integrations' status, fetched in the background (the menu can't wait for the daemon).
    private var natives: [NativeIntegrations.Status] = []

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    private var loop: VoiceLoop? { app.loop }
    private var name: String { Brand.shared.name }

    func install() {
        let main = menu ?? build()
        menu = main
        NSApp.mainMenu = main
        // SwiftUI may swap in its default menus later (e.g. when a window becomes key): put ours back.
        for note in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let m = self.menu, NSApp.mainMenu !== m else { return }
                    NSApp.mainMenu = m
                }
            }
        }
        // …and right after launch, when SwiftUI sets up its scenes.
        for delay in [0.3, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let m = self.menu, NSApp.mainMenu !== m else { return }
                NSApp.mainMenu = m
            }
        }
        refreshNatives()
    }

    // MARK: Building

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                      target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    private func own(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        item(title, action, key, mods, target: self)
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        i.submenu = menu
        return i
    }

    private func build() -> NSMenu {
        let main = NSMenu()

        // Elio
        elioMenu.delegate = self
        elioMenu.addItem(item("Informazioni su \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        elioMenu.addItem(.separator())
        elioMenu.addItem(own("Impostazioni…", #selector(settings), ","))
        elioMenu.addItem(own("Impostazioni › Integrazioni…", #selector(integrationsSettings)))
        elioMenu.addItem(own("Impostazioni › Telefono…", #selector(phoneSettings)))
        elioMenu.addItem(.separator())
        elioMenu.addItem(own("Copia link del telefono (Tailscale)", #selector(copyPhoneLink)))
        elioMenu.addItem(own("Avvia al login", #selector(toggleLogin)))
        elioMenu.addItem(.separator())
        elioMenu.addItem(item("Nascondi \(name)", #selector(NSApplication.hide(_:)), "h"))
        elioMenu.addItem(item("Nascondi altre", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        elioMenu.addItem(item("Mostra tutte", #selector(NSApplication.unhideAllApplications(_:))))
        elioMenu.addItem(.separator())
        elioMenu.addItem(item("Esci da \(name)", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(submenu(name, elioMenu))

        // File
        let file = NSMenu()
        file.addItem(own("Parla con \(name)", #selector(talk), "j", [.command, .option]))
        file.addItem(own("Scrivi a \(name)…", #selector(write), "n", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(own("Apri progetto nell'IDE…", #selector(openProject), "o", [.command, .shift]))
        file.addItem(own("Apri il codice di \(name) nell'IDE", #selector(openSelf)))
        file.addItem(.separator())
        file.addItem(own("Report dell'ultimo workflow", #selector(lastReport)))
        file.addItem(own("Cartella dei documenti di \(name)", #selector(openDocuments)))
        file.addItem(.separator())
        file.addItem(item("Chiudi finestra", #selector(NSWindow.performClose(_:)), "w"))
        main.addItem(submenu("File", file))

        // Modifica
        let edit = NSMenu()
        edit.addItem(item("Annulla", Selector(("undo:")), "z"))
        edit.addItem(item("Ripeti", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Taglia", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copia", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Incolla", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Elimina", #selector(NSText.delete(_:))))
        edit.addItem(item("Seleziona tutto", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = item("Trova…", #selector(NSTextView.performFindPanelAction(_:)), "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.addItem(find)
        edit.addItem(.separator())
        edit.addItem(item("Emoji e simboli", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]))
        main.addItem(submenu("Modifica", edit))

        // Vista
        let view = NSMenu()
        view.addItem(own("Dashboard", #selector(dashboard), "d", [.command, .option]))
        view.addItem(own("Missione (squadra di agenti)", #selector(mission), "s", [.command, .option]))
        view.addItem(own("IDE", #selector(ide), "i", [.command, .option]))
        view.addItem(own("Archivio", #selector(archive), "a", [.command, .option]))
        view.addItem(own("Mostra HUD", #selector(hud)))
        view.addItem(.separator())
        view.addItem(own("Ripristina la disposizione della dashboard", #selector(resetLayout)))
        view.addItem(.separator())
        view.addItem(item("Schermo intero", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(submenu("Vista", view))

        // Assistente
        assistantMenu.delegate = self
        main.addItem(submenu("Assistente", assistantMenu))

        // Agenti (live)
        agentsMenu.delegate = self
        main.addItem(submenu("Agenti", agentsMenu))

        // Integrazioni (live)
        integrationsMenu.delegate = self
        main.addItem(submenu("Integrazioni", integrationsMenu))

        // Finestra
        let window = NSMenu()
        window.addItem(item("Riduci", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Porta tutto in primo piano", #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(submenu("Finestra", window))
        NSApp.windowsMenu = window

        // Aiuto
        let help = NSMenu()
        help.addItem(own("Scorciatoie da tastiera", #selector(shortcuts)))
        help.addItem(own("Cosa sa fare \(name)", #selector(capabilities)))
        help.addItem(.separator())
        help.addItem(own("Apri i log", #selector(logs)))
        help.addItem(own("Cartella dati di \(name)", #selector(dataFolder)))
        main.addItem(submenu("Aiuto", help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Live menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === agentsMenu { fillAgents() }
        if menu === integrationsMenu { fillIntegrations(); refreshNatives() }
        if menu === assistantMenu { fillAssistant() }
        if menu === elioMenu {
            menu.items.first { $0.action == #selector(toggleLogin) }?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    private func fillAssistant() {
        let m = assistantMenu
        m.removeAllItems()
        m.addItem(own("Briefing di oggi", #selector(brief)))
        m.addItem(own("Recap della giornata", #selector(recap)))
        m.addItem(own("Pianifica la giornata (to-do)", #selector(plan)))
        m.addItem(.separator())
        let mic = own(loop?.muted == true ? "Riattiva microfono" : "Silenzia microfono", #selector(toggleMute), "m", [.command, .option])
        m.addItem(mic)
        let always = own("Ascolto sempre attivo (\"\(name)…\")", #selector(toggleAlways))
        always.state = loop?.alwaysListening == true ? .on : .off
        m.addItem(always)
        let silent = own("Workflow in silenzio (solo domande e problemi)", #selector(toggleSilent))
        silent.state = ElioConfig.load().workflowVoice == "silent" ? .on : .off
        m.addItem(silent)
        m.addItem(.separator())
        let voices = NSMenu()
        for v in VoiceLoop.voices {
            let i = own(v.name, #selector(pickVoice(_:)))
            i.representedObject = v.id
            i.state = loop?.voiceId == v.id ? .on : .off
            voices.addItem(i)
        }
        m.addItem(submenu("Voce", voices))
        let accounts = NSMenu()
        let current = ElioConfig.load().claudeAccount
        for a in ClaudeAccount.detect(including: current.dir) {
            let i = own(a.label, #selector(pickAccount(_:)))
            i.representedObject = a.dir
            i.state = a == current ? .on : .off
            accounts.addItem(i)
        }
        accounts.addItem(.separator())
        accounts.addItem(own("Login account attuale…", #selector(loginAccount)))
        m.addItem(submenu("Account Claude", accounts))
        m.addItem(.separator())
        m.addItem(own("Interrompi quello che sta facendo", #selector(stopAll), "."))
    }

    private func fillAgents() {
        let m = agentsMenu
        m.removeAllItems()
        let tasks = (loop?.tasks ?? []).reversed()
        let active = tasks.filter(\.isActive)
        if tasks.isEmpty {
            let none = NSMenuItem(title: "Nessun agente", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for t in tasks.prefix(15) {
            let label = "\(statusMark(t.status)) \(t.member ?? t.title)" + (t.project.map { "  ·  \($0)" } ?? "")
            let sub = NSMenu()
            let now = NSMenuItem(title: AgentActivity.now(t, log: loop?.taskLogs[t.id] ?? []), action: nil, keyEquivalent: "")
            now.isEnabled = false
            sub.addItem(now)
            sub.addItem(.separator())
            for (title, action) in [("Dettaglio", #selector(agentDetail(_:))), ("Apri nell'IDE", #selector(agentIDE(_:)))] {
                let i = own(title, action); i.representedObject = t.id; sub.addItem(i)
            }
            if t.isActive {
                sub.addItem(.separator())
                let pause = own(t.status == .paused ? "Riprendi" : "Pausa", #selector(agentPause(_:))); pause.representedObject = t.id
                let stop = own("Ferma", #selector(agentStop(_:))); stop.representedObject = t.id
                sub.addItem(pause); sub.addItem(stop)
            }
            let i = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            i.submenu = sub
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(own("Missione…", #selector(mission)))
        let stopAll = own("Ferma tutti gli agenti", #selector(stopAgents))
        stopAll.isEnabled = !active.isEmpty
        m.addItem(stopAll)
    }

    private func statusMark(_ s: TaskInfo.Status) -> String {
        switch s {
        case .running: "●"
        case .waitingConfirmation: "◐"
        case .paused: "❚❚"
        case .done: "✓"
        case .failed: "✕"
        case .cancelled: "–"
        }
    }

    private func fillIntegrations() {
        let m = integrationsMenu
        m.removeAllItems()
        if natives.isEmpty {
            let wait = NSMenuItem(title: "Carico lo stato…", action: nil, keyEquivalent: "")
            wait.isEnabled = false
            m.addItem(wait)
        }
        for n in natives {
            let i = own("\(n.connected ? "●" : "○") \(n.name)", #selector(openIntegration(_:)))
            i.representedObject = n.id
            i.toolTip = n.detail
            m.addItem(i)
        }
        let custom = IntegrationStore.load()
        if !custom.isEmpty {
            m.addItem(.separator())
            for c in custom {
                let i = own("\(c.enabled ? "●" : "○") \(c.name)  ·  \(c.kind == .mcp ? "MCP" : "API")", #selector(openIntegration(_:)))
                i.representedObject = c.id
                m.addItem(i)
            }
        }
        m.addItem(.separator())
        m.addItem(own("Collega un servizio nuovo…", #selector(newIntegration)))
        m.addItem(own("Gestisci integrazioni…", #selector(integrationsSettings)))
        m.addItem(own("Monitor…", #selector(monitors)))
    }

    private func refreshNatives() {
        guard let loop, loop.connected else {
            // At launch the daemon isn't there yet: try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshNatives() }
            return
        }
        Task { @MainActor in
            let (json, err) = await loop.callTool("integrations_native")
            if !err, let list = [NativeIntegrations.Status].fromJSON(json) { self.natives = list.filter { $0.id != "calendar" } + list.filter { $0.id == "calendar" } }
        }
    }

    // MARK: Actions

    @objc private func settings() { app.showSettings() }
    @objc private func integrationsSettings() { app.showSettings(tab: .integrations) }
    @objc private func phoneSettings() { app.showSettings(tab: .phone) }
    @objc private func monitors() { app.showSettings(tab: .monitors) }
    @objc private func openIntegration(_ sender: NSMenuItem) {
        app.showSettings(tab: .integrations, integration: sender.representedObject as? String)
    }
    @objc private func newIntegration() {
        app.activate()
        loop?.submit(text: "Voglio collegare un servizio nuovo: chiedimi quale e configuralo tu.")
    }
    @objc private func copyPhoneLink() {
        try? PhoneSetup.publish(config: ElioConfig.load())
        if let url = PhoneSetup.pairingURL() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
    }
    @objc private func toggleLogin() {
        try? SMAppService.mainApp.status == .enabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register()
    }
    @objc private func talk() { app.activate() }
    @objc private func write() { app.hud.show(pinned: true) }
    @objc private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Apri"
        if let first = ElioConfig.load().projectRoots.first {
            panel.directoryURL = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url { app.showIDE(path: url.path) }
    }
    @objc private func openSelf() { app.showIDE(path: ElioPaths.selfSource) }
    @objc private func lastReport() { Task { _ = await loop?.callTool("workflow_report") } }
    @objc private func openDocuments() { NSWorkspace.shared.open(ElioPaths.outputDir) }
    @objc private func dashboard() { app.showDashboard() }
    @objc private func mission() {
        app.dashboardState.squadMode = true
        app.showDashboard(forceFront: true)
    }
    @objc private func ide() { app.showIDE() }
    @objc private func archive() { app.showArchive() }
    @objc private func hud() { app.hud.show(pinned: true) }
    @objc private func resetLayout() { NotificationCenter.default.post(name: .resetDashboardLayout, object: nil) }
    @objc private func brief() { loop?.submit(text: "briefing") }
    @objc private func recap() { loop?.submit(text: "recap della giornata") }
    @objc private func plan() { loop?.submit(text: "Pianifichiamo la giornata: guarda la mia to-do list e l'agenda e aiutami a organizzarla.") }
    @objc private func toggleMute() { if let loop { loop.setMuted(!loop.muted) } }
    @objc private func toggleAlways() { if let loop { loop.alwaysListening.toggle() } }
    @objc private func toggleSilent() {
        let silent = ElioConfig.load().workflowVoice == "silent"
        Task { _ = await loop?.callTool("workflow_mode", ["mode": silent ? "talking" : "silent"]) }
    }
    @objc private func pickVoice(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { loop?.setVoice(id) } }
    @objc private func pickAccount(_ sender: NSMenuItem) {
        guard let loop, let dir = sender.representedObject as? String else { return }
        ClaudeAccounts.switchTo(ClaudeAccount(dir: dir), loop: loop)
    }
    @objc private func loginAccount() { ClaudeAccounts.login(ElioConfig.load().claudeAccount) }
    @objc private func stopAll() { loop?.stopEverything() }
    @objc private func agentDetail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        app.dashboardState.theater = id
        app.showDashboard(forceFront: true)
    }
    @objc private func agentIDE(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        IDEWindowController.shared.showAgent(loop: loop, taskId: id, cwd: loop?.tasks.first { $0.id == id }?.cwd)
    }
    @objc private func agentPause(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let t = loop?.tasks.first(where: { $0.id == id }) else { return }
        loop?.controlTask(id, t.status == .paused ? "resume" : "pause")
    }
    @objc private func agentStop(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { loop?.controlTask(id, "stop") } }
    @objc private func stopAgents() { for t in loop?.tasks ?? [] where t.isActive { loop?.controlTask(t.id, "stop") } }
    @objc private func shortcuts() {
        CardWindows.shared.show(title: "Scorciatoie", markdown: """
        | Ovunque | |
        |---|---|
        | Parla con \(name) | ⌥⌘J |
        | Dashboard | ⌥⌘D |
        | IDE | ⌥⌘I |
        | Archivio | ⌥⌘A |
        | Microfono on/off | ⌥⌘M |

        | IDE | |
        |---|---|
        | Cerca ovunque | ⇧⇧ |
        | Vai a file / recenti / riga | ⌘⇧O · ⌘E · ⌘L |
        | Cerca nel progetto | ⌘⇧F |
        | Terminale | ⌥F12 |
        | Commit / push | ⌘K · ⌘⇧K |
        | Duplica / cancella riga | ⌘D · ⌘⌫ |
        | Chiedi a \(name) sulla selezione | ⌘⌥E |
        """)
    }
    @objc private func capabilities() {
        app.activate()
        loop?.submit(text: "Mostrami a schermo cosa sai fare, diviso per aree, in breve.")
    }
    @objc private func logs() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Elio")) }
    @objc private func dataFolder() { NSWorkspace.shared.open(ElioPaths.support) }
}
