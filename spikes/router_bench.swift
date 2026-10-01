// Spike: Apple Foundation Models as Elio fast router (Italian/English).
import Foundation
import FoundationModels

@Generable
enum Route: String {
    case local      // trivial command or chit-chat handled on-device
    case claude     // needs knowledge or reasoning, quick answer
    case agent      // long task: terminal, code, PR, multi-step work
}

@Generable
struct Decision {
    @Guide(description: "Dove instradare la richiesta")
    var route: Route
    @Guide(description: "Frase breve e naturale da dire SUBITO all'utente, nella sua lingua, senza inventare fatti")
    var ack: String
}

let instructions = """
Sei il router vocale di Elio. Classifica la richiesta:
- local: comandi semplici (apri app, timer, ora, volume) o saluti/chiacchiere.
- claude: domande che richiedono conoscenza, ragionamento o dati (calendario, mail, consigli).
- agent: lavori lunghi (codice, terminale, PR, review, ricerche in più passi).
Il campo ack è una conferma breve. Non rispondere mai nel merito, non inventare dati.
"""

let model = SystemLanguageModel.default
print("availability:", model.availability)
guard case .available = model.availability else { exit(1) }

let tests = [
    "Apri Slack", "Ciao Elio, buongiorno!", "Metti un timer di 10 minuti",
    "Cosa ho in calendario oggi?", "Spiegami la differenza tra Redis e Memcached",
    "Fammi la review della branch feature/checkout e preparami il diff",
    "Open Spotify please", "What's the weather like in Naples today?",
    "Controlla i test del progetto klynn e sistema quelli rotti",
]

for t in tests {
    let session = LanguageModelSession(instructions: instructions)
    let start = Date()
    do {
        let r = try await session.respond(to: t, generating: Decision.self)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("\(ms)ms | \(r.content.route) | \(t) → \(r.content.ack)")
    } catch { print("ERR \(t): \(error)") }
}
