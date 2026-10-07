import AppKit
import ElioCore
import ElioVoice
import Security
import SwiftUI

/// Everything configurable, so the app can be handed to colleagues.
/// Plain settings go to config.json (the daemon restarts to apply them); secrets go to the
/// Keychain, readable by both the app and the daemon.
@MainActor
@Observable
final class SettingsModel {
    var config = ElioConfig.load()
    var integrations = IntegrationStore.load()
    var selectedIntegration: String?
    var tab: SettingsTab = .general
    var saved = false

    func reload() {
        config = ElioConfig.load()
        integrations = IntegrationStore.load()
    }

    func save(loop: VoiceLoop?) {
        config.save()
        IntegrationStore.save(integrations)
        Brand.shared.apply(config)
        WakeWord.configure(name: config.assistantName, aliases: config.wakeAliases)
        loop?.applySettings(config)
        ElioApp.delegate.idle.apply(config)
        loop?.requestDaemonReload()
        saved = true
        Task { try? await Task.sleep(for: .seconds(2)); saved = false }
    }
}

/// Switching account restarts the daemon with CLAUDE_CONFIG_DIR pointing at another login.
@MainActor
enum ClaudeAccounts {
    static func switchTo(_ account: ClaudeAccount, loop: VoiceLoop?) {
        var config = ElioConfig.load()
        guard config.claudeConfigDir != account.dir else { return }
        config.claudeConfigDir = account.dir
        config.save()
        loop?.requestDaemonReload()
    }

    /// Opens Terminal on `claude` running as that account: /login there, then come back.
    static func login(_ account: ClaudeAccount) {
        let claude = ElioConfig.load().claudePath
        let env = account.dir.isEmpty ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(shellQuote(account.dir))"
        let cmd = "\(env); \(shellQuote(claude)) /login"
        let script = "tell application \"Terminal\" to do script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nactivate application \"Terminal\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Asks for a name, creates ~/.claude-<name> and opens the login for it.
    static func create() -> String? {
        let alert = NSAlert()
        alert.messageText = "Nuovo account Claude"
        alert.informativeText = "Nome dell'account (es. personale). Si apre il Terminale per il login."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !name.isEmpty else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let account = ClaudeAccount(dir: dir.path)
        login(account)
        return account.dir
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "Generale", voice = "Voce", brain = "Cervello", routines = "Routine",
         integrations = "Integrazioni", monitors = "Monitor", phone = "Telefono"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "person.crop.circle"
        case .voice: "waveform"
        case .brain: "brain"
        case .routines: "sunrise"
        case .integrations: "puzzlepiece.extension"
        case .monitors: "waveform.path.ecg"
        case .phone: "iphone"
        }
    }
}

/// Keychain items shared by the app and the daemon (both listed as trusted applications).
enum SharedKeychain {
    static var daemonPath: String {
        ElioPaths.support.appendingPathComponent("ElioDaemon.app").path
    }

    static func set(_ value: String, service: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecAttrAccount as String] = "elio"
        item[kSecValueData as String] = Data(value.utf8)
        var apps: [SecTrustedApplication] = []
        for path in [nil, daemonPath] as [String?] {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        if SecAccessCreate("Elio: \(service)" as CFString, apps as CFArray, &access) == errSecSuccess, let access {
            item[kSecAttrAccess as String] = access
        }
        SecItemAdd(item as CFDictionary, nil)
    }

    static func has(_ service: String) -> Bool { KeychainItem.read(service: service) != nil }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    let loop: VoiceLoop?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                DNALogoView(height: 20).padding(.bottom, 14)
                Text(Brand.shared.dotted).font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(4)
                    .foregroundStyle(Theme.text).padding(.bottom, 4)
                Text("IMPOSTAZIONI").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim).padding(.bottom, 18)
                ForEach(SettingsTab.allCases) { tab in
                    Button { model.tab = tab } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon).frame(width: 18)
                            Text(tab.rawValue)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: model.tab == tab ? .semibold : .regular))
                        .foregroundStyle(model.tab == tab ? Color.black : Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.tab == tab ? Theme.accent : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(model.saved ? "Salvato ✓" : "Salva e applica") { model.save(loop: loop) }
                    .buttonStyle(HUDButton(color: Theme.accent, filled: true))
                    .keyboardShortcut("s")
                Text("Il cervello si riavvia in pochi secondi per applicare.").font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            .padding(20)
            .frame(width: 210)
            .background(Theme.panel)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.tab {
                    case .general: GeneralSettings(model: model)
                    case .voice: VoiceSettings(model: model); if let loop { OwnerVoiceSettings(model: model, loop: loop) }
                    case .brain: BrainSettings(model: model)
                    case .routines: RoutineSettings(model: model)
                    case .monitors: if let loop { MonitorSettings(loop: loop) }
                    case .integrations:
                        if let loop { NativeIntegrationsSettings(loop: loop) }
                        IntegrationSettings(model: model)
                    case .phone: PhoneSettings(model: model)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

// MARK: - Building blocks

private struct Group<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Rectangle().fill(Theme.accent).frame(width: 3, height: 11)
                Text(title.uppercased()).font(Theme.mono).tracking(2).foregroundStyle(Theme.dim)
            }
            content
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.dim) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

