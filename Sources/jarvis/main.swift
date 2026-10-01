import Foundation
import JarvisCore

// jarvis: text client for jarvisd.
//   jarvis "apri slack"   → one-shot
//   jarvis                → interactive REPL

setvbuf(stdout, nil, _IONBF, 0)

let config = JarvisConfig.load()
guard let token = try? AuthToken.loadOrCreate() else {
    fputs("token non disponibile\n", stderr)
    exit(1)
}

var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(config.port)")!)
request.setValue(token, forHTTPHeaderField: "X-Jarvis-Token")
let socket = URLSession.shared.webSocketTask(with: request)
socket.resume()

let encoder = JSONEncoder()
let decoder = JSONDecoder()

func send(_ message: ClientMessage) async throws {
    let data = try encoder.encode(message)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
}

func receive() async throws -> ServerMessage {
    switch try await socket.receive() {
    case .string(let s): return try decoder.decode(ServerMessage.self, from: Data(s.utf8))
    case .data(let d): return try decoder.decode(ServerMessage.self, from: d)
    @unknown default: throw URLError(.cannotParseResponse)
    }
}

/// Sends one utterance and prints the streamed reply. Unsolicited events are printed as they arrive.
func ask(_ text: String) async throws {
    let id = UUID().uuidString
    try await send(.say(id: id, text: text))
    var streamed = false
    while true {
        let msg = try await receive()
        if msg.type == .event {
            // Only spoken events (reminders, timers, task results); skip tool/task telemetry.
            if msg.speak == true { print("\n🔔 \(msg.text ?? "")") }
            continue
        }
        guard msg.id == id else { continue }
        switch msg.type {
        case .delta:
            if !streamed { print("jarvis › ", terminator: ""); streamed = true }
            print(msg.text ?? "", terminator: "")
        case .done:
            if !streamed { print("jarvis › \(msg.text ?? "")", terminator: "") }
            print("   [\(msg.route?.rawValue ?? "?") \(msg.latencyMs ?? -1)ms]")
            return
        case .error:
            print("\n⚠️  \(msg.text ?? "errore")")
            return
        default:
            continue
        }
    }
}

do {
    try await send(.ping)
    _ = try await receive()
} catch {
    fputs("jarvisd non raggiungibile su 127.0.0.1:\(config.port) — è in esecuzione? (\(error))\n", stderr)
    exit(1)
}

let args = CommandLine.arguments.dropFirst()

// jarvis events            → print every event (tasks, confirmations, diffs…)
// jarvis confirm <id> yes|no
if args.first == "events" {
    while true {
        let msg = try await receive()
        guard msg.type == .event else { continue }
        print("[\(msg.kind ?? "event")] id=\(msg.id ?? "-") \(msg.text ?? "")")
        if let payload = msg.payload { print("   \(payload.prefix(400))") }
    }
}
if args.first == "confirm", args.count == 3 {
    let a = Array(args)
    try await send(.confirm(id: a[1], approved: a[2] == "yes"))
    try await Task.sleep(for: .milliseconds(300))
    exit(0)
}

if !args.isEmpty {
    try await ask(args.joined(separator: " "))
    exit(0)
}

print("Jarvis — scrivi e premi invio (ctrl-d per uscire)")
while true {
    print("tu › ", terminator: "")
    guard let line = readLine() else { break }
    let text = line.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { continue }
    do { try await ask(text) } catch { print("⚠️  \(error)"); break }
}
