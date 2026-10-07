import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The main tab: orb, live transcript, the conversation, and the dock (voice + text + attachments).
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var typing: Bool
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false

    var body: some View {
        VStack(spacing: 0) {
            header
            OrbView(orb: model.orb, level: { model.voiceIn.level })
                .frame(height: typing ? 64 : 170)
                .animation(.easeOut(duration: 0.3), value: typing)
            Text(model.stateLabel.prefix(1).uppercased() + model.stateLabel.dropFirst())
                .font(.footnote).foregroundStyle(Theme.text2)
            if let line = model.activityLine {
                Text(line)
                    .font(.caption).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
            Text(model.voiceIn.partial)
                .font(.subheadline).foregroundStyle(Theme.text2)
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(minHeight: 20)
                .padding(.horizontal, 24)
            FeedView()
            dock
        }
        .background(Theme.bg)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Elio").font(.title2.bold()).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Circle().fill(model.client.isConnected ? Theme.ok : Theme.danger).frame(width: 6, height: 6)
                    Text(connText).font(.caption).foregroundStyle(Theme.text2)
                    if model.macResting {
                        Text("·").foregroundStyle(Theme.text2)
                        Label("Mac a riposo", systemImage: "moon").font(.caption).foregroundStyle(Theme.text2)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            Spacer()
            Button { model.callElio() } label: {
                Image(systemName: "phone.fill").frame(width: 44, height: 44).background(Circle().fill(Theme.fill))
            }
            .accessibilityLabel("Chiama Elio")
            .disabled(!model.client.isConnected)
            SettingsButton()
                .frame(width: 44, height: 44).background(Circle().fill(Theme.fill))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var connText: String {
        switch model.client.state {
        case .connected: "Connesso al Mac"
        case .connecting, .idle: "Connessione…"
        case .offline: "Offline, riprovo…"
        }
    }

    // MARK: Dock

    private var dock: some View {
        VStack(spacing: 8) {
            if !typing {
                HStack(spacing: 28) {
                    RoundToggle(on: model.ambientOn, symbol: "ear", label: model.ambientOn ? "Ascolto continuo: attivo" : "Ascolto continuo: spento") {
                        model.toggleAmbient()
                    }
                    MicButton()
                    RoundToggle(on: model.voiceOn, symbol: model.voiceOn ? "speaker.wave.2" : "speaker.slash",
                                label: model.voiceOn ? "Risposte a voce: attive" : "Risposte a voce: spente") {
                        model.voiceOn.toggle()
                        model.showToast(model.voiceOn ? "Risposte a voce attive." : "Risposte solo scritte.")
                    }
                }
                Text(model.hint).font(.caption).foregroundStyle(Theme.text3).frame(minHeight: 18)
            }
            if !model.attachments.isEmpty { attachmentChips }
            HStack(spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label("Foto", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .foregroundStyle(model.attachments.isEmpty ? Theme.text2 : Theme.accent)
                        .frame(width: 40, height: 44)
                }
                .accessibilityLabel("Allega foto o file")
                TextField("Scrivi a Elio", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    .foregroundStyle(Theme.text)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accent))
                }
                .accessibilityLabel("Invia")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { a in
                    HStack(spacing: 8) {
                        Group {
                            if let img = a.preview {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Image(systemName: "doc").foregroundStyle(Theme.text2)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .background(Theme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(a.filename).font(.footnote).lineLimit(1).foregroundStyle(Theme.text2).frame(maxWidth: 140)
                        Button { model.attachments.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark").font(.caption).foregroundStyle(Theme.text3).frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Rimuovi")
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                }
            }
        }
    }

    private func send() {
        let text = input
        input = ""
        typing = false
        model.sendComposed(text)
    }

    // MARK: Attachments

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // HEIC isn't readable everywhere on the Mac side: send JPEG.
            let image = UIImage(data: data)
            let jpeg = image?.jpegData(compressionQuality: 0.85) ?? data
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            add(Attachment(data: jpeg, filename: "foto-\(stamp)-\(i + 1).jpg", mime: "image/jpeg",
                           preview: image?.preparingThumbnail(of: CGSize(width: 120, height: 120))))
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let preview = type?.conforms(to: .image) == true ? UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 120, height: 120)) : nil
            add(Attachment(data: data, filename: url.lastPathComponent, mime: mime, preview: preview))
        }
    }

    private func add(_ a: Attachment) {
        guard a.data.count <= 60 * 1024 * 1024 else {
            model.showToast("\(a.filename) è troppo grande (massimo 60 MB).")
            return
        }
        model.attachments.append(a)
    }
}

/// Hold to talk, or tap to start and tap again to send.
struct MicButton: View {
    @Environment(AppModel.self) private var model
    @State private var downAt: Date?
    @State private var pulse = false

    var body: some View {
        let recording = model.voiceIn.pushToTalk
        Image(systemName: "mic.fill")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(recording ? .white : Theme.accentInk)
            .frame(width: 68, height: 68)
            .background(Circle().fill(recording ? Theme.danger : Theme.accent))
            .overlay(
                Circle().stroke(Theme.danger.opacity(recording && pulse ? 0 : 0.45), lineWidth: recording && pulse ? 18 : 0)
                    .scaleEffect(recording && pulse ? 1.25 : 1)
            )
            .shadow(color: Theme.accent.opacity(recording ? 0 : 0.22), radius: 12, y: 6)
            .scaleEffect(recording ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: recording)
            .onChange(of: recording) { _, on in
                pulse = false
                if on { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard downAt == nil else { return }
                        downAt = Date()
                        model.micTapped()
                    }
                    .onEnded { _ in
                        let held = downAt.map { Date().timeIntervalSince($0) > 0.45 } ?? false
                        downAt = nil
                        model.micReleased(afterHold: held)
                    }
            )
            .accessibilityLabel(recording ? "Invia" : "Parla con Elio")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.micTapped() }
    }
}

struct RoundToggle: View {
    let on: Bool
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(on ? Theme.accent : Theme.text2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(on ? Theme.accentSoft : Theme.fill))
        }
        .accessibilityLabel(label)
    }
}
