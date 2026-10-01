import Testing
@testable import JarvisCore

struct IntentMatcherTests {
    let m = IntentMatcher()

    @Test(arguments: [
        ("Apri Slack", LocalIntent.openApp("slack"), Lang.it),
        ("Jarvis, apri Google Chrome per favore", .openApp("google chrome"), .it),
        ("open spotify please", .openApp("spotify"), .en),
        ("Che ore sono?", .time, .it),
        ("what time is it", .time, .en),
        ("Metti un timer di 10 minuti", .timer(seconds: 600), .it),
        ("timer di cinque minuti", .timer(seconds: 300), .it),
        ("set a timer for 30 seconds", .timer(seconds: 30), .en),
        ("Volume al 40%", .volume(.set(40)), .it),
        ("alza il volume", .volume(.up), .it),
        ("mute", .volume(.mute), .en),
        ("Basta", .stop, .it),
        ("Jarvis, fammi il briefing", .brief, .it),
        ("recap della notte", .brief, .it),
        ("Jarvis, recap della giornata", .recap, .it),
        ("com'è andata oggi?", .recap, .it),
        ("fatto", .done, .it),
    ])
    func matches(input: String, intent: LocalIntent, lang: Lang) {
        #expect(m.match(input) == MatchedIntent(intent: intent, lang: lang))
    }

    @Test(arguments: [
        "Cosa ho in calendario oggi?",
        "Spiegami la differenza tra Redis e Memcached",
        "Apri la PR di feature checkout e fammi vedere il diff con i commenti",
        "Ricordami alle 17 di chiamare Marco",
        "Come stai?",
        "timer di zero minuti",
    ])
    func fallsThroughToClaude(input: String) {
        #expect(m.match(input) == nil)
    }

    @Test func unknownAppIsNotResolved() {
        #expect(LocalActions().resolveApp("la pr di feature") == nil)
        #expect(LocalActions().resolveApp("calcolatrice") != nil)
    }

    @Test func durations() {
        #expect(Replies.duration(90, .it) == "1 minuto e 30 secondi")
        #expect(Replies.duration(3600, .en) == "1 hour")
    }
}
