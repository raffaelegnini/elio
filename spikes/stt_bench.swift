// Spike: on-device STT with SpeechAnalyzer (macOS 26), Italian.
import Foundation
import Speech
import AVFoundation

let path = CommandLine.arguments[1]
let locale = Locale(identifier: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "it_IT")
let supported = await SpeechTranscriber.supportedLocales
print("locale supported:", supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) })

let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                    reportingOptions: [.volatileResults], attributeOptions: [])
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    print("downloading model assets…"); try await req.downloadAndInstall()
}
let analyzer = SpeechAnalyzer(modules: [transcriber])
let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let start = Date()
let collector = Task {
    var final = ""
    var first: TimeInterval?
    for try await r in transcriber.results {
        if first == nil { first = Date().timeIntervalSince(start) }
        if r.isFinal { final += String(r.text.characters) }
    }
    return (final, first ?? -1)
}
try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
let (text, first) = try await collector.value
let audioSecs = Double(file.length) / file.fileFormat.sampleRate
print(String(format: "audio %.1fs | first partial %.2fs | done %.2fs", audioSecs, first, Date().timeIntervalSince(start)))
print("→", text)
