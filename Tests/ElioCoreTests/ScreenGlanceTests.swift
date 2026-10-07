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
        #expect(!wrong.lowercased().contains("slack"))
        let right = FastPath.grounded("Guardo Slack, Signore.", in: "ho messaggi su slack?", addressAs: "Signore")
        #expect(right == "Guardo Slack, Signore.")
        #expect(FastPath.grounded("Controllo l'agenda di domani, Signore.", in: "che impegni ho domani", addressAs: "Signore").contains("agenda"))
    }
}
