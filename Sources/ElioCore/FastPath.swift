import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Simple commands ("salta la canzone", "apri Figma", "apri il sito di Repubblica", "metti i Coldplay")
/// are understood by Apple's on-device model and executed locally: ~0.5 s, no Claude tokens.
/// Anything else, or anything the model isn't sure about, goes to Claude.
public enum FastPath {
    public enum Action: String, Sendable, CaseIterable {
        case none, openApp, openURL, webSearch, play, pause, next, previous, nowPlaying, volumeUp, volumeDown, volumeSet
        case lockScreen, darkMode, lightMode
    }

    public struct Command: Sendable, Equatable {
        public var action: Action
        public var target: String
        public var kind: String
        public var value: Int
    }

    /// Cheap prefilter: only short sentences that look like a device command reach the model.
    public static func worthTrying(_ text: String) -> Bool {
        let t = " " + text.lowercased().folding(options: .diacriticInsensitive, locale: .current) + " "
        guard t.split(separator: " ").count <= 14 else { return false }
        let cues = [" apri ", " aprimi ", " lancia ", " avvia ", " metti ", " mettimi ", " suona ", " riproduci ", " fai partire ",
                    " pausa ", " salta ", " skippa ", " prossima ", " successiva ", " precedente ", " canzone ", " brano ",
                    " musica ", " spotify ", " volume ", " sito ", " link ", " vai su ", " cerca su google ", " googla ",
                    " che canzone ", " cosa sta suonando ", " riprendi la musica ", " play ", " next ", " open ",
                    " blocca lo schermo ", " blocca il mac ", " modalita scura ", " modalita chiara ", " tema scuro ", " tema chiaro ", " dark mode "]
        return cues.contains { t.contains($0) }
    }

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static let instructions = """
    Classifichi comandi vocali in italiano o inglese per un assistente su Mac. Rispondi solo con l'azione.
    Azioni:
    - openApp: aprire un'applicazione (target = nome dell'app, es. "Figma", "Visual Studio Code").
    - openURL: aprire un sito o link (target = dominio o URL, es. "repubblica.it", "github.com").
    - webSearch: cercare qualcosa sul web (target = cosa cercare).
    - play: far partire musica. Se è indicato cosa (brano, artista, album, playlist) target = quello e kind = track, artist, \
    album, playlist, oppure liked per "i brani che mi piacciono"; se è solo "riprendi"/"play", target vuoto.
    - pause, next (salta/prossima/skippa), previous (precedente/indietro), nowPlaying (che canzone è).
    - volumeUp, volumeDown, volumeSet (value 0-100).
    - lockScreen (blocca lo schermo / il Mac), darkMode (modalità o tema scuro), lightMode (modalità chiara).
    - none: qualunque altra cosa (domande, lavoro, email, calendario, messaggi, file, codice, richieste ambigue o \
    composte). Nel dubbio: none.
    """