/// Several folders: one per row, added with the Finder picker, removed with ⊖.
/// Used for the project folders (CODICE scans all of them, each one becomes a branch of the network).
private struct FolderList: View {
    let label: String
    @Binding var folders: [String]

    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(folders.enumerated()), id: \.offset) { i, folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(Theme.accent).frame(width: 16)
                        Text(folder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button { folders.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Rimuovi")
                    }
                }
                if folders.isEmpty {
                    Text("Nessuna cartella: aggiungine almeno una.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Button("Aggiungi cartella…", action: add).controlSize(.small)
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        panel.message = "Scegli le cartelle che contengono i tuoi progetti"
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in panel.urls {
            // Stored with ~ so the config works for any colleague's user name.
            let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            let expanded = Set(folders.map { ($0 as NSString).expandingTildeInPath })
            if !expanded.contains(url.path) { folders.append(path) }
        }
    }
}

private struct SecretField: View {
    let label: String
    let service: String
    @State private var value = ""
    @State private var stored = false

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
            SecureField(stored ? "•••••••• salvata nel Portachiavi" : "incolla qui", text: $value).textFieldStyle(.roundedBorder)
            Button("Salva") {
                SharedKeychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), service: service)
                value = ""
                stored = SharedKeychain.has(service)
            }
            .disabled(value.isEmpty)
            Image(systemName: stored ? "checkmark.seal.fill" : "seal").foregroundStyle(stored ? .green : Theme.dim)
        }
        .onAppear { stored = SharedKeychain.has(service) }
    }
}

private func listBinding(_ binding: Binding<[String]>) -> Binding<String> {
    Binding(get: { binding.wrappedValue.joined(separator: ", ") },
            set: { binding.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
}

// MARK: - Tabs

private struct GeneralSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Identità", note: "Il nome dell'assistente è anche la parola di attivazione.") {
            Field(label: "Nome dell'assistente", text: $model.config.assistantName)
            Field(label: "Varianti della parola", text: listBinding($model.config.wakeAliases), placeholder: "es. elica, helica")
            Field(label: "Il tuo nome", text: $model.config.userName)
            Field(label: "Come ti chiama", text: $model.config.addressAs, placeholder: "Signore")
        }
        Group(title: "Personalità",
              note: "Chi è e come parla: è l'inizio del suo prompt. {assistente}, {utente} e {titolo} diventano i valori qui sopra. Strumenti, sicurezza e regole dell'app restano fissi. Si applica dal messaggio successivo al salvataggio.") {
            TextEditor(text: Binding(
                get: { model.config.persona.isEmpty ? Brain.defaultPersona : model.config.persona },
                set: { model.config.persona = $0 == Brain.defaultPersona ? "" : $0 }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Ripristina predefinita") { model.config.persona = "" }
                    .disabled(model.config.persona.isEmpty)
            }
        }
        RestSettings(model: model)
        Group(title: "Aspetto") {
            HStack {
                Text("Colore accento").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                ColorPicker("", selection: Binding(
                    get: { Color(hex: model.config.accentColor) },
                    set: { model.config.accentColor = $0.hexString; Brand.shared.accent = $0 }))
                    .labelsHidden()
                TextField("#FFD360", text: $model.config.accentColor).textFieldStyle(.roundedBorder).frame(width: 110)
                Button("Giallo DNA") { model.config.accentColor = "#FFD360"; Brand.shared.accent = Color(hex: "#FFD360") }
            }
            Toggle("Progetti colorati per tecnologia (Magento, Laravel, React…)", isOn: Binding(
                get: { model.config.stackColors },
                set: { model.config.stackColors = $0; Brand.shared.stackColors = $0 }))
                .font(.system(size: 12.5))
        }
    }
}

/// Rest mode: the Mac stays awake for background work, the screen goes off, Elio keeps quiet.
private struct RestSettings: View {
    @Bindable var model: SettingsModel
    private let idle = ElioApp.delegate.idle

