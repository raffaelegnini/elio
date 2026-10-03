import Foundation

/// Which model an agent runs on. Opus by default: code work needs it. The lighter model only for the
/// truly trivial (a typo, a label, a colour, a version bump in one or two files) — about 1 job in 20.
/// Both have to agree: Elio flags the job as trivial *and* the text of the job looks trivial; if either
/// doubts, it's Opus. A wrong "trivial" costs a redo, a wrong "hard" only costs a few tokens.
public enum ModelRouter {
    public struct Choice: Sendable, Equatable {
        public let model: String
        public let light: Bool
        public let reason: String
    }

    /// Anything that smells like real work.
    static let heavy = #"refactor|architett|migra|debug|bug|errore|error|crash|eccezion|perform|lent[oa]|ottimizz|sicurezz|security|auth|login|password|pagament|payment|database|\bdb\b|schema|query|\bapi\b|endpoint|integra|implement|nuov[oa] (funzion|pagin|schermat|component)|feature|\btest|algoritm|analizz|indaga|capire perch|review|revision|deploy|ridisegn|redesign|progett|struttur|logica|stato|state|cache|concorren|async|thread|tutto il|tutti i file|ovunque|intero|ogni (file|pagina|componente)|più (file|pagine|componenti)|squadra|multipl"#

    /// What a trivial job usually is.
    static let trivial = #"typo|refuso|errore di battitura|rinomin|testo|label|etichett|scritta|copy\b|tradu|stringa|commento|versione|\bbump\b|changelog|readme|format|indent|spazi|import inutil|costante|link|icona|colore|colour|color\b|margin|padding|font|placeholder|titolo|emoji|virgola|maiuscol"#

    public static func pick(title: String, prompt: String, difficulty: String?, base: String, light: String,
                            enabled: Bool = true) -> Choice {
        let text = (title + " " + prompt).lowercased()
        guard enabled else { return Choice(model: base, light: false, reason: "routing spento") }
        guard difficulty?.lowercased() == "trivial" else { return Choice(model: base, light: false, reason: "lavoro normale") }
        if text.count > 600 { return Choice(model: base, light: false, reason: "istruzioni lunghe") }
        if let m = text.range(of: heavy, options: .regularExpression) {
            return Choice(model: base, light: false, reason: "contiene \"\(text[m])\"")
        }
        guard text.range(of: trivial, options: .regularExpression) != nil else {
            return Choice(model: base, light: false, reason: "non riconosciuto come banale")
        }
        return Choice(model: light, light: true, reason: "micro-modifica")
    }
}
