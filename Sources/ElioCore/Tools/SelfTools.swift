import Foundation

/// Elio knows and adjusts itself: its settings and the app's windows.
public enum SelfTools {
    /// Settings Elio may change on request. Security-relevant ones need the user's OK.
    static let editable: [String: (label: String, sensitive: Bool)] = [
        "assistantName": ("nome dell'assistente (anche parola di attivazione)", false),
        "addressAs": ("come chiama l'utente (Signore/Signora…)", false),
        "userName": ("nome dell'utente", false),
        "spokenSentences": ("frasi pronunciate per risposta", false),
        "elevenLabsVoiceId": ("voce ElevenLabs (voice id)", false),
        "elevenLabsModel": ("modello della voce", false),
        "claudeModel": ("modello della conversazione (sonnet/opus/haiku)", false),
        "agentModel": ("modello degli agenti", false),
        "briefEarliest": ("briefing: dalle (HH:mm)", false),
        "briefLatest": ("briefing: al più tardi (HH:mm)", false),
        "briefOpening": ("sigla del briefing (true/false)", false),
        "recapTime": ("recap automatico (HH:mm, vuoto = solo a comando)", false),
        "meetingLeadMinutes": ("minuti di anticipo per aprire i Meet", false),
        "nudgeMissedMeetings": ("avviso meeting mancati", false),
        "repeatReminders": ("ripeti i promemoria finché non dico fatto", false),
        "slackClockInChannel": ("canale del clock in", false),
        "slackClockInText": ("messaggio del clock in", false),
        "accentColor": ("colore accento (#RRGGBB)", false),
        "persona": ("personalità e modo di parlare (il tuo prompt; vuoto = predefinito; segnaposto {assistente} {utente} {titolo})", true),
        "projectRoots": ("cartelle dei progetti (separate da virgola)", false),
        "echoCancellation": ("cancellazione dell'eco", false),
        "speakerThreshold": ("severità del riconoscimento della voce (0.3–0.85)", false),
        "speakerVerification": ("solo la voce dell'utente può comandare", true),
        "browserAutonomy": ("usare il browser da solo", true),
        "confirmCodeExecution": ("chiedere conferma anche per build e test", true),
        "stackColors": ("progetti colorati per tecnologia in dashboard", false),
        "appleFastPath": ("comandi semplici (musica, app, link, volume) col modello Apple sul Mac", true),
        "delegateDecisions": ("Elio risponde da solo alle domande piccole degli agenti, in base ai gusti dell'utente", true),
        "tasteReview": ("un revisore controlla il lavoro degli agenti sui gusti dell'utente e fa correggere", false),
        "reviewModel": ("modello per revisioni di gusto e decisioni delegate", false),
        "maxSquadAgents": ("numero massimo di agenti per squadra", false),
        "squadModel": ("modello degli agenti di squadra, scout e coordinatore (sonnet/opus/haiku)", false),
        "speechPrep": ("si prepara mentre l'utente parla (sessione veloce di sola lettura)", false),
        "screenGlance": ("allega uno screenshot alle richieste su ciò che l'utente sta guardando (cancellato dopo la risposta)", false),
        "prepModel": ("modello della preparazione mentre l'utente parla", false),
        "smartModelRouting": ("modello leggero solo per le micro-modifiche banali (Opus per tutto il resto)", false),
        "lightModel": ("modello leggero per le micro-modifiche", false),
        "idleAuto": ("modalità riposo automatica dopo idleMinutes senza tastiera e mouse", false),
        "idleMinutes": ("minuti di inattività prima del riposo automatico (5–120)", false),
        "idleScreen": ("schermo a riposo: off (spento) o dim (luminosità al minimo)", false),
        "quietStart": ("ore di silenzio: dalle (HH:mm), a riposo non sveglia il Mac nemmeno per le urgenze", false),
        "quietEnd": ("ore di silenzio: alle (HH:mm)", false),
        "idleListen": ("a riposo il microfono resta in ascolto della parola di attivazione", false),
    ]

    static let get = ElioTool(
        name: "elio_settings",
        description: "Le tue impostazioni attuali (cosa puoi cambiare con elio_set_setting) e lo stato di voce, integrazioni e rubrica."
    ) { _, ctx in
        let cfg = ElioConfig.load()
        let data = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(cfg))) as? [String: Any] ?? [:]
        var lines = ["Impostazioni:"]
        for key in editable.keys.sorted() {
            lines.append("- \(key) = \(data[key].map { "\($0)" } ?? "?") — \(editable[key]!.label)\(editable[key]!.sensitive ? " [serve conferma]" : "")")
        }
        lines.append("Voce dell'utente registrata: \(FileManager.default.fileExists(atPath: ElioPaths.support.appendingPathComponent("voiceprint.json").path) ? "sì" : "no")")
        lines.append(IntegrationStore.promptBlock(includeDisabled: true))
        let stats = await ctx.memory.cacheStats().map { "\($0.source) \($0.count)" }.joined(separator: ", ")
        lines.append("Rubrica locale: \(stats.isEmpty ? "vuota" : stats)")
        return lines.joined(separator: "\n")
    }

    static let set = ElioTool(
        name: "elio_set_setting",
        description: "Cambia una tua impostazione (vedi elio_settings). Si applica subito o al prossimo messaggio.",
        properties: ["key": prop("Nome dell'impostazione"), "value": prop("Nuovo valore")],
        required: ["key", "value"]
    ) { args, ctx in
        let key = args["key"] as? String ?? ""
        guard let meta = editable[key] else { throw ToolError("Impostazione non modificabile: \(key)") }
        let raw = "\(args["value"] ?? "")"
        if meta.sensitive {
            let ok = await ctx.gate.request(ConfirmRequest(
                id: UUID().uuidString, title: "Cambio l'impostazione \(meta.label) in \(raw)",
                detail: "\(key) = \(raw)", risk: .normal, taskId: nil), timeout: 120)
            guard ok else { return "L'utente non ha confermato." }
        }
        var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ElioConfig.load()))) as? [String: Any] ?? [:]
        switch json[key] {
        case is Bool: json[key] = ["true", "sì", "si", "1", "on"].contains(raw.lowercased())
        case let n as NSNumber where CFNumberIsFloatType(n): json[key] = Double(raw.replacingOccurrences(of: ",", with: ".")) ?? n
        case is NSNumber: json[key] = Int(raw) ?? json[key]
        case is [Any]: json[key] = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default: json[key] = raw
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let cfg = try? JSONDecoder().decode(ElioConfig.self, from: data) else { throw ToolError("Valore non valido") }
        cfg.save()
        ctx.broadcast(ServerMessage(type: .event, text: key, kind: "settingsChanged"))
        await ctx.requestRestartAfterTurn()
        return "Impostato \(key) = \(raw)."
    }

    static let open = ElioTool(
        name: "open_elio",
        description: "Apre una tua finestra sul Mac: dashboard, settings (tab: generale, voce, cervello, routine, integrazioni, telefono; opzionale integration id) o archive.",
        properties: ["view": prop("dashboard, settings o archive"), "tab": prop("Tab delle impostazioni"), "integration": prop("Id integrazione")],
        required: ["view"]
    ) { args, ctx in
        let payload = ["view": args["view"] as? String ?? "dashboard", "tab": args["tab"] as? String ?? "",
                       "integration": args["integration"] as? String ?? ""]
        let data = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) }
        ctx.broadcast(ServerMessage(type: .event, text: payload["view"], kind: "openView", payload: data))
        return "Aperto."
    }
}
