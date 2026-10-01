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
        loop?.requestDaemonReload()
        saved = true
        Task { try? await Task.sleep(for: .seconds(2)); saved = false }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "Generale", voice = "Voce", brain = "Cervello", routines = "Routine",
         integrations = "Integrazioni", phone = "Telefono"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "person.crop.circle"
        case .voice: "waveform"
        case .brain: "brain"
        case .routines: "sunrise"
        case .integrations: "puzzlepiece.extension"
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
                    case .voice: VoiceSettings(model: model)
                    case .brain: BrainSettings(model: model)
                    case .routines: RoutineSettings(model: model)
                    case .integrations: IntegrationSettings(model: model)
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
        }
    }
}

private struct BrainSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Claude", note: "Usa l'account Claude Code con cui hai fatto login nel terminale.") {
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
            Field(label: "Cartelle dei progetti", text: listBinding($model.config.projectRoots), placeholder: "~/Desktop/dev")
        }
    }
}

private struct RoutineSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Briefing del mattino", note: "Parte al primo sblocco dopo l'orario minimo nei giorni feriali, o all'orario massimo.") {
            Field(label: "Dalle", text: $model.config.briefEarliest, placeholder: "07:30")
            Field(label: "Al più tardi alle", text: $model.config.briefLatest, placeholder: "09:30")
            Toggle("Sigla d'apertura", isOn: $model.config.briefOpening).font(.system(size: 12.5))
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

private struct IntegrationSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Group(title: "Integrazioni",
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
        Group(title: "Notifiche (ntfy)", note: "Arrivano solo quando sei lontano dal Mac (schermo bloccato o inattivo).") {
            Field(label: "Topic ntfy", text: $model.config.ntfyTopic)
        }
        .onAppear { status = PhoneSetup.status(config: model.config) }
    }
}

extension Color {
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .yellow
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
