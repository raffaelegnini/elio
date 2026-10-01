import Foundation

/// Wake word detection on transcribed text. On-device STT sometimes mangles "Jarvis"
/// in Italian ("Giarvis", "Giaviscose"), so the first words are matched fuzzily.
public enum WakeWord {
    nonisolated(unsafe) private static var variants = ["jarvis", "giarvis", "jarvi", "giarvi", "giavis", "jervis", "gervis", "jarvys", "giarviss"]
    nonisolated(unsafe) private static var prefixes = ["jarvis", "giarvis", "giavis"]

    /// Uses the assistant's configured name (and the recognizer's usual misspellings) as wake word.
    public static func configure(name: String, aliases: [String]) {
        let n = name.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !n.isEmpty else { return }
        if n == "jarvis" {
            variants = ["jarvis", "giarvis", "jarvi", "giarvi", "giavis", "jervis", "gervis", "jarvys", "giarviss"]
        } else {
            variants = [n]
        }
        variants += aliases.map { $0.lowercased() }
        prefixes = n == "jarvis" ? ["jarvis", "giarvis", "giavis"] : [n]
    }

    /// Returns the command after the wake word ("" if only the wake word was said),
    /// or nil if the utterance doesn't start with the wake word.
    public static func strip(_ utterance: String) -> String? {
        let words = utterance.split(whereSeparator: { $0 == " " }).map(String.init)
        // The wake word may follow a short interjection the recognizer splits oddly
        // ("ehi jarvis" → "e i jarvis"), so look at the first three words.
        for (i, word) in words.prefix(3).enumerated() where matches(clean(word)) {
            let before = words.prefix(i).map(clean)
            guard before.allSatisfy({ interjections.contains($0) }) else { return nil }
            let rest = words.dropFirst(i + 1).joined(separator: " ")
            return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:"))
        }
        return nil
    }

    private static let interjections: Set<String> = ["ehi", "hey", "ehy", "ok", "okay", "ei", "e", "i", "hei", "ah", "oh", "allora"]

    static func matches(_ token: String) -> Bool {
        if variants.contains(token) { return true }
        // Glued words ("giaviscose" = "giarvis cosa"): accept a close prefix.
        for v in prefixes where token.count > v.count {
            if distance(String(token.prefix(v.count)), v) <= 1 { return true }
        }
        return token.count >= 4 && variants.contains { $0.count >= 4 && distance(token, $0) <= ($0.count >= 6 ? 1 : 0) }
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
            if ch == "\n", length >= 2 { return next }
            if ".!?…;:".contains(ch), next < buffer.endIndex, buffer[next].isWhitespace, length >= minLength {
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
        var t = SecretFilter.speakable(text)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#`>|~]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Energy-based voice activity detection with an adaptive noise floor.
/// Pure state machine: feed one RMS level (dBFS) per audio buffer with its duration.
public struct VoiceActivityDetector {
    public enum Event: Equatable { case speechStart, speechEnd }

    public var startMarginDb: Float = 14       // above noise floor to start speech
    public var endMarginDb: Float = 7          // below this (over the floor) counts as silence
    public var startDuration: TimeInterval = 0.15
    public var endSilence: TimeInterval = 0.8
    public var maxUtterance: TimeInterval = 15
    /// Extra start margin while Jarvis is talking, so its own voice doesn't trigger barge-in.
    public var extraMarginDb: Float = 0

    public private(set) var noiseFloorDb: Float = -50
    public private(set) var inSpeech = false
    private var loudTime: TimeInterval = 0
    private var silence: TimeInterval = 0
    private var speechDuration: TimeInterval = 0
    private var calibrated: TimeInterval = 0

    public init() {}

    public mutating func process(levelDb: Float, duration: TimeInterval) -> Event? {
        // The floor follows the room: drops fast to quieter levels, rises slowly with
        // steady noise (also during speech, so a noisy room can't keep an utterance open).
        let rise: Float = inSpeech ? 0.004 : 0.03
        let rate: Float = levelDb < noiseFloorDb ? 0.25 : rise
        noiseFloorDb = max(-90, min(-25, noiseFloorDb + (levelDb - noiseFloorDb) * rate))

        // First second: only learn the room.
        if calibrated < 1 {
            calibrated += duration
            noiseFloorDb = noiseFloorDb * 0.7 + levelDb * 0.3
            return nil
        }

        if !inSpeech {
            loudTime = levelDb > noiseFloorDb + startMarginDb + extraMarginDb ? loudTime + duration : 0
            if loudTime >= startDuration {
                inSpeech = true
                silence = 0
                speechDuration = 0
                return .speechStart
            }
            return nil
        }
        speechDuration += duration
        silence = levelDb > noiseFloorDb + endMarginDb ? 0 : silence + duration
        if silence >= endSilence || speechDuration >= maxUtterance {
            inSpeech = false
            loudTime = 0
            return .speechEnd
        }
        return nil
    }

    public mutating func reset() {
        inSpeech = false
        loudTime = 0
        silence = 0
    }
}

/// Spotting the user talking over Jarvis through the speakers: the mic also hears Jarvis,
/// so only interrupt words that Jarvis itself isn't saying count.
public enum BargeIn {
    nonisolated(unsafe) public static var words = ["jarvis", "giarvis", "stop", "basta", "aspetta", "fermati", "fermo", "zitto", "silenzio", "wait"]

    public static func detect(_ heard: String, whileSaying spoken: String) -> Bool {
        let h = heard.lowercased(), s = spoken.lowercased()
        return words.contains { w in
            h.range(of: "\\b\(w)\\b", options: .regularExpression) != nil
                && s.range(of: "\\b\(w)\\b", options: .regularExpression) == nil
        }
    }
}

/// Interprets a spoken reply to a confirmation request.
public enum ConfirmationAnswer: Equatable {
    case approve, deny, needsExplicit, unrelated

    public static func parse(_ text: String, risk: ConfirmRequest.Risk) -> ConfirmationAnswer {
        let t = " " + text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?")) + " "
        let has = { (words: [String]) in words.contains { t.contains(" \($0) ") } }
        if has(["no", "annulla", "annullato", "stop", "aspetta", "fermo", "non farlo", "cancel", "don't"]) { return .deny }
        if has(["confermo", "conferma", "confermato", "i confirm", "confirm"]) { return .approve }
        if has(["sì", "si", "ok", "okay", "vai", "procedi", "certo", "va bene", "yes", "go ahead", "fallo"]) {
            return risk == .dangerous ? .needsExplicit : .approve
        }
        return .unrelated
    }
}
