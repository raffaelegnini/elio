import Testing
@testable import JarvisCore

struct SecretFilterTests {
    @Test(arguments: [
        "Il token è xoxp-1234567890-abcdefghij-0987654321",
        "Ecco: password: Sup3rS3gr3ta!",
        "username raffaele, pwd=hunter2hunter2",
        "clona con https://raffaele:ATBBx9Kk2LmQ8zR4tYvW1pN7cD3fG6hJ@bitbucket.org/dna/repo.git",
        "AWS AKIAIOSFODNN7EXAMPLE nel file",
        "chiave ⟦qualunque-cosa⟧ fornita",
        "header Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abc123",
        "sk_0000fake1111fake2222fake3333fake4444fake5555",
        "token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
    ])
    func detectsSecrets(text: String) {
        #expect(SecretFilter.contains(text), "\(text)")
        #expect(!SecretFilter.speakable(text).contains("Sup3r"))
    }

    @Test(arguments: [
        "Domani alle dieci hai il meeting con il team di prodotto.",
        "Il file è in /Users/raffaele/Desktop/dev/jarvis/Sources/JarvisCore/SecretFilter.swift",
        "Il commit 35ed629 sistema la funzione add.",
        "Apri https://meet.google.com/abc-defg-hij",
        "La password va cambiata ogni tre mesi.",
    ])
    func leavesNormalTextAlone(text: String) {
        #expect(!SecretFilter.contains(text), "\(text)")
    }

    @Test func redactsOnlyTheValue() {
        let out = SecretFilter.redact("utente: mario, password: Abc12345xyz")
        #expect(out == "utente: mario, password: \(SecretFilter.placeholder)")
    }

    @Test func speaksPlaceholder() {
        #expect(SecretFilter.speakable("La chiave è ⟦xyz-123⟧, la trovi nel vault.")
                == "La chiave è dato riservato, la trovi nel vault.")
    }
}
