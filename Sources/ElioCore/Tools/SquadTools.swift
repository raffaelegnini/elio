import Foundation

// MARK: - Prompts

extension TaskRunner {
    static func macPrompt(title: String, prompt: String) -> String {
        """
        Sei un agente di Elio, l'assistente personale di Raffaele, e lavori sul suo Mac in background mentre lui fa altro.

        Compito: \(title)
        Dettagli: \(prompt)

        Hai a disposizione il terminale, i file della sua home, il browser e gli strumenti di Elio: puoi spostare e creare \
        file e cartelle, cambiare impostazioni (defaults, networksetup, pmset -g…), leggere log, debuggare app e progetti.
        Regole:
        - Tienilo aggiornato con mcp__elio__report_progress ai passaggi importanti: una frase breve, parlata, al presente o \
        passato prossimo, senza "Signore" (lo aggiunge Elio). Es. "Ho spostato la cartella, ora creo il file." \
        Non più di un aggiornamento ogni 15-20 secondi e mai per dettagli tecnici minori.
        - Cancellare file, usare sudo, fermare processi, inviare messaggi o dati all'esterno passa da una conferma: \
        chiedila solo se serve davvero. Preferisci spostare nel Cestino (`mv … ~/.Trash/`) piuttosto che cancellare.
        - Nei comandi Bash scrivi il campo description in italiano, breve, all'infinito: se serve una conferma, \
        è quello che Raffaele sente.
        - Per spostare/copiare usa `mv -n` / `cp -n` (mai sovrascrivere senza chiedere). Per creare o modificare file \
        usa Write/Edit, non redirect della shell (> sovrascrive e chiede conferma). Niente `python -c`/`sh -c`: \
        il codice inline chiede conferma.
        - Se un'informazione manca o c'è una scelta con impatto, chiedi con mcp__elio__ask_user (domanda breve e chiara).
        - Termina con un riassunto in italiano di massimo due frasi, adatto a essere letto a voce.
        """
    }

    static func memberPrompt(goal: String, name: String, role: String, task: String, cwd: String, team: [TaskInfo]) -> String {
        let others = team.isEmpty ? "(per ora nessun altro)"
            : team.map { "- \($0.member ?? "?"): \($0.role ?? "")" }.joined(separator: "\n")
        return """
        Sei "\(name)", un agente di una squadra coordinata da Elio, l'assistente personale di Raffaele.
        Obiettivo della squadra: \(goal)
        Progetto: \(cwd)
        Il tuo ruolo: \(role)
        Il tuo compito: \(task)

        Compagni di squadra:
        \(others)

        Come collaborare:
        - Leggi i messaggi con mcp__elio__squad_inbox all'inizio, prima di decisioni importanti e ogni tanto mentre lavori.
        - Scrivi con mcp__elio__squad_post: `to` = nome di un compagno, "tutti", oppure "elio" per riferire al coordinatore. \
        Messaggi brevi e concreti (interfacce concordate, file che tocchi, risultati, blocchi).
        - Concorda con i compagni chi tocca quali file per non pestarvi i piedi.
        - A Elio riferisci solo cose utili a Raffaele: progressi importanti, decisioni da prendere, problemi.
        - Codice: lavora su un branch locale `elio/<slug-breve>` (lo stesso per tutta la squadra, se lavorate sullo stesso repo: \
        mettetevi d'accordo), committa lì. Mai push, merge, rebase né PR: Raffaele rivede il diff e crea lui la PR.
        - Per creare o modificare file usa Edit/Write (già autorizzati nel progetto), non printf/echo/cat con > o >>: \
        quelli chiedono una conferma a Raffaele e vi bloccano. Comandi git semplici, uno per volta, senza `git -C` né `cd`: \
        siete già nella cartella del progetto.
        - Nei comandi Bash scrivi il campo description in italiano, breve, all'infinito ("aggiornare il repository \
        da main"): se serve una conferma, è quello che Raffaele sente.
        - Non cancellare file e non inviare messaggi fuori dalla squadra senza conferma.
        - Se ti manca un'informazione che solo Raffaele ha, chiedi con mcp__elio__ask_user.
        - Termina con un riassunto di massimo due frasi del tuo lavoro.
        """
    }
}

// MARK: - Tools

