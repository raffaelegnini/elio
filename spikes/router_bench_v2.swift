// Spike v2: route-only classification, prewarmed sessions.
import Foundation
import FoundationModels

@Generable
enum Route: String { case local, claude, agent }

let instructions = """
Classifica la richiesta vocale. local = comando semplice del Mac (apri app, timer, volume, ora) o saluto. \
claude = domanda che richiede conoscenza, ragionamento o dati personali (calendario, mail, meteo, spiegazioni). \
agent = lavoro lungo su codice, terminale, test, PR, review.
"""

let tests = [
    "Apri Slack", "Ciao Elio, buongiorno!", "Metti un timer di 10 minuti",
    "Cosa ho in calendario oggi?", "Spiegami la differenza tra Redis e Memcached",
    "Fammi la review della branch feature/checkout e preparami il diff",
    "Open Spotify please", "What's the weather like in Naples today?",
    "Controlla i test del progetto klynn e sistema quelli rotti",
    "Ricordami alle 17 di chiamare Marco", "Come stai?", "Scrivi a Luca su Slack che arrivo tardi",
]

func makeSession() -> LanguageModelSession {
    let s = LanguageModelSession(instructions: instructions)
    s.prewarm()
    return s
}

var next = makeSession()
try await Task.sleep(for: .seconds(2))
for t in tests {
    let session = next
    let start = Date()
    let r = try await session.respond(to: t, generating: Route.self,
                                      options: GenerationOptions(sampling: .greedy))
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print("\(ms)ms | \(r.content) | \(t)")
    next = makeSession()
    try await Task.sleep(for: .milliseconds(500))
}