    var body: some View {
        Group(title: "Modalità riposo",
              note: "A riposo il Mac resta sveglio per agenti e monitor, \(Brand.shared.name) non parla ad alta voce e ti scrive sul telefono. Fuori dalle ore di silenzio ti chiama per allarmi, problemi nei workflow e conferme. Esce da solo appena tocchi tastiera o mouse. Con il coperchio chiuso serve l'alimentatore e uno schermo esterno, altrimenti macOS va comunque in stop.") {
            HStack {
                Toggle("Riposo automatico", isOn: $model.config.idleAuto).font(.system(size: 12.5))
                Spacer()
                Button(idle.active ? "Esci dal riposo" : "Riposo adesso") { idle.toggle() }
            }
            Stepper("Dopo \(model.config.idleMinutes) minuti senza tastiera e mouse",
                    value: $model.config.idleMinutes, in: 5...120, step: 5)
                .font(.system(size: 12.5))
                .disabled(!model.config.idleAuto)
            HStack {
                Text("Schermo").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Picker("", selection: $model.config.idleScreen) {
                    Text("Spento").tag("off")
                    Text("Luminosità al minimo").tag("dim")
                }
                .labelsHidden()
            }
            Stepper(model.config.restScreenMinutes == 0 ? "Schermata «a riposo»: no, spegni subito lo schermo"
                        : "Schermata «a riposo» per \(model.config.restScreenMinutes) minuti, poi lo schermo si spegne",
                    value: $model.config.restScreenMinutes, in: 0...30)
                .font(.system(size: 12.5))
            Field(label: "Ore di silenzio: dalle", text: $model.config.quietStart, placeholder: "23:00")
            Field(label: "Ore di silenzio: alle", text: $model.config.quietEnd, placeholder: "07:30")
            Toggle("Resta in ascolto di \"\(Brand.shared.name)\" (per dirgli \"sono tornato\")", isOn: $model.config.idleListen)
                .font(.system(size: 12.5))
        }
    }
}

private struct VoiceSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "ElevenLabs", note: "Voci della libreria (es. italiane native) richiedono un piano a pagamento.") {
            SecretField(label: "API key", service: "elio-elevenlabs")
            HStack {
                Text("Voce").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Picker("", selection: $model.config.elevenLabsVoiceId) {
                    ForEach(VoiceLoop.voices, id: \.id) { Text($0.name).tag($0.id) }
                    if !VoiceLoop.voices.contains(where: { $0.id == model.config.elevenLabsVoiceId }) {
                        Text("Personalizzata").tag(model.config.elevenLabsVoiceId)
                    }
                }
                .labelsHidden()
            }
            Field(label: "Voice ID personalizzato", text: $model.config.elevenLabsVoiceId)
            HStack {
                Text("Modello").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Picker("", selection: $model.config.elevenLabsModel) {
                    Text("Flash v2.5 (più veloce)").tag("eleven_flash_v2_5")
                    Text("Turbo v2.5").tag("eleven_turbo_v2_5")
                    Text("Multilingual v2 (più naturale, più lento)").tag("eleven_multilingual_v2")
                }
                .labelsHidden()
            }
        }
        Group(title: "Ascolto") {
            Stepper("Frasi pronunciate per risposta: \(model.config.spokenSentences)",
                    value: $model.config.spokenSentences, in: 1...10)
                .font(.system(size: 12.5))
            Toggle("Con le AirPods usa il microfono del Mac (audio più pulito)", isOn: $model.config.builtInMicWithBluetooth)
                .font(.system(size: 12.5))
            Toggle("Cancellazione dell'eco (interrompilo parlando anche con gli altoparlanti)", isOn: $model.config.echoCancellation)
                .font(.system(size: 12.5))
        }
    }
}

