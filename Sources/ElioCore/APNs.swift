import CryptoKit
import Foundation

// MARK: - Device registry

/// A native iPhone app registered for Apple push (alerts) and, when it has one, a PushKit VoIP token (calls).
public struct APNsDevice: Codable, Sendable, Equatable {
    public var token: String
    public var voipToken: String?
    public var bundleId: String
    /// "sandbox" (built from Xcode) or "production" (TestFlight / App Store).
    public var env: String
    public var updatedAt: Date

    public init(token: String, voipToken: String? = nil, bundleId: String, env: String, updatedAt: Date = Date()) {
        self.token = token; self.voipToken = voipToken; self.bundleId = bundleId; self.env = env; self.updatedAt = updatedAt
    }

    var host: String { env == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com" }
}

/// Native devices, kept in Application Support/Elio/apns-devices.json (deduped by token).
public final class APNsRegistry: @unchecked Sendable {
    public static let shared = APNsRegistry(file: ElioPaths.support.appendingPathComponent("apns-devices.json"))

    public enum RegistrationError: Error, CustomStringConvertible {
        case badToken, badVoipToken, badBundleId, badEnv
        public var description: String {
            switch self {
            case .badToken: "token non valido (esadecimale, almeno 64 caratteri)"
            case .badVoipToken: "voipToken non valido (esadecimale, almeno 64 caratteri)"
            case .badBundleId: "bundleId non valido"
            case .badEnv: "env deve essere sandbox o production"
            }
        }
    }

    private let file: URL
    private let lock = NSLock()

    init(file: URL) { self.file = file }

    public var devices: [APNsDevice] { lock.withLock { load() } }
    public var callers: [APNsDevice] { devices.filter { $0.voipToken != nil } }

    static func isHexToken(_ s: String) -> Bool {
        (64...200).contains(s.count) && s.allSatisfy(\.isHexDigit)
    }

    static func isBundleId(_ s: String) -> Bool {
        s.count <= 155 && s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    /// Adds or refreshes a device. A registration without voipToken keeps the one already known.
    @discardableResult
    public func register(token: String, voipToken: String?, bundleId: String, env: String) throws -> APNsDevice {
        let token = token.lowercased()
        let voip = voipToken.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        guard Self.isHexToken(token) else { throw RegistrationError.badToken }
        if let voip, !Self.isHexToken(voip) { throw RegistrationError.badVoipToken }
        guard Self.isBundleId(bundleId) else { throw RegistrationError.badBundleId }
        guard env == "sandbox" || env == "production" else { throw RegistrationError.badEnv }
        return lock.withLock {
            var all = load()
            let previous = all.first { $0.token == token }
            let device = APNsDevice(token: token, voipToken: voip ?? previous?.voipToken, bundleId: bundleId, env: env)
            // Same token, or the same phone reinstalled (same VoIP token): one entry.
            all.removeAll { $0.token == token || (device.voipToken != nil && $0.voipToken == device.voipToken) }
            all.append(device)
            save(all)
            return device
        }
    }

    public func remove(token: String) {
        lock.withLock {
            var all = load()
            all.removeAll { $0.token == token }
            save(all)
        }
    }

    /// The VoIP token is dead but the alert token may still be fine.
    public func clearVoip(_ voipToken: String) {
        lock.withLock {
            var all = load()
            for i in all.indices where all[i].voipToken == voipToken { all[i].voipToken = nil }
            save(all)
        }
    }

    private func load() -> [APNsDevice] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.iso.decode([APNsDevice].self, from: $0) } ?? []
    }

    private func save(_ all: [APNsDevice]) {
        try? JSONEncoder.iso.encode(all).write(to: file, options: .atomic)
    }
}

// MARK: - Provider token (JWT)

public struct APNsCredentials: Sendable {
    public var teamId: String
    public var keyId: String
    public var key: P256.Signing.PrivateKey

    public init(teamId: String, keyId: String, key: P256.Signing.PrivateKey) {
        self.teamId = teamId; self.keyId = keyId; self.key = key
    }

    /// The .p8 file Apple gives you (PKCS#8 PEM); a bare base64 body is accepted too.
    public static func parseKey(_ text: String) throws -> P256.Signing.PrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN") { return try P256.Signing.PrivateKey(pemRepresentation: trimmed) }
        guard let der = Data(base64Encoded: trimmed.filter { !$0.isWhitespace }) else { throw ToolError("chiave .p8 non valida") }
        return try P256.Signing.PrivateKey(derRepresentation: der)
    }
}

enum APNsJWT {
    static func make(teamId: String, keyId: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyId], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamId, "iat": Int(issuedAt.timeIntervalSince1970)],
                                                options: .sortedKeys)
        let input = "\(b64url(header)).\(b64url(claims))"
        let signature = try key.signature(for: Data(input.utf8))
        return "\(input).\(b64url(signature.rawRepresentation))"
    }
}

