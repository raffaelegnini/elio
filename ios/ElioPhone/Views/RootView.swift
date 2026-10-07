import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.pairing == nil {
                PairingView()
            } else {
                MainTabs()
            }
        }
        .overlay(alignment: .top) {
            if let text = model.alarm {
                AlarmBanner(text: text) { model.dismissAlarm() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let text = model.toast {
                ToastView(text: text)
                    .padding(.bottom, 70)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.toast)
        .animation(.easeOut(duration: 0.3), value: model.alarm)
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(item: Binding(get: { model.reportId.map(ReportRef.init) }, set: { model.reportId = $0?.id })) { ref in
            ReportView(id: ref.id)
        }
        .fullScreenCover(isPresented: Binding(get: { model.showsCallScreen },
                                              set: { if !$0 { model.calls.end() } })) {
            CallView()
        }
        .alert("Associare questo iPhone?", isPresented: Binding(get: { model.pendingPairing != nil },
                                                               set: { if !$0 { model.pendingPairing = nil } }),
               presenting: model.pendingPairing) { _ in
            Button("Associa") { model.confirmPendingPairing() }
            Button("Annulla", role: .cancel) { model.pendingPairing = nil }
        } message: { p in
            Text("Il Mac \(p.host) riceverà quello che dici a Elio, gli allegati e le notifiche di questo iPhone."
                 + (p.isTailnet ? "" : "\n\nAttenzione: non è un indirizzo Tailscale (.ts.net)."))
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(active: phase == .active)
        }
        .onChange(of: model.inbox.player.state) { model.updateListening() }
    }
}

private struct ReportRef: Identifiable { let id: String }

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Elio", systemImage: "sun.max", value: AppModel.Tab.elio) {
                ConversationView()
            }
            Tab("Messaggi", systemImage: "tray", value: AppModel.Tab.messages) {
                MessagesView()
            }
            .badge(model.inbox.unread)
            Tab("To do", systemImage: "checklist", value: AppModel.Tab.todo) {
                TodoView()
            }
            Tab("Workflow", systemImage: "square.stack.3d.up", value: AppModel.Tab.workflow) {
                WorkflowView()
            }
        }
    }
}

/// Urgent, can't be missed: stays until acknowledged.
struct AlarmBanner: View {
    let text: String
    let onOK: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.danger))
            VStack(alignment: .leading, spacing: 6) {
                Text("Avviso urgente").font(.footnote.weight(.semibold)).foregroundStyle(Theme.danger)
                Text(text).font(.body).foregroundStyle(Theme.text)
                Button("Ho visto", action: onOK)
                    .buttonStyle(PillButtonStyle(kind: .danger))
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x2A1615)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.danger.opacity(0.45)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 44 / 255, green: 44 / 255, blue: 48 / 255).opacity(0.96)))
            .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
            .padding(.horizontal, 16)
    }
}

/// Buttons in the PWA's style (".act").
struct PillButtonStyle: ButtonStyle {
    enum Kind { case go, plain, danger, neutral }
    var kind: Kind = .neutral
    var small = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((small ? Font.subheadline : Font.body).weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .plain ? 6 : 12)
            .frame(minHeight: small ? 36 : 44)
            .background(RoundedRectangle(cornerRadius: small ? 10 : 12).fill(background))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .go: Theme.accentInk
        case .plain: Theme.accent
        case .danger: .white
        case .neutral: Theme.text
        }
    }

    private var background: Color {
        switch kind {
        case .go: Theme.accent
        case .plain: .clear
        case .danger: Theme.danger
        case .neutral: Theme.fill
        }
    }
}

/// Gear in the top bar of every tab.
struct SettingsButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.showSettings = true } label: {
            Image(systemName: "gearshape")
                .overlay(alignment: .topTrailing) {
                    if model.push.authorization == .notDetermined || model.push.authorization == .denied {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 3, y: -2)
                    }
                }
        }
        .accessibilityLabel("Impostazioni")
    }
}