private struct BrainSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Claude", note: "Ogni account vive in una cartella ~/.claude-<nome>. Cambialo al volo anche dal menu nella barra (Account Claude).") {
            HStack {
                Text("Account").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Picker("", selection: $model.config.claudeConfigDir) {
                    ForEach(ClaudeAccount.detect(including: model.config.claudeConfigDir)) { Text($0.label).tag($0.dir) }
                }.labelsHidden()
                Button("Login…") { ClaudeAccounts.login(model.config.claudeAccount) }
                Button("Nuovo…") { if let dir = ClaudeAccounts.create() { model.config.claudeConfigDir = dir } }
            }
            HStack {
                Text("Modello conversazione").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Picker("", selection: $model.config.claudeModel) {
                    Text("Sonnet (veloce)").tag("sonnet"); Text("Opus (più capace)").tag("opus"); Text("Haiku").tag("haiku")
                }.labelsHidden()
            }
            HStack {
                Text("Modello agenti").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Picker("", selection: $model.config.agentModel) {
                    Text("Opus").tag("opus"); Text("Sonnet").tag("sonnet")
                }.labelsHidden()
            }
            Field(label: "Percorso di claude", text: $model.config.claudePath)
            FolderList(label: "Cartelle dei progetti", folders: $model.config.projectRoots)
        }
        Group(title: "Sicurezza degli agenti",
              note: "Push, merge, cancellazioni e messaggi chiedono sempre conferma. Test e build eseguono il codice del progetto: con questa opzione chiedono conferma anche loro.") {
            Toggle("Conferma anche build e test", isOn: $model.config.confirmCodeExecution).font(.system(size: 12.5))
        }
        Group(title: "Autonomia",
              note: "Con il browser Elio usa il tuo Chrome (dove sei già loggato) per fare le cose da solo, per esempio prendere le chiavi API delle integrazioni. Acquisti, invii e cancellazioni li chiede sempre.") {
            Toggle("Elio può usare il browser da solo", isOn: $model.config.browserAutonomy).font(.system(size: 12.5))
        }
        Group(title: "Workflow multi-agente",
              note: "Elio coordina le squadre al posto tuo: risponde ai dubbi piccoli degli agenti con i tuoi gusti, fa rivedere il loro lavoro e chiede di correggere ciò che non ti piacerebbe. Le scelte importanti le chiede sempre a te, sul Mac o sul telefono.") {
            Toggle("Elio decide le cose piccole al posto mio", isOn: $model.config.delegateDecisions).font(.system(size: 12.5))
            Toggle("Revisione del gusto sul lavoro degli agenti", isOn: $model.config.tasteReview).font(.system(size: 12.5))
            Toggle("Silenzioso mentre lavorano (solo domande, problemi e fine)", isOn: Binding(
                get: { model.config.workflowVoice == "silent" },
                set: { model.config.workflowVoice = $0 ? "silent" : "talking" })).font(.system(size: 12.5))
            Field(label: "Modello del revisore", text: $model.config.reviewModel, placeholder: "sonnet")
            Stepper("Agenti per missione (al massimo): \(model.config.maxSquadAgents)", value: $model.config.maxSquadAgents, in: 1...12)
                .font(.system(size: 12.5))
            Field(label: "Modello degli agenti di squadra", text: $model.config.squadModel, placeholder: "opus")
            Toggle("Modello leggero per le micro-modifiche (typo, testi, colori)", isOn: $model.config.smartModelRouting)
                .font(.system(size: 12.5))
                .help("Opus resta il default. Il modello leggero solo quando Elio e il router concordano che è banale: circa un lavoro su venti.")
            Toggle("Si prepara mentre parlo (ricerca veloce in parallelo)", isOn: $model.config.speechPrep).font(.system(size: 12.5))
            Toggle("Guarda lo schermo quando chiedo di quello che ho davanti (\"ho degli errori qui\", \"cosa vedi\")", isOn: $model.config.screenGlance).font(.system(size: 12.5))
        }
        Group(title: "Comandi rapidi",
              note: "Musica, app, link, volume, blocco schermo e tema li capisce il modello Apple sul Mac in meno di un secondo, senza usare Claude. Tutto il resto va a Claude.") {
            Toggle("Usa il modello Apple per i comandi semplici", isOn: $model.config.appleFastPath).font(.system(size: 12.5))
        }
    }
}

private struct RoutineSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Briefing di oggi", note: "Si adatta all'ora: al mattino la notte e la giornata, di giorno cosa è successo e cosa resta, la sera il riassunto e domani. Parte da solo al primo sblocco dopo l'orario minimo nei giorni feriali.") {
            Field(label: "Dalle", text: $model.config.briefEarliest, placeholder: "07:30")
            Field(label: "Al più tardi alle", text: $model.config.briefLatest, placeholder: "09:30")
            Toggle("Sigla d'apertura (briefing e recap)", isOn: $model.config.briefOpening).font(.system(size: 12.5))
        }
        Group(title: "Recap di fine giornata") {
            Field(label: "Orario automatico (vuoto = solo a comando)", text: $model.config.recapTime, placeholder: "18:30")
        }
        Group(title: "Meeting e impegni") {
            Stepper("Apri il Meet \(model.config.meetingLeadMinutes) minuti prima", value: $model.config.meetingLeadMinutes, in: 0...15)
                .font(.system(size: 12.5))
            Toggle("Avvisami se un meeting è iniziato e non sono entrato", isOn: $model.config.nudgeMissedMeetings)
                .font(.system(size: 12.5))
            Toggle("Ripeti i promemoria finché non dico \"fatto\"", isOn: $model.config.repeatReminders)
                .font(.system(size: 12.5))
        }
        Group(title: "Slack") {
            SecretField(label: "User token (xoxp-…)", service: "elio-slack")
            Field(label: "Canale clock in", text: $model.config.slackClockInChannel)
            Field(label: "Messaggio clock in", text: $model.config.slackClockInText)
        }
    }
}