    /// Returns nil when the model is unavailable, unsure, or too slow.
    public static func parse(_ text: String) async -> Command? {
        #if canImport(FoundationModels)
        guard worthTrying(text) else { return nil }
        guard isAvailable else { log("fast path: Apple model unavailable (\(SystemLanguageModel.default.availability))"); return nil }
        return try? await withTimeout(2.5) {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: text, generating: Parsed.self,
                                              options: GenerationOptions(sampling: .greedy))
            let p = r.content
            guard let action = Action(rawValue: p.action), action != .none else { return nil }
            return Command(action: action, target: p.target.trimmingCharacters(in: .whitespacesAndNewlines),
                           kind: p.kind, value: p.value)
        } ?? nil
        #else
        return nil
        #endif
    }

    public static func prewarm() {
        #if canImport(FoundationModels)
        guard isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
        LanguageModelSession(instructions: ackInstructions).prewarm()
        #endif
    }

    static let ackInstructions = """
    Sei l'assistente vocale di un professionista italiano, che chiami "Signore". Ricevi la sua richiesta e scrivi SOLO \
    la frase di riscontro che diresti subito, prima di metterti al lavoro: specifica su cosa farai, breve (al massimo \
    12 parole), all'indicativo presente, cortese. Esempi: "Certo, Signore, controllo l'agenda di domani." \
    "Subito, Signore, apro il progetto Personal CRM e faccio il pull." "Certo, Signore, cerco la mail di Rossella." \
    Parla in prima persona di cosa fai tu (controllo, apro, verifico, cerco, preparo), riformulando: non copiare le \
    parole della richiesta e non usare imperativi come "dimmi" o "fammi". \
    Non rispondere alla domanda, non inventare dati, nomi o numeri che non sono nella richiesta. \
    Se è un saluto, una chiacchiera o una domanda di cultura generale, scrivi solo: -
    """

    /// The specific acknowledgement said while Claude works ("Certo, Signore, controllo l'agenda di domani."),
    /// from the on-device model. Nil when not useful (small talk), unavailable or too slow.
    public static func acknowledgement(for text: String, addressAs: String) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable, text.split(separator: " ").count >= 3 else { return nil }
        return try? await withTimeout(2.0) {
            let session = LanguageModelSession(instructions: ackInstructions.replacingOccurrences(of: "Signore", with: addressAs))
            let r = try await session.respond(to: text, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 40))
            var s = r.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"«»")))
            guard s.count > 8, s != "-", s.split(separator: " ").count <= 16, !s.contains("\n") else { return nil }
            // Only a real acknowledgement ("Certo, Signore, …"), never an answer it made up.
            guard s.range(of: #"^(Certo|Subito|Va bene|D'accordo|Senz'altro|Volentieri|Perfetto|Certamente)\b"#,
                          options: .regularExpression) != nil, s.contains(addressAs) else { return nil }
            guard s.lowercased().range(of: #"\b(dimmi|fammi|dammi|mi dici|mostrami|spiegami|trovami)\b"#,
                                       options: .regularExpression) == nil else { return nil }
            if !(s.hasSuffix(".") || s.hasSuffix("!")) { s += "." }
            return s
        } ?? nil
        #else
        return nil
        #endif
    }

    /// Runs the command; nil if it can't be done locally (→ Claude).
    public static func run(_ c: Command, actions: LocalActions, addressAs: String) async -> String? {
        switch c.action {
        case .none:
            return nil
        case .openApp:
            guard !c.target.isEmpty, let url = actions.resolveApp(c.target) else { return nil }
            guard (try? await actions.openApp(at: url)) != nil else { return nil }
            return "Apro \(url.deletingPathExtension().lastPathComponent)."
        case .openURL:
            var s = c.target.replacingOccurrences(of: " ", with: "")
            guard s.contains(".") else { return nil }
            if !s.contains("://") { s = "https://" + s }
            guard let url = URL(string: s) else { return nil }
            NSWorkspace.shared.open(url)
            return "Apro \(url.host ?? c.target)."
        case .webSearch:
            guard !c.target.isEmpty, let q = c.target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.google.com/search?q=\(q)") else { return nil }
            NSWorkspace.shared.open(url)
            return "Cerco \(c.target)."
        // Music errors (missing permission, Spotify not installed) are answered here: Claude couldn't do better.
        case .play:
            if c.target.isEmpty { return music { try Spotify.control("play") } }
            do { return try await Spotify.play(c.target, type: c.kind.isEmpty ? "track" : c.kind, mine: c.target.lowercased().contains("mia")) }
            catch { return "\(error)" }
        case .pause: return music { try Spotify.control("pause") }
        case .next: return music { try Spotify.control("next") }
        case .previous: return music { try Spotify.control("previous") }
        case .nowPlaying: return music { try Spotify.control("now") }
        case .volumeUp: return (try? actions.setVolume(.up)).map { "Volume a \($0)." }
        case .volumeDown: return (try? actions.setVolume(.down)).map { "Volume a \($0)." }
        case .volumeSet: return (try? actions.setVolume(.set(max(0, min(100, c.value))))).map { "Volume a \($0)." }
        case .lockScreen:
            _ = try? shell("/usr/bin/pmset", ["displaysleepnow"])
            return "Schermo bloccato."
        case .darkMode, .lightMode:
            let dark = c.action == .darkMode
            guard (try? shell("/usr/bin/osascript", ["-e",
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"])) != nil else { return nil }
            return dark ? "Modalità scura attiva." : "Modalità chiara attiva."
        }
    }
}

private func music(_ f: () throws -> String) -> String {
    do { return try f() } catch { return "\(error)" }
}

#if canImport(FoundationModels)
@Generable
struct Parsed {
    @Guide(description: "Una tra: none, openApp, openURL, webSearch, play, pause, next, previous, nowPlaying, volumeUp, volumeDown, volumeSet, lockScreen, darkMode, lightMode")
    var action: String
    @Guide(description: "App, sito, ricerca o musica richiesta; vuoto se non serve")
    var target: String
    @Guide(description: "Per play: track, artist, album, playlist o liked; altrimenti vuoto")
    var kind: String
    @Guide(description: "Per volumeSet: livello 0-100; altrimenti 0")
    var value: Int
}
#endif
