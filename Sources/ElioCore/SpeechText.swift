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
    /// or nil if no sentence of the utterance starts with the wake word.
    public static func strip(_ utterance: String) -> String? {
        let words = utterance.split(whereSeparator: { $0 == " " }).map(String.init)
        // The continuous recognizer often glues what was said just before into the same segment
        // ("non mi piace. Elio, che ore sono?"): the wake word may open any sentence, not only the first.
        let starts = [0] + words.indices.dropLast().filter { words[$0].last.map { ".!?".contains($0) } ?? false }.map { $0 + 1 }
        for start in starts {
            let sentence = words[start...]
            // The wake word may follow a short interjection the recognizer splits oddly
            // ("ehi elio" → "e i elio"), so look at the first three words.
            for (i, word) in sentence.prefix(3).enumerated() where matches(clean(word)) {
                let before = sentence.prefix(i).map(clean)
                guard before.allSatisfy({ interjections.contains($0) }) else { break }
                let rest = sentence.dropFirst(i + 1).joined(separator: " ")
                return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:"))
            }
        }
        return nil
    }

    private static let interjections: Set<String> = ["ehi", "hey", "ehy", "ok", "okay", "ei", "e", "i", "hei", "ah", "oh", "eh", "ehm",
                                                     "allora", "senti", "scusa", "dai", "quindi", "ciao", "sì", "si", "no"]

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
        // Before the symbols go: "1.0.1", "10:30", "#42", "50%" must become words the voice can say.
        t = SpeechNormalizer.italian(t)
        // snake_case reads as two words, not one glued word.
        t = t.replacingOccurrences(of: #"(?<=\w)_(?=\w)"#, with: " ", options: .regularExpression)
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
    /// Long dictations are cut here, then stitched back together by the app (continuation window).
    public var maxUtterance: TimeInterval = 45
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
    // Word boundaries matter: "proposta" must not mean "posta", "attest" not "test".
    static let rules: [(String, String)] = [
        (#"agenda|calendari|meeting|riunion|impegn|appuntament|\bcall\b"#, "controllo l'agenda."),
        (#"slack|messagg|\bdm\b|\bscritto\b|menzion|\brispost"#, "guardo Slack."),
        (#"\b(e-?mail|mail|posta)\b"#, "controllo la posta."),
        (#"progett|codice|\bbug|\bbranch|\bpr\b|review|\btest\b|\bdeploy|\brepo\b|repository|\bcommit"#, "me ne occupo subito."),
        (#"meteo|che tempo|\bcerca|notizie|quanto costa|chi è|cos'è|\bnews\b"#, "cerco subito."),
        (#"teamwork|\btask\b|attivit"#, "controllo i task."),
        (#"ricorda|promemoria|memoria|sai che"#, "un attimo."),
    ]

    /// Nil for chit-chat (thanks, greetings, opinions): a quick ack there would only double the reply.
    public static func phrase(for request: String, addressAs: String) -> String? {
        let t = request.lowercased()
        for (pattern, tail) in rules where t.range(of: pattern, options: .regularExpression) != nil {
            return "\(openers.randomElement()!), \(addressAs), \(tail)"
        }
        // A real request (not a quick remark) still gets an immediate sign of life.
        let words = t.split(separator: " ").count
        let chitChat = t.range(of: #"^(ciao|grazie|ok|bene|come stai|buongiorno|buonasera|perfetto|bravo)"#, options: .regularExpression) != nil
        return words >= 6 && !chitChat ? "\(["Un attimo", "Subito", "Ci penso io"].randomElement()!), \(addressAs)." : nil
    }

    /// Varied openers: "Certo, Signore" every time sounded mechanical.
    static let openers = ["Subito", "Va bene", "Volentieri", "Con piacere"]

    public static func all(addressAs: String) -> [String] {
        Set(rules.flatMap { r in openers.map { "\($0), \(addressAs), \(r.1)" } }
            + ["Un attimo", "Subito", "Ci penso io"].map { "\($0), \(addressAs)." }).sorted()
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
        let refusal = t.range(of: #" non (lo |la |li |le |gli |ne )?(inviar|mandar|far|procedere|andare|scriver|pubblicar|toccar|cancellar)\w* "#,
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

/// Did the user finish their request, or did they just pause? Words like "e", "poi", "che" or a trailing comma
/// mean more is coming; long dictations usually go on too. The app holds the request that long before sending.
public enum EndOfTurn {
    static let connectives: Set<String> = [
        "e", "ed", "che", "per", "di", "del", "della", "dei", "delle", "a", "al", "alla", "ai", "in", "con", "su", "poi",
        "quindi", "allora", "ma", "però", "cioè", "tipo", "oppure", "o", "se", "come", "anche", "dove", "quando", "mentre",
        "perché", "un", "una", "uno", "il", "lo", "la", "i", "gli", "le", "da", "dal", "dalla", "nel", "nella", "sul",
        "sulla", "questo", "questa", "quello", "quella", "sia", "eh", "ehm", "uhm", "mmm", "dunque", "inoltre",
        "praticamente", "insomma", "comunque", "and", "the", "to", "of", "then", "so", "but", "or", "with",
    ]

    /// How long to wait for the rest of a request (0 = it's complete, go).
    public static func wait(_ text: String, cutByLimit: Bool) -> TimeInterval {
        if cutByLimit { return 1.8 }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix(",") || t.hasSuffix(":") || t.hasSuffix("…") || t.hasSuffix("...") || t.hasSuffix(";") { return 1.6 }
        let words = t.split(whereSeparator: { $0 == " " })
        let last = words.last.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if connectives.contains(last) { return 1.6 }
        let closed = t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!")
        if words.count >= 25 { return closed ? 0.9 : 1.3 }   // a long dictation usually goes on
        if words.count >= 12, !closed { return 0.8 }
        return 0
    }

}

/// Turns what a voice can't read into what a person would say (Italian): "1.0.1" → "1 punto 0 punto 1",
/// "v2.3" → "versione 2 punto 3", "10:30" → "10 e 30", "50%" → "50 per cento", "#42" → "numero 42",
/// "3-5" → "da 3 a 5", "1920x1080" → "1920 per 1080", "app.swift" → "app punto swift", "->" → pause.
/// ElevenLabs otherwise reads the dots as a stop and makes odd sounds on symbols.
public enum SpeechNormalizer {
    static let letterNames: [Character: String] = [
        "a": "a", "b": "bi", "c": "ci", "d": "di", "e": "e", "f": "effe", "g": "gi", "h": "acca", "i": "i", "j": "i lunga",
        "k": "cappa", "l": "elle", "m": "emme", "n": "enne", "o": "o", "p": "pi", "q": "cu", "r": "erre", "s": "esse",
        "t": "ti", "u": "u", "v": "vu", "w": "doppia vu", "x": "ics", "y": "ipsilon", "z": "zeta",
    ]
    static let digitNames: [Character: String] = [
        "0": "zero", "1": "uno", "2": "due", "3": "tre", "4": "quattro", "5": "cinque", "6": "sei", "7": "sette", "8": "otto", "9": "nove",
    ]

    /// "85f3b61" → "otto cinque effe tre bi sei uno": hashes (7+ hex chars, shortened to 7) and other codes of
    /// 5+ characters mixing letters and digits. Short tech names (H264, UTF8, B2B, iPhone15) stay as they are.
    static func spellCodes(_ text: String) -> String {
        let pattern = #"\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{5,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let token = String(out[r])
            let lower = token.lowercased()
            // Git hashes are lowercase hex; uppercase codes (tickets, ids) are spelled in full.
            let isHash = token == lower && lower.count >= 7 && lower.allSatisfy { $0.isHexDigit }
            let digits = token.filter(\.isNumber).count, letters = token.count - digits
            // A word with a number glued on ("build14", "iPhone15") reads fine; a code alternates.
            let alternations = zip(token, token.dropFirst()).filter { $0.0.isNumber != $0.1.isNumber }.count
            guard isHash || (digits >= 2 && letters >= 2 && alternations >= 3) else { continue }
            let chars = isHash ? Array(lower.prefix(7)) : Array(lower.prefix(12))
            let spelled = chars.compactMap { digitNames[$0] ?? letterNames[$0] }.joined(separator: " ")
            out.replaceSubrange(r, with: spelled)
        }
        return out
    }

    static let extensions = "swift|js|mjs|ts|tsx|jsx|php|py|rb|go|rs|kt|java|dart|vue|json|md|html|css|scss|yml|yaml|toml|xml|env|sh|zsh|sql|txt|pdf|csv|xlsx|docx|pptx|png|jpg|jpeg|svg|gif|zip|plist|lock|log|ini|conf"

    public static func italian(_ text: String) -> String {
        var t = text
        func sub(_ pattern: String, _ template: String) {
            t = t.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        // Codes mixing letters and digits (commit hashes, ids): spelled out, the way a person reads them.
        t = spellCodes(t)
        // Versions: "v2.3.1", "1.0.1", "8.2" (a single dot followed by 1–2 digits; "1.200" is a thousand).
        sub(#"\bv(\d+(?:\.\d+)*)\b"#, "versione $1")
        for _ in 0..<4 { sub(#"(\d)\.(\d)(?=\d*\.\d)"#, "$1 punto $2") }      // all but the last dot of a chain
        sub(#"(\d+) punto (\d+)\.(\d+)"#, "$1 punto $2 punto $3")
        sub(#"\b(\d+)\.(\d{1,2})\b(?!\.\d)"#, "$1 punto $2")
        // File names and extensions: "app.swift", ".env".
        sub(#"(\w)\.(\#(extensions))\b"#, "$1 punto $2")
        sub(#"(^|\s)\.(\#(extensions))\b"#, "$1punto $2")
        // Times: "10:30" → "10 e 30", "9:00" → "9", "10:05" → "10 e 5".
        sub(#"\b([01]?\d|2[0-3]):00\b"#, "$1")
        sub(#"\b([01]?\d|2[0-3]):0(\d)\b"#, "$1 e $2")
        sub(#"\b([01]?\d|2[0-3]):([1-5]\d)\b"#, "$1 e $2")
        // Numbers with symbols.
        sub(#"(\d)\s?%"#, "$1 per cento")
        sub(#"(\d)\s?°C?"#, "$1 gradi")
        sub(#"(\d)\s?x\s?(\d)"#, "$1 per $2")
        sub(#"(\d)\s?\+\s?(\d)"#, "$1 più $2")
        sub(#"(\d)\s?=\s?(\d)"#, "$1 uguale $2")
        sub(#"\b(\d+)\s?[-–]\s?(\d+)\b(?!\s*[-–/]\s*\d)"#, "da $1 a $2")
        sub(#"#(\d+)"#, "numero $1")
        sub(#"(\d)/(\d)"#, "$1 su $2")
        // Words joined by symbols.
        sub(#"\s*(->|=>|→|⟶)\s*"#, ", ")
        sub(#"\s&\s|(?<=\w)&(?=\w)"#, " e ")
        sub(#"(?<=[A-Za-zÀ-ÿ])/(?=[A-Za-zÀ-ÿ])"#, " slash ")
        sub(#"@(?=\w)"#, "")
        sub(#"\.{3}"#, "…")
        return t
    }
}