/// Monitors: what Elio keeps an eye on by itself. Created by voice; paused, run or deleted here.
private struct MonitorSettings: View {
    let loop: VoiceLoop
    @State private var items: [Watcher] = []
    @State private var result: [String: String] = [:]
    @State private var request = ""

    var body: some View {
        Group(title: "Monitor",
              note: "Controlli automatici: a orario, su Slack, un sito, un comando, un webhook, lo schermo, l'audio del Mac, la posta, un processo, un file o una pipeline CI. Quando scattano, Elio ti manda un messaggio, ti avvisa o ti chiama, oppure fa partire un'analisi e ti manda il report.") {
            HStack {
                TextField("Es. chiamami quando finisce la pausa del Meet · dimmi quando finisce la pipeline di elio", text: $request)
                    .textFieldStyle(.roundedBorder)
                Button("Crea") {
                    loop.submit(text: "Crea un monitor: \(request)")
                    request = ""
                    Task { try? await Task.sleep(for: .seconds(12)); await reload() }
                }
                .disabled(request.isEmpty)
            }
            if items.isEmpty { Text("Nessun monitor ancora.").font(.system(size: 12.5)).foregroundStyle(Theme.dim) }
            ForEach(items) { w in row(w) }
        }
        .task { await reload() }
    }

    private func row(_ w: Watcher) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(!w.enabled ? Theme.dim : w.state == "down" ? Color(hex: "#FF6B61") : w.urgency == .call ? .orange : .green).frame(width: 8, height: 8)
                Text(w.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(summary(w)).font(Theme.mono).foregroundStyle(Theme.accent).lineLimit(1)
                Spacer()
                Button("Esegui ora") { control(w, "run") }
                Button(w.enabled ? "Pausa" : "Riattiva") { control(w, w.enabled ? "pause" : "resume") }
                Button(role: .destructive) { control(w, "delete") } label: { Image(systemName: "trash") }
            }
            Text(detail(w)).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(2)
            if let r = result[w.id] { Text(r).font(.system(size: 11.5)).foregroundStyle(.green) }
        }
        .padding(.vertical, 4)
    }

    private func summary(_ w: Watcher) -> String {
        w.triggerSummary + (w.action == .agent ? " → analisi" : " → \(w.urgencyLabel)") + (w.phone ? " +telefono" : "") + (w.once ? " · una volta" : "")
    }

    private func detail(_ w: Watcher) -> String {
        let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"
        return "Ultimo controllo \(w.lastCheck.map(f.string) ?? "mai") · ultimo allarme \(w.lastFired.map(f.string) ?? "mai")"
            + (w.lastResult.map { " · \($0)" } ?? "")
    }

    private func control(_ w: Watcher, _ action: String) {
        Task {
            let (text, _) = await loop.callTool("watch_control", ["id": w.id, "action": action])
            result[w.id] = text
            await reload()
        }
    }

    private func reload() async {
        let (json, err) = await loop.callTool("watch_list_json")
        if !err, let list = [Watcher].fromJSON(json) { items = list }
    }
}

/// Built-in integrations: status and "Collega" (the daemon does the work and keeps the secrets).
private struct NativeIntegrationsSettings: View {
    let loop: VoiceLoop
    @State private var items: [NativeIntegrations.Status] = []
    @State private var open: String?
    @State private var busy: String?
    @State private var message: [String: String] = [:]
    @State private var token = ""
    @State private var clientId = ""
    @State private var clientSecret = ""

    var body: some View {
        Group(title: "Integrazioni native", note: "Pronte all'uso: premi Collega e segui il passaggio richiesto.") {
            if items.isEmpty { Text("Controllo lo stato…").font(.system(size: 12.5)).foregroundStyle(Theme.dim) }
            ForEach(items, id: \.id) { item in row(item) }
        }
        .task { await reload() }
    }

