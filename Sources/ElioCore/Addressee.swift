import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Who a sentence is for, and what the user wants with it — decided on the Mac by Apple's on-device model
/// (fractions of a second, no Claude tokens). Used when the user talks while Elio is speaking (stop it,
/// redirect it, or just tell it something), and for follow-ups said without "Elio" (to it, or to a colleague?).
public enum Addressee {
    public enum Target: String, Sendable { case elio, other, unclear }
    public enum Intent: String, Sendable {
        /// Stop talking / stop what you're doing.
        case stop
        /// Correction or a new, more urgent request: what Elio is saying no longer fits.
        case change
        /// Something for Elio that doesn't need to cut it off ("domani sono fuori", "ricordati che…").
        case remark
        /// "sì", "ok", "mh", "capito": just listening along.
        case backchannel
        /// A request (when Elio isn't talking).
        case request
    }

    public struct Verdict: Sendable, Equatable {
        public let target: Target
        public let intent: Intent
    }

    static let backchannels: Set<String> = ["si", "sì", "ok", "okay", "mh", "mhm", "certo", "capito", "va bene", "perfetto",
                                           "giusto", "esatto", "ah", "ah ok", "ok ok", "sì sì", "si si", "bene", "ottimo", "vero"]

    /// Quick rules first (no model needed), then the on-device model, then a cautious fallback.
    public static func classify(said: String, elioSaying: String?, wakeWord: Bool) async -> Verdict {
        let t = said.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if BargeIn.words.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") }) && t.split(separator: " ").count <= 4 {
            return Verdict(target: .elio, intent: .stop)
        }
        if backchannels.contains(t) { return Verdict(target: .elio, intent: .backchannel) }
        // Strong cues the small model misses: a correction while Elio talks, or the assistant's own topics.
        let speaking = elioSaying != nil
        if speaking, t.range(of: #"^(no|anzi|invece|scusa|aspetta|intendevo|non quello|ma no|fermo)\b"#, options: .regularExpression) != nil {
            return Verdict(target: .elio, intent: .change)
        }
        let thirdPerson = t.range(of: #"\b(gli ho detto|non mi sente|non mi capisce|elio è|elio non|ha detto elio)\b"#, options: .regularExpression) != nil
        let assistantTopic = t.range(of: #"\b(mail|email|slack|agenda|calendario|riunion|meeting|promemoria|ricordami|ricordati|segna|segnati|to.?do|lista|messaggio|scrivi|manda|codice|repo|branch|commit|deploy|musica|canzone|spotify|briefing|recap|agente|squadra|apri|cerca)\w*"#, options: .regularExpression) != nil
        if !thirdPerson, assistantTopic {
            return Verdict(target: .elio, intent: speaking ? .change : .request)
        }
        if let v = await model(said: said, elioSaying: elioSaying, wakeWord: wakeWord) {
            // Personal information said while Elio talks is usually for it ("domani sono in ferie").
            if speaking, v.target == .other, !thirdPerson,
               t.range(of: #"\b(sono|ho|devo|io|mio|mia)\b"#, options: .regularExpression) != nil,
               t.range(of: #"\b(tu|te|ti|voi|vi|usciamo|andiamo|passami|dammi)\b"#, options: .regularExpression) == nil {
                return Verdict(target: .elio, intent: .remark)
            }
            return v
        }
        // No model: with the wake word it's for Elio; otherwise, while Elio talks, a remark; else not for it.
        if wakeWord { return Verdict(target: .elio, intent: elioSaying == nil ? .request : .change) }
        return elioSaying == nil ? Verdict(target: .unclear, intent: .request) : Verdict(target: .elio, intent: .remark)
    }

    static let instructions = """
    Raffaele lavora al Mac con il suo assistente vocale Elio; vicino a lui possono esserci colleghi o può essere al \
    telefono. Ricevi una frase detta da Raffaele (trascrizione automatica, con possibili errori) e, se c'è, cosa Elio \
    stava dicendo in quel momento. Decidi:

    target:
    - elio: la frase è per l'assistente. Indizi: nomina Elio; risponde a ciò che Elio ha appena detto o chiesto; \
    è un ordine o una domanda che un assistente può eseguire (agenda, mail, messaggi, codice, musica, file, ricerche); \
    corregge Elio ("no, intendevo…", "non quello").
    - other: la frase è per un'altra persona. Indizi: nomina o si rivolge a qualcun altro; parla di Elio in terza \
    persona ("gli ho detto…", "non mi sente"); chiacchiere, battute o commenti tra persone; argomenti che non \
    c'entrano con quello che Elio stava dicendo e che non sono richieste.
    - unclear: davvero impossibile dirlo.

    intent:
    - stop: vuole che Elio smetta di parlare o si fermi (basta, stop, zitto, aspetta, fermati, ho capito non serve).
    - change: Elio stava parlando e la frase cambia ciò che deve dire o fare (correzione, nuova richiesta più urgente, \
    "no, dimmi invece…").
    - remark: un'informazione o un commento per Elio che non richiede di interromperlo.
    - backchannel: solo un segno di ascolto (sì, ok, mh, capito, va bene).
    - request: una richiesta normale (quando Elio non stava parlando).
    """

    static func model(said: String, elioSaying: String?, wakeWord: Bool) async -> Verdict? {
        #if canImport(FoundationModels)
        guard FastPath.isAvailable else { return nil }
        let prompt = """
            \(elioSaying.map { "Elio stava dicendo: «\(String($0.suffix(400)))»" } ?? "Elio era in silenzio.")
            \(wakeWord ? "Raffaele ha iniziato la frase chiamando Elio per nome." : "Raffaele non ha detto il nome di Elio.")
            Raffaele ha detto: «\(said)»
            """
        return try? await withTimeout(1.8) {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: prompt, generating: AddresseeParsed.self,
                                              options: GenerationOptions(sampling: .greedy))
            let target = Target(rawValue: r.content.target) ?? .unclear
            let intent = Intent(rawValue: r.content.intent) ?? (elioSaying == nil ? .request : .remark)
            return Verdict(target: target, intent: intent)
        } ?? nil
        #else
        return nil
        #endif
    }

    public static func prewarm() {
        #if canImport(FoundationModels)
        guard FastPath.isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct AddresseeParsed {
    @Guide(description: "Una tra: elio, other, unclear")
    var target: String
    @Guide(description: "Una tra: stop, change, remark, backchannel, request")
    var intent: String
}
#endif
