import Testing
@testable import ElioCore

@Suite(.serialized)
struct WakeWordTests {
    @Test func elio() {
        WakeWord.configure(name: "Elio", aliases: ["helio"])
        defer { WakeWord.configure(name: "Elio", aliases: ["helio"]) }
        #expect(WakeWord.strip("Elio, che ore sono") == "che ore sono")
        #expect(WakeWord.strip("Ehi Elio cosa ho oggi") == "cosa ho oggi")
        #expect(WakeWord.strip("Elio") == "")
        #expect(WakeWord.strip("Ho parlato con Elio ieri sera") == nil)
        #expect(WakeWord.strip("Elia vieni qui") == nil)
    }

    @Test(arguments: [
        ("Elio, apri Slack", "apri Slack"),
        ("Elio che ore sono", "che ore sono"),
        ("Ehi Elio, come va?", "come va"),
        ("Helio metti un timer", "metti un timer"),
        ("Elio", ""),
        ("E i Elio, cosa ho in calendario oggi?", "cosa ho in calendario oggi"),
    ])
    func detects(utterance: String, command: String) {
        #expect(WakeWord.strip(utterance) == command)
    }

    @Test(arguments: [
        "Ho parlato con Marco della riunione di domani",
        "Elia vieni qui",
        "Apri Slack",
        "Ho detto a Elio di aspettare",
        "",
    ])
    func ignores(utterance: String) {
        #expect(WakeWord.strip(utterance) == nil)
    }
}

struct SentenceSplitterTests {
    @Test func streamsSentences() {
        var s = SentenceSplitter()
        var out: [String] = []
        for chunk in ["Buongiorno Raffaele. ", "Oggi hai tre meet", "ing, il primo alle 10.30 con il team! Vuoi", " il riepilogo?"] {
            out += s.push(chunk)
        }
        if let rest = s.flush() { out.append(rest) }
        #expect(out == ["Buongiorno Raffaele.", "Oggi hai tre meeting, il primo alle 10.30 con il team!", "Vuoi il riepilogo?"])
    }

    @Test func breaksLongFirstSentenceAtComma() {
        var s = SentenceSplitter()
        let out = s.push("Ho controllato il calendario di oggi e quello di domani mattina, e devo dire che ")
        #expect(out == ["Ho controllato il calendario di oggi e quello di domani mattina,"])
    }
}

struct VADTests {
    func run(_ vad: inout VoiceActivityDetector, level: Float, seconds: Double, frame: Double = 0.02) -> [VoiceActivityDetector.Event] {
        var events: [VoiceActivityDetector.Event] = []
        for _ in 0..<Int(seconds / frame) {
            if let e = vad.process(levelDb: level, duration: frame) { events.append(e) }
        }
        return events
    }

    @Test func detectsUtterance() {
        var vad = VoiceActivityDetector()
        var events = run(&vad, level: -62, seconds: 2)
        events += run(&vad, level: -30, seconds: 1)
        events += run(&vad, level: -62, seconds: 1)
        #expect(events == [.speechStart, .speechEnd])
    }

    @Test func ignoresShortClick() {
        var vad = VoiceActivityDetector()
        var events = run(&vad, level: -62, seconds: 2)
        events += run(&vad, level: -25, seconds: 0.06)
        events += run(&vad, level: -62, seconds: 1)
        #expect(events.isEmpty)
    }

    /// Regression: floor learned in a quiet instant, then normal room noise must not
    /// keep the utterance open until the max length.
    @Test func endsInRoomNoiseAfterQuietStart() {
        var vad = VoiceActivityDetector()
        var events = run(&vad, level: -82, seconds: 2)
        events += run(&vad, level: -60, seconds: 6)
        #expect(events.count <= 2)
        #expect(!vad.inSpeech)
    }

    @Test func steadyNoiseIsNotSpeech() {
        var vad = VoiceActivityDetector()
        let events = run(&vad, level: -45, seconds: 10)
        #expect(events.isEmpty)
    }
}

