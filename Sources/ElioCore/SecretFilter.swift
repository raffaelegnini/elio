import Foundation

/// Finds credentials in text so they are never spoken, stored in the archive, logged or sent
/// to the phone. Claude is asked to wrap secrets in ⟦…⟧; known token formats, `key: value`
/// pairs and long random-looking strings are caught as a fallback.
public enum SecretFilter {
    public static let open = "⟦", close = "⟧"
    public static let placeholder = "‹dato riservato›"

    /// Character ranges of secrets in `text` (non-overlapping, in order).
    public static func find(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        func add(_ r: Range<String.Index>) {
            guard !r.isEmpty, !ranges.contains(where: { $0.overlaps(r) }) else { return }
            ranges.append(r)
        }
        // 1. Explicit markers from the assistant: ⟦secret⟧ (markers included).
        var search = text.startIndex
        while let o = text.range(of: open, range: search..<text.endIndex),
              let c = text.range(of: close, range: o.upperBound..<text.endIndex) {
            add(o.lowerBound..<c.upperBound)
            search = c.upperBound
        }
        // 2. Known formats and key/value pairs (only the value is secret).
        for (pattern, group) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: group), in: text) { add(r) }
            }
        }
        // 3. Long, random-looking tokens (letters + digits, no spaces).
        if let re = try? NSRegularExpression(pattern: #"(?<![\w/.-])[A-Za-z0-9_\-+/=]{28,}(?![\w/.-])"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text), looksRandom(String(text[r])) else { continue }
                add(r)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    static let patterns: [(String, Int)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, 0),
        (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, 0),                       // Slack
        (#"\b(?:sk|pk|rk)[_-](?:live_|test_)?[A-Za-z0-9]{16,}"#, 0),     // Stripe, ElevenLabs, OpenAI-style
        (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}"#, 0),
        (#"\bglpat-[A-Za-z0-9_-]{20,}"#, 0),                            // GitLab
        (#"\bATATT[A-Za-z0-9_\-=]{20,}|\bATBB[A-Za-z0-9]{20,}"#, 0),     // Atlassian / Bitbucket
        (#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, 0),                         // AWS access key
        (#"\bAIza[0-9A-Za-z_-]{35}\b"#, 0),                             // Google API key
        (#"\bBearer\s+([A-Za-z0-9._\-+/=]{16,})"#, 1),
        (#"://[^/\s:@]+:([^@\s/]+)@"#, 1),                              // user:password@host
        (#"(?:password|passwd|pwd|pass|passcode|secret|token|api[ _-]?key|apikey|access[ _-]?key|client[ _-]?secret|private[ _-]?key|app[ _-]?password|parola d'ordine|chiave)\s*(?:[:=]|è|e'|is)\s*[`"']?([^\s`"',;]{4,})"#, 1),
    ]

    static func looksRandom(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter).count, digits = s.filter(\.isNumber).count
        let upper = s.filter(\.isUppercase).count, lower = s.filter(\.isLowercase).count
        guard digits >= 3, letters >= 6 else { return false }
        // Paths, URLs and plain words are not secrets.
        if s.contains("/") && !s.contains("+") && !s.hasSuffix("=") { return false }
        return upper >= 2 && lower >= 2 || Double(digits) / Double(s.count) > 0.25
    }

    /// Text with every secret replaced (for archive, logs, phone, notifications).
    public static func redact(_ text: String, with replacement: String = placeholder) -> String {
        var out = text
        for r in find(text).reversed() {
            out.replaceSubrange(r, with: replacement)
        }
        return out
    }

    /// For the voice: secrets become "dato riservato", markers disappear.
    public static func speakable(_ text: String) -> String {
        redact(text, with: "dato riservato")
    }

    /// Removes the ⟦⟧ markers, keeping the secret (for reveal / copy on the Mac screen).
    public static func unwrap(_ text: String) -> String {
        text.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
    }

    public static func contains(_ text: String) -> Bool { !find(text).isEmpty }
}
