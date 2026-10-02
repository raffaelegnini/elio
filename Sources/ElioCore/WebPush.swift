import CryptoKit
import Foundation

/// Web Push to the phone PWA (iOS 16.4+ home-screen apps, Android, desktop browsers), no third party:
/// VAPID (RFC 8292) signed with a key kept on the Mac, payload encrypted per RFC 8291 (aes128gcm).
public final class WebPush: @unchecked Sendable {
    public static let shared = WebPush()

    public struct Subscription: Codable, Sendable, Equatable {
        public var endpoint: String
        public var p256dh: String   // base64url, uncompressed P-256 point
        public var auth: String     // base64url, 16 bytes
        public init(endpoint: String, p256dh: String, auth: String) { self.endpoint = endpoint; self.p256dh = p256dh; self.auth = auth }
    }

    private let lock = NSLock()
    private let keyFile = ElioPaths.support.appendingPathComponent("vapid.key")
    private let subsFile = ElioPaths.support.appendingPathComponent("push-subscriptions.json")
    private lazy var signingKey: P256.Signing.PrivateKey = {
        if let data = try? Data(contentsOf: keyFile), let k = try? P256.Signing.PrivateKey(rawRepresentation: data) { return k }
        let k = P256.Signing.PrivateKey()
        try? k.rawRepresentation.write(to: keyFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return k
    }()

    /// Public key for `pushManager.subscribe({applicationServerKey})`.
    public var publicKey: String { b64url(signingKey.publicKey.x963Representation) }

    public var subscriptions: [Subscription] {
        lock.withLock { (try? Data(contentsOf: subsFile)).flatMap { try? JSONDecoder().decode([Subscription].self, from: $0) } ?? [] }
    }

    public func add(_ sub: Subscription) {
        lock.withLock {
            var all = (try? Data(contentsOf: subsFile)).flatMap { try? JSONDecoder().decode([Subscription].self, from: $0) } ?? []
            all.removeAll { $0.endpoint == sub.endpoint }
            all.append(sub)
            try? JSONEncoder().encode(all).write(to: subsFile, options: .atomic)
        }
    }

    private func remove(_ endpoint: String) {
        lock.withLock {
            var all = (try? Data(contentsOf: subsFile)).flatMap { try? JSONDecoder().decode([Subscription].self, from: $0) } ?? []
            all.removeAll { $0.endpoint == endpoint }
            try? JSONEncoder().encode(all).write(to: subsFile, options: .atomic)
        }
    }

    /// Sends to every subscribed device; expired subscriptions are dropped.
    public func send(title: String, body: String, tag: String? = nil) {
        let payload: [String: Any] = ["title": title, "body": body, "tag": tag ?? UUID().uuidString]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        for sub in subscriptions {
            Task {
                do {
                    let status = try await deliver(json, to: sub, urgent: tag == "confirm")
                    if status == 404 || status == 410 { remove(sub.endpoint) }
                } catch {
                    FileHandle.standardError.write(Data("web push failed: \(error)\n".utf8))
                }
            }
        }
    }

    func deliver(_ plaintext: Data, to sub: Subscription, urgent: Bool) async throws -> Int {
        guard let url = URL(string: sub.endpoint), let host = url.host,
              let uaPublicData = unb64url(sub.p256dh), let authSecret = unb64url(sub.auth) else { return 410 }
        let body = try Self.encrypt(plaintext, uaPublic: uaPublicData, authSecret: authSecret)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("86400", forHTTPHeaderField: "TTL")
        req.setValue(urgent ? "high" : "normal", forHTTPHeaderField: "Urgency")
        req.setValue("vapid t=\(try jwt(audience: "\(url.scheme ?? "https")://\(host)")), k=\(publicKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    func jwt(audience: String) throws -> String {
        let header = b64url(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims: [String: Any] = ["aud": audience, "exp": Int(Date().timeIntervalSince1970) + 12 * 3600,
                                     "sub": "mailto:elio@dnafactory.it"]
        let payload = b64url(try JSONSerialization.data(withJSONObject: claims))
        let input = "\(header).\(payload)"
        let signature = try signingKey.signature(for: Data(input.utf8))
        return "\(input).\(b64url(signature.rawRepresentation))"
    }

    /// RFC 8291: ECDH with the browser's key, HKDF with its auth secret, AES-128-GCM, single record.
    static func encrypt(_ plaintext: Data, uaPublic: Data, authSecret: Data,
                        ephemeral: P256.KeyAgreement.PrivateKey = .init(), fixedSalt: Data? = nil) throws -> Data {
        let ua = try P256.KeyAgreement.PublicKey(x963Representation: uaPublic)
        let asPublic = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: ua)
        let ecdh = shared.withUnsafeBytes { Data($0) }

        let prkKey = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ecdh), salt: authSecret)
        let keyInfo = Data("WebPush: info".utf8) + Data([0]) + uaPublic + asPublic
        let ikm = HKDF<SHA256>.expand(pseudoRandomKey: prkKey, info: keyInfo, outputByteCount: 32)

        var salt = Data(count: 16)
        if let fixedSalt { salt = fixedSalt } else {
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]), outputByteCount: 16)
        let nonceData = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: nonce".utf8) + Data([0]), outputByteCount: 12)
            .withUnsafeBytes { Data($0) }

        let sealed = try AES.GCM.seal(plaintext + Data([2]), using: cek, nonce: AES.GCM.Nonce(data: nonceData))
        var out = salt
        out += Data([0, 0, 0x10, 0])          // record size 4096
        out += Data([UInt8(asPublic.count)])
        out += asPublic
        out += sealed.ciphertext + sealed.tag
        return out
    }
}

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func unb64url(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    t += String(repeating: "=", count: (4 - t.count % 4) % 4)
    return Data(base64Encoded: t)
}