struct SpeakableTests {
    @Test func stripsMarkdown() {
        #expect(Speakable.clean("**Fatto**: vedi https://x.y/z e `git status`") == "Fatto: vedi e git status")
    }
}

struct BargeInTests {
    @Test func interruptsOnStopWordsElioIsNotSaying() {
        let saying = "Ha tre riunioni oggi, la prima alle dieci con il team di prodotto."
        #expect(BargeIn.detect("Elio aspetta", whileSaying: saying))
        #expect(BargeIn.detect("basta così", whileSaying: saying))
        #expect(!BargeIn.detect("tre riunioni oggi la prima", whileSaying: saying))
    }

    @Test func ignoresEchoOfItsOwnWords() {
        #expect(!BargeIn.detect("aspetta un attimo", whileSaying: "Aspetta un attimo che controllo."))
    }
}

struct AcknowledgementTests {
    @Test func picksBySubject() {
        #expect(Acknowledgement.phrase(for: "cosa ho in agenda domani?", addressAs: "Signore")?.hasSuffix(", Signore, controllo l'agenda.") == true)
        #expect(Acknowledgement.phrase(for: "Rosario mi ha scritto su Slack?", addressAs: "Signora")?.hasSuffix(", Signora, guardo Slack.") == true)
        #expect(Acknowledgement.phrase(for: "come stai", addressAs: "Signore") == nil)
        #expect(Acknowledgement.phrase(for: "grazie", addressAs: "Signore") == nil)
        #expect(Acknowledgement.phrase(for: "puoi preparare una bozza della proposta per il nuovo cliente", addressAs: "Signore")?
                .hasSuffix(", Signore.") == true)
        #expect(Acknowledgement.phrase(for: "controlla la mail di Rosario", addressAs: "Signore")?.hasSuffix(", Signore, controllo la posta.") == true)
        for _ in 0..<20 { #expect(Acknowledgement.phrase(for: "cosa ho in agenda", addressAs: "Signore")?.hasPrefix("Certo") == false) }
        #expect(Acknowledgement.isAcknowledgement("Certo, Signore, controllo subito le previsioni."))
        #expect(!Acknowledgement.isAcknowledgement("Domani sarà soleggiato con ventisette gradi."))
    }
}

struct EchoTests {
    let said = "Certo, Signore, le faccio subito il recap della giornata."

    @Test func dropsPureEcho() {
        #expect(Echo.remove(from: "Elio Certo, signore, le faccio subito il reca della giornata", spoken: said)
                .split(separator: " ").count <= 2)
        #expect(Echo.remove(from: "le faccio subito il recap", spoken: said) == "")
    }

    @Test func keepsWhatTheUserAdds() {
        #expect(Echo.remove(from: "subito il recap della giornata Elio aspetta", spoken: said) == "Elio aspetta")
        #expect(Echo.remove(from: "Elio che ore sono", spoken: said) == "Elio che ore sono")
    }
}

struct ConfirmationAnswerTests {
    @Test func dangerousNeedsTheExplicitWord() {
        #expect(ConfirmationAnswer.parse("sì sì vai", risk: .dangerous) == .approve)
        #expect(ConfirmationAnswer.parse("invialo", risk: .dangerous) == .approve)
        #expect(ConfirmationAnswer.parse("sì però prima dimmi bene a chi lo stai mandando", risk: .dangerous) == .needsExplicit)
        #expect(ConfirmationAnswer.parse("no non mandarlo", risk: .dangerous) == .deny)
        // Real session: a leading "no" before an order is a yes; echoed "non puoi" is gone after Echo.remove.
        #expect(ConfirmationAnswer.parse("No, allora Elio invia il messaggio a Damiano", risk: .dangerous) == .approve)
        #expect(ConfirmationAnswer.parse("no", risk: .dangerous) == .deny)
        #expect(ConfirmationAnswer.parse("lascia stare", risk: .normal) == .deny)
        #expect(ConfirmationAnswer.parse("non lo scrivere. Non lo scrivere.", risk: .normal) == .deny)
        #expect(ConfirmationAnswer.parse("non mandarlo", risk: .dangerous) == .deny)
        #expect(ConfirmationAnswer.parse("sì sì sì vai", risk: .dangerous) == .approve)
        #expect(ConfirmationAnswer.parse("Confermo.", risk: .dangerous) == .approve)
        #expect(ConfirmationAnswer.parse("no aspetta", risk: .dangerous) == .deny)
    }

