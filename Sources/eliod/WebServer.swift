import Foundation
import ElioCore
import Network

/// Minimal HTTP server on 127.0.0.1 for the phone PWA (published on the tailnet by `tailscale serve`).
/// Serves static files from ~/Library/Application Support/Elio/web and proxies TTS so the
/// ElevenLabs key never leaves the Mac. One request per connection.
final class WebServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "elio.web")
    private let root: URL
    private let remoteToken: String
    private let config: ElioConfig

    init(port: UInt16, remoteToken: String, config: ElioConfig) throws {
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
            } else if done || error != nil || buffer.count > 9_000_000 {
                conn.cancel()
            } else {
                self.read(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ req: HTTPRequest, on conn: NWConnection) async {
        switch (req.method, req.path) {
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
        case ("GET", "/push/key"):
            send(conn, 200, "application/json", Data("{\"key\":\"\(WebPush.shared.publicKey)\"}".utf8))
        case ("POST", "/push/subscribe"):
            guard req.headers["x-elio-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let endpoint = obj["endpoint"] as? String, endpoint.hasPrefix("https://"),
                  let keys = obj["keys"] as? [String: Any], let p = keys["p256dh"] as? String, let a = keys["auth"] as? String else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            WebPush.shared.add(.init(endpoint: endpoint, p256dh: p, auth: a))
            WebPush.shared.send(title: "Elio", body: "Notifiche attive su questo telefono.", tag: "welcome")
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

    /// Phone voice → text with ElevenLabs Scribe (the key stays on the Mac).
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

    private func send(_ conn: NWConnection, _ status: Int, _ type: String, _ body: Data, cache: Bool = false) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 502: "Bad Gateway"][status] ?? "OK"
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
