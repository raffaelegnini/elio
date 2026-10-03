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

    static func memberPrompt(goal: String, name: String, role: String, task: String, cwd: String, team: [TaskInfo],
                             hasLead: Bool = false, brief: String? = nil) -> String {
        let others = team.isEmpty ? "(per ora nessun altro)"
            : team.map { "- \($0.member ?? "?"): \($0.role ?? "")" }.joined(separator: "\n")
        let briefBlock = brief.map { """

            Brief della codebase preparato dallo scout per tutta la squadra. NON riesplorare il repo da capo: parti da qui \
            e apri solo i file che servono al tuo compito.
            \($0)
            """ } ?? ""
        return """
        Sei "\(name)", un agente di una squadra coordinata da Elio, l'assistente personale di Raffaele.
        Obiettivo della squadra: \(goal)
        Progetto: \(cwd)
        Il tuo ruolo: \(role)
        Il tuo compito: \(task)

        Compagni di squadra:
        \(others)
        \(briefBlock)

        \(workRules)

        Come collaborare:
        - Bacheca: leggi mcp__elio__squad_inbox all'inizio, prima di toccare file che potrebbero toccare altri, e quando \
        aspetti una risposta; non a ogni passo. Scrivi con mcp__elio__squad_post (`to` = un compagno, "tutti" o "elio"): \
        messaggi brevi e concreti (interfacce concordate, file che tocchi, risultati, blocchi).
        - Concorda chi tocca quali file. Se lavorate sullo stesso repo usate lo stesso branch: mettetevi d'accordo all'inizio.
        - Se ti manca un'informazione che solo Raffaele ha, chiedi con mcp__elio__ask_user: per le scelte piccole \
        risponde Elio al suo posto, conoscendo i suoi gusti.\(hasLead ? """

        - Elio coordina la squadra di persona (membro "elio" sulla bacheca): fa le veci di Raffaele, risponde ai dubbi, \
        rivede il lavoro e può chiederti correzioni. Per dubbi di implementazione scrivi a "elio" e intanto prosegui sul resto. \
        Se ti chiede una correzione, falla prima di chiudere.
        """ : "")
        - Il tuo lavoro viene controllato sui gusti di Raffaele (sotto): rispettali da subito, così non devi rifarlo.
        - Termina con un riassunto di massimo due frasi del tuo lavoro.
        """
    }

    /// The scout explores once for everyone: members start from its brief instead of each mapping the repo.
    static func scoutPrompt(goal: String, cwd: String, members: [(name: String, role: String, task: String)]) -> String {
        let tasks = members.map { "- \($0.name) (\($0.role)): \($0.task)" }.joined(separator: "\n")
        return """
        Sei lo scout di una squadra di agenti coordinata da Elio, l'assistente di Raffaele. Progetto: \(cwd)
        Obiettivo della squadra: \(goal)
        Dopo di te partiranno questi agenti, in parallelo:
        \(tasks)

        Il tuo unico compito: esplorare il codice UNA volta per tutti, così loro non devono rifarlo (ogni esplorazione \
        ripetuta costa crediti). Non modificare nulla, non creare branch.
        - In fretta e mirato: struttura delle cartelle, stack e versioni, come si lanciano test/build/lint (comandi esatti), \
        convenzioni (naming, pattern, stile), e per OGNI compito i file e i punti esatti da cui partire, le dipendenze tra \
        i compiti e i rischi di conflitto (file toccati da più agenti).
        - Usa TodoWrite per un piano di 3-4 passi, come gli altri.
        - Al massimo 10-15 minuti di lavoro: non leggere file interi se basta una ricerca.

        Termina con il BRIEF (massimo 600 parole, in italiano, in markdown compatto), con queste sezioni: \
        Stack e comandi · Struttura · Convenzioni · Per ciascun agente (file e punti di partenza) · Rischi e coordinamento. \
        Prima del brief, una frase di riassunto.
        """
    }

    static func leadPrompt(squad: SquadInfo?, user: String, team: [TaskInfo], maxAgents: Int, taste: String) -> String {
        let members = team.isEmpty ? "(nessuno)"
            : team.map { "- \($0.member ?? "?"): \($0.role ?? "")" }.joined(separator: "\n")
        return """
        Sei Elio, l'assistente personale di \(user), e coordini di persona una squadra di agenti Claude al posto suo. \
        Lui è impegnato: tu fai le sue veci. Conosci i suoi gusti (sotto) e li fai rispettare.

        Squadra: \(squad?.id ?? "")
        Obiettivo: \(squad?.goal ?? "")
        Progetto: \(squad?.project ?? "")
        Membri:
        \(members)

        Il tuo lavoro:
        - Rispondi ai dubbi dei membri come risponderebbe \(user), con mcp__elio__squad_send (to = nome, o "tutti"). \
        Decidi tu le cose piccole e reversibili coperte dai suoi gusti o dal buon senso di un senior; chiedi a lui \
        (mcp__elio__ask_user, una domanda chiara con le opzioni e la tua raccomandazione) solo per scelte importanti, \
        irreversibili, di prodotto, o che dipendono da informazioni che solo lui ha.
        - Rivedi il lavoro: quando un membro dice di aver finito, guarda cosa ha fatto (git diff, Read, Grep) e confrontalo \
        con l'obiettivo e con i gusti di \(user). Se qualcosa non gli piacerebbe (es. AI slop nel design, naming, struttura), \
        diglielo con squad_send in modo preciso: file, cosa, come correggerlo. Un membro che ha finito si risveglia da solo.
        - Coordina: evita che due membri tocchino gli stessi file, sblocca chi è fermo, ridistribuisci il lavoro. \
        Se serve più forza lavoro, aggiungi un agente con mcp__elio__squad_add (massimo \(maxAgents) in totale); \
        mcp__elio__squad_status per lo stato.
        - Tieni informato \(user) solo sull'essenziale con mcp__elio__report_progress: una frase parlata. Usa important: true \
        SOLO per problemi seri o blocchi (è l'unica cosa che sente in modalità silenziosa).
        - Non scrivi codice tu: coordini, decidi e rivedi. Non fare push, merge o PR.
        - Sii economico: ogni risveglio rilegge il tuo contesto. Rispondi in poche righe, rivedi con `git diff --stat` e solo \
        i file chiave (mai l'intero repo: c'è il brief dello scout), non chiamare squad_status se la bacheca basta.

        Lavori a turni: all'inizio dai il via (messaggio a "tutti" con le regole d'ingaggio se servono), poi chiudi il turno \
        con una frase di stato. Verrai risvegliato con i nuovi messaggi della bacheca. Quando tutti hanno finito e il \
        risultato è come lo vorrebbe \(user), chiudi con il riassunto finale: prima due frasi da leggere a voce, poi i \
        dettagli (cosa è stato fatto, branch, decisioni che hai preso al suo posto, cose da verificare).

        \(taste.isEmpty ? "Gusti di \(user): ancora nessuno registrato, usa il buon senso di un senior pignolo." : taste)
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
            "difficulty": prop("trivial SOLO per micro-modifiche (un typo, un testo, un colore, una versione) in 1-2 file: gira su un modello più leggero. Nel dubbio, e per tutto il resto, ometti (Opus)."),
        ],
        required: ["title", "prompt"]
    ) { args, ctx in
        let dir = expandPath(args["directory"] as? String ?? "~")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Cartella non trovata: \(dir)")
        }
        let info = try await ctx.tasks.start(title: args["title"] as? String ?? "Lavoro sul Mac",
                                             prompt: args["prompt"] as? String ?? "", cwd: dir, kind: .mac,
                                             difficulty: args["difficulty"] as? String)
        return "Agente avviato (id \(info.id)). Riferirà a voce: non serve aspettarlo, rispondi a Raffaele con una frase."
    }

    static let progress = ElioTool(
        name: "report_progress",
        description: """
        Aggiorna Raffaele a voce su un passaggio importante del tuo lavoro in background (una frase breve). \
        important: true solo per problemi o blocchi seri: è l'unica cosa che sente in modalità silenziosa.
        """,
        properties: ["text": prop("La frase da dire, breve e parlata"),
                     "important": prop("Problema o blocco serio (default false)", type: "boolean")],
        required: ["text"]
    ) { args, ctx in
        let important = args["important"] as? Bool ?? false
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("Testo vuoto") }
        let addressAs = ctx.config.addressAs
        let spoken = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")
            ? "\(text.dropLast()), \(addressAs)\(text.last!)" : "\(text), \(addressAs)."
        if let who = await ctx.tasks.identity(of: ctx.taskId) {
            await ctx.tasks.post(squad: who.squad, from: who.member, to: "elio", text: text)
        }
        await ctx.tasks.logEvent(taskId: ctx.taskId, important ? .alert : .progress, text: text)
        ctx.broadcast(ServerMessage(type: .event, text: spoken, lang: .it, kind: important ? "workflowAlert" : "progress",
                                    payload: ctx.taskId.map { "{\"task\":\"\($0)\"}" }, speak: true))
        return Attention.mode == .silent && !important ? "Registrato (Raffaele è in modalità silenziosa: lo vedrà nel report)." : "Detto a Raffaele."
    }

    static let start = ElioTool(
        name: "squad_start",
        description: """
        Modalità squadra: avvia più agenti Claude in parallelo che collaborano su un obiettivo di codice \
        (es. backend + frontend + test, oppure analisi di più repository). COSTA MOLTO: ogni agente consuma una sessione intera di crediti: usala solo per lavori grandi e davvero parallelizzabili, altrimenti start_task (un agente). Di solito 2-3 agenti, su compiti che non toccano gli stessi file; prima parte uno scout che esplora il codice una volta per tutti. Gli agenti si parlano tra loro con una bacheca. \
        Di default un agente coordinatore (Elio in persona, lead: true) fa le veci di Raffaele: risponde ai dubbi, rivede il \
        lavoro sui suoi gusti, fa correggere e può aggiungere agenti. Quanti agenti servono davvero (fino al massimo \
        configurato), ruoli distinti, compiti parallelizzabili e autosufficienti. Raffaele vede tutto nella dashboard e sul \
        telefono, con un report finale. Restituisce subito l'id della squadra.
        """,
        properties: [
            "goal": prop("Obiettivo complessivo, in italiano"),
            "project_path": prop("Percorso assoluto del repository o della cartella"),
            "members": [
                "type": "array",
                "description": "Gli agenti: nome breve (es. \"backend\"), ruolo, compito dettagliato e autosufficiente",
                "items": [
                    "type": "object",
                    "properties": ["name": prop("Nome breve"), "role": prop("Ruolo"), "task": prop("Compito dettagliato"),
                                   "difficulty": prop("trivial SOLO per micro-modifiche (un typo, un testo, un colore, una versione) in 1-2 file: gira su un modello più leggero. Nel dubbio, e per tutto il resto, ometti (Opus).")],
                    "required": ["name", "role", "task"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
            "lead": prop("Coordinatore Elio che fa le veci di Raffaele (default true)", type: "boolean"),
            "scout": prop("Uno scout esplora il codice una volta per tutti prima che partano gli altri (default true con 2+ agenti sullo stesso repo)", type: "boolean"),
        ],
        required: ["goal", "project_path", "members"]
    ) { args, ctx in
        let path = expandPath(args["project_path"] as? String ?? "")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Cartella non trovata: \(path)")
        }
        let members = (args["members"] as? [[String: Any]] ?? []).prefix(max(1, ctx.config.maxSquadAgents))
        guard members.count >= 1 else { throw ToolError("Servono degli agenti") }
        let goal = args["goal"] as? String ?? "Squadra"
        let lead = args["lead"] as? Bool ?? true
        let scout = args["scout"] as? Bool ?? (members.count >= 2)
        let squad = await ctx.tasks.createSquad(goal: goal, project: path, lead: lead)
        if scout {
            // One exploration for everyone: members and lead start when the scout's brief is ready.
            let queued = members.map { m in
                TaskRunner.QueuedMember(name: (m["name"] as? String ?? "agente").lowercased().replacingOccurrences(of: " ", with: "-"),
                                        role: m["role"] as? String ?? "", task: m["task"] as? String ?? "",
                                        difficulty: m["difficulty"] as? String)
            }
            await ctx.tasks.queueAfterScout(squad: squad.id, members: queued, lead: lead)
            _ = try await ctx.tasks.start(title: "scout: mappa il codice", prompt: TaskRunner.scoutPrompt(
                goal: goal, cwd: path, members: queued.map { ($0.name, $0.role, $0.task) }), cwd: path, kind: .scout,
                squad: squad.id, member: "scout", role: "esplora il codice una volta per tutti")
            ctx.broadcast(ServerMessage(type: .event, kind: "openView", payload: "{\"view\":\"squad\"}"))
            return "Squadra \(squad.id): prima uno scout mappa il codice (pochi minuti), poi partono \(queued.map(\.name).joined(separator: ", "))\(lead ? " con il coordinatore" : "") partendo dal suo brief. Report con workflow_report."
        }
        // Register everyone first so each prompt lists the whole team.
        var started: [String] = []
        for m in members {
            let name = (m["name"] as? String ?? "agente").lowercased().replacingOccurrences(of: " ", with: "-")
            _ = try await ctx.tasks.start(title: "\(name): \(m["role"] as? String ?? "")", prompt: m["task"] as? String ?? "",
                                          cwd: path, kind: .squad, squad: squad.id, member: name, role: m["role"] as? String,
                                          difficulty: m["difficulty"] as? String)
            started.append(name)
        }
        await ctx.tasks.post(squad: squad.id, from: "elio", to: "tutti",
                             text: "Squadra al lavoro su: \(goal). Membri: \(started.joined(separator: ", ")). Coordinatevi qui.")
        if lead {
            _ = try await ctx.tasks.start(title: "elio: coordinatore", prompt: goal, cwd: path, kind: .lead,
                                          squad: squad.id, member: "elio", role: "coordinatore (fa le veci di \(ctx.config.userName))")
        }
        ctx.broadcast(ServerMessage(type: .event, kind: "openView", payload: "{\"view\":\"squad\"}"))
        let mode = Attention.mode == .silent ? " Sono in modalità silenziosa: Raffaele sentirà solo domande, problemi e la fine." : ""
        return "Squadra \(squad.id) avviata con \(started.joined(separator: ", "))\(lead ? ", coordinata da un agente Elio che fa le veci di Raffaele" : ""). Report con workflow_report.\(mode)"
    }

    static let add = ElioTool(
        name: "squad_add",
        description: "Aggiunge un agente a una squadra già al lavoro (più forza lavoro, un ruolo che mancava, un revisore).",
        properties: ["squad": prop("Id della squadra (per il coordinatore: opzionale)"), "name": prop("Nome breve"),
                     "role": prop("Ruolo"), "task": prop("Compito dettagliato e autosufficiente"),
                     "difficulty": prop("trivial SOLO per micro-modifiche (typo, testo, colore, versione); altrimenti ometti")],
        required: ["name", "role", "task"]
    ) { args, ctx in
        var id = args["squad"] as? String ?? ""
        if id.isEmpty, let me = await ctx.tasks.identity(of: ctx.taskId) { id = me.squad }
        guard let squad = await ctx.tasks.squad(id), squad.endedAt == nil else { throw ToolError("Squadra non trovata o finita") }
        let running = await ctx.tasks.runningMembers(of: id)
        guard running < ctx.config.maxSquadAgents else {
            throw ToolError("La squadra ha già \(running) agenti al lavoro (massimo \(ctx.config.maxSquadAgents))")
        }
        let name = (args["name"] as? String ?? "agente").lowercased().replacingOccurrences(of: " ", with: "-")
        guard !(await ctx.tasks.members(of: id).contains { $0.member == name }) else { throw ToolError("Nome già usato: \(name)") }
        let role = args["role"] as? String ?? ""
        _ = try await ctx.tasks.start(title: "\(name): \(role)", prompt: args["task"] as? String ?? "", cwd: squad.project,
                                      kind: .squad, squad: id, member: name, role: role, difficulty: args["difficulty"] as? String)
        await ctx.tasks.post(squad: id, from: "elio", to: "tutti", text: "Nuovo membro: \(name) (\(role)).")
        return "\(name) aggiunto alla squadra."
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
