import Foundation

/// Wake word detection on transcribed text. On-device STT sometimes mangles "Jarvis"
/// in Italian ("Giarvis", "Giaviscose"), so the first words are matched fuzzily.
public enum WakeWord {
    private static let variants = ["jarvis", "giarvis", "jarvi", "giarvi", "giavis", "jervis", "gervis", "jarvys", "giarviss"]

    /// Returns the command after the wake word ("" if only the wake word was said),
    /// or nil if the utterance doesn't start with the wake word.
    public static func strip(_ utterance: String) -> String? {
        var words = utterance
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
        // Skip a leading interjection: "ehi jarvis", "ok jarvis".
        if let first = words.first, ["ehi", "hey", "ehy", "ok", "okay", "ei"].contains(clean(first)) {
            words.removeFirst()
        }
        guard let first = words.first else { return nil }
        let token = clean(first)
        guard matches(token) else { return nil }
        let rest = words.dropFirst().joined(separator: " ")
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:"))
    }

    static func matches(_ token: String) -> Bool {
        if variants.contains(token) { return true }
        // Glued words ("giaviscose" = "giarvis cosa"): accept a close prefix.
        for v in ["jarvis", "giarvis", "giavis"] where token.count > v.count {
            if distance(String(token.prefix(v.count)), v) <= 1 { return true }
        }
        return token.count >= 5 && variants.contains { distance(token, $0) <= 1 }
    }

    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// Splits streamed LLM text into speakable sentences so TTS can start on the first one.
public struct SentenceSplitter {
    private var buffer = ""
    private var emittedAny = false

    public init() {}

    /// Feed a delta; returns complete sentences ready to speak.
    public mutating func push(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = nextCut() {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !sentence.isEmpty { out.append(sentence); emittedAny = true }
        }
        return out
    }

    /// Returns whatever is left at the end of the stream.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextCut() -> String.Index? {
        let minLength = 12
        var idx = buffer.startIndex
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            let next = buffer.index(after: idx)
            let length = buffer.distance(from: buffer.startIndex, to: next)
            if ".!?…;:\n".contains(ch), next < buffer.endIndex, buffer[next].isWhitespace, length >= minLength {
                // Don't split decimals or abbreviations like "3.5" or "ecc."-followed-by-lowercase.
                if ch == ".", let after = buffer[next...].first(where: { !$0.isWhitespace }), after.isLowercase {
                    idx = next
                    continue
                }
                return next
            }
            // Start speaking sooner: break the first sentence at a comma once it's long enough.
            if !emittedAny, ch == ",", next < buffer.endIndex, buffer[next].isWhitespace, length >= 60 {
                return next
            }
            idx = next
        }
        return nil
    }
}

/// Removes things that sound bad when read aloud (markdown, URLs, code ticks).
public enum Speakable {
    public static func clean(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#`>|~]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Energy-based voice activity detection with an adaptive noise floor.
/// Pure state machine: feed one RMS level (dBFS) per audio buffer.
public struct VoiceActivityDetector {
    public enum Event: Equatable { case speechStart, speechEnd }

    public var startMarginDb: Float = 12      // above noise floor to count as speech
    public var startFrames = 3                // consecutive loud buffers to start (~60ms)
    public var endSilence: TimeInterval = 0.8 // silence that ends an utterance
    public var maxUtterance: TimeInterval = 30
    /// Extra margin while Jarvis is talking, so residual echo doesn't trigger barge-in.
    public var extraMarginDb: Float = 0

    public private(set) var noiseFloorDb: Float = -60
    public private(set) var inSpeech = false
    private var loudFrames = 0
    private var silence: TimeInterval = 0
    private var speechDuration: TimeInterval = 0

    public init() {}

    public mutating func process(levelDb: Float, duration: TimeInterval) -> Event? {
        let threshold = noiseFloorDb + startMarginDb + extraMarginDb
        let loud = levelDb > threshold
        if !inSpeech {
            // Track the floor only outside speech; rise slowly, fall fast.
            let rate: Float = levelDb < noiseFloorDb ? 0.3 : 0.02
            noiseFloorDb = max(-90, min(-20, noiseFloorDb + (levelDb - noiseFloorDb) * rate))
            loudFrames = loud ? loudFrames + 1 : 0
            if loudFrames >= startFrames {
                inSpeech = true
                silence = 0
                speechDuration = 0
                return .speechStart
            }
            return nil
        }
        speechDuration += duration
        silence = loud ? 0 : silence + duration
        if silence >= endSilence || speechDuration >= maxUtterance {
            inSpeech = false
            loudFrames = 0
            return .speechEnd
        }
        return nil
    }

    public mutating func reset() {
        inSpeech = false
        loudFrames = 0
        silence = 0
    }
}
