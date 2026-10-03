import Testing
@testable import ElioCore

/// The rules that don't need the on-device model.
struct AddresseeTests {
    let saying = "Alle dieci hai lo standup, poi la call con il cliente"

    @Test func stopAndBackchannel() async {
        #expect(await Addressee.classify(said: "basta così", elioSaying: saying, wakeWord: false) == .init(target: .elio, intent: .stop))
        #expect(await Addressee.classify(said: "ok", elioSaying: saying, wakeWord: false) == .init(target: .elio, intent: .backchannel))
    }

    @Test func correctionsChangeCourse() async {
        #expect(await Addressee.classify(said: "no aspetta dimmi solo le mail", elioSaying: saying, wakeWord: false).intent == .change)
        #expect(await Addressee.classify(said: "anzi mandalo a Rosario", elioSaying: saying, wakeWord: false).target == .elio)
    }

    @Test func assistantTopicsAreForElio() async {
        #expect(await Addressee.classify(said: "e mandami il report su slack", elioSaying: nil, wakeWord: false) == .init(target: .elio, intent: .request))
    }
}