/// Apple wants the same token reused: refreshed no more than every 20 minutes and never older than an hour.
final class APNsTokenCache: @unchecked Sendable {
    static let lifetime: TimeInterval = 50 * 60
    private let lock = NSLock()
    private var cached: (jwt: String, issuedAt: Date, identity: String)?

    func token(for c: APNsCredentials, now: Date = Date()) throws -> String {
        try lock.withLock {
            let identity = "\(c.teamId)/\(c.keyId)/\(b64url(c.key.publicKey.rawRepresentation))"
            if let cached, cached.identity == identity, now.timeIntervalSince(cached.issuedAt) < Self.lifetime, now >= cached.issuedAt {
                return cached.jwt
            }
            let jwt = try APNsJWT.make(teamId: c.teamId, keyId: c.keyId, key: c.key, issuedAt: now)
            cached = (jwt, now, identity)
            return jwt
        }
    }

    /// Apple said the token is expired or invalid: the next send makes a new one.
    func invalidate() { lock.withLock { cached = nil } }
}

// MARK: - Messages

/// One push, ready for any device: headers and JSON body.
public struct APNsMessage: Sendable {
    public var pushType: String          // alert | voip
    public var topicSuffix: String       // "" or ".voip"
    public var priority: Int
    public var expiration: Int?
    public var collapseId: String?
    public var body: Data

    /// title/body → aps.alert; "messages" collapses and carries the unread count as badge;
    /// confirm/question (and urgent calls) are time-sensitive; low urgency is delivered at priority 5, silently.
    public static func alert(title: String, body: String, tag: String?, urgency: String? = nil, badge: Int? = nil) -> APNsMessage {
        let level = urgency ?? (tag == "confirm" || tag == "question" ? "high" : "normal")
        var alert: [String: Any] = ["title": String(title.prefix(120)), "body": String(body.prefix(400))]
        if body.isEmpty { alert.removeValue(forKey: "body") }
        var aps: [String: Any] = ["alert": alert]
        if level != "low" && level != "very-low" { aps["sound"] = "default" }
        if tag == "confirm" || tag == "question" || level == "high" { aps["interruption-level"] = "time-sensitive" }
        if let badge { aps["badge"] = badge }
        if let tag { aps["thread-id"] = tag == "messages" ? "messages" : String(tag.prefix(64)) }
        var elio: [String: Any] = ["kind": tag ?? "elio"]
        if tag == "messages" { elio["url"] = "elio://messages" }
        let payload: [String: Any] = ["aps": aps, "elio": elio]
        // Repeats of the same call, and the messages summary, replace the previous notification.
        let collapse = tag.flatMap { $0 == "messages" || $0.hasPrefix("call-") ? String($0.prefix(64)) : nil }
        return APNsMessage(pushType: "alert", topicSuffix: "", priority: level == "low" || level == "very-low" ? 5 : 10,
                           expiration: nil, collapseId: collapse,
                           body: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data())
    }

    /// PushKit: the app reports it to CallKit and the phone rings. Never stored: a late call is useless.
    public static func call(id: String, title: String, text: String, reason: String? = nil) -> APNsMessage {
        var payload: [String: Any] = ["type": "call", "id": id, "title": title, "text": String(text.prefix(2000))]
        if let reason, !reason.isEmpty { payload["reason"] = String(reason.prefix(120)) }
        return APNsMessage(pushType: "voip", topicSuffix: ".voip", priority: 10, expiration: 0, collapseId: nil,
                           body: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data())
    }

    func request(to deviceToken: String, device: APNsDevice, jwt: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(device.host)/3/device/\(deviceToken)")!)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(device.bundleId + topicSuffix, forHTTPHeaderField: "apns-topic")
        req.setValue(pushType, forHTTPHeaderField: "apns-push-type")
        req.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        if let expiration { req.setValue(String(expiration), forHTTPHeaderField: "apns-expiration") }
        if let collapseId { req.setValue(collapseId, forHTTPHeaderField: "apns-collapse-id") }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body
        req.timeoutInterval = 15
        return req
    }
}

// MARK: - Sender

/// Apple Push Notification service for the native iPhone app: token-based auth (.p8 key in the Keychain,
/// Key ID / Team ID in the config), HTTP/2 straight to Apple (URLSession negotiates it).
public final class APNs: @unchecked Sendable {
    public static let shared = APNs()
    public static let keyService = "elio-apns-key"
    static let statusFile = ElioPaths.support.appendingPathComponent("apns-status.json")

