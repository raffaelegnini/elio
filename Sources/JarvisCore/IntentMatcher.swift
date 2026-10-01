import Foundation

public enum Lang: String, Codable, Sendable { case it, en }

public enum LocalIntent: Equatable, Sendable {
    case openApp(String)
    case timer(seconds: Int)
    case time
    case volume(VolumeChange)
    case stop

    public enum VolumeChange: Equatable, Sendable {
        case set(Int), up, down, mute, unmute
    }
}

public struct MatchedIntent: Equatable, Sendable {
    public let intent: LocalIntent
    public let lang: Lang
}

/// Deterministic fast path for trivial commands: zero latency, zero Claude tokens.
/// Anything not matched here (or not resolvable, e.g. an unknown app) goes to Claude.
public struct IntentMatcher: Sendable {
    public init() {}

    public func match(_ raw: String) -> MatchedIntent? {
        let text = normalize(raw)
        guard !text.isEmpty else { return nil }

        if let m = matchStop(text) { return m }
        if let m = matchTime(text) { return m }
        if let m = matchTimer(text) { return m }
        if let m = matchVolume(text) { return m }
        if let m = matchOpenApp(text) { return m }
        return nil
    }

    // MARK: - Rules

    private func matchStop(_ t: String) -> MatchedIntent? {
        if ["stop", "basta", "zitto", "silenzio", "fermati", "shut up", "be quiet"].contains(t) {
            return MatchedIntent(intent: .stop, lang: ["stop", "shut up", "be quiet"].contains(t) ? .en : .it)
        }
        return nil
    }

    private func matchTime(_ t: String) -> MatchedIntent? {
        if t.range(of: #"^(che ore sono|che ora è|che ora e|mi dici l'ora|dimmi l'ora)$"#, options: .regularExpression) != nil {
            return MatchedIntent(intent: .time, lang: .it)
        }
        if t.range(of: #"^(what time is it|what's the time|tell me the time)$"#, options: .regularExpression) != nil {
            return MatchedIntent(intent: .time, lang: .en)
        }
        return nil
    }

    private func matchTimer(_ t: String) -> MatchedIntent? {
        let it = #"^(?:metti|imposta|avvia|fai partire)?\s*(?:un )?timer (?:di |da )?(\S+) (secondi|secondo|minuti|minuto|ore|ora)$"#
        let en = #"^(?:set|start)?\s*(?:a )?(?:timer for|timer of|timer) (\S+) (seconds|second|minutes|minute|hours|hour)$"#
        for (pattern, lang) in [(it, Lang.it), (en, Lang.en)] {
            guard let caps = captures(pattern, in: t), caps.count == 2,
                  let n = number(caps[0]) else { continue }
            let unit = caps[1]
            let mult = unit.hasPrefix("sec") ? 1 : unit.hasPrefix("min") ? 60 : 3600
            let seconds = n * mult
            guard seconds > 0, seconds <= 24 * 3600 else { return nil }
            return MatchedIntent(intent: .timer(seconds: seconds), lang: lang)
        }
        return nil
    }

    private func matchVolume(_ t: String) -> MatchedIntent? {
        if let caps = captures(#"^(?:metti |imposta )?(?:il )?volume (?:al |a )?(\d{1,3})(?: ?%| per ?cento)?$"#, in: t),
           let n = Int(caps[0]) {
            return MatchedIntent(intent: .volume(.set(min(n, 100))), lang: .it)
        }
        if let caps = captures(#"^(?:set )?(?:the )?volume (?:to )?(\d{1,3})(?: ?%| percent)?$"#, in: t),
           let n = Int(caps[0]) {
            return MatchedIntent(intent: .volume(.set(min(n, 100))), lang: .en)
        }
        let table: [(String, LocalIntent.VolumeChange, Lang)] = [
            (#"^alza (?:il )?volume$"#, .up, .it),
            (#"^abbassa (?:il )?volume$"#, .down, .it),
            (#"^(?:muto|silenzia (?:il )?(?:volume|audio)|togli (?:il )?(?:volume|audio))$"#, .mute, .it),
            (#"^(?:riattiva (?:il )?(?:volume|audio)|togli (?:il )?muto)$"#, .unmute, .it),
            (#"^(?:turn (?:the )?volume up|volume up|louder)$"#, .up, .en),
            (#"^(?:turn (?:the )?volume down|volume down|quieter)$"#, .down, .en),
            (#"^(?:mute|mute (?:the )?(?:volume|audio|sound))$"#, .mute, .en),
            (#"^(?:unmute|unmute (?:the )?(?:volume|audio|sound))$"#, .unmute, .en),
        ]
        for (pattern, change, lang) in table where t.range(of: pattern, options: .regularExpression) != nil {
            return MatchedIntent(intent: .volume(change), lang: lang)
        }
        return nil
    }

    private func matchOpenApp(_ t: String) -> MatchedIntent? {
        for (pattern, lang) in [(#"^(?:apri|apriti|lancia|avvia) (?:l'app |l'applicazione |app )?(.+)$"#, Lang.it),
                                (#"^(?:open|launch|start) (?:the app |app )?(.+)$"#, Lang.en)] {
            guard let caps = captures(pattern, in: t) else { continue }
            var name = caps[0]
            for suffix in [" per favore", " please", " grazie"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            // Leading articles are usually part of a sentence ("apri la PR di …"), not an app name:
            // keep them so the resolver fails and the request falls through to Claude.
            guard name.count >= 2, name.split(separator: " ").count <= 3 else { return nil }
            return MatchedIntent(intent: .openApp(name), lang: lang)
        }
        return nil
    }

    // MARK: - Helpers

    func normalize(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "’", with: "'")
        // Drop wake word and courtesy prefixes: "jarvis, apri slack" → "apri slack".
        t = t.replacingOccurrences(of: #"^(?:ehi |hey |ok )?jarvis[,!.]?\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^(?:per favore|please)[,]?\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func captures(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    private static let numberWords: [String: Int] = [
        "un": 1, "uno": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6,
        "sette": 7, "otto": 8, "nove": 9, "dieci": 10, "quindici": 15, "venti": 20, "trenta": 30,
        "quaranta": 40, "quarantacinque": 45, "sessanta": 60, "novanta": 90,
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty-five": 45, "sixty": 60, "ninety": 90,
    ]

    private func number(_ s: String) -> Int? {
        Int(s) ?? Self.numberWords[s]
    }
}
