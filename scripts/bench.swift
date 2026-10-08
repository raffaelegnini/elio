#!/usr/bin/env swift
// Measures Elio's reply latency through the daemon, like a client would: time to the first sentence and to
// the full reply, per prompt. Usage: swift scripts/bench.swift [remote] ["prompt" …]
// "remote" uses the phone socket (127.0.0.1:8767, phone token) instead of the Mac one (8765).
import Foundation

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Elio")
var args = Array(CommandLine.arguments.dropFirst())
let remote = args.first == "remote"
if remote { args.removeFirst() }
let token = (try? String(contentsOf: support.appendingPathComponent(remote ? "remote-token" : "token"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let prompts = args.isEmpty ? [
    "mi senti?",
    "che ore sono?",
    "che giorno è domani?",
    "quanto fa 17 per 23?",
    "dimmi in una frase cos'è un webhook",
    "che impegni ho oggi?",
] : args

var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(remote ? 8767 : 8765)")!)
if remote { req.setValue("elio, t-\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol") }
else { req.setValue(token, forHTTPHeaderField: "X-Elio-Token") }
let ws = URLSession.shared.webSocketTask(with: req)
ws.resume()

func receive() async throws -> [String: Any] {
    while true {
        let msg = try await ws.receive()
        guard case .string(let s) = msg, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
        return obj
    }
}

print(String(format: "%-42@ %10@ %10@ %8@", "prompt" as NSString, "1ª frase" as NSString, "totale" as NSString, "via" as NSString))
for p in prompts {
    let id = UUID().uuidString
    let payload = try JSONSerialization.data(withJSONObject: ["type": "say", "id": id, "text": p])
    let t0 = Date()
    try await ws.send(.string(String(decoding: payload, as: UTF8.self)))
    var first: Double?
    while true {
        let m = try await receive()
        guard m["id"] as? String == id else { continue }
        let type = m["type"] as? String
        if type == "delta", first == nil, !((m["text"] as? String) ?? "").isEmpty { first = Date().timeIntervalSince(t0) }
        if type == "done" || type == "error" {
            let total = Date().timeIntervalSince(t0)
            let route = (m["route"] as? String) ?? type ?? "?"
            print(String(format: "%-42@ %9.2fs %9.2fs %8@", String(p.prefix(40)) as NSString, first ?? total, total, route as NSString))
            break
        }
    }
    try await Task.sleep(for: .milliseconds(400))
}
ws.cancel(with: .goingAway, reason: nil)
