import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmUnpair = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Button(action: notificationsTapped) {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: pushOK ? "bell" : "bell.slash")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notifiche").foregroundStyle(Theme.text)
                                Text(pushStatus.text).font(.footnote).foregroundStyle(pushStatus.color)
                            }
                        }
                    }
                    if model.push.authorization == .authorized {
                        Button {
                            Task { model.showToast(await model.push.sendTest()) }
                        } label: {
                            HStack(spacing: 12) { SettingsIcon(symbol: "paperplane"); Text("Invia una prova").foregroundStyle(Theme.text) }
                        }
                    }
                } header: { Text("Notifiche") } footer: {
                    Text(model.push.authorization == .denied
                         ? "Per riattivarle: Impostazioni di iOS, Notifiche, Elio, Consenti notifiche."
                         : "Elio ti scrive qui quando non sei al Mac: domande, conferme, avvisi e messaggi da ascoltare con calma. Le chiamate di Elio squillano come una telefonata.")
                }

                Section {
                    Toggle(isOn: $model.voiceOn) {
                        HStack(spacing: 12) { SettingsIcon(symbol: "speaker.wave.2"); Text("Risposte a voce") }
                    }
                    Toggle(isOn: Binding(get: { model.ambientOn }, set: { if $0 != model.ambientOn { model.toggleAmbient() } })) {
                        HStack(spacing: 12) { SettingsIcon(symbol: "ear"); Text("Ascolto continuo") }
                    }
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "waveform")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Trascrizione")
                            Text(model.voiceIn.usesPhoneRecognition
                                 ? (model.voiceIn.onDevice ? "Sul telefono, senza rete" : "Sul telefono (riconoscimento Apple)")
                                 : "Sul Mac (consenti il riconoscimento vocale per farla qui, più veloce)")
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                } header: { Text("Voce") } footer: {
                    Text("Con l'ascolto continuo Elio ti sente mentre l'app è aperta, e risponde solo quando parli con lui.")
                }

                Section {
                    Button { dismiss(); model.callElio() } label: {
                        HStack(spacing: 12) { SettingsIcon(symbol: "phone"); Text("Chiama Elio").foregroundStyle(Theme.text) }
                    }
                    .disabled(!model.client.isConnected)
                    Button {
                        Task { model.showToast(await model.push.testCall(), seconds: 5) }
                    } label: {
                        HStack(spacing: 12) { SettingsIcon(symbol: "phone.arrow.down.left"); Text("Fammi chiamare da Elio (prova)").foregroundStyle(Theme.text) }
                    }
                    .disabled(model.push.voipToken == nil)
                } header: { Text("Chiamate") } footer: {
                    Text("In chiamata parli liberamente, senza dire \"Elio\", e puoi interromperlo mentre risponde.")
                }

                Section {
                    Toggle(isOn: Binding(get: { model.macResting }, set: { _ in model.toggleRest() })) {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "moon")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Modalità riposo")
                                Text(model.macResting ? "Il Mac è a riposo" : "Mac acceso").font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                } header: { Text("Mac") } footer: {
                    Text("A riposo il Mac spegne lo schermo ma resta sveglio per agenti e monitor; Elio non parla lì e ti scrive qui. Esce appena tocchi tastiera o mouse.")
                }

                Section("Questo telefono") {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "link")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mac")
                            Text(model.pairing?.host ?? "").font(.footnote.monospaced()).foregroundStyle(Theme.text2).textSelection(.enabled)
                            Text(model.client.isConnected ? "Connesso" : "Non raggiungibile").font(.footnote)
                                .foregroundStyle(model.client.isConnected ? Theme.ok : Theme.warn)
                        }
                    }
                    Button("Dissocia questo telefono", role: .destructive) { confirmUnpair = true }
                        .frame(maxWidth: .infinity)
                }

                Section {
                    Text("Elio · DNA Factory · \(version)")
                        .font(.caption2.monospaced()).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .task { await model.push.refreshAuthorization() }
            .confirmationDialog("Dissociare questo telefono da Elio? Per riassociarlo servirà un nuovo link dal Mac.",
                                isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Dissocia", role: .destructive) { dismiss(); model.unpair() }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b)) · APNs \(PushManager.environment)"
    }

    private var pushOK: Bool {
        if case .ok = model.push.registration { return model.push.authorization == .authorized }
        return false
    }

    private var pushStatus: (text: String, color: Color) {
        switch model.push.authorization {
        case .denied: return ("Bloccate nelle impostazioni di iOS", Theme.danger)
        case .notDetermined: return ("Non attive: tocca per attivare", Theme.warn)
        default: break
        }
        switch model.push.registration {
        case .ok(_, let configured):
            return configured ? ("Attive", Theme.ok)
                              : ("Registrate, ma il Mac non ha ancora la chiave APNs (Impostazioni → Telefono sul Mac)", Theme.warn)
        case .failed(let e): return ("Il Mac non le ha registrate: tocca per riprovare (\(e))", Theme.danger)
        case .sending: return ("Registrazione sul Mac…", Theme.text2)
        case .idle:
            if let e = model.push.tokenError { return ("Token APNs non disponibile: \(e)", Theme.danger) }
            return ("Controllo…", Theme.text2)
        }
    }

    private func notificationsTapped() {
        switch model.push.authorization {
        case .notDetermined: Task { await model.push.requestPermission() }
        case .denied:
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        default: model.push.sync(force: true)
        }
    }
}

struct SettingsIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline)
            .foregroundStyle(Theme.text)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill2))
    }
}