    private func row(_ item: NativeIntegrations.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon(item.id)).frame(width: 18).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(item.detail).font(.system(size: 11.5)).foregroundStyle(item.connected ? .green : Theme.dim)
                }
                Spacer()
                if busy == item.id { ProgressView().controlSize(.small) }
                if item.connected && item.id != "calendar" {
                    Button(item.id == "gmail" ? "Aggiungi account" : "Ricollega") { start(item) }
                    if item.id != "calendar" {
                        Button("Scollega") { Task { _ = await loop.callTool("integration_disconnect", ["id": item.id]); await reload() } }
                            .foregroundStyle(Theme.dim)
                    }
                } else if !item.connected {
                    Button("Collega") { start(item) }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                }
            }
            if open == item.id {
                Text(item.help).font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                switch item.needs {
                case "token":
                    SecureField("Token (xoxp-…)", text: $token).textFieldStyle(.roundedBorder)
                    Button("Salva e verifica") { connect(item, ["token": token]) }.disabled(token.isEmpty)
                case "oauthClient":
                    TextField("ID client", text: $clientId).textFieldStyle(.roundedBorder)
                    SecureField("Client secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Accedi con Google") { connect(item, ["client_id": clientId, "client_secret": clientSecret]) }
                            .disabled(clientId.isEmpty || clientSecret.isEmpty)
                        Button("Fallo fare a \(Brand.shared.name)") {
                            loop.submit(text: "Configura tu l'integrazione Gmail: crea il client OAuth desktop su Google Cloud col browser, poi collegala con integration_connect.")
                            open = nil
                        }
                    }
                case "clientId":
                    TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Accedi a Spotify") { connect(item, ["client_id": clientId]) }.disabled(clientId.isEmpty)
                        Button("Fallo fare a \(Brand.shared.name)") { loop.submit(text: "Collega tu Spotify: crea l'app sul sito sviluppatori col browser e fai il login."); open = nil }
                    }
                default:
                    EmptyView()
                }
            }
            if let m = message[item.id] {
                Text(m).font(.system(size: 11.5)).foregroundStyle(m.hasPrefix("Errore") ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ id: String) -> String {
        switch id {
        case "slack": "number"
        case "gmail": "envelope.badge"
        case "applemail": "envelope"
        case "calendar": "calendar"
        case "spotify": "music.note"
        default: "puzzlepiece"
        }
    }

    /// Steps that need input open the row; the others connect right away (browser login / macOS permission).
    private func start(_ item: NativeIntegrations.Status) {
        if item.needs == "none" { connect(item, [:]) } else { open = open == item.id ? nil : item.id }
    }

    private func connect(_ item: NativeIntegrations.Status, _ args: [String: Any]) {
        busy = item.id
        message[item.id] = item.id == "gmail" || item.id == "spotify" ? "Si apre il browser per l'accesso…" : nil
        Task {
            var a = args
            a["id"] = item.id
            let (text, err) = await loop.callTool("integration_connect", a)
            message[item.id] = err ? "Errore: \(text.replacingOccurrences(of: "Errore: ", with: ""))" : text
            busy = nil
            token = ""; clientSecret = ""
            if !err { open = nil }
            await reload()
        }
    }

    private func reload() async {
        let (json, err) = await loop.callTool("integrations_native")
        if !err, let list = [NativeIntegrations.Status].fromJSON(json) { items = list }
    }
}

private struct IntegrationSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Integrazioni personalizzate",
              note: "Di' \"integra Teamwork\" e l'assistente cerca MCP o API, prepara la configurazione e ti chiede qui solo la chiave.") {
            if model.integrations.isEmpty {
                Text("Nessuna integrazione ancora.").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
            ForEach($model.integrations) { $item in
                IntegrationRow(item: $item, expanded: model.selectedIntegration == item.id,
                               toggle: { model.selectedIntegration = model.selectedIntegration == item.id ? nil : item.id },
                               delete: {
                                   SharedKeychain.set("", service: item.secretService)
                                   model.integrations.removeAll { $0.id == item.id }
                               })
            }
            Button("Aggiungi a mano") {
                let item = Integration(id: "nuova-\(model.integrations.count + 1)", name: "Nuova integrazione", kind: .api)
                model.integrations.append(item)
                model.selectedIntegration = item.id
            }
        }
    }
}