    @Test func normalAcceptsYes() {
        #expect(ConfirmationAnswer.parse("Sì, procedi", risk: .normal) == .approve)
        #expect(ConfirmationAnswer.parse("che ore sono", risk: .normal) == .unrelated)
        #expect(ConfirmationAnswer.parse("non farlo", risk: .normal) == .deny)
        #expect(ConfirmationAnswer.parse("che ore sono", risk: .dangerous) == .unrelated)
    }
}

struct EndOfTurnTests {
    @Test func completeRequestsGoRightAway() {
        #expect(EndOfTurn.wait("che ore sono?", cutByLimit: false) == 0)
        #expect(EndOfTurn.wait("metti un po' di musica", cutByLimit: false) == 0)
    }

    @Test func pausesMidSentenceWait() {
        #expect(EndOfTurn.wait("manda un messaggio ad Antonio Vitale e", cutByLimit: false) > 1)
        #expect(EndOfTurn.wait("nel repo comitiva devo fare tre modifiche:", cutByLimit: false) > 1)
        #expect(EndOfTurn.wait("la prima è sul login, poi", cutByLimit: false) > 1)
        #expect(EndOfTurn.wait("breve", cutByLimit: true) > 1)
        let long = Array(repeating: "parola", count: 30).joined(separator: " ")
        #expect(EndOfTurn.wait(long, cutByLimit: false) > 1)
    }
}

struct SpeechNormalizerTests {
    @Test(arguments: [
        ("Ho rilasciato la 1.0.1.", "Ho rilasciato la 1 punto 0 punto 1."),
        ("Aggiorna a v2.3", "Aggiorna a versione 2 punto 3"),
        ("Usa PHP 8.2 e Laravel 11", "Usa PHP 8 punto 2 e Laravel 11"),
        ("Costa 1.200 euro", "Costa 1.200 euro"),
        ("Alle 10:30 e alle 9:00", "Alle 10 e 30 e alle 9"),
        ("Il 50% dei test", "Il 50 per cento dei test"),
        ("Chiusa la PR #42", "Chiusa la PR numero 42"),
        ("Ci vogliono 3-5 minuti", "Ci vogliono da 3 a 5 minuti"),
        ("Schermo 1920x1080", "Schermo 1920 per 1080"),
        ("Ho modificato app.swift e .env", "Ho modificato app punto swift e punto env"),
        ("login -> dashboard", "login, dashboard"),
        ("frontend/backend", "frontend slash backend"),
        ("Master è passato da 85f3b61 a 6b0e2a4", "Master è passato da otto cinque effe tre bi sei uno a sei bi zero e due a quattro"),
        ("commit 9c1d2e3f4a5b6c7d8e9f", "commit nove ci uno di due e tre"),
        ("il ticket AB12CD34", "il ticket a bi uno due ci di tre quattro"),
        ("video H264 in UTF8 su iPhone15 per la build14", "video H264 in UTF8 su iPhone15 per la build14"),
    ])
    func saysItLikeAPerson(input: String, expected: String) {
        #expect(SpeechNormalizer.italian(input) == expected, "\(input)")
    }

    @Test func snakeCaseIsTwoWords() {
        #expect(Speakable.clean("Il campo user_id è vuoto") == "Il campo user id è vuoto")
    }
}
