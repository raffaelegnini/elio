import AVFoundation
import Foundation
import Speech

/// One on-device transcription per utterance (SpeechAnalyzer, macOS 26).
/// Audio never leaves the Mac.
public final class UtteranceTranscriber: @unchecked Sendable {
    public var onPartial: (@Sendable (String) -> Void)?

    private let locale: Locale
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var converter: BufferConverter?
    private var collector: Task<String, Never>?
    private let lock = NSLock()

    public init(locale: Locale) {
        self.locale = locale
    }

    /// Downloads the on-device model for the locale if it's missing. Call once at startup.
    public static func ensureModel(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    public func begin(inputFormat: AVAudioFormat) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Jarvis", "Slack", "Teamwork", "Bitbucket", "PR", "Google Meet"]

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: inputFormat),
              let converter = BufferConverter(from: inputFormat, to: format) else {
            throw VoiceError.audioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)

        let onPartial = self.onPartial
        let collector = Task<String, Never> {
            var final = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        final += text
                        onPartial?(final)
                    } else {
                        onPartial?(final + text)
                    }
                }
            } catch {
                NSLog("Jarvis transcriber error: \(error)")
            }
            return final.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        VoiceLog.write("stt begin: \(inputFormat) → \(format)")
        lock.withLock {
            self.converter = converter
            self.input = continuation
            self.analyzer = analyzer
            self.collector = collector
        }
    }

    /// Thread-safe; called from the audio thread.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        let (converter, input) = lock.withLock { (self.converter, self.input) }
        guard let converter, let input else { return }
        guard let converted = converter.convert(buffer) else {
            if convertFailures == 0 { VoiceLog.write("stt convert failed from \(buffer.format) to \(converter.output)") }
            convertFailures += 1
            return
        }
        fedBuffers += 1
        input.yield(AnalyzerInput(buffer: converted))
    }

    public private(set) var fedBuffers = 0
    private var convertFailures = 0

    public func finish() async -> String {
        let (input, analyzer, collector) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<String, Never>?) in
            defer { self.input = nil }
            return (self.input, self.analyzer, self.collector)
        }
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        return await collector?.value ?? ""
    }

    public func cancel() async {
        let (input, analyzer) = lock.withLock { (self.input, self.analyzer) }
        input?.finish()
        await analyzer?.cancelAndFinishNow()
    }
}

public enum VoiceError: Error {
    case audioFormat
    case tts(String)
}