private struct IntegrationRow: View {
    @Binding var item: Integration
    let expanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack {
                    Circle().fill(item.isReady ? Color.green : (item.needsSecret ? Color.orange : Theme.dim)).frame(width: 8, height: 8)
                    Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(item.kind == .api ? "API" : "MCP").font(Theme.mono).foregroundStyle(Theme.accent)
                    if item.needsSecret { Text("manca la chiave").font(.system(size: 11)).foregroundStyle(.orange) }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(Theme.dim)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Field(label: "Nome", text: $item.name)
                Picker("Tipo", selection: $item.kind) { Text("API REST").tag(Integration.Kind.api); Text("MCP").tag(Integration.Kind.mcp) }
                    .pickerStyle(.segmented).frame(width: 260)
                Field(label: item.kind == .api ? "Base URL" : "URL server (MCP HTTP)", text: $item.baseURL)
                if item.kind == .mcp {
                    Field(label: "Comando (MCP stdio)", text: $item.mcpCommand, placeholder: "npx")
                    Field(label: "Argomenti", text: listBinding($item.mcpArgs))
                }
                Picker("Autenticazione", selection: $item.authType) {
                    ForEach(Integration.AuthType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 320)
                if item.authType == .header || item.authType == .query || item.kind == .mcp {
                    Field(label: "Nome header / parametro / env", text: $item.authParam)
                }
                if item.authType == .basic { Field(label: "Utente (vuoto = la chiave)", text: $item.basicUser) }
                if item.authType != .none { SecretField(label: "Chiave / token", service: item.secretService) }
                Field(label: "Documentazione", text: $item.docsURL)
                if item.kind == .mcp && !item.mcpCommand.isEmpty {
                    Text("⚠︎ Attivandola, il Mac eseguirà: \(([item.mcpCommand] + item.mcpArgs).joined(separator: " "))")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Toggle("Attiva (ho controllato la configurazione)", isOn: $item.enabled).font(.system(size: 12.5))
                if !item.notes.isEmpty {
                    Text("Note d'uso imparate").font(Theme.mono).foregroundStyle(Theme.dim)
                    Text(item.notes).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.85))
                        .textSelection(.enabled)
                }
                Button("Rimuovi", role: .destructive, action: delete)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
    }
}

private struct PhoneSettings: View {
    @Bindable var model: SettingsModel
    @State private var status = ""
    @State private var copied = false

    var body: some View {
        Group(title: "Telefono (PWA via Tailscale)") {
            Text(status).font(.system(size: 12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
            HStack {
                Button(copied ? "Link copiato ✓" : "Pubblica e copia link di accoppiamento") {
                    try? PhoneSetup.publish(config: model.config)
                    if let url = PhoneSetup.pairingURL() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        copied = true
                    }
                    status = PhoneSetup.status(config: model.config)
                }
                .disabled(PhoneSetup.tailscaleCLI == nil)
                Button("Revoca telefoni associati") {
                    try? FileManager.default.removeItem(at: ElioPaths.support.appendingPathComponent("remote-token"))
                    status = "Token revocato: dopo il riavvio serve un nuovo link di accoppiamento."
                }
            }
        }
        NativePhoneSettings(model: model)
        Group(title: "Notifiche (ntfy)", note: "Arrivano solo quando sei lontano dal Mac (schermo bloccato o inattivo).") {
            Field(label: "Topic ntfy", text: $model.config.ntfyTopic)
        }
        .onAppear { status = PhoneSetup.status(config: model.config) }
    }
}

/// The native iPhone app: Apple push (APNs) for notifications, PushKit + CallKit for real calls.
/// The .p8 key goes straight to the Keychain and is never shown again.
private struct NativePhoneSettings: View {
    @Bindable var model: SettingsModel
    @State private var keyStored = false
    @State private var status = ""
    @State private var result = ""

    var body: some View {
        Group(title: "App iPhone (notifiche e chiamate)",
              note: "Nel portale Apple Developer: crea una chiave APNs (Keys → Apple Push Notifications service), scarica il file .p8 e annota il Key ID; il Team ID è in Membership. La stessa chiave vale per notifiche e chiamate VoIP. Dopo aver cambiato Team ID, Key ID o bundle id premi Salva e applica.") {
            Field(label: "Team ID", text: $model.config.apnsTeamId, placeholder: "ABCDE12345")
            Field(label: "Key ID", text: $model.config.apnsKeyId, placeholder: "XYZ9876543")
            HStack {
                Text("Chiave APNs (.p8)").font(.system(size: 12.5)).foregroundStyle(Theme.text).frame(width: 190, alignment: .leading)
                Button("Scegli file .p8…", action: chooseKey)
                Image(systemName: keyStored ? "checkmark.seal.fill" : "seal").foregroundStyle(keyStored ? .green : Theme.dim)
                Text(keyStored ? "salvata nel Portachiavi" : "mancante").font(.system(size: 12)).foregroundStyle(Theme.dim)
                if keyStored {
                    Button("Rimuovi") { SharedKeychain.set("", service: APNs.keyService); refresh() }.controlSize(.small)
                }
            }
            Field(label: "Bundle id dell'app", text: $model.config.apnsBundleId, placeholder: "it.dnafactory.elio.phone")
            Text(status).font(.system(size: 12)).foregroundStyle(Theme.dim).textSelection(.enabled)
            HStack {
                Button("Invia notifica di prova") { Task { await test("/push/test") } }
                Button("Chiama di prova") { Task { await test("/api/call/test") } }
                if !result.isEmpty { Text(result).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2) }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        keyStored = SharedKeychain.has(APNs.keyService)
        let devices = APNsRegistry.shared.devices
        let callers = devices.filter { $0.voipToken != nil }.count
        var line = devices.isEmpty ? "Nessun iPhone registrato: apri l'app Elio sul telefono e consenti le notifiche."
            : "iPhone registrati: \(devices.count) (\(callers) per le chiamate)"
        if let last = APNs.lastResult {
            line += "\nUltimo invio (\(last.at.formatted(date: .omitted, time: .shortened))): \(last.text)"
        }
        status = line
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Usa questa chiave"
        panel.message = "Scegli la chiave APNs scaricata dal portale Apple Developer (AuthKey_XXXXXXXXXX.p8)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let pem = try? String(contentsOf: url, encoding: .utf8), (try? APNsCredentials.parseKey(pem)) != nil else {
            result = "Il file non è una chiave .p8 valida."
            return
        }
        SharedKeychain.set(pem.trimmingCharacters(in: .whitespacesAndNewlines), service: APNs.keyService)
        // AuthKey_<KEYID>.p8: the Key ID comes with the file name.
        let name = url.deletingPathExtension().lastPathComponent
        if model.config.apnsKeyId.isEmpty, name.hasPrefix("AuthKey_") { model.config.apnsKeyId = String(name.dropFirst(8)) }
        result = "Chiave salvata nel Portachiavi."
        refresh()
    }

