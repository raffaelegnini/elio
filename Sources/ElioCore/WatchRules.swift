import Foundation

/// The pure decisions behind the monitors (when a check fires and what state it leaves),
/// kept apart from the I/O so they can be tested.
enum WatchRules {
    struct Decision: Equatable {
        var fire: Bool
        var state: String?
        /// http "down" mode: the site answers again after being down.
        var recovered = false
    }

    // MARK: http / command

    /// fireOn: down (default: fires when it stops answering), up (once it answers again),
    /// change (the page content changes), match (`match` shows up in the page).
    static func http(fireOn: String?, ok: Bool, matched: Bool, hash: String?, previous: String?) -> Decision {
        switch fireOn ?? "down" {
        case "up":
            return Decision(fire: ok && previous != "up", state: ok ? "up" : "down")
        case "change":
            // A failed fetch is not a change: keep the last good hash.
            guard ok, let hash else { return Decision(fire: false, state: previous) }
            return Decision(fire: previous != nil && previous != hash, state: hash)
        case "match":
            return Decision(fire: matched && previous != "match", state: matched ? "match" : "nomatch")
        default:
            return Decision(fire: !ok && previous != "down", state: ok ? "up" : "down", recovered: ok && previous == "down")
        }
    }

    /// fireOn: failure (default, every failing run), change (output changes), success (first exit 0:
    /// "until" loops), match (output matches `match`). success/match fire on the transition only.
    static func command(fireOn: String?, code: Int32, hash: String, matched: Bool, previous: String?) -> Decision {
        switch fireOn ?? "failure" {
        case "change": Decision(fire: previous != nil && previous != hash, state: hash)
        case "success": Decision(fire: code == 0 && previous != "ok", state: code == 0 ? "ok" : "ko")
        case "match": Decision(fire: matched && previous != "match", state: matched ? "match" : "nomatch")
        default: Decision(fire: code != 0, state: hash)
        }
    }

    // MARK: Presence (screen text, files)

    /// appear: fires when the thing is there and wasn't (also on the first check).
    /// disappear: only after it has been seen; `debounce` wants two misses in a row (OCR flickers).
    static func presence(fireOn: String?, present: Bool, previous: String?, debounce: Bool) -> Decision {
        if fireOn == "disappear" {
            if present { return Decision(fire: false, state: "present") }
            switch previous {
            case "present": return debounce ? Decision(fire: false, state: "gone1") : Decision(fire: true, state: "absent")
            case "gone1": return Decision(fire: true, state: "absent")
            default: return Decision(fire: false, state: "absent")
            }
        }
        return Decision(fire: present && previous != "present", state: present ? "present" : "absent")
    }

    /// Screen "change": ignores numbers (clocks, timers, counters) and small OCR jitter.
    static func meaningfulChange(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        let diff = x.symmetricDifference(y).count
        return diff >= 3 && Double(diff) / Double(max(1, x.union(y).count)) > 0.15
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && $0.rangeOfCharacter(from: .decimalDigits) == nil })
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func regexMatches(_ pattern: String?, _ text: String) -> Bool {
        guard let pattern, !pattern.isEmpty else { return false }
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Files

    struct FileInfo: Sendable, Equatable {
        var path: String
        var size: Int64
        var mtime: Double
    }

    /// Browsers write downloads under a temporary name and rename them when done.
    static func isTempDownload(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let exts = [".crdownload", ".download", ".part", ".partial", ".tmp", ".opdownload"]
        return exts.contains { name.hasSuffix($0) } || name.hasPrefix(".com.google.chrome") || name == ".ds_store"
    }

    static func signature(_ f: FileInfo) -> String { "\(f.path)|\(Int(f.mtime))" }

    /// Download-style "appear": the first check only records what is already there; afterwards a new
    /// (or rewritten) file is ready once its size held still between two checks and no temp sibling
    /// (Firefox's .part next to the placeholder) is left.
    static func filesAppeared(_ current: [FileInfo], seen: [String]?, lastSizes: [String: Int64],
                              hasTempSibling: (String) -> Bool) -> (ready: [FileInfo], seen: [String]) {
        let finals = current.filter { !isTempDownload($0.path) }
        guard let seen else { return ([], mergeSeen([], finals.map(signature), limit: 1000)) }
        let known = Set(seen)
        let ready = finals.filter {
            !known.contains(signature($0)) && lastSizes[$0.path] == $0.size && !hasTempSibling($0.path)
        }
        return (ready, mergeSeen(seen, ready.map(signature), limit: 1000))
    }

    /// Appends the new ids, keeping only the most recent `limit`.
    static func mergeSeen(_ old: [String], _ new: [String], limit: Int) -> [String] {
        var out = old
        var set = Set(old)
        for id in new where set.insert(id).inserted { out.append(id) }
        return out.count > limit ? Array(out.suffix(limit)) : out
    }

    // MARK: Pipelines

    /// https://github.com/o/r/actions/runs/123[/job/…] → ("o/r", "123")
    static func parseRunURL(_ s: String) -> (repo: String, id: String)? {
        guard let m = s.firstMatch(of: #/github\.com\/([^\/\s]+\/[^\/\s]+)\/actions\/runs\/(\d+)/#) else { return nil }
        return (String(m.1), String(m.2))
    }

    /// git@github.com:o/r.git, https://github.com/o/r(.git) → "o/r"
    static func parseGitHubRemote(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = t.firstMatch(of: #/github\.com[:\/]([^\/\s]+)\/([^\/\s]+?)(?:\.git)?\/?$/#) else { return nil }
        return "\(m.1)/\(m.2)"
    }

    static func conclusionIT(_ c: String?) -> String {
        switch c ?? "" {
        case "success": "riuscita"
        case "failure": "fallita"
        case "cancelled": "annullata"
        case "skipped": "saltata"
        case "timed_out": "scaduta per timeout"
        case "action_required": "in attesa di un'azione"
        case "startup_failure": "fallita all'avvio"
        default: "conclusa"
        }
    }

    // MARK: Processes

    /// ps etime: [[dd-]hh:]mm:ss
    static func parseEtime(_ s: String) -> TimeInterval? {
        var rest = Substring(s.trimmingCharacters(in: .whitespaces))
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + $1! } + days * 86400
    }

    /// Spoken duration: "40 secondi", "12 minuti", "1 ora e 5 minuti".
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return s == 1 ? "1 secondo" : "\(s) secondi" }
        let m = s / 60
        if m < 60 { return m == 1 ? "1 minuto" : "\(m) minuti" }
        let h = m / 60, r = m % 60
        let hours = h == 1 ? "1 ora" : "\(h) ore"
        return r == 0 ? hours : "\(hours) e \(r == 1 ? "1 minuto" : "\(r) minuti")"
    }

    // MARK: Mail

    /// Apple Mail only searches subject/sender for one string: keep the most telling part of a Gmail query.
    static func appleMailQuery(_ q: String) -> String {
        func op(_ name: String) -> String? {
            guard let r = q.range(of: "\(name):(\"[^\"]+\"|\\([^)]+\\)|\\S+)", options: .regularExpression) else { return nil }
            return String(q[r].dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"()"))
        }
        if let from = op("from") { return from }
        if let subject = op("subject") { return subject }
        return q.split(separator: " ").filter { !$0.contains(":") && !$0.hasPrefix("-") }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    /// "Mario Rossi <mario@x.it>" → "Mario Rossi"
    static func senderName(_ from: String) -> String {
        let name = from.split(separator: "<").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? from
        return name.isEmpty ? from.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) : name
    }
}
