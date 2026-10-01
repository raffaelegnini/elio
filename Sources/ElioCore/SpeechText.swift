import Foundation

/// Wake word detection on transcribed text. On-device STT sometimes mangles "Elio"
/// in Italian, so the first words are matched fuzzily (and glued words like "eliocosa" are accepted).
public enum WakeWord {
    nonisolated(unsafe) private static var variants = ["elio", "helio"]
    nonisolated(unsafe) private static var prefixes = ["elio"]

    /// Uses the assistant's configured name, plus spellings the recognizer produces (Settings), as wake word.
    public static func configure(name: String, aliases: [String]) {
        let n = name.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !n.isEmpty else { return }
        variants = [n] + aliases.map { $0.lowercased() }
        prefixes = [n]
    }

    /// Returns the command after the wake word ("" if only the wake word was said),
    /// or nil if the utterance doesn't start with the wake word.
    public static func strip(_ utterance: String) -> String? {
        let words = utterance.split(whereSeparator: { $0 == " " }).map(String.init)
        // The wake word may follow a short interjection the recognizer splits oddly
        // ("ehi elio" → "e i elio"), so look at the first three words.
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
        // Glued words ("eliocosa" = "elio cosa"): accept a close prefix.
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
    /// Extra start margin while Elio is talking, so its own voice doesn't trigger barge-in.
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

/// Spotting the user talking over Elio through the speakers: the mic also hears Elio,
/// so only interrupt words that Elio itself isn't saying count.
public enum BargeIn {
    nonisolated(unsafe) public static var words = ["elio", "stop", "basta", "aspetta", "fermati", "fermo", "zitto", "silenzio", "wait"]

    public static func detect(_ heard: String, whileSaying spoken: String) -> Bool {
        let h = heard.lowercased(), s = spoken.lowercased()
        return words.contains { w in
            h.range(of: "\\b\(w)\\b", options: .regularExpression) != nil
                && s.range(of: "\\b\(w)\\b", options: .regularExpression) == nil
        }
    }
}

/// The mic hears Elio through the speakers: drop the words that match what it just said,
/// keeping anything the user added. Empty if it was all echo.
public enum Echo {
    public static func remove(from heard: String, spoken: String) -> String {
        let norm = { (s: String) in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let said = Set(norm(spoken))
        let words = heard.split(separator: " ").map(String.init)
        guard !said.isEmpty, !words.isEmpty else { return heard }
        let isEcho = { (w: String) in norm(w).allSatisfy { said.contains($0) } }
        guard Double(words.filter(isEcho).count) / Double(words.count) >= 0.6 else { return heard }
        // Mostly echo: keep the trailing part that isn't ("…le faccio subito. Elio, aspetta").
        var tail: [String] = []
        for w in words.reversed() {
            if isEcho(w) { break }
            tail.insert(w, at: 0)
        }
        return tail.joined(separator: " ")
    }
}

/// Instant, request-specific acknowledgement played while Claude works (cached audio, ~0 latency).
public enum Acknowledgement {
    static let rules: [(String, String)] = [
        (#"agenda|calendari|meeting|riunion|impegn|appuntament|call\b"#, "controllo l'agenda."),
        (#"slack|messagg|\bdm\b|scritto|menzion|risposto"#, "guardo Slack."),
        (#"mail|email|posta"#, "controllo la posta."),
        (#"progett|codice|bug|branch|\bpr\b|review|test|deploy|repo|commit"#, "me ne occupo subito."),
        (#"meteo|che tempo|cerca|notizie|quanto costa|chi è|cos'è|news"#, "cerco subito."),
        (#"teamwork|task|attivit"#, "controllo i task."),
        (#"ricorda|promemoria|memoria|sai che"#, "un attimo."),
    ]

    /// Nil for chit-chat (thanks, greetings, opinions): a quick ack there would only double the reply.
    public static func phrase(for request: String, addressAs: String) -> String? {
        let t = request.lowercased()
        for (pattern, tail) in rules where t.range(of: pattern, options: .regularExpression) != nil {
            return "Certo, \(addressAs), \(tail)"
        }
        return nil
    }

    public static func all(addressAs: String) -> [String] {
        Set(rules.map { "Certo, \(addressAs), \($0.1)" } + ["Certo, \(addressAs), un attimo."]).sorted()
    }

    /// Claude's own opening acknowledgement ("Certo, Signore, controllo subito…"), redundant after ours.
    public static func isAcknowledgement(_ sentence: String) -> Bool {
        let t = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        return t.count < 110 && t.range(of: #"^(certo|subito|va bene|perfetto|benissimo|senz'altro)\b"#, options: .regularExpression) != nil
    }
}

/// Interprets a spoken reply to a confirmation request.
public enum ConfirmationAnswer: Equatable {
    case approve, deny, needsExplicit, unrelated

    public static func parse(_ text: String, risk: ConfirmRequest.Risk) -> ConfirmationAnswer {
        let clean = text.lowercased().replacingOccurrences(of: #"[.,!?;:]"#, with: " ", options: .regularExpression)
        let t = " " + clean.split(separator: " ").joined(separator: " ") + " "
        let has = { (words: [String]) in words.contains { t.contains(" \($0) ") } }
        let words = t.split(separator: " ").count
        // Refusals: explicit ones only. A leading "no" followed by an order ("no, allora invia") is a yes.
        let refusal = t.range(of: #" non (inviare|inviarlo|inviarla|mandare|mandarlo|mandarla|farlo|farla|procedere|andare|scrivere|scriverlo) "#,
                              options: .regularExpression) != nil
            || has(["annulla", "annullalo", "lascia stare", "lascia perdere", "stop", "fermo", "fermati", "aspetta", "cancel", "don't"])
            || t.range(of: #"^ (no )+$"#, options: .regularExpression) != nil
        if refusal { return .deny }
        if has(["confermo", "conferma", "confermato", "i confirm", "confirm"]) { return .approve }
        let strong = ["vai", "procedi", "invia", "invialo", "inviala", "mandalo", "mandala", "manda", "fallo", "falla",
                      "go ahead", "send it", "do it"]
        if has(strong) { return .approve }
        let soft = ["sì", "si", "ok", "okay", "certo", "va bene", "yes", "esatto", "perfetto", "d'accordo"]
        // A lone "sì/ok" in a long, unrelated sentence isn't a clear yes for a delicate action.
        if has(soft) { return risk == .dangerous && words > 6 ? .needsExplicit : .approve }
        if t.trimmingCharacters(in: .whitespaces) == "no" { return .deny }
        return .unrelated
    }
}
