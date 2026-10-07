import CryptoKit
import Foundation
import Testing
@testable import ElioCore

@Suite struct APNsTests {
    static let hex64 = String(repeating: "ab", count: 32)
    static let voip64 = String(repeating: "cd", count: 32)

    func part(_ jwt: String, _ i: Int) throws -> [String: Any] {
        let s = String(jwt.split(separator: ".")[i])
        return try #require(try JSONSerialization.jsonObject(with: unb64url(s)!) as? [String: Any])
    }

    @Test func jwtShapeAndSignature() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try APNsJWT.make(teamId: "TEAM123456", keyId: "KEY1234567", key: key, issuedAt: now)
        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)
        let header = try part(jwt, 0), claims = try part(jwt, 1)
        #expect(header as NSDictionary == ["alg": "ES256", "kid": "KEY1234567"] as NSDictionary)
        #expect(claims as NSDictionary == ["iss": "TEAM123456", "iat": 1_700_000_000] as NSDictionary)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: unb64url(String(parts[2]))!)
        #expect(key.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func tokenCachedForFiftyMinutes() throws {
        let creds = APNsCredentials(teamId: "T", keyId: "K", key: P256.Signing.PrivateKey())
        let cache = APNsTokenCache()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try cache.token(for: creds, now: t0)
        #expect(try cache.token(for: creds, now: t0.addingTimeInterval(49 * 60)) == a)
        let b = try cache.token(for: creds, now: t0.addingTimeInterval(50 * 60))
        #expect(b != a)
        #expect(try part(b, 1)["iat"] as? Int == 1_700_000_000 + 3000)
        // Another key id: a new token right away.
        var other = creds
        other.keyId = "K2"
        #expect(try cache.token(for: other, now: t0.addingTimeInterval(50 * 60 + 1)) != b)
        cache.invalidate()
        #expect(try cache.token(for: other, now: t0.addingTimeInterval(50 * 60 + 2)) != b)
    }

    @Test func parsesP8() throws {
        let key = P256.Signing.PrivateKey()
        let parsed = try APNsCredentials.parseKey(key.pemRepresentation + "\n")
        #expect(parsed.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(throws: (any Error).self) { try APNsCredentials.parseKey("not a key") }
    }

    @Test func registryDedupeAndValidation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apns-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let reg = APNsRegistry(file: file)
        try reg.register(token: Self.hex64.uppercased(), voipToken: Self.voip64, bundleId: "it.dnafactory.elio.phone", env: "sandbox")
        // Same token again without VoIP token: one entry, VoIP token kept.
        try reg.register(token: Self.hex64, voipToken: nil, bundleId: "it.dnafactory.elio.phone", env: "production")
        #expect(reg.devices.count == 1)
        #expect(reg.devices[0].token == Self.hex64)
        #expect(reg.devices[0].voipToken == Self.voip64)
        #expect(reg.devices[0].env == "production")
        // Reinstalled app: new token, same VoIP token → replaces.
        let other = String(repeating: "12", count: 32)
        try reg.register(token: other, voipToken: Self.voip64, bundleId: "it.dnafactory.elio.phone", env: "sandbox")
        #expect(reg.devices.map(\.token) == [other])

        #expect(throws: APNsRegistry.RegistrationError.self) {
            try reg.register(token: "abc", voipToken: nil, bundleId: "it.x.y", env: "sandbox")
        }
        #expect(throws: APNsRegistry.RegistrationError.self) {
            try reg.register(token: String(repeating: "zz", count: 32), voipToken: nil, bundleId: "it.x.y", env: "sandbox")
        }
        #expect(throws: APNsRegistry.RegistrationError.self) {
            try reg.register(token: Self.hex64, voipToken: "123", bundleId: "it.x.y", env: "sandbox")
        }
        #expect(throws: APNsRegistry.RegistrationError.self) {
            try reg.register(token: Self.hex64, voipToken: nil, bundleId: "no spaces/allowed", env: "sandbox")
        }
        #expect(throws: APNsRegistry.RegistrationError.self) {
            try reg.register(token: Self.hex64, voipToken: nil, bundleId: "it.x.y", env: "dev")
        }

        reg.clearVoip(Self.voip64)
        #expect(reg.callers.isEmpty)
        reg.remove(token: other)
        #expect(reg.devices.isEmpty)
    }

    func json(_ m: APNsMessage) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: m.body) as? [String: Any])
    }

    @Test func alertPayload() throws {
        let m = APNsMessage.alert(title: "Promemoria", body: "Chiama Marco", tag: "reminder")
        #expect(m.pushType == "alert" && m.priority == 10 && m.collapseId == nil && m.expiration == nil)
        let aps = try #require(try json(m)["aps"] as? [String: Any])
        #expect((aps["alert"] as? [String: String]) == ["title": "Promemoria", "body": "Chiama Marco"])
        #expect(aps["sound"] as? String == "default")
        #expect(aps["interruption-level"] == nil)
        #expect(aps["badge"] == nil)

        let q = try json(APNsMessage.alert(title: "Una domanda per te", body: "Procedo?", tag: "question"))
        #expect((q["aps"] as? [String: Any])?["interruption-level"] as? String == "time-sensitive")
        let c = try json(APNsMessage.alert(title: "Serve una conferma", body: "Push?", tag: "confirm"))
        #expect((c["aps"] as? [String: Any])?["interruption-level"] as? String == "time-sensitive")
    }

    @Test func messagesBadgeAndCollapse() throws {
        let m = APNsMessage.alert(title: "3 messaggi da Elio", body: "Build finita", tag: "messages", urgency: "low", badge: 3)
        #expect(m.collapseId == "messages")
        #expect(m.priority == 5)
        let obj = try json(m)
        let aps = try #require(obj["aps"] as? [String: Any])
        #expect(aps["badge"] as? Int == 3)
        #expect(aps["sound"] == nil)
        #expect((obj["elio"] as? [String: String]) == ["kind": "messages", "url": "elio://messages"])

        let device = APNsDevice(token: Self.hex64, bundleId: "it.dnafactory.elio.phone", env: "sandbox")
        let req = m.request(to: device.token, device: device, jwt: "J")
        #expect(req.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(Self.hex64)")
        #expect(req.value(forHTTPHeaderField: "authorization") == "bearer J")
        #expect(req.value(forHTTPHeaderField: "apns-topic") == "it.dnafactory.elio.phone")
        #expect(req.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(req.value(forHTTPHeaderField: "apns-priority") == "5")
        #expect(req.value(forHTTPHeaderField: "apns-collapse-id") == "messages")
        #expect(req.value(forHTTPHeaderField: "apns-expiration") == nil)
    }

    @Test func voipCall() throws {
        let m = APNsMessage.call(id: "c1", title: "Elio", text: "La pausa è finita", reason: "Fine pausa")
        let obj = try json(m)
        #expect(obj["type"] as? String == "call")
        #expect(obj["id"] as? String == "c1")
        #expect(obj["title"] as? String == "Elio")
        #expect(obj["text"] as? String == "La pausa è finita")
        let device = APNsDevice(token: Self.hex64, voipToken: Self.voip64, bundleId: "it.dnafactory.elio.phone", env: "production")
        let req = m.request(to: Self.voip64, device: device, jwt: "J")
        #expect(req.url?.absoluteString == "https://api.push.apple.com/3/device/\(Self.voip64)")
        #expect(req.value(forHTTPHeaderField: "apns-topic") == "it.dnafactory.elio.phone.voip")
        #expect(req.value(forHTTPHeaderField: "apns-push-type") == "voip")
        #expect(req.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(req.value(forHTTPHeaderField: "apns-expiration") == "0")
    }

    @Test func quietHoursGateCalls() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: h, minute: m))! }
        #expect(PhoneCalls.mayRing(at: at(15, 0), phone: false, quietStart: "23:00", quietEnd: "07:30", calendar: cal))
        #expect(!PhoneCalls.mayRing(at: at(23, 30), phone: false, quietStart: "23:00", quietEnd: "07:30", calendar: cal))
        #expect(!PhoneCalls.mayRing(at: at(7, 0), phone: false, quietStart: "23:00", quietEnd: "07:30", calendar: cal))
        #expect(PhoneCalls.mayRing(at: at(7, 30), phone: false, quietStart: "23:00", quietEnd: "07:30", calendar: cal))
        // Asked explicitly for the phone: rings anyway.
        #expect(PhoneCalls.mayRing(at: at(2, 0), phone: true, quietStart: "23:00", quietEnd: "07:30", calendar: cal))
    }

    @Test func callLifecycle() async throws {
        let declined = CallCounter()
        let calls = PhoneCalls(ring: { _ in 1 }, fallback: { _ in await declined.add() }, canRing: { true },
                               timeout: 3600, retry: 3600)
        let call = try #require(await calls.start(text: "Fine pausa", title: "Meet", phone: true))
        #expect(call.status == .ringing && call.attempt == 1)
        #expect(await calls.answer(call.id)?.status == .answered)
        #expect(await calls.end(call.id)?.status == .ended)
        #expect(await calls.answer("nope") == nil)

        let second = try #require(await calls.start(text: "Ancora", title: "Meet", phone: true))
        #expect(await calls.decline(second.id)?.status == .declined)
        #expect(await declined.value == 1)

        // Unanswered after the first ring: missed, retry scheduled (no fallback yet).
        let third = try #require(await calls.start(text: "Ehi", title: "Meet", phone: true))
        await calls.unanswered(third.id)
        #expect(await calls.call(third.id)?.status == .missed)
        #expect(await declined.value == 1)

        let none = PhoneCalls(ring: { _ in 0 }, fallback: { _ in }, canRing: { true })
        #expect(await none.start(text: "x", title: "y", phone: true) == nil)
        let noApp = PhoneCalls(ring: { _ in 1 }, fallback: { _ in }, canRing: { false })
        #expect(await noApp.start(text: "x", title: "y", phone: true) == nil)
    }
}

actor CallCounter {
    var value = 0
    func add() { value += 1 }
}
