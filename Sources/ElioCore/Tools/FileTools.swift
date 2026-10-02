import AppKit
import Foundation
import PDFKit
import WebKit

/// Documents, files, PDFs and printing. Elio writes freely in ~/Documents/Elio;
/// anywhere else (and printing) goes through the confirmation gate.
public enum FileTools {
    static func resolve(_ path: String) -> URL {
        let p = expandPath(path)
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : ElioPaths.outputDir.appendingPathComponent(p)
    }

    static func insideOutput(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(ElioPaths.outputDir.standardizedFileURL.path + "/")
    }

    /// Writes outside the work folder need an OK.
    static func checkWrite(_ url: URL, ctx: ToolContext) async throws {
        guard !insideOutput(url) else { return }
        let ok = await ctx.gate.request(ConfirmRequest(
            id: UUID().uuidString, title: "Salvo il file \(url.lastPathComponent) in \(url.deletingLastPathComponent().path)",
            detail: url.path, risk: FileManager.default.fileExists(atPath: url.path) ? .dangerous : .normal, taskId: ctx.taskId),
            timeout: 120)
        guard ok else { throw ToolError("L'utente non ha confermato") }
    }

    static let save = ElioTool(
        name: "save_document",
        description: """
        Crea un documento e lo salva (di default in ~/Documents/Elio). format: md, txt, csv, html o pdf \
        (il PDF viene impaginato da markdown o html, tabelle comprese). Con open=true lo apre subito.
        """,
        properties: [
            "name": prop("Nome del file senza percorso, es. presenze-settembre"),
            "content": prop("Contenuto (markdown per md/pdf, html per html/pdf, testo, csv)"),
            "format": prop("md, txt, csv, html, pdf"),
            "folder": prop("Cartella (opzionale, default ~/Documents/Elio)"),
            "open": prop("Aprire il file dopo averlo creato", type: "boolean"),
        ],
        required: ["name", "content", "format"]
    ) { args, ctx in
        let format = (args["format"] as? String ?? "md").lowercased()
        let base = (args["name"] as? String ?? "documento").replacingOccurrences(of: "/", with: "-")
        let folder = (args["folder"] as? String).map { resolve($0) } ?? ElioPaths.outputDir
        let url = folder.appendingPathComponent(base.hasSuffix("." + format) ? base : "\(base).\(format)")
        try await checkWrite(url, ctx: ctx)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = args["content"] as? String ?? ""
        switch format {
        case "pdf":
            let html = content.contains("<") && content.contains(">") && content.contains("</") ? content : MarkdownHTML.render(content)
            try await PDFRenderer.render(html: MarkdownHTML.page(body: html, title: base), to: url)
        case "html":
            try MarkdownHTML.page(body: content.contains("</") ? content : MarkdownHTML.render(content), title: base)
                .write(to: url, atomically: true, encoding: .utf8)
        default:
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        if args["open"] as? Bool == true { NSWorkspace.shared.open(url) }
        return "Salvato: \(url.path)"
    }

    static let open = ElioTool(
        name: "open_file",
        description: "Apre un file con l'app predefinita (es. PDF in Anteprima), o lo mostra nel Finder con reveal=true.",
        properties: ["path": prop("Percorso del file"), "reveal": prop("Mostra nel Finder invece di aprire", type: "boolean")],
        required: ["path"]
    ) { args, _ in
        let url = resolve(args["path"] as? String ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("File non trovato: \(url.path)") }
        if args["reveal"] as? Bool == true {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
        return "Aperto \(url.lastPathComponent)."
    }

    static let printFile = ElioTool(
        name: "print_file",
        description: "Stampa un file (PDF, immagine, testo) sulla stampante predefinita o su quella indicata.",
        properties: [
            "path": prop("Percorso del file"),
            "copies": prop("Numero di copie", type: "integer"),
            "printer": prop("Nome della stampante (opzionale)"),
        ],
        required: ["path"]
    ) { args, ctx in
        let url = resolve(args["path"] as? String ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("File non trovato") }
        let copies = max(1, args["copies"] as? Int ?? 1)
        let ok = await ctx.gate.request(ConfirmRequest(
            id: UUID().uuidString, title: "Stampo \(url.lastPathComponent)\(copies > 1 ? " in \(copies) copie" : "")",
            detail: url.path, risk: .normal, taskId: ctx.taskId), timeout: 120)
        guard ok else { return "Stampa annullata." }
        var lpArgs = ["-n", "\(copies)"]
        if let printer = args["printer"] as? String, !printer.isEmpty { lpArgs += ["-d", printer] }
        let out = try shell("/usr/bin/lp", lpArgs + [url.path])
        return "Inviato in stampa. \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static let pdf = ElioTool(
        name: "pdf_tool",
        description: """
        Lavora sui PDF. action: info (pagine), text (estrae il testo), merge (unisce inputs in output), \
        extract (pagine "1-3,5" in output), delete (toglie pagine), rotate (ruota pagine di angle gradi), \
        ocr (legge il testo dei PDF scansionati), compress (riduce il peso), to_images (pagine in PNG), \
        from_images (crea un PDF dalle immagini in inputs).
        """,
        properties: [
            "action": prop("info, text, merge, extract, delete, rotate, ocr, compress, to_images, from_images"),
            "input": prop("PDF di partenza"),
            "inputs": ["type": "array", "items": ["type": "string"], "description": "PDF da unire (merge) o immagini (from_images)"],
            "pages": prop("Pagine, es. 1-3,5 (1 = prima pagina)"),
            "angle": prop("Gradi per rotate: 90, 180, 270", type: "integer"),
            "output": prop("PDF risultato (default: accanto all'originale con un suffisso)"),
        ],
        required: ["action"]
    ) { args, ctx in
        let action = args["action"] as? String ?? ""
        func load(_ path: String) throws -> PDFDocument {
            guard let doc = PDFDocument(url: resolve(path)) else { throw ToolError("PDF non leggibile: \(path)") }
            return doc
        }
        func output(default suffix: String) -> URL {
            if let o = args["output"] as? String { return resolve(o) }
            let input = resolve(args["input"] as? String ?? (args["inputs"] as? [String])?.first ?? "documento.pdf")
            return ElioPaths.outputDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-\(suffix).pdf")
        }
        switch action {
        case "info":
            let doc = try load(args["input"] as? String ?? "")
            return "\(doc.pageCount) pagine, \(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] ?? "senza titolo")"
        case "text":
            let doc = try load(args["input"] as? String ?? "")
            let text = doc.string ?? ""
            return text.count > 12_000 ? String(text.prefix(12_000)) + "\n…[troncato]" : text
        case "merge":
            let paths = args["inputs"] as? [String] ?? []
            guard paths.count >= 2 else { throw ToolError("Servono almeno due PDF") }
            let result = PDFDocument()
            for p in paths {
                let doc = try load(p)
                for i in 0..<doc.pageCount { if let page = doc.page(at: i) { result.insert(page, at: result.pageCount) } }
            }
            let url = output(default: "unito")
            try await checkWrite(url, ctx: ctx)
            guard result.write(to: url) else { throw ToolError("Scrittura non riuscita") }
            return "Creato \(url.path) (\(result.pageCount) pagine)."
        case "extract", "delete", "rotate":
            let doc = try load(args["input"] as? String ?? "")
            let selected = parsePages(args["pages"] as? String ?? "", count: doc.pageCount)
            guard !selected.isEmpty || action == "rotate" else { throw ToolError("Pagine non valide") }
            let targets = selected.isEmpty ? Set(0..<doc.pageCount) : selected
            let result = PDFDocument()
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                switch action {
                case "extract": if targets.contains(i) { result.insert(page, at: result.pageCount) }
                case "delete": if !targets.contains(i) { result.insert(page, at: result.pageCount) }
                default:
                    if targets.contains(i) { page.rotation = (page.rotation + (args["angle"] as? Int ?? 90)) % 360 }
                    result.insert(page, at: result.pageCount)
                }
            }
            let url = output(default: action == "extract" ? "estratto" : action == "delete" ? "ridotto" : "ruotato")
            try await checkWrite(url, ctx: ctx)
            guard result.write(to: url) else { throw ToolError("Scrittura non riuscita") }
            return "Creato \(url.path) (\(result.pageCount) pagine)."
        case "ocr":
            let doc = try load(args["input"] as? String ?? "")
            let selected = parsePages(args["pages"] as? String ?? "", count: doc.pageCount)
            let pages = (selected.isEmpty ? Array(0..<doc.pageCount) : selected.sorted()).prefix(60)
            var text: [String] = []
            for i in pages {
                guard let image = render(doc.page(at: i), dpi: 200) else { continue }
                text.append("— Pagina \(i + 1) —\n" + (try MediaTools.recognizeText(image)))
            }
            let input = resolve(args["input"] as? String ?? "")
            return try MediaTools.long(text.joined(separator: "\n\n"), name: input.deletingPathExtension().lastPathComponent + "-testo")
        case "compress":
            let input = resolve(args["input"] as? String ?? "")
            let doc = try load(input.path)
            let url = output(default: "compresso")
            try await checkWrite(url, ctx: ctx)
            guard doc.write(to: url, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
                throw ToolError("Scrittura non riuscita")
            }
            return "Creato \(url.path) (\(MediaTools.fileSize(input)) → \(MediaTools.fileSize(url)))."
        case "to_images":
            let input = resolve(args["input"] as? String ?? "")
            let doc = try load(input.path)
            let selected = parsePages(args["pages"] as? String ?? "", count: doc.pageCount)
            let folder = (args["output"] as? String).map { resolve($0) }
                ?? ElioPaths.outputDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-pagine", isDirectory: true)
            try await checkWrite(folder.appendingPathComponent("pagina-1.png"), ctx: ctx)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var count = 0
            for i in selected.isEmpty ? Array(0..<doc.pageCount) : selected.sorted() {
                guard let image = render(doc.page(at: i), dpi: 150) else { continue }
                try MediaTools.write(image, to: folder.appendingPathComponent("pagina-\(i + 1).png"), type: .png)
                count += 1
            }
            return "Create \(count) immagini in \(folder.path)."
        case "from_images":
            let paths = args["inputs"] as? [String] ?? []
            guard !paths.isEmpty else { throw ToolError("Indica le immagini in inputs") }
            let result = PDFDocument()
            for p in paths {
                let image = try MediaTools.uprightImage(MediaTools.existing(p))
                guard let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else { continue }
                result.insert(page, at: result.pageCount)
            }
            let url = output(default: "da-immagini")
            try await checkWrite(url, ctx: ctx)
            guard result.write(to: url) else { throw ToolError("Scrittura non riuscita") }
            return "Creato \(url.path) (\(result.pageCount) pagine)."
        default:
            throw ToolError("Azione sconosciuta")
        }
    }

    /// A PDF page as a bitmap at the given resolution (white background, rotation applied).
    static func render(_ page: PDFPage?, dpi: CGFloat) -> CGImage? {
        guard let page else { return nil }
        let box = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let rotated = page.rotation % 180 != 0
        let size = NSSize(width: (rotated ? box.height : box.width) * scale, height: (rotated ? box.width : box.height) * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// "1-3,5" → zero-based page indexes.
    static func parsePages(_ spec: String, count: Int) -> Set<Int> {
        var out = Set<Int>()
        for part in spec.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first else { continue }
            let last = bounds.count > 1 ? bounds[1] : first
            for p in min(first, last)...max(first, last) where p >= 1 && p <= count { out.insert(p - 1) }
        }
        return out
    }
}

/// HTML → A4 PDF: WebKit renders the page to an in-memory PDF (no print system, which loops in a
/// background process), PDFKit slices it into A4 pages, and the file is written once.
public enum PDFRenderer {
    static let pageSize = NSSize(width: 595, height: 842)  // A4 in points
    static let maxPages = 200

    @MainActor
    public static func render(html: String, to url: URL) async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height))
        let loader = Loader()
        web.navigationDelegate = loader
        web.loadHTMLString(html, baseURL: nil)
        try await loader.wait()
        let data = try await web.pdf(configuration: WKPDFConfiguration())
        guard let full = PDFDocument(data: data), let source = full.page(at: 0) else {
            throw ToolError("Impaginazione non riuscita")
        }
        let bounds = source.bounds(for: .mediaBox)
        let pages = min(maxPages, max(1, Int((bounds.height / pageSize.height).rounded(.up))))
        let out = PDFDocument()
        for i in 0..<pages {
            guard let page = source.copy() as? PDFPage else { continue }
            // PDF coordinates start at the bottom: page 1 is the top slice.
            let top = bounds.maxY - CGFloat(i) * pageSize.height
            let slice = NSRect(x: bounds.minX, y: max(bounds.minY, top - pageSize.height),
                               width: pageSize.width, height: min(pageSize.height, top - bounds.minY))
            page.setBounds(slice, for: .mediaBox)
            page.setBounds(slice, for: .cropBox)
            out.insert(page, at: out.pageCount)
        }
        guard let bytes = out.dataRepresentation(), bytes.count < 50_000_000 else { throw ToolError("PDF troppo grande") }
        try bytes.write(to: url, options: .atomic)
    }

    @MainActor
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume(); continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error); continuation = nil
        }
    }
}

