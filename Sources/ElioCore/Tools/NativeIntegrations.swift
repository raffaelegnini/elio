import AppKit
import EventKit
import Foundation

/// Built-in integrations (Slack, Gmail, Apple Mail, Calendar, Spotify): status and "Collega"
/// for Settings → Integrazioni, also usable by voice. Secrets are written by the daemon itself.
public enum NativeIntegrations {
    public struct Status: Codable, Sendable {
        public var id: String
        public var name: String
        public var connected: Bool
        public var detail: String
        /// What "Collega" needs: none, token, oauthClient (id+secret), clientId.
        public var needs: String
        public var help: String
    }

    public static func all() async -> [Status] {
        let slackOK = KeychainItem.read(service: "elio-slack")?.hasPrefix("xox") == true
        let slackWho = slackOK ? ((try? await SlackAPI.shared.call("auth.test"))?["user"] as? String).map { "come \($0)" } ?? "token salvato" : "non collegato"
        let gmail = Gmail.accounts()
        let cal = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let calCount = cal ? CalendarTools.store.calendars(for: .event).count : 0
        return [
            Status(id: "slack", name: "Slack", connected: slackOK, detail: slackWho, needs: "token",
                   help: "Token utente (xoxp-…) dall'app Slack di Elio: api.slack.com/apps → la tua app → OAuth & Permissions."),
            Status(id: "gmail", name: "Gmail", connected: !gmail.isEmpty,
                   detail: gmail.isEmpty ? (Gmail.hasClient ? "client Google pronto, manca l'accesso" : "non collegato") : gmail.joined(separator: ", "),
                   needs: Gmail.hasClient ? "none" : "oauthClient",
                   help: "Una volta sola: console.cloud.google.com → nuovo progetto → abilita Gmail API → Schermata consenso (Esterno, aggiungi la tua mail tra i tester) → Credenziali → ID client OAuth tipo \"App desktop\". Incolla ID e secret, poi \"Accedi con Google\". Puoi anche chiederlo a Elio: lo fa lui col browser."),
            Status(id: "applemail", name: "Mail (app del Mac)", connected: AppleMail.isAvailable,
                   detail: AppleMail.isAvailable ? "tutti gli account configurati in Mail" : "non collegata", needs: "none",
                   help: "Usa gli account già configurati nell'app Mail (iCloud, Outlook, posta aziendale…). Al primo collegamento macOS chiede il permesso."),
            Status(id: "calendar", name: "Calendario", connected: cal,
                   detail: cal ? "\(calCount) calendari (Google, iCloud… quelli aggiunti al Mac)" : "permesso non concesso", needs: "none",
                   help: "Vede i calendari aggiunti in Impostazioni di Sistema → Account Internet."),
            Status(id: "spotify", name: "Spotify", connected: Spotify.isLoggedIn,
                   detail: Spotify.isLoggedIn ? "collegato" : (Spotify.clientId == nil ? "solo controllo dell'app" : "manca l'accesso"),
                   needs: Spotify.clientId == nil ? "clientId" : "none",
                   help: "developer.spotify.com/dashboard → Create app → Redirect URI http://127.0.0.1:8739/callback → Web API. Incolla il Client ID."),
        ]
    }

    public static func connect(_ id: String, _ args: [String: Any]) async throws -> String {
        switch id {
        case "slack":
            let token = (args["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.hasPrefix("xox") else { throw ToolError("Il token Slack inizia con xoxp- o xoxb-") }
            KeychainItem.write(service: "elio-slack", value: token)
            let r = try await SlackAPI.shared.call("auth.test")
            guard r["ok"] as? Bool == true else { throw ToolError("Slack rifiuta il token: \(r["error"] as? String ?? "?")") }
            return "Slack collegato come \(r["user"] as? String ?? "?")."
        case "gmail":
            if let cid = args["client_id"] as? String, let secret = args["client_secret"] as? String, !cid.isEmpty, !secret.isEmpty {
                Gmail.setClient(id: cid.trimmingCharacters(in: .whitespaces), secret: secret.trimmingCharacters(in: .whitespaces))
            }
            let email = try await Gmail.connect()
            return "Gmail collegato: \(email)."
        case "applemail":
            return try AppleMail.enable()
        case "calendar":
            try await CalendarTools.ensureAccess()
            return "Calendario collegato."
        case "spotify":
            if let cid = args["client_id"] as? String, !cid.isEmpty {
                KeychainItem.write(service: Spotify.clientService, value: cid.trimmingCharacters(in: .whitespaces))
            }
            return try await Spotify.login()
        default:
            throw ToolError("Integrazione sconosciuta: \(id)")
        }
    }

    public static func disconnect(_ id: String, account: String?) -> String {
        switch id {
        case "slack": KeychainItem.delete(service: "elio-slack")
        case "gmail":
            for a in Gmail.accounts() where account == nil || a == account { KeychainItem.delete(service: Gmail.tokenService(a)) }
        case "applemail": AppleMail.disable()
        case "spotify": KeychainItem.delete(service: Spotify.tokenService)
        default: return "Non si scollega da qui."
        }
        return "Scollegato."
    }

    static let status = ElioTool(
        name: "integrations_native",
        description: "Stato delle integrazioni native (Slack, Gmail, Mail, Calendario, Spotify), in JSON.",
        properties: [:]
    ) { _, _ in await all().jsonString() }

    static let connectTool = ElioTool(
        name: "integration_connect",
        description: """
        Collega un'integrazione nativa: id = slack (token), gmail (client_id e client_secret la prima volta, poi apre il login \
        Google), applemail, calendar, spotify (client_id la prima volta, poi login). Non ripetere mai token o secret.
        """,
        properties: ["id": prop("slack, gmail, applemail, calendar o spotify"), "token": prop("Token Slack"),
                     "client_id": prop("Client ID (Google o Spotify)"), "client_secret": prop("Client secret Google")],
        required: ["id"]
    ) { args, _ in
        try await connect(args["id"] as? String ?? "", args)
    }

    static let disconnectTool = ElioTool(
        name: "integration_disconnect",
        description: "Scollega un'integrazione nativa (slack, gmail, applemail, spotify).",
        properties: ["id": prop("Integrazione"), "account": prop("Per Gmail: quale account (vuoto = tutti)")],
        required: ["id"]
    ) { args, _ in
        disconnect(args["id"] as? String ?? "", account: args["account"] as? String)
    }
}
