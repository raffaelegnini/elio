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
    ])
    func detects(utterance: String, command: String) {
        #expect(WakeWord.strip(utterance) == command)
    }

    @Test(arguments: [
        "Ho parlato con Marco della riunione di domani",
        "Gravi problemi in produzione",
        "Apri Slack",
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
    @Test func detectsUtterance() {
        var vad = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        let frame = 0.02
        for _ in 0..<50 { if let e = vad.process(levelDb: -60, duration: frame) { events.append(e) } }
        for _ in 0..<50 { if let e = vad.process(levelDb: -30, duration: frame) { events.append(e) } }
        for _ in 0..<60 { if let e = vad.process(levelDb: -60, duration: frame) { events.append(e) } }
        #expect(events == [.speechStart, .speechEnd])
    }

    @Test func ignoresShortClick() {
        var vad = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        for _ in 0..<50 { _ = vad.process(levelDb: -60, duration: 0.02) }
        for level: Float in [-25, -60, -25, -60] { if let e = vad.process(levelDb: level, duration: 0.02) { events.append(e) } }
        #expect(events.isEmpty)
    }
}

struct SpeakableTests {
    @Test func stripsMarkdown() {
        #expect(Speakable.clean("**Fatto**: vedi https://x.y/z e `git status`") == "Fatto: vedi e git status")
    }
}