/// Small Markdown → HTML converter (headings, lists, tables, emphasis, code, links) with DNA styling.
public enum MarkdownHTML {
    public static func render(_ md: String) -> String {
        var html: [String] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0
        var list: String?
        func closeList() { if let l = list { html.append("</\(l)>"); list = nil } }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                closeList()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(escape(lines[i])); i += 1 }
                html.append("<pre><code>\(code.joined(separator: "\n"))</code></pre>")
            } else if t.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].contains("---") {
                closeList()
                let cells = { (row: String) in row.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { inline($0.trimmingCharacters(in: .whitespaces)) } }
                var table = "<table><thead><tr>" + cells(t).map { "<th>\($0)</th>" }.joined() + "</tr></thead><tbody>"
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    table += "<tr>" + cells(lines[i]).map { "<td>\($0)</td>" }.joined() + "</tr>"
                    i += 1
                }
                html.append(table + "</tbody></table>")
                continue
            } else if let level = t.prefix(while: { $0 == "#" }).count as Int?, level > 0, level <= 6, t.dropFirst(level).hasPrefix(" ") {
                closeList()
                html.append("<h\(level)>\(inline(String(t.dropFirst(level + 1))))</h\(level)>")
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                let ordered = !(t.hasPrefix("- ") || t.hasPrefix("* "))
                let tag = ordered ? "ol" : "ul"
                if list != tag { closeList(); html.append("<\(tag)>"); list = tag }
                let item = ordered ? t.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression) : String(t.dropFirst(2))
                html.append("<li>\(inline(item))</li>")
            } else if t.isEmpty {
                closeList()
            } else {
                closeList()
                html.append("<p>\(inline(t))</p>")
            }
            i += 1
        }
        closeList()
        return html.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![*\w])\*([^*]+)\*(?![*\w])"#, with: "<em>$1</em>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return t
    }

    /// Full HTML page with the DNA look (also used for PDFs, where it prints on white).
    public static func page(body: String, title: String, dark: Bool = false) -> String {
        let bg = dark ? "#0E0E10" : "#FFFFFF", fg = dark ? "#FBF8F1" : "#1A1A1D", dim = dark ? "#9E9A8E" : "#6E6B62"
        let line = dark ? "rgba(255,211,96,.18)" : "#E2DFD6", head = dark ? "rgba(255,211,96,.10)" : "#FFF4D1"
        return """
        <!doctype html><html lang="it"><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        body{font:14px/1.5 -apple-system,'Helvetica Neue',sans-serif;color:\(fg);background:\(bg);margin:24px}
        h1,h2,h3{line-height:1.25;margin:1.2em 0 .5em} h1{font-size:22px;border-bottom:3px solid #FFD360;padding-bottom:6px}
        h2{font-size:17px} h3{font-size:15px;color:\(dim)}
        table{border-collapse:collapse;width:100%;margin:12px 0;font-size:13px}
        th,td{border:1px solid \(line);padding:6px 9px;text-align:left;vertical-align:top} th{background:\(head);font-weight:600}
        code{font:12px ui-monospace,Menlo,monospace;background:\(head);padding:1px 4px;border-radius:4px}
        pre{background:\(head);padding:10px;border-radius:8px;overflow:auto} a{color:#E0A82A}
        </style></head><body>\(body)</body></html>
        """
    }
}
