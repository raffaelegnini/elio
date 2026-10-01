import Foundation
import JarvisCore

// jarvisd: always-on daemon. Owns the warm Claude session, memory and local actions,
// and serves clients over a token-protected loopback WebSocket.

setvbuf(stderr, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--mcp") {
    await MCPBridge.run()
}

let config = JarvisConfig.load()
let token: String
let memory: Memory
do {
    token = try AuthToken.loadOrCreate()
    memory = try Memory()
} catch {
    fputs("startup failed: \(error)\n", stderr)
    exit(1)
}

let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
let brain = await Brain(config: config, memory: memory, executablePath: executable)
let server = try Server(brain: brain, token: token, port: config.port)
server.start()
await brain.start()

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
let shutdown: @Sendable () -> Void = {
    Task {
        await brain.shutdown()
        exit(0)
    }
}
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: shutdown)
    source.resume()
    signalSources.append(source)
}

// Top-level code is already async on the main actor: suspend forever instead of dispatchMain().
while true { try await Task.sleep(for: .seconds(3600)) }