    /// Through the daemon, which owns the call state (the phone answers to it).
    private func test(_ path: String) async {
        guard let token = try? AuthToken.loadOrCreateRemote(),
              let url = URL(string: "http://127.0.0.1:\(model.config.webPort)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-Elio-Token")
        req.httpBody = Data("{}".utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            result = code == 200 ? (path == "/push/test" ? "Notifica inviata." : "Il telefono dovrebbe squillare.")
                : error ?? String(decoding: data.prefix(200), as: UTF8.self)
        } catch {
            result = "Elio non risponde sul Mac (il servizio è avviato?)."
        }
        try? await Task.sleep(for: .seconds(2))
        refresh()
    }
}

extension Color {
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .yellow
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Owner voice enrollment and verification.
private struct OwnerVoiceSettings: View {
    @Bindable var model: SettingsModel
    let loop: VoiceLoop

    var body: some View {
        Group(title: "Riconoscimento della tua voce",
              note: "Con la voce registrata solo tu puoi dare comandi a Elio e interromperlo; chi parla intorno a te viene ignorato. L'impronta vocale resta sul Mac.") {
            if !loop.speakerModelAvailable {
                Text("Modello vocale non disponibile: reinstalla Elio.").font(.system(size: 12.5)).foregroundStyle(.orange)
            } else if let clips = loop.enrollment {
                let i = min(clips.count, VoiceLoop.enrollmentSentences.count - 1)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Leggi ad alta voce (\(clips.count + 1) di \(VoiceLoop.enrollmentSentences.count)):")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Text("“\(VoiceLoop.enrollmentSentences[i])”")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.08)))
                    ProgressView(value: Double(clips.count), total: Double(VoiceLoop.enrollmentSentences.count)).tint(Theme.accent)
                    Button("Annulla") { loop.cancelEnrollment() }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: loop.isOwnerEnrolled ? "person.wave.2.fill" : "person.wave.2")
                        .foregroundStyle(loop.isOwnerEnrolled ? .green : Theme.dim)
                    Text(loop.isOwnerEnrolled ? "Voce registrata" : "Voce non ancora registrata").font(.system(size: 12.5))
                    if let score = loop.lastOwnerScore {
                        Text(String(format: "ultima somiglianza %.2f", score)).font(Theme.mono).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Button(loop.isOwnerEnrolled ? "Registra di nuovo" : "Registra la mia voce") { loop.startEnrollment() }
                        .buttonStyle(HUDButton(color: Theme.accent, filled: true))
                    if loop.isOwnerEnrolled { Button("Elimina") { loop.forgetOwnerVoice() } }
                }
                Toggle("Solo la mia voce può comandare e interrompere Elio", isOn: $model.config.speakerVerification).font(.system(size: 12.5))
                HStack {
                    Text("Severità").font(.system(size: 12.5)).frame(width: 190, alignment: .leading)
                    Slider(value: $model.config.speakerThreshold, in: 0.3...0.85)
                    Text(String(format: "%.2f", model.config.speakerThreshold)).font(Theme.mono).frame(width: 40)
                }
            }
        }
    }
}