    let tokens = APNsTokenCache()
    let registry: APNsRegistry
    private let session = URLSession(configuration: .ephemeral)
    private let lock = NSLock()
    private var parsedKey: (pem: String, key: P256.Signing.PrivateKey)?

    init(registry: APNsRegistry = .shared) { self.registry = registry }

    /// Team ID, Key ID and the .p8 key are all there.
    public static var isConfigured: Bool {
        let c = ElioConfig.load()
        return !c.apnsTeamId.isEmpty && !c.apnsKeyId.isEmpty && KeychainItem.read(service: keyService) != nil
    }

    /// A native app that can ring (CallKit) is registered and APNs is set up.
    public var canCall: Bool { !registry.callers.isEmpty && Self.isConfigured }

    func credentials() -> APNsCredentials? {
        let c = ElioConfig.load()
        let team = c.apnsTeamId.trimmingCharacters(in: .whitespaces), kid = c.apnsKeyId.trimmingCharacters(in: .whitespaces)
        guard !team.isEmpty, !kid.isEmpty, let pem = KeychainItem.read(service: Self.keyService) else { return nil }
        return lock.withLock {
            if let parsedKey, parsedKey.pem == pem { return APNsCredentials(teamId: team, keyId: kid, key: parsedKey.key) }
            guard let key = try? APNsCredentials.parseKey(pem) else { return nil }
            parsedKey = (pem, key)
            return APNsCredentials(teamId: team, keyId: kid, key: key)
        }
    }

    /// To every registered device; fire and forget.
    public func sendAlert(title: String, body: String, tag: String? = nil, urgency: String? = nil, badge: Int? = nil) {
        let devices = registry.devices
        guard !devices.isEmpty else { return }
        let message = APNsMessage.alert(title: title, body: body, tag: tag, urgency: urgency, badge: badge)
        for device in devices {
            Task { _ = await deliver(message, to: device.token, device: device, voip: false) }
        }
    }

    /// Rings every device with a VoIP token; returns how many Apple accepted.
    public func sendCall(id: String, title: String, text: String, reason: String? = nil) async -> Int {
        let message = APNsMessage.call(id: id, title: title, text: text, reason: reason)
        var reached = 0
        for device in registry.callers {
            if let voip = device.voipToken, await deliver(message, to: voip, device: device, voip: true) { reached += 1 }
        }
        return reached
    }

    @discardableResult
    func deliver(_ message: APNsMessage, to deviceToken: String, device: APNsDevice, voip: Bool) async -> Bool {
        guard let creds = credentials() else {
            record("APNs non configurato (Team ID, Key ID o chiave .p8 mancanti)")
            return false
        }
        let label = "\(voip ? "voip" : message.pushType) …\(deviceToken.suffix(6)) [\(device.env)]"
        do {
            let req = message.request(to: deviceToken, device: device, jwt: try tokens.token(for: creds))
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                record("ok: \(label)")
                return true
            }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? ""
            log("apns: \(label) answered \(status) \(reason)")
            record("errore \(status) \(reason): \(label)")
            if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" {
                if voip { registry.clearVoip(deviceToken) } else { registry.remove(token: deviceToken) }
            }
            if reason == "ExpiredProviderToken" || reason == "InvalidProviderToken" { tokens.invalidate() }
            return false
        } catch {
            log("apns: \(label) failed: \(error.localizedDescription)")
            record("errore di rete: \(label)")
            return false
        }
    }

    // Last result, for the Settings status line (the app runs in another process).
    private func record(_ text: String) {
        let obj: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "result": text]
        try? JSONSerialization.data(withJSONObject: obj).write(to: Self.statusFile, options: .atomic)
    }

    public static var lastResult: (at: Date, text: String)? {
        guard let data = try? Data(contentsOf: statusFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = (obj["at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }),
              let text = obj["result"] as? String else { return nil }
        return (at, text)
    }
}

// MARK: - Facade

/// Everything Elio pushes to the phone goes to both channels: Web Push for the PWA, APNs for the native app.
public enum PhonePush {
    public static func send(title: String, body: String, tag: String? = nil, urgency: String? = nil, badge: Int? = nil) {
        let native = !APNsRegistry.shared.devices.isEmpty
        // With only the native app, the PWA's "no phone subscribed" warning is just noise.
        if !native || !WebPush.shared.subscriptions.isEmpty {
            WebPush.shared.send(title: title, body: body, tag: tag, urgency: urgency)
        }
        if native { APNs.shared.sendAlert(title: title, body: body, tag: tag, urgency: urgency, badge: badge) }
    }

    /// Phones that can receive pushes (PWA subscriptions + native devices).
    public static var deviceCount: Int { WebPush.shared.subscriptions.count + APNsRegistry.shared.devices.count }
}
