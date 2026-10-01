import Foundation
import JarvisCore
import Network

/// Minimal HTTP server on 127.0.0.1 for the phone PWA (published on the tailnet by `tailscale serve`).
/// Serves static files from ~/Library/Application Support/Jarvis/web and proxies TTS so the
/// ElevenLabs key never leaves the Mac. One request per connection.
final class WebServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "jarvis.web")
    private let root: URL
    private let remoteToken: String
    private let config: JarvisConfig

    init(port: UInt16, remoteToken: String, config: JarvisConfig) throws {
        root = JarvisPaths.support.appendingPathComponent("web", isDirectory: true)
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
            if case .ready = state, let port = self?.listener.port { fputs("jarvisd web on 127.0.0.1:\(port)\n", stderr) }
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
            } else if done || error != nil || buffer.count > 1_000_000 {
                conn.cancel()
            } else {
                self.read(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ req: HTTPRequest, on conn: NWConnection) async {
        switch (req.method, req.path) {
        case ("POST", "/tts"):
            guard req.headers["x-jarvis-token"] == remoteToken else { return send(conn, 401, "text/plain", Data("unauthorized".utf8)) }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty, text.count <= 2000 else {
                return send(conn, 400, "text/plain", Data("bad request".utf8))
            }
            do {
                send(conn, 200, "audio/mpeg", try await tts(Speakable.clean(text)))
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

    private func tts(_ text: String) async throws -> Data {
        guard let key = KeychainItem.read(service: "jarvis-elevenlabs") else { throw ToolError("ElevenLabs key missing") }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.elevenLabsVoiceId)?output_format=mp3_44100_64")!)
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
