import Testing
@testable import ElioCore

struct ModelRouterTests {
    func pick(_ title: String, _ prompt: String, _ difficulty: String?) -> ModelRouter.Choice {
        ModelRouter.pick(title: title, prompt: prompt, difficulty: difficulty, base: "opus", light: "sonnet")
    }

    @Test func trivialEditsGoLight() {
        #expect(pick("Correggi un typo", "Nel README c'è 'recieve' invece di 'receive'", "trivial").model == "sonnet")
        #expect(pick("Cambia colore bottone", "Il bottone Salva in settings.vue deve essere #FFD360 invece di blu", "trivial").model == "sonnet")
        #expect(pick("Bump versione", "Porta la versione in package.json a 1.0.2", "trivial").model == "sonnet")
    }

    @Test func everythingElseIsOpus() {
        // Not flagged trivial by Elio.
        #expect(pick("Correggi un typo", "README", nil).model == "opus")
        // Flagged trivial, but it's real work.
        #expect(pick("Cambia il testo del login", "Il testo dell'errore di login", "trivial").model == "opus")
        #expect(pick("Rinomina", "Rinomina la funzione in tutti i file del progetto", "trivial").model == "opus")
        #expect(pick("Aggiorna testo", "Aggiorna il testo e aggiungi un test", "trivial").model == "opus")
        #expect(pick("Sistema", "Sistema la pagina", "trivial").model == "opus")
        #expect(pick("Implementa export CSV", "Nuova feature con API e test", "hard").model == "opus")
    }

    @Test func routingCanBeTurnedOff() {
        let c = ModelRouter.pick(title: "typo", prompt: "typo nel README", difficulty: "trivial", base: "opus", light: "sonnet", enabled: false)
        #expect(c.model == "opus")
    }
}
