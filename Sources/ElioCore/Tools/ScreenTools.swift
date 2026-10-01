import AppKit
import ApplicationServices
import Foundation

/// What the user is looking at, and acting on it: "compilalo tu", "scrivi tu questa mail",
/// "riassumi quello che ho selezionato", "metti Chrome a sinistra".
public enum DesktopTools {
    static func axTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func attribute(_ el: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func frontWindowTitle(_ app: NSRunningApplication) -> String? {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return attribute(w as! AXUIElement, kAXTitleAttribute as String)
    }

    static func browserTab(_ bundle: String) -> (String, String)? {
        let script: String
        switch bundle {
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac":
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent ?? "Google Chrome"
            script = "tell application \"\(name)\" to return (URL of active tab of front window) & \"\\n\" & (title of active tab of front window)"
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return (URL of current tab of front window) & \"\\n\" & (name of current tab of front window)"
        default:
            return nil
        }
        guard let out = try? shell("/usr/bin/osascript", ["-e", script]) else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }

    static let context = ElioTool(
        name: "screen_context",
        description: """
        Cosa sta guardando l'utente adesso: app in primo piano, titolo della finestra, testo selezionato, campo in cui \
        si trova il cursore (tipo e contenuto), URL e titolo della scheda del browser, appunti. Usalo PRIMA di agire su \
        "questo", "qui", "quello che ho selezionato", "compilalo", "scrivi tu questa mail".
        """
    ) { _, _ in
        var out: [String] = []
        guard let app = NSWorkspace.shared.frontmostApplication else { return "Nessuna app in primo piano." }
        out.append("App: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? ""))")
        let trusted = axTrusted(prompt: false)
        if trusted, let title = frontWindowTitle(app) { out.append("Finestra: \(title)") }
        if let bundle = app.bundleIdentifier, let (url, title) = browserTab(bundle) {
            out.append("Scheda: \(title) — \(url)")
            out.append("(Per leggere o compilare la pagina usa gli strumenti del browser.)")
        }
        if trusted, let el = focusedElement() {
            let role = attribute(el, kAXRoleAttribute as String) ?? ""
            let desc = [attribute(el, kAXTitleAttribute as String), attribute(el, kAXDescriptionAttribute as String),
                        attribute(el, kAXPlaceholderValueAttribute as String)].compactMap { $0 }.filter { !$0.isEmpty }
            out.append("Campo attivo: \(role)\(desc.isEmpty ? "" : " (\(desc.joined(separator: ", ")))")")
            if let sel = attribute(el, kAXSelectedTextAttribute as String), !sel.isEmpty {
                out.append("Testo selezionato:\n\(sel.prefix(6000))")
            } else if let value = attribute(el, kAXValueAttribute as String), !value.isEmpty {
                out.append("Contenuto del campo:\n\(value.prefix(4000))")
            }
        } else if !trusted {
            _ = axTrusted(prompt: true)
            out.append("(Per leggere selezione e campi serve il permesso Accessibilità per eliod: Impostazioni di Sistema → Privacy → Accessibilità.)")
        }
        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            out.append("Appunti: \(clip.prefix(1500))")
        }
        return SecretFilter.redact(out.joined(separator: "\n"))
    }

