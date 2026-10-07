import Foundation
import Observation
import UIKit
import UserNotifications

/// Native notifications: asks permission, gets the APNs token and tells the Mac where to reach this phone
/// (api/apns/register, together with the VoIP token for calls). Re-registers at every launch and whenever
/// a token changes: the call is idempotent on the Mac.
@Observable
final class PushManager: NSObject {
    enum Registration: Equatable { case idle, sending, ok(devices: Int?, macConfigured: Bool), failed(String) }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var apnsToken: String?
    private(set) var voipToken: String?
    private(set) var registration: Registration = .idle
    /// APNs refused to give a token (no entitlement, Simulator without a team…).
    private(set) var tokenError: String?

    @ObservationIgnored weak var client: ElioClient?
    /// A notification was tapped: (kind, url).
    @ObservationIgnored var onOpen: ((String?, String?) -> Void)?
    @ObservationIgnored private var lastSent: (body: String, at: Date)?

    /// Sandbox for builds signed for development (Xcode), production for TestFlight and the App Store.
    /// Read from the provisioning profile's aps-environment: a wrong value makes Apple reject the token.
    static let environment: String = {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .isoLatin1),
           let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
           let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
           let ent = plist["Entitlements"] as? [String: Any],
           let aps = ent["aps-environment"] as? String {
            return aps == "production" ? "production" : "sandbox"
        }
        #if DEBUG
        return "sandbox"
        #else
        // No embedded profile: App Store install.
        return "production"
        #endif
    }()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// From a tap in Settings or at first launch after pairing.
    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refreshAuthorization()
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// At every launch: iOS hands out the token even before (or without) alert permission.
    func start() {
        Task { await refreshAuthorization() }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        tokenError = nil
        guard hex != apnsToken else { sync(); return }
        apnsToken = hex
        sync(force: true)
    }

    func didFailToRegister(_ error: Error) {
        tokenError = error.localizedDescription
    }

    func setVoipToken(_ token: String) {
        guard token != voipToken else { return }
        voipToken = token
        sync(force: true)
    }

    /// Sends the tokens to the Mac (skipped if the same body went out in the last minute, unless forced).
    func sync(force: Bool = false) {
        // The Mac requires the APNs token; the VoIP one rides along when PushKit has delivered it.
        guard let client, client.pairing != nil, apnsToken != nil else { return }
        var body: [String: Any] = ["bundleId": Bundle.main.bundleIdentifier ?? "it.dnafactory.elio.phone",
                                   "env": Self.environment]
        if let apnsToken { body["token"] = apnsToken }
        if let voipToken { body["voipToken"] = voipToken }
        let key = "\(apnsToken ?? "")|\(voipToken ?? "")|\(Self.environment)"
        if !force, let last = lastSent, last.body == key, Date().timeIntervalSince(last.at) < 60 { return }
        lastSent = (key, Date())
        registration = .sending
        struct Reply: Decodable { var ok: Bool?; var devices: Int?; var configured: Bool? }
        Task {
            do {
                let reply = try await client.post("api/apns/register", json: body, as: Reply.self)
                registration = .ok(devices: reply.devices, macConfigured: reply.configured ?? true)
            } catch {
                lastSent = nil
                registration = .failed(error.localizedDescription)
            }
        }
    }

    func sendTest() async -> String {
        guard let client else { return "Non associato." }
        do {
            try await client.post("push/test")
            return "Prova inviata: dovrebbe arrivare tra pochi secondi."
        } catch {
            return "Prova non inviata: \(error.localizedDescription)"
        }
    }

    /// Asks the Mac to ring this phone (api/call/test).
    func testCall() async -> String {
        guard let client else { return "Non associato." }
        struct Reply: Decodable { var ok: Bool?; var error: String? }
        do {
            try await client.post("api/call/test")
            return "Chiamata di prova in arrivo."
        } catch let ElioClient.ClientError.http(_, body) {
            let msg = (try? JSONDecoder().decode(Reply.self, from: Data(body.utf8)))?.error ?? body
            return "Chiamata non partita: \(msg)"
        } catch {
            return "Chiamata non partita: \(error.localizedDescription)"
        }
    }

    func setBadge(_ n: Int) {
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // In the app the socket already shows it; a quiet banner still helps when on another tab.
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let elio = info["elio"] as? [String: Any]
        let kind = elio?["kind"] as? String
        let url = elio?["url"] as? String
        Task { @MainActor in self.onOpen?(kind, url) }
        completionHandler()
    }
}
