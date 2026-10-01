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
        context.contextualStrings[.general] = ["Elio", "Slack", "Teamwork", "Bitbucket", "PR", "Google Meet"]

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
                NSLog("Elio transcriber error: \(error)")
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

/// One long-lived on-device transcription of everything the mic hears (while not muted).
/// Unlike per-utterance sessions it never misses the first syllable or a short word like the
/// assistant's name, and uses context across sentences. Final results mark utterance ends.
public final class ContinuousTranscriber: @unchecked Sendable {
    public var onVolatile: (@Sendable (String) -> Void)?
    public var onFinal: (@Sendable (String) -> Void)?

    private let locale: Locale
    private let contextWords: [String]
    private let lock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var converter: BufferConverter?
    private var reader: Task<Void, Never>?
    private var startedAt = Date()
    /// Final text since the last `takeSegment()`.
    private var segment = ""
    private var latestVolatile = ""

    public init(locale: Locale, contextWords: [String]) {
        self.locale = locale
        self.contextWords = contextWords
    }

    public func start(inputFormat: AVAudioFormat) async throws {
        await stop()
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextWords
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat),
              let converter = BufferConverter(from: inputFormat, to: format) else { throw VoiceError.audioFormat }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)
        let onVolatile = self.onVolatile, onFinal = self.onFinal
        let reader = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self?.lock.withLock {
                            self?.segment += (self?.segment.isEmpty == false ? " " : "") + text
                            self?.latestVolatile = ""
                        }
                        onFinal?(text)
                    } else {
                        self?.lock.withLock { self?.latestVolatile = text }
                        onVolatile?(text)
                    }
                }
            } catch {
                VoiceLog.write("continuous transcriber ended: \(error)")
            }
        }
        lock.withLock {
            self.converter = converter
            self.input = continuation
            self.analyzer = analyzer
            self.reader = reader
            self.startedAt = Date()
        }
        VoiceLog.write("continuous stt started: \(inputFormat) → \(format)")
    }

    /// Thread-safe; called from the audio thread for every mic buffer.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        let (converter, input) = lock.withLock { (self.converter, self.input) }
        guard let converter, let input, let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    public var age: TimeInterval { lock.withLock { Date().timeIntervalSince(startedAt) } }

    /// Text heard so far in the current segment (finals + the pending volatile part).
    public var currentText: String {
        lock.withLock { [segment, latestVolatile].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// Discards what was heard so far (e.g. background speech before the user started).
    public func resetSegment() {
        lock.withLock { segment = ""; latestVolatile = "" }
    }

    /// The speaker stopped (VAD): force the recognizer to commit what it heard now instead of
    /// waiting for its own, slower and sentence-merging finalization, and return that segment.
    public func finalizeSegment() async -> String {
        let analyzer = lock.withLock { self.analyzer }
        try? await analyzer?.finalize(through: nil)
        // Final results are delivered asynchronously after finalize returns.
        for _ in 0..<8 {
            if lock.withLock({ latestVolatile.isEmpty }) { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(60))
        return lock.withLock { () -> String in
            let text = [segment, latestVolatile].filter { !$0.isEmpty }.joined(separator: " ")
            segment = ""
            latestVolatile = ""
            return text
        }
    }

    public func stop() async {
        let (input, analyzer, reader) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Never>?) in
            defer { self.input = nil; self.analyzer = nil; self.converter = nil; self.reader = nil }
            return (self.input, self.analyzer, self.reader)
        }
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        reader?.cancel()
    }
}
