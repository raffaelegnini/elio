import SwiftUI

/// Messaggi: what Elio left to read or listen to with calm.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        let inbox = model.inbox
        NavigationStack {
            List {
                if inbox.messages.contains(where: { !$0.read }) || inbox.player.playingAll {
                    HStack {
                        Button {
                            if inbox.player.playingAll { inbox.player.stop() } else { inbox.playUnread() }
                        } label: {
                            Label(inbox.player.playingAll ? "Ferma l'ascolto" : "Ascolta i non letti",
                                  systemImage: inbox.player.playingAll ? "stop.fill" : "headphones")
                        }
                        .buttonStyle(PillButtonStyle(kind: .go))
                        Spacer()
                        if inbox.unread > 0 {
                            Button("Segna tutti letti") { inbox.act("readAll") }
                                .buttonStyle(PillButtonStyle(kind: .plain))
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if !inbox.loaded {
                    Text(inbox.error ?? "Carico…").font(.subheadline).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                        .listRowBackground(Color.clear)
                } else if inbox.messages.isEmpty {
                    Text("Nessun messaggio. Quando Elio avrà qualcosa da raccontarti con calma, lo troverai qui.")
                        .font(.subheadline).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                        .listRowBackground(Color.clear)
                }
                ForEach(inbox.messages) { m in
                    MessageRow(message: m)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.08))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { inbox.act("delete", id: m.id) } label: { Label("Elimina", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { inbox.act(m.read ? "unread" : "read", id: m.id) } label: {
                                Label(m.read ? "Da leggere" : "Letto", systemImage: m.read ? "circle.fill" : "checkmark")
                            }
                            .tint(Theme.accent)
                        }
                }
                if inbox.messages.contains(where: \.read) {
                    Button { confirmClear = true } label: {
                        Label("Elimina i messaggi letti", systemImage: "trash").font(.subheadline)
                    }
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Messaggi")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .refreshable { await inbox.load() }
            .task { await inbox.load() }
            .confirmationDialog("Eliminare tutti i messaggi già letti?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { inbox.act("clearRead") }
            }
        }
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: InboxMessage

    var body: some View {
        let inbox = model.inbox
        let open = inbox.openId == message.id
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { inbox.openId = open ? nil : message.id }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(message.read ? .clear : Theme.accent).frame(width: 9, height: 9).padding(.top, 7)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(message.title ?? "Messaggio")
                                .fontWeight(message.read ? .medium : .semibold)
                                .foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                                Text(RelTime.string(message.date, now: ctx.date)).font(.caption.monospaced()).foregroundStyle(Theme.text3)
                            }
                        }
                        if !open {
                            Text(message.text ?? "").font(.subheadline).foregroundStyle(Theme.text2).lineLimit(2)
                        }
                        if let src = message.sourceLabel {
                            Label(src, systemImage: "eye").font(.caption).foregroundStyle(Theme.text2)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.fill))
                                .padding(.top, 4)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.text ?? "").foregroundStyle(Theme.text).textSelection(.enabled)
                    PlayerBar(id: message.id)
                    HStack(spacing: 8) {
                        Button { inbox.act(message.read ? "unread" : "read", id: message.id) } label: {
                            Label(message.read ? "Segna da leggere" : "Segna come letto", systemImage: message.read ? "circle.fill" : "checkmark")
                        }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        Button { inbox.act("delete", id: message.id) } label: { Label("Elimina", systemImage: "trash") }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(.leading, 21)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Play/pause, progress (tap to seek) and time of one message.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let player = model.inbox.player
        let state = player.state(of: id)
        HStack(spacing: 12) {
            Button { player.toggle(id) } label: {
                Image(systemName: state == .playing ? "pause.fill" : "play.fill")
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.accent))
                    .opacity(state == .loading ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .playing ? "Pausa" : "Ascolta")
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let mine = player.currentId == id
                let dur = mine ? player.duration : 0
                let cur = mine ? player.currentTime : 0
                HStack(spacing: 12) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.fill2).frame(height: 4)
                            Capsule().fill(Theme.accent).frame(width: dur > 0 ? geo.size.width * cur / dur : 0, height: 4)
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { loc in if mine { player.seek(loc.x / geo.size.width) } }
                    }
                    .frame(height: 28)
                    Text(state == .loading ? "preparo…" : dur > 0 ? "\(RelTime.clock(cur)) / \(RelTime.clock(dur))" : "")
                        .font(.caption.monospaced()).foregroundStyle(Theme.text2)
                        .frame(minWidth: 76, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg2))
    }
}
