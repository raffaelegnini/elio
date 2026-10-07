import Observation
import SwiftUI
import UIKit

/// One line of the conversation feed.
struct FeedItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, elio, event, alarm
        case confirm(ConfirmRequest)
        case question(QuestionRequest)
    }
    let id = UUID()
    var kind: Kind
    var text: String
    var meta = ""
    var error = false

    var cardId: String? {
        switch kind {
        case .confirm(let c): c.id
        case .question(let q): q.id
        default: nil
        }
    }
}

/// A photo or file waiting to be sent with the next message.
struct Attachment: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let mime: String
    let preview: UIImage?
    var isImage: Bool { mime.hasPrefix("image/") }
}

/// The app's state and the conversation logic: the native counterpart of the PWA's script.
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Tab: String, Hashable { case elio, messages, todo, workflow }
    enum Orb { case listening, thinking, speaking, hearing, offline }

    private(set) var pairing: Pairing?
    /// A pairing from a link, QR code or paste, waiting for the user to confirm the host.
    var pendingPairing: Pairing?
    /// A link asked to start a call: it opens the mic, so the user confirms it in the app first.
    var pendingLinkCall = false
    var tab: Tab = .elio {
        didSet { workflows.visible = tab == .workflow }
    }
    var showSettings = false
    var reportId: String?
    private(set) var feed: [FeedItem] = []
    private(set) var tasks: [TaskInfo] = []
    var alarm: String?
    private(set) var toast: String?
    private(set) var macResting = false
    private(set) var busyLabel: String?
    var attachments: [Attachment] = []
    private(set) var inCall = false
    private(set) var foreground = true

    var voiceOn: Bool {
        didSet {
            UserDefaults.standard.set(voiceOn, forKey: "elio.voice")
            if !voiceOn && !inCall { voiceOut.stop() }
        }
    }
    var ambientOn: Bool {
        didSet { UserDefaults.standard.set(ambientOn, forKey: "elio.ambient") }
    }

    let client = ElioClient()
    let voiceIn = VoiceIn()
    let voiceOut = VoiceOut()
    let calls = CallManager()
    let push = PushManager()
    let inbox = InboxModel()
    let todos = TodoModel()
    let workflows = WorkflowModel()

    private struct Turn {
        let id: String
        let elioItem: UUID
        let userItem: UUID?
        var text = ""
        var spoken = 0
        let ambient: Bool
        let sentAt = Date()
        var firstAt: Date?
        /// The user talked over Elio during a call: the rest of this reply stays written only.
        var hushed = false
    }
    private var current: Turn?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        voiceOn = defaults.object(forKey: "elio.voice") as? Bool ?? true
        ambientOn = defaults.object(forKey: "elio.ambient") as? Bool ?? false
        wire()
        if let p = Pairing.load(), p.isValid {
            pairing = p
            client.pairing = p
        }
        AudioRoute.configureAssistant()
        #if DEBUG
        if Self.demoRequested { loadDemo() }
        #endif
    }

    private func wire() {
        client.onMessage = { [weak self] in self?.handle($0) }
        client.onConnected = { [weak self] in
            guard let self else { return }
            Task { await self.inbox.load() }
            if self.todos.board != nil { Task { await self.todos.load() } }
            self.workflows.refreshSoon()
            self.push.sync()
        }
        voiceIn.client = client
        voiceIn.onUtterance = { [weak self] text, source in self?.heard(text, source) }
        voiceIn.onPartial = { [weak self] text, source in self?.partialHeard(text, source) }
        voiceIn.onError = { [weak self] in self?.showToast($0) }
        voiceOut.client = client
        voiceOut.onStart = { [weak self] in self?.updateListening() }
        voiceOut.onIdle = { [weak self] in self?.updateListening() }
        inbox.client = client
        inbox.onToast = { [weak self] in self?.showToast($0) }
        inbox.onUnreadChange = { [weak self] n in self?.push.setBadge(n) }
        inbox.onPlay = { [weak self] in self?.voiceOut.stop() }
        todos.client = client
        workflows.client = client
        push.client = client
        push.onOpen = { [weak self] kind, url in self?.openNotification(kind: kind, url: url) }
        calls.onVoipToken = { [weak self] in self?.push.setVoipToken($0) }
        calls.notifyMac = { [weak self] action, id in
            guard let client = self?.client else { return }
            Task { _ = try? await client.post("api/call/\(action)", json: ["id": id]) }
        }
        calls.onCallLive = { [weak self] in self?.startCallMode($0) }
        calls.onCallEnded = { [weak self] in self?.endCallMode() }
        calls.onMuteChanged = { [weak self] in self?.voiceIn.setMuted($0) }
    }

    // MARK: Derived state

    var orb: Orb {
        #if DEBUG
        if Self.demoRequested && client.state != .connected { return voiceOut.isSpeaking ? .speaking : .listening }
        #endif
        if client.state != .connected { return .offline }
        if voiceIn.hearing || voiceIn.pushToTalk { return .hearing }
        if voiceOut.isSpeaking { return .speaking }
        if current != nil || busyLabel != nil || voiceIn.transcribing { return .thinking }
        return .listening
    }

    var stateLabel: String {
        switch orb {
        case .offline: client.state == .connecting || client.state == .idle ? "connessione…" : "offline"
        case .hearing: "ti ascolto"
        case .speaking: "parlo"
        case .thinking: busyLabel ?? (voiceIn.transcribing ? "trascrivo" : "elaboro")
        case .listening: inCall ? "in chiamata" : "pronto"
        }
    }

    /// The in-app call screen: during a call, or an outgoing/answered one being set up (a ringing incoming
    /// call shows the system UI instead).
    var showsCallScreen: Bool {
        if inCall { return true }
        guard let call = calls.active else { return false }
        return call.answered || !call.incoming
    }

    var hint: String {
        if voiceIn.pushToTalk { return "Ti ascolto. Rilascia o tocca per inviare" }
        if ambientOn {
            return voiceIn.mode == .ambient ? "Ti ascolto sempre: chiamami \"Elio\" quando ti serve" : "Tocca l'orecchio per ascoltarti sempre"
        }
        return "Tieni premuto o tocca per parlare"
    }

    // MARK: Lifecycle

    func scenePhaseChanged(active: Bool) {
        foreground = active
        guard pairing != nil else { return }
        if active {
            client.connect()
            client.ack()
            push.start()
            push.sync()
            Task { await inbox.load() }
        } else if !inCall {
            voiceIn.endPushToTalk(send: false)
            // Keep the socket while Elio is still talking or a message plays; iOS suspends the rest anyway.
            if !voiceOut.isSpeaking && !inbox.player.isAudible { client.disconnect() }
        }
        updateListening()
    }

    /// Who should be listening right now.
    func updateListening() {
        if inCall { voiceIn.setMode(.call); return }
        let wantAmbient = ambientOn && pairing != nil && foreground && VoiceIn.micGranted
        voiceIn.setMode(wantAmbient ? .ambient : .off)
        voiceIn.setSuspended(voiceOut.isSpeaking || inbox.player.state == .playing || inbox.player.state == .loading || current != nil)
    }

    // MARK: Pairing

    private func pair(_ p: Pairing) {
        p.save()
        pairing = p
        client.pairing = p
        client.connect()
        push.start()
        Task {
            await push.requestPermission()
            push.sync(force: true)
        }
    }

    func unpair() {
        voiceOut.stop()
        inbox.player.stop()
        voiceIn.endPushToTalk(send: false)
        calls.end()
        client.disconnect()
        client.pairing = nil
        Pairing.clear()
        pairing = nil
        feed = []
        tasks = []
        current = nil
        attachments = []
        push.setBadge(0)
        updateListening()
    }

    // MARK: Links

    func open(_ url: URL) {
        if url.scheme?.lowercased() == "elio" {
            switch url.host()?.lowercased() {
            case "messages": tab = .messages
            case "todo": tab = .todo
            case "workflow": tab = .workflow
            // From a Shortcut or another app: starting a call opens the mic, so ask in the app first (iOS doesn't
            // always ask before opening a link).
            case "call": pendingLinkCall = true
            case "pair":
                if let p = Pairing.parse(url.absoluteString) { requestPairing(p) }
                else { showToast("Link di associazione non valido: serve un indirizzo .ts.net.") }
            default: tab = .elio
            }
        }
        // Any other URL is ignored: pairing never comes from an arbitrary link.
    }

    /// Never pairs silently: the user confirms the host first, and an existing pairing is never replaced
    /// from outside (unpair in Settings first).
    func requestPairing(_ p: Pairing) {
        guard pairing == nil else {
            showToast("Questo iPhone è già associato. Per cambiare Mac, dissocialo prima dalle Impostazioni.", seconds: 5)
            return
        }
        pendingPairing = p
    }

    func confirmPendingPairing() {
        guard let p = pendingPairing, pairing == nil else { pendingPairing = nil; return }
        pendingPairing = nil
        pair(p)
    }

    func openNotification(kind: String?, url: String?) {
        client.ack()
        if let url, let u = URL(string: url), u.scheme == "elio" { open(u); return }
        switch kind {
        case "messages", "message": tab = .messages
        case "todo", "todos": tab = .todo
        case "workflow", "task", "squad": tab = .workflow
        default: tab = .elio
        }
    }

    // MARK: Talking to Elio

    func say(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard client.isConnected else { showToast("Il Mac non è raggiungibile."); return }
        voiceOut.stop()
        let id = UUID().uuidString
        let user = append(FeedItem(kind: .user, text: text))
        let elio = append(FeedItem(kind: .elio, text: "…"))
        current = Turn(id: id, elioItem: elio, userItem: user, ambient: false)
        client.send(.say(id, text))
        updateListening()
    }

    /// Heard by the always-on mic: the Mac answers only if it was meant for Elio (wake word, or an awaited answer).
    private func sayAmbient(_ text: String) {
        guard client.isConnected, current == nil else { return }
        let id = UUID().uuidString
        let user = append(FeedItem(kind: .user, text: text))
        let elio = append(FeedItem(kind: .elio, text: "…"))
        current = Turn(id: id, elioItem: elio, userItem: user, ambient: true)
        client.send(.ambient(id, text))
        updateListening()
    }

    /// Text plus attachments, uploaded first and then described to Elio exactly like the PWA does.
    func sendComposed(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !text.isEmpty || !files.isEmpty else { return }
        guard !files.isEmpty else { say(text); return }
        guard client.isConnected else { showToast("Il Mac non è raggiungibile."); return }
        attachments = []
        voiceOut.stop()
        let id = UUID().uuidString
        let shown = [text, "Allegati: " + files.map(\.filename).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: "\n")
        let user = append(FeedItem(kind: .user, text: shown))
        let elio = append(FeedItem(kind: .elio, text: "…"))
        current = Turn(id: id, elioItem: elio, userItem: user, ambient: false)
        busyLabel = "invio gli allegati"
        Task {
            do {
                var paths: [String] = []
                for f in files { paths.append(try await client.upload(f.data, filename: f.filename, mime: f.mime)) }
                busyLabel = nil
                client.send(.say(id, Self.withAttachments(text, files, paths)))
            } catch {
                busyLabel = nil
                updateItem(elio) { $0.text = "Non sono riuscito a inviare gli allegati: \(error.localizedDescription)"; $0.error = true }
                if current?.id == id { current = nil }
                updateListening()
            }
        }
    }

    /// Same shape the Mac builds (Attachments.compose): the request, then the files for Elio to open.
    static func withAttachments(_ text: String, _ files: [Attachment], _ paths: [String]) -> String {
        let lines = zip(files, paths).map { f, p in
            "- \(p) (\(f.isImage ? "immagine" : f.mime == "application/pdf" ? "PDF" : "file"))"
        }
        return (text.isEmpty ? "Guarda questi allegati." : text)
            + "\n\n[Allegati dell'utente: aprili tu (Read per immagini e testo, pdf_tool, media_tool…)]\n"
            + lines.joined(separator: "\n")
    }

    func answerConfirm(_ id: String, approved: Bool) {
        client.send(.confirm(id, approved))
        feed.removeAll { $0.cardId == id }
        append(FeedItem(kind: .user, text: approved ? "Confermato" : "Annullato"))
    }

    func answerQuestion(_ id: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        client.send(.answer(id, t))
        feed.removeAll { $0.cardId == id }
        append(FeedItem(kind: .user, text: t))
    }

    func dismissAlarm() {
        alarm = nil
        client.ack()
    }

    func toggleRest() {
        guard client.isConnected else { showToast("Il Mac non è raggiungibile."); return }
        // The Mac app switches and then reports back with an "idle" event.
        client.send(.idle(!macResting))
        showToast(macResting ? "Sveglio il Mac…" : "Metto il Mac a riposo…")
    }

    // MARK: Voice in

    func micTapped() {
        if voiceIn.pushToTalk { voiceIn.endPushToTalk(); return }
        Task {
            guard await ensureMic() else { return }
            voiceOut.stop()
            inbox.player.pause()
            voiceIn.beginPushToTalk()
        }
    }

    func micReleased(afterHold: Bool) {
        if afterHold, voiceIn.pushToTalk { voiceIn.endPushToTalk() }
    }

    func toggleAmbient() {
        if ambientOn {
            ambientOn = false
            updateListening()
            showToast("Ascolto continuo spento.")
            return
        }
        Task {
            guard await ensureMic() else { return }
            ambientOn = true
            updateListening()
            showToast("Ascolto continuo attivo: rispondo solo quando dici \"Elio\".")
        }
    }

    func ensureMic() async -> Bool {
        if VoiceIn.micGranted && voiceIn.usesPhoneRecognition { return true }
        let ok = await voiceIn.requestPermissions()
        if !ok { showToast("Serve il permesso del microfono: Impostazioni, Elio, Microfono.") }
        return ok
    }

    private func heard(_ text: String, _ source: VoiceIn.Source) {
        switch source {
        case .pushToTalk:
            say(text)
        case .ambient:
            // Two words at least: "Elio" alone or a cough isn't a request.
            if text.split(separator: " ").count >= 2 { sayAmbient(text) }
        case .call:
            if voiceOut.isEcho(text) { return }
            say(text)
        }
    }

    /// Barge-in: in a call, the user talking over Elio stops its voice.
    private func partialHeard(_ text: String, _ source: VoiceIn.Source) {
        guard source == .call, voiceOut.isSpeaking, text.split(separator: " ").count >= 2, !voiceOut.isEcho(text) else { return }
        voiceOut.stop()
        current?.hushed = true
    }

    // MARK: Voice out

    private func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, voiceOn || inCall else { return }
        if inbox.player.state != .idle { inbox.player.stop() }
        voiceOut.speak(t)
    }

    // MARK: Calls

    func callElio() {
        guard client.pairing != nil else { return }
        Task {
            guard await ensureMic() else { return }
            calls.startOutgoing()
        }
    }

    private func startCallMode(_ call: CallManager.Call) {
        inCall = true
        voiceOut.stop()
        inbox.player.stop()
        voiceIn.endPushToTalk(send: false)
        client.connect()
        voiceIn.setMuted(false)
        updateListening()
        if !call.text.isEmpty {
            append(FeedItem(kind: .event, text: call.text))
            speak(call.text)
        }
    }

    private func endCallMode() {
        guard inCall else { return }
        inCall = false
        voiceOut.stop()
        voiceIn.setMuted(false)
        voiceIn.setMode(.off)
        AudioRoute.configureAssistant()
        updateListening()
    }

    // MARK: Socket messages

    private func handle(_ m: ServerMessage) {
        if m.type == "event" { handleEvent(m); return }
        guard var turn = current, m.id == turn.id else { return }
        switch m.type {
        case "delta":
            if turn.firstAt == nil {
                turn.firstAt = Date()
                client.log("first sentence after \(Int(Date().timeIntervalSince(turn.sentAt) * 1000))ms")
            }
            // Whole sentences arrive as Elio writes them: each one is spoken right away.
            turn.text += m.text ?? ""
            let text = turn.text
            updateItem(turn.elioItem) { $0.text = text }
            turn.spoken = turn.text.count
            current = turn
            if !turn.hushed { speak(m.text ?? "") }
        case "done":
            if turn.ambient && (m.text ?? "").isEmpty && turn.text.isEmpty {
                // Not meant for Elio: nothing to show.
                feed.removeAll { $0.id == turn.elioItem || $0.id == turn.userItem }
                current = nil
                updateListening()
                return
            }
            let text = m.route == "local" ? (m.text ?? "") : ((m.text?.isEmpty == false ? m.text : nil) ?? turn.text)
            let meta = [m.route ?? "", m.latencyMs.map { "\($0) ms" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            updateItem(turn.elioItem) { $0.text = text; $0.meta = meta }
            client.log("done after \(Int(Date().timeIntervalSince(turn.sentAt) * 1000))ms route=\(m.route ?? "?") server=\(m.latencyMs ?? -1)ms voice=\(voiceOn) ambient=\(turn.ambient) call=\(inCall)")
            let rest = m.route == "local" ? text : String(text.dropFirst(turn.spoken))
            current = nil
            if !turn.hushed { speak(rest) }
            updateListening()
        case "error":
            updateItem(turn.elioItem) { $0.text = m.text ?? "Qualcosa è andato storto."; $0.error = true }
            current = nil
            updateListening()
        default:
            break
        }
    }

    private func handleEvent(_ m: ServerMessage) {
        let kind = m.kind ?? ""
        switch kind {
        case "confirm":
            if let req = JSON.decode(ConfirmRequest.self, m.payload), !feed.contains(where: { $0.cardId == req.id }) {
                append(FeedItem(kind: .confirm(req), text: req.title))
                Haptics.attention()
            }
        case "question":
            if let q = JSON.decode(QuestionRequest.self, m.payload), !feed.contains(where: { $0.cardId == q.id }) {
                append(FeedItem(kind: .question(q), text: q.question))
                Haptics.attention()
            }
        case "questionResolved", "confirmResolved":
            if let id = m.id { feed.removeAll { $0.cardId == id } }
        case "task", "taskDone":
            if let t = JSON.decode(TaskInfo.self, m.payload) {
                if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
                if tasks.count > 20 { tasks.removeFirst(tasks.count - 20) }
            }
            workflows.refreshSoon()
        case "workflowEvent", "squad", "squadDone":
            workflows.refreshSoon()
        case "mode":
            workflows.mode = m.text == "silent" ? "silent" : "talking"
        case "idle":
            macResting = m.text == "on"
        case "todos":
            if let b = JSON.decode(TodoBoard.self, m.payload) { todos.set(b) }
        case "message":
            // Something for later: into the inbox, no voice.
            if let msg = JSON.decode(InboxMessage.self, m.payload) {
                inbox.add(msg)
                if tab != .messages { showToast("Nuovo messaggio: \(msg.title ?? "da Elio")") }
            }
        case "alarm":
            alarm = m.text ?? ""
            Haptics.alarm()
        default:
            break
        }
        // The device the user is on speaks; the other one still shows what matters.
        let shown: Set<String> = ["confirm", "question", "taskDone", "squadDone", "workflowAlert", "reminder",
                                  "autoDecision", "progress", "tasteFix", "alarm"]
        if let text = m.text, !text.isEmpty, m.speak == true || shown.contains(kind),
           !["confirm", "question", "message"].contains(kind) {
            append(FeedItem(kind: kind == "alarm" ? .alarm : .event, text: text))
        }
        if m.speak == true, let text = m.text { speak(text) }
    }

    // MARK: Feed helpers

    #if DEBUG
    func feedForDemo(_ items: [FeedItem]) { feed = items }
    func tasksForDemo(_ items: [TaskInfo]) { tasks = items }
    #endif

    @discardableResult
    private func append(_ item: FeedItem) -> UUID {
        feed.append(item)
        if feed.count > 200 { feed.removeFirst(feed.count - 200) }
        return item.id
    }

    private func updateItem(_ id: UUID, _ change: (inout FeedItem) -> Void) {
        guard let i = feed.firstIndex(where: { $0.id == id }) else { return }
        change(&feed[i])
    }

    func showToast(_ text: String, seconds: Double = 3.5) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

enum Haptics {
    static func attention() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func alarm() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
}