    static let screenshot = ElioTool(
        name: "screenshot",
        description: """
        Cattura lo schermo (o solo la finestra in primo piano) e restituisce il percorso dell'immagine: leggila con Read \
        per vedere cosa c'è. Utile per moduli in app native, errori a schermo, "cosa vedi?".
        """,
        properties: ["window_only": prop("Solo la finestra in primo piano", type: "boolean")]
    ) { args, _ in
        let dir = ElioPaths.support.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep only the last few.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in old.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(5) { try? FileManager.default.removeItem(at: f) }
        }
        let file = dir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
        var a = ["-x", "-t", "png"]
        if args["window_only"] as? Bool == true, let id = frontWindowID() { a += ["-l", "\(id)", "-o"] } else { a += ["-m"] }
        _ = try shell("/usr/sbin/screencapture", a + [file.path])
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ToolError("Cattura non riuscita: serve il permesso Registrazione schermo per eliod (Impostazioni di Sistema → Privacy).")
        }
        _ = try? shell("/usr/bin/sips", ["-Z", "1600", file.path])
        return "Screenshot salvato in \(file.path). Leggilo con Read."
    }

    static func frontWindowID() -> Int? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
    }

    static let typeText = ElioTool(
        name: "type_text",
        description: """
        Scrive un testo nel campo in cui si trova il cursore dell'utente, in qualsiasi app (lo incolla e ripristina gli appunti). \
        Per compilare campi in app native, scrivere il corpo di una mail, rispondere in una chat. Non invia nulla: \
        l'invio resta all'utente (o passa da una conferma). Nel browser preferisci gli strumenti del browser.
        """,
        properties: ["text": prop("Testo da scrivere"), "press_tab_after": prop("Premi Tab dopo (campo successivo)", type: "boolean")],
        required: ["text"]
    ) { args, _ in
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty else { throw ToolError("Testo vuoto") }
        guard axTrusted(prompt: true) else {
            throw ToolError("Serve il permesso Accessibilità per eliod (Impostazioni di Sistema → Privacy e sicurezza → Accessibilità).")
        }
        await MainActor.run {
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(text, forType: .string)
            key(9, flags: .maskCommand)  // ⌘V
            if args["press_tab_after"] as? Bool == true { key(48) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
            }
        }
        return "Scritto nel campo attivo."
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static let arrange = ElioTool(
        name: "arrange_windows",
        description: """
        Dispone le finestre: layout = left, right, top, bottom, full, center, oppure "split" con due app (sinistra|destra). \
        Es. app "Google Chrome" layout left; split "Visual Studio Code|Google Chrome".
        """,
        properties: ["app": prop("Nome dell'app (o due app separate da | per split)"), "layout": prop("left, right, top, bottom, full, center, split")],
        required: ["app", "layout"]
    ) { args, _ in
        guard axTrusted(prompt: true) else { throw ToolError("Serve il permesso Accessibilità per eliod.") }
        let layout = args["layout"] as? String ?? "full"
        let apps = (args["app"] as? String ?? "").components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let screen = await MainActor.run(body: { NSScreen.main?.visibleFrame }),
              let full = await MainActor.run(body: { NSScreen.main?.frame }) else { throw ToolError("Schermo non trovato") }
        // AX uses top-left origin.
        let top = full.maxY - screen.maxY
        func rect(_ l: String) -> CGRect {
            let x = screen.minX, w = screen.width, h = screen.height
            switch l {
            case "left": return CGRect(x: x, y: top, width: w / 2, height: h)
            case "right": return CGRect(x: x + w / 2, y: top, width: w / 2, height: h)
            case "top": return CGRect(x: x, y: top, width: w, height: h / 2)
            case "bottom": return CGRect(x: x, y: top + h / 2, width: w, height: h / 2)
            case "center": return CGRect(x: x + w * 0.15, y: top + h * 0.1, width: w * 0.7, height: h * 0.8)
            default: return CGRect(x: x, y: top, width: w, height: h)
            }
        }
        let plan: [(String, CGRect)] = layout == "split" && apps.count >= 2
            ? [(apps[0], rect("left")), (apps[1], rect("right"))]
            : [(apps[0], rect(layout))]
        var done: [String] = []
        for (name, r) in plan {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
            }) else { continue }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            var win: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success
                    || AXUIElementCopyAttributeValue(el, kAXMainWindowAttribute as CFString, &win) == .success,
                  let w = win else { continue }
            var origin = r.origin, size = r.size
            if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w as! AXUIElement, kAXPositionAttribute as CFString, p) }
            if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w as! AXUIElement, kAXSizeAttribute as CFString, s) }
            app.activate()
            done.append(app.localizedName ?? name)
        }
        return done.isEmpty ? "Non ho trovato le finestre di \(apps.joined(separator: " e "))." : "Sistemate: \(done.joined(separator: ", "))."
    }

    static let find = ElioTool(
        name: "find_files",
        description: "Cerca file e cartelle sul Mac con Spotlight (per nome o contenuto). Veloce: usalo invece di find.",
        properties: ["query": prop("Nome o testo da cercare"), "in": prop("Cartella in cui cercare (opzionale)"),
                     "name_only": prop("Solo nel nome del file", type: "boolean")],
        required: ["query"]
    ) { args, _ in
        let q = args["query"] as? String ?? ""
        var a: [String] = []
        if let dir = args["in"] as? String, !dir.isEmpty { a += ["-onlyin", expandPath(dir)] }
        a += args["name_only"] as? Bool == true ? ["-name", q] : [q]
        let out = try shell("/usr/bin/mdfind", a)
        let lines = out.split(separator: "\n").filter { !$0.contains("/Library/Caches/") }.prefix(30)
        return lines.isEmpty ? "Nessun risultato." : lines.joined(separator: "\n")
    }

    static let note = ElioTool(
        name: "quick_note",
        description: "Annota al volo un'idea, un appunto o una cosa da ricordare in Apple Note (cartella \"Elio\"). Per promemoria con orario usa set_reminder.",
        properties: ["text": prop("Testo della nota"), "title": prop("Titolo breve (opzionale)")],
        required: ["text"]
    ) { args, _ in
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty else { throw ToolError("Nota vuota") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM HH:mm"
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Nota del \(f.string(from: Date()))"
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let html = "<h3>\(esc(title))</h3><p>\(esc(text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        let script = """
        tell application "Notes"
            if not (exists folder "Elio") then make new folder with properties {name:"Elio"}
            make new note at folder "Elio" with properties {body:"\(html)"}
        end tell
        """
        do {
            _ = try shell("/usr/bin/osascript", ["-e", script])
            return "Annotato in Note, cartella Elio."
        } catch {
            // Fallback: a Markdown file in the work folder.
            let file = ElioPaths.outputDir.appendingPathComponent("Note.md")
            let line = "\n## \(title)\n\(text)\n"
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: file, atomically: true, encoding: .utf8) }
            return "Annotato in \(file.path) (Note non è disponibile: \(error))."
        }
    }

    static let clipboard = ElioTool(
        name: "clipboard",
        description: "Legge (action get) o scrive (action set, con text) gli appunti.",
        properties: ["action": prop("get o set"), "text": prop("Testo da copiare")],
        required: ["action"]
    ) { args, _ in
        if args["action"] as? String == "set" {
            let text = args["text"] as? String ?? ""
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return "Copiato negli appunti."
        }
        return SecretFilter.redact(NSPasteboard.general.string(forType: .string) ?? "Appunti vuoti.")
    }
}
