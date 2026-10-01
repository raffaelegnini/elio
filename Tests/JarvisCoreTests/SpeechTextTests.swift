import Testing
@testable import JarvisCore

struct WakeWordTests {
    @Test(arguments: [
        ("Jarvis, apri Slack", "apri Slack"),
        ("Jarvis che ore sono", "che ore sono"),
        ("Ehi Jarvis, come va?", "come va"),
        ("Giarvis metti un timer", "metti un timer"),
        ("Jarvis", ""),
        ("Giaviscose oggi in calendario", "oggi in calendario"),
        ("E i Jarvis, cosa ho in calendario oggi?", "cosa ho in calendario oggi"),
    ])
    func detects(utterance: String, command: String) {
        #expect(WakeWord.strip(utterance) == command)
    }

    @Test(arguments: [
        "Ho parlato con Marco della riunione di domani",
        "Gravi problemi in produzione",
        "Apri Slack",
        "Ho detto a Jarvis di aspettare",
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

struct ConfirmationAnswerTests {
    @Test func dangerousNeedsTheExplicitWord() {
        #expect(ConfirmationAnswer.parse("sì vai", risk: .dangerous) == .needsExplicit)
        #expect(ConfirmationAnswer.parse("Confermo.", risk: .dangerous) == .approve)
        #expect(ConfirmationAnswer.parse("no aspetta", risk: .dangerous) == .deny)
    }

    @Test func normalAcceptsYes() {
        #expect(ConfirmationAnswer.parse("Sì, procedi", risk: .normal) == .approve)
        #expect(ConfirmationAnswer.parse("che ore sono", risk: .normal) == .unrelated)
        #expect(ConfirmationAnswer.parse("non farlo", risk: .normal) == .deny)
    }
}