public enum SquadTools {
    static let macTask = ElioTool(
        name: "mac_task",
        description: """
        Avvia un agente in background che agisce sul Mac di Raffaele: spostare/creare/riordinare file e cartelle, \
        cambiare o indagare impostazioni di macOS, debuggare un'app o un problema, installare strumenti, lavori di più passaggi. \
        Restituisce subito: l'agente aggiorna Raffaele a voce ai passaggi importanti e riferisce alla fine. \
        Usalo per qualunque cosa richieda più di un paio di comandi, così la conversazione resta libera.
        """,
        properties: [
            "title": prop("Titolo breve, in italiano (es. \"Sposto Progetti in Archivio\")"),
            "prompt": prop("Istruzioni complete e autosufficienti per l'agente"),
            "directory": prop("Cartella di lavoro (default: la home)"),
        ],
        required: ["title", "prompt"]
    ) { args, ctx in
        let dir = expandPath(args["directory"] as? String ?? "~")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Cartella non trovata: \(dir)")
        }
        let info = try await ctx.tasks.start(title: args["title"] as? String ?? "Lavoro sul Mac",
                                             prompt: args["prompt"] as? String ?? "", cwd: dir, kind: .mac)
        return "Agente avviato (id \(info.id)). Riferirà a voce: non serve aspettarlo, rispondi a Raffaele con una frase."
    }

    static let progress = ElioTool(
        name: "report_progress",
        description: "Aggiorna Raffaele a voce su un passaggio importante del tuo lavoro in background (una frase breve).",
        properties: ["text": prop("La frase da dire, breve e parlata")],
        required: ["text"]
    ) { args, ctx in
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("Testo vuoto") }
        let addressAs = ctx.config.addressAs
        let spoken = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")
            ? "\(text.dropLast()), \(addressAs)\(text.last!)" : "\(text), \(addressAs)."
        if let who = await ctx.tasks.identity(of: ctx.taskId) {
            await ctx.tasks.post(squad: who.squad, from: who.member, to: "elio", text: text)
        }
        ctx.broadcast(ServerMessage(type: .event, text: spoken, lang: .it, kind: "progress",
                                    payload: ctx.taskId.map { "{\"task\":\"\($0)\"}" }, speak: true))
        return "Detto a Raffaele."
    }

    static let start = ElioTool(
        name: "squad_start",
        description: """
        Modalità squadra: avvia più agenti Claude in parallelo che collaborano su un obiettivo di codice \
        (es. backend + frontend + test, oppure analisi di più repository). Gli agenti si parlano tra loro con una bacheca \
        e riferiscono a te; tu riferisci a Raffaele. Raffaele vede tutto nella dashboard. Da 2 a 5 agenti, ruoli distinti, \
        compiti che si possono fare in parallelo. Restituisce subito l'id della squadra.
        """,
        properties: [
            "goal": prop("Obiettivo complessivo, in italiano"),
            "project_path": prop("Percorso assoluto del repository o della cartella"),
            "members": [
                "type": "array",
                "description": "Gli agenti: nome breve (es. \"backend\"), ruolo, compito dettagliato e autosufficiente",
                "items": [
                    "type": "object",
                    "properties": ["name": prop("Nome breve"), "role": prop("Ruolo"), "task": prop("Compito dettagliato")],
                    "required": ["name", "role", "task"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
        required: ["goal", "project_path", "members"]
    ) { args, ctx in
        let path = expandPath(args["project_path"] as? String ?? "")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Cartella non trovata: \(path)")
        }
        let members = (args["members"] as? [[String: Any]] ?? []).prefix(5)
        guard members.count >= 1 else { throw ToolError("Servono degli agenti") }
        let goal = args["goal"] as? String ?? "Squadra"
        let squad = await ctx.tasks.createSquad(goal: goal, project: path)
        // Register everyone first so each prompt lists the whole team.
        var started: [String] = []
        for m in members {
            let name = (m["name"] as? String ?? "agente").lowercased().replacingOccurrences(of: " ", with: "-")
            _ = try await ctx.tasks.start(title: "\(name): \(m["role"] as? String ?? "")", prompt: m["task"] as? String ?? "",
                                          cwd: path, kind: .squad, squad: squad.id, member: name, role: m["role"] as? String)
            started.append(name)
        }
        await ctx.tasks.post(squad: squad.id, from: "elio", to: "tutti",
                             text: "Squadra al lavoro su: \(goal). Membri: \(started.joined(separator: ", ")). Coordinatevi qui.")
        ctx.broadcast(ServerMessage(type: .event, kind: "openView", payload: "{\"view\":\"squad\"}"))
        return "Squadra \(squad.id) avviata con \(started.joined(separator: ", ")). Riferiranno sulla bacheca; Raffaele vede tutto nella dashboard."
    }

    static let send = ElioTool(
        name: "squad_send",
        description: "Manda un messaggio a un agente della squadra (o a \"tutti\"). Se l'agente aveva finito, lo risveglia con il messaggio.",
        properties: ["squad": prop("Id della squadra (da squad_status)"), "to": prop("Nome dell'agente o \"tutti\""),
                     "text": prop("Messaggio")],
        required: ["squad", "to", "text"]
    ) { args, ctx in
        let squad = args["squad"] as? String ?? "", to = args["to"] as? String ?? "tutti", text = args["text"] as? String ?? ""
        guard await ctx.tasks.squad(squad) != nil else { throw ToolError("Squadra non trovata") }
        await ctx.tasks.post(squad: squad, from: "elio", to: to, text: text)
        var woke: [String] = []
        let names = to == "tutti" ? await ctx.tasks.members(of: squad).compactMap(\.member) : [to]
        for name in Set(names) where try await ctx.tasks.resume(squad: squad, member: name, message: "Messaggio da Elio: \(text)") {
            woke.append(name)
        }
        return woke.isEmpty ? "Messaggio inviato." : "Messaggio inviato; ho risvegliato \(woke.joined(separator: ", "))."
    }

    static let status = ElioTool(
        name: "squad_status",
        description: "Stato delle squadre: agenti, cosa stanno facendo, token, e gli ultimi messaggi della bacheca.",
        properties: ["squad": prop("Id della squadra (opzionale: tutte)")]
    ) { args, ctx in
        let wanted = args["squad"] as? String
        let squads = await ctx.tasks.allSquads().filter { wanted == nil || $0.id == wanted }
        guard !squads.isEmpty else { return "Nessuna squadra." }
        var out: [String] = []
        for s in squads {
            out.append("Squadra \(s.id) — \(s.goal) [\(s.endedAt == nil ? "in corso" : "finita")]")
            for m in await ctx.tasks.members(of: s.id) {
                let tok = (m.tokensIn ?? 0) + (m.tokensOut ?? 0)
                out.append("- \(m.member ?? "?") (\(m.role ?? "")): \(m.status.rawValue), \(tok) token. Ultimo: \(m.lastMessage ?? m.steps.last ?? "—")")
            }
            out.append("Bacheca (ultimi):")
            for msg in await ctx.tasks.messages(squad: s.id).suffix(12) {
                out.append("  \(msg.from) → \(msg.to): \(msg.text.prefix(300))")
            }
        }
        return out.joined(separator: "\n")
    }

    static let stop = ElioTool(
        name: "squad_stop",
        description: "Ferma tutti gli agenti di una squadra.",
        properties: ["squad": prop("Id della squadra")],
        required: ["squad"]
    ) { args, ctx in
        await ctx.tasks.stopSquad(args["squad"] as? String ?? "")
        return "Squadra fermata."
    }

    static let post = ElioTool(
        name: "squad_post",
        description: "Scrive sulla bacheca della tua squadra: to = nome di un compagno, \"tutti\", oppure \"elio\".",
        properties: ["to": prop("Destinatario"), "text": prop("Messaggio breve e concreto")],
        required: ["to", "text"]
    ) { args, ctx in
        guard let me = await ctx.tasks.identity(of: ctx.taskId) else { throw ToolError("Non fai parte di una squadra") }
        let to = (args["to"] as? String ?? "tutti").lowercased()
        await ctx.tasks.post(squad: me.squad, from: me.member, to: to, text: args["text"] as? String ?? "")
        if to != "elio", to != "tutti" {
            // A finished teammate is woken up to read it.
            _ = try? await ctx.tasks.resume(squad: me.squad, member: to,
                                            message: "Nuovo messaggio da \(me.member): \(args["text"] as? String ?? "")")
        }
        return "Inviato."
    }

    static let inbox = ElioTool(
        name: "squad_inbox",
        description: "Legge i nuovi messaggi della bacheca indirizzati a te o a tutti.",
        properties: [:]
    ) { _, ctx in
        guard let me = await ctx.tasks.identity(of: ctx.taskId) else { throw ToolError("Non fai parte di una squadra") }
        let msgs = await ctx.tasks.inbox(squad: me.squad, member: me.member)
        guard !msgs.isEmpty else { return "Nessun nuovo messaggio." }
        return msgs.map { "\($0.from) → \($0.to): \($0.text)" }.joined(separator: "\n")
    }

    static let usage = ElioTool(
        name: "usage_report",
        description: "Quanti token Claude sono stati usati oggi e nella finestra delle ultime 5 ore (tutte le sessioni sul Mac, Elio compreso).",
        properties: [:]
    ) { _, _ in
        let u = await UsageMeter.shared.snapshot()
        let reset = u.windowStart.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970 + 5 * 3600) }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return """
        Oggi: \(UsageMeter.format(u.today.fresh)) token nuovi (\(UsageMeter.format(u.today.output)) generati) più \(UsageMeter.format(u.today.cacheRead)) riletti dalla cache, \(u.today.messages) risposte; di cui Elio \(UsageMeter.format(u.elioToday.fresh)).
        Finestra 5 ore: \(UsageMeter.format(u.window5h.fresh)) token nuovi, \(u.window5h.messages) risposte\(reset.map { ", si azzera verso le \(f.string(from: $0))" } ?? "").
        Costo equivalente API degli agenti in background: $\(String(format: "%.2f", u.agentsCostUSD)).
        """
    }
}
