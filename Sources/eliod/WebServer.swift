import Foundation
import ElioCore
import Network
import Security

/// Minimal HTTP server on 127.0.0.1 for the phone PWA (published on the tailnet by `tailscale serve`).
/// Serves static files from ~/Library/Application Support/Elio/web and proxies TTS so the
/// ElevenLabs key never leaves the Mac. One request per connection.
final class WebServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "elio.web")
    private let root: URL
    private let remoteToken: String
    private let config: ElioConfig
    private let brain: Brain

    init(port: UInt16, remoteToken: String, config: ElioConfig, brain: Brain) throws {
        self.brain = brain
        root = ElioPaths.support.appendingPathComponent("web", isDirectory: true)
        self.remoteToken = remoteToken
        self.config = config
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.read(conn, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { fputs("eliod web on 127.0.0.1:\(port)\n", stderr) }
        }
        listener.start(queue: queue)
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task { await self.respond(request, on: conn) }
            } else if done || error != nil || buffer.count > Attachments.maxUpload + 65_536 {
                conn.cancel()
            } else {
                self.read(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ req: HTTPRequest, on conn: NWConnection) async {
        switch (req.method, req.path) {
        case ("POST", "/tts/ticket"):
            // An <audio> element can't send headers: it gets a one-shot ticket instead of the pairing token,
            // so neither the token nor the text ever appears in a URL.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty, text.count <= 2000 else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            let ticket = TTSTickets.shared.issue(text)
            send(conn, 200, "application/json", Data("{\"ticket\":\"\(ticket)\"}".utf8))
        case ("GET", let p) where p.hasPrefix("/tts/stream?"):
            // Streaming voice for the phone: <audio src> starts playing on the first bytes.
            let k = URLComponents(string: "http://x\(p)")?.queryItems?.first { $0.name == "k" }?.value ?? ""
            guard let text = TTSTickets.shared.redeem(k) else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            await streamTTS(Speakable.clean(text), on: conn)
        case ("POST", "/tts/pcm"):
            // The iPhone app's voice: raw 16-bit mono PCM at 16 kHz (voice quality, a third less data over the tailnet) streamed as ElevenLabs makes it, played as it
            // arrives (first sound in ~0.3 s). Authenticated by header, so no one-shot ticket to get wrong.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty, text.count <= 2000 else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            await streamTTS(Speakable.clean(text), on: conn, format: "pcm_16000", contentType: "audio/L16; rate=16000; channels=1")
        case ("POST", "/tts"):
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty, text.count <= 2000 else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            do {
                send(conn, 200, "audio/mpeg", try await tts(Speakable.clean(text)))
            } catch {
                send(conn, 502, "text/plain", Data("\(error)".utf8))
            }
        case ("GET", let p) where p.hasPrefix("/manifest.webmanifest?"):
            // Home-screen apps on iOS don't share storage with Safari: the app added from a paired page
            // starts already paired (start_url carries the token, only if it's the right one).
            let pair = URLComponents(string: "http://x\(p)")?.queryItems?.first { $0.name == "pair" }?.value ?? ""
            guard pair == remoteToken, let data = try? Data(contentsOf: root.appendingPathComponent("manifest.webmanifest")),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return send(conn, 404, "text/plain", Data("not found".utf8))
            }
            obj["start_url"] = "./#pair=\(pair)"
            send(conn, 200, "application/manifest+json", (try? JSONSerialization.data(withJSONObject: obj)) ?? data)
        case ("GET", let p) where p.hasPrefix("/api/"):
            // Workflow progress and reports for the phone (read-only).
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            let comps = URLComponents(string: "http://x\(p)")
            let id = comps?.queryItems?.first { $0.name == "id" }?.value ?? ""
            switch comps?.path {
            case "/api/workflows":
                let json = (try? await WorkflowFeed.json(memory: brain.memory, tasks: brain.tasks)) ?? "{}"
                send(conn, 200, "application/json", Data(SecretFilter.redact(json).utf8))
            case "/api/todos":
                send(conn, 200, "application/json", Data(SecretFilter.redact(await brain.memory.todoBoard().jsonString()).utf8))
            case "/api/messages":
                send(conn, 200, "application/json", Data(await Self.inboxJSON().utf8))
            case "/api/workflow":
                guard let report = await WorkflowReport.build(id: id, memory: brain.memory, tasks: brain.tasks) else {
                    return send(conn, 404, "text/plain", Data("not found".utf8))
                }
                send(conn, 200, "application/json", Data(SecretFilter.redact(report.jsonString()).utf8))
            default:
                send(conn, 404, "text/plain", Data("not found".utf8))
            }
        case ("POST", "/api/todos"):
            // The phone's one-tap actions: toggle, add, remove, focus, tomorrow, today, important, carry.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            try? await TodoTools.quickAction(obj, ctx: await brain.toolContext)
            send(conn, 200, "application/json", Data(SecretFilter.redact(await brain.memory.todoBoard().jsonString()).utf8))
        case ("POST", "/api/messages"):
            // The phone's inbox actions: read, unread, delete, readAll, clearRead.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let action = obj["action"] as? String else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            await MessageBox.shared.apply(action: action, id: obj["id"] as? String)
            send(conn, 200, "application/json", Data(await Self.inboxJSON().utf8))
        case ("POST", "/api/upload"):
            // A photo or file attached to a message from the phone: saved on the Mac, its path goes in the message.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard !req.body.isEmpty, req.body.count <= Attachments.maxUpload else {
                return send(conn, 413, "text/plain", Data("File vuoto o troppo grande (massimo 60 MB).".utf8))
            }
            let name = (req.headers["x-filename"]?.removingPercentEncoding).flatMap { $0.isEmpty ? nil : $0 } ?? "allegato"
            do {
                let file = try Attachments.store(Data(req.body), name: name)
                let json = try JSONSerialization.data(withJSONObject: ["path": file.path, "name": name, "size": req.body.count])
                send(conn, 200, "application/json", json)
            } catch {
                send(conn, 500, "text/plain", Data("Non sono riuscito a salvare il file.".utf8))
            }
        case ("POST", "/api/log"):
            // The phone app's timings and audio errors (it has no console the user can see): one line each.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            let line = String(decoding: req.body.prefix(2000), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Elio/phone.log")
            let entry = "[\(ISO8601DateFormatter().string(from: Date()))] \(SecretFilter.redact(line))\n"
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
            else { try? Data(entry.utf8).write(to: file) }
            send(conn, 204, "text/plain", Data())
        case ("POST", "/api/ack"):
            // The phone was opened or a call notification tapped: stop ringing.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            await Alerts.shared.acknowledge()
            send(conn, 200, "application/json", Data("{\"ok\":true}".utf8))
        case ("POST", "/push/test"):
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            let n = PhonePush.deviceCount
            guard n > 0 else { return send(conn, 409, "text/plain", Data("Nessun telefono iscritto alle notifiche.".utf8)) }
            PhonePush.send(title: "Elio", body: "Prova: le notifiche funzionano.", tag: "test")
            send(conn, 200, "application/json", Data("{\"ok\":true,\"devices\":\(n)}".utf8))
        case ("POST", "/api/apns/register"):
            // The native iPhone app: APNs token (alerts) and PushKit token (calls).
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let token = obj["token"] as? String else {
                return send(conn, 400, "application/json", Self.json(["ok": false, "error": "token mancante"]))
            }
            do {
                let device = try APNsRegistry.shared.register(
                    token: token, voipToken: obj["voipToken"] as? String,
                    bundleId: obj["bundleId"] as? String ?? ElioConfig.load().apnsBundleId,
                    env: obj["env"] as? String ?? "production")
                send(conn, 200, "application/json", Self.json(["ok": true, "devices": APNsRegistry.shared.devices.count,
                                                               "voip": device.voipToken != nil, "configured": APNs.isConfigured]))
            } catch {
                send(conn, 400, "application/json", Self.json(["ok": false, "error": "\(error)"]))
            }
        case ("POST", "/api/call/test"):
            // "Chiama di prova" from the Mac's Settings.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard APNs.shared.canCall else {
                return send(conn, 409, "application/json", Self.json(["ok": false, "error": "Nessuna app iPhone che può squillare, o APNs non configurato."]))
            }
            guard let call = await PhoneCalls.shared.start(text: "Prova: questa è una chiamata di \(config.assistantName). Funziona.",
                                                           title: "Chiamata di prova", phone: true) else {
                return send(conn, 502, "application/json", Self.json(["ok": false, "error": APNs.lastResult?.text ?? "invio non riuscito"]))
            }
            send(conn, 200, "application/json", Data("{\"ok\":true,\"call\":\(call.jsonString())}".utf8))
        case ("POST", "/api/call/answer"), ("POST", "/api/call/decline"), ("POST", "/api/call/end"):
            // CallKit on the iPhone: picked up (Mac stops ringing), declined (urgent push + inbox), hung up.
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let id = obj["id"] as? String, !id.isEmpty else {
                return send(conn, 400, "application/json", Self.json(["ok": false, "error": "id mancante"]))
            }
            let call: PhoneCall? = switch req.path {
            case "/api/call/answer": await PhoneCalls.shared.answer(id)
            case "/api/call/decline": await PhoneCalls.shared.decline(id)
            default: await PhoneCalls.shared.end(id)
            }
            guard let call else { return send(conn, 404, "application/json", Self.json(["ok": false, "error": "chiamata sconosciuta"])) }
            send(conn, 200, "application/json", Data("{\"ok\":true,\"call\":\(SecretFilter.redact(call.jsonString()))}".utf8))
        case ("GET", "/push/key"):
            send(conn, 200, "application/json", Data("{\"key\":\"\(WebPush.shared.publicKey)\"}".utf8))
        case ("POST", "/push/subscribe"):
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let endpoint = obj["endpoint"] as? String, endpoint.hasPrefix("https://"),
                  let keys = obj["keys"] as? [String: Any], let p = keys["p256dh"] as? String, let a = keys["auth"] as? String else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            let isNew = !WebPush.shared.subscriptions.contains { $0.endpoint == endpoint }
            WebPush.shared.add(.init(endpoint: endpoint, p256dh: p, auth: a))
            // Sent once per phone, not at every re-subscription the app does on launch.
            if isNew { WebPush.shared.send(title: "Elio", body: "Notifiche attive su questo telefono.", tag: "welcome") }
            send(conn, 200, "application/json", Data("{\"ok\":true}".utf8))
        case ("POST", let path) where path.hasPrefix("/hook/"):
            // Monitor webhooks: /hook/<id>?key=<secret> (each monitor has its own secret).
            let comps = URLComponents(string: "http://x\(path)")
            let id = String(comps?.path.dropFirst("/hook/".count) ?? "")
            let key = comps?.queryItems?.first { $0.name == "key" }?.value ?? req.headers["x-elio-key"] ?? ""
            let ok = await WatcherEngine.shared.webhook(id: id, key: key, body: String(decoding: req.body, as: UTF8.self))
            send(conn, ok ? 200 : 404, "application/json", Data(ok ? "{\"ok\":true}".utf8 : "{\"ok\":false}".utf8))
        case ("POST", "/stt"):
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            do {
                let text = try await stt(req.body, mime: req.headers["content-type"] ?? "audio/mp4")
                let json = try JSONSerialization.data(withJSONObject: ["text": text])
                send(conn, 200, "application/json", json)
            } catch {
                send(conn, 502, "text/plain", Data("\(error)".utf8))
            }
        case ("GET", _):
            var path = req.path.split(separator: "?").first.map(String.init) ?? "/"
            if path == "/" { path = "/index.html" }
            // No path traversal: only plain file names in the web root.
            let name = String(path.dropFirst())
            guard !name.contains(".."), !name.contains("/"),
                  let data = try? Data(contentsOf: root.appendingPathComponent(name)) else {
                return send(conn, 404, "text/plain", Data("not found".utf8))
            }
            send(conn, 200, Self.mime(name), data, cache: name != "index.html" && name != "sw.js")
        default:
            send(conn, 405, "text/plain", Data("method not allowed".utf8))
        }
    }

    static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)) ?? Data("{}".utf8)
    }

    /// Phone voice → text with ElevenLabs Scribe (the key stays on the Mac).
    static func inboxJSON() async -> String {
        let messages = await MessageBox.shared.all()
        struct Inbox: Encodable { let unread: Int; let messages: [InboxMessage] }
        return SecretFilter.redact(Inbox(unread: messages.filter { !$0.read }.count, messages: messages).jsonString())
    }

    private func stt(_ audio: Data, mime: String) async throws -> String {
        guard let key = KeychainItem.read(service: "elio-elevenlabs") else { throw ToolError("ElevenLabs key missing") }
        guard !audio.isEmpty, audio.count < 8_000_000 else { throw ToolError("audio vuoto o troppo lungo") }
        let boundary = "elio-\(UUID().uuidString)"
        let ext = mime.contains("webm") ? "webm" : mime.contains("wav") ? "wav" : "m4a"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field("model_id", "scribe_v1")
        field("language_code", "ita")
        field("tag_audio_events", "false")
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body += audio
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("ElevenLabs STT \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tts(_ text: String) async throws -> Data {
        guard let key = KeychainItem.read(service: "elio-elevenlabs") else { throw ToolError("ElevenLabs key missing") }
        let voice = ElioConfig.load().elevenLabsVoiceId  // follows the voice picked in the app
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_64")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "model_id": config.elevenLabsModel,
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "speed": 1.05],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError("ElevenLabs \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    /// ElevenLabs' streaming endpoint relayed chunk by chunk (HTTP chunked encoding): first audio in ~0.3 s
    /// instead of waiting for the whole sentence.
    private func streamTTS(_ text: String, on conn: NWConnection, format: String = "mp3_44100_64", contentType: String = "audio/mpeg") async {
        guard let key = KeychainItem.read(service: "elio-elevenlabs") else { return send(conn, 502, "text/plain", Data("no key".utf8)) }
        let voice = ElioConfig.load().elevenLabsVoiceId
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=\(format)&optimize_streaming_latency=3")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "model_id": config.elevenLabsModel,
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "speed": 1.05],
        ])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return send(conn, 502, "text/plain", Data("tts".utf8)) }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\n" +
                "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            var chunk = Data()
            chunk.reserveCapacity(4096)
            func flush() {
                guard !chunk.isEmpty else { return }
                var framed = Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8)
                framed += chunk
                framed += Data("\r\n".utf8)
                conn.send(content: framed, completion: .contentProcessed { _ in })
                chunk.removeAll(keepingCapacity: true)
            }
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 2048 { flush() }
            }
            flush()
            conn.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in conn.cancel() })
        } catch {
            conn.cancel()
        }
    }

    private func send(_ conn: NWConnection, _ status: Int, _ type: String, _ body: Data, cache: Bool = false) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      409: "Conflict", 502: "Bad Gateway"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += cache ? "Cache-Control: max-age=3600\r\n" : "Cache-Control: no-cache\r\n"
        head += "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func mime(_ name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "json", "webmanifest": "application/manifest+json"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "css": "text/css"
        default: "application/octet-stream"
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Nil until the full request (headers + Content-Length body) is in the buffer.
    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(first[0])
        path = String(first[1])
        self.headers = headers
        body = data[bodyStart..<(bodyStart + length)]
    }
}

/// One-shot, short-lived tickets for streamed speech: each one plays one sentence once, within a minute.
final class TTSTickets: @unchecked Sendable {
    static let shared = TTSTickets()
    private let lock = NSLock()
    private var tickets: [String: (text: String, expires: Date)] = [:]

    func issue(_ text: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let ticket = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            let now = Date()
            tickets = tickets.filter { $0.value.expires > now }
            tickets[ticket] = (text, now.addingTimeInterval(60))
        }
        return ticket
    }

    func redeem(_ ticket: String) -> String? {
        lock.withLock {
            guard let t = tickets.removeValue(forKey: ticket), t.expires > Date() else { return nil }
            return t.text
        }
    }
}
