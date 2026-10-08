import Testing
@testable import ElioCore

struct ScreenGlanceTests {
    @Test func spotsRequestsAboutTheScreen() {
        for t in ["ora ho degli errori sull'IDE, me li spieghi?", "cosa vedi?", "guarda qui, che significa questo?",
                  "mi dà un errore strano", "che vuol dire questo errore", "leggimi cosa c'è scritto", "dai un'occhiata a questa pagina",
                  "c'è un problema nello schermo"] {
            #expect(ScreenGlance.wants(t), "\(t)")
        }
        for t in ["che tempo fa domani", "metti un po' di musica", "ricordami di chiamare Marco alle 5", "apri Slack"] {
            #expect(!ScreenGlance.wants(t), "\(t)")
        }
    }
}

struct AckGroundingTests {
    @Test func acksOnlyNameWhatTheUserSaid() {
        let wrong = FastPath.grounded("Guardo Slack, Signore.", in: "mi fai il riassunto del progetto skgame?", addressAs: "Signore")
        #expect(wrong.map { !$0.lowercased().contains("slack") } ?? true)
        let right = FastPath.grounded("Guardo Slack, Signore.", in: "ho messaggi su slack?", addressAs: "Signore")
        #expect(right == "Guardo Slack, Signore.")
        #expect(FastPath.grounded("Controllo l'agenda di domani, Signore.", in: "che impegni ho domani", addressAs: "Signore")?.contains("agenda") == true)
        #expect(FastPath.grounded("Il presidente della repubblica è Sergio Mattarella, Signore.", in: "chi è il presidente della repubblica?", addressAs: "Signore") == nil)
        #expect(FastPath.grounded("Fa 391, Signore.", in: "quanto fa 17 per 23", addressAs: "Signore") == nil)
    }
}
