import Foundation
import UniformTypeIdentifiers

/// Photos and files sent along with a typed message (Mac input fields, phone app). Elio gets their paths in the
/// message and opens them with its own tools (Read shows images, pdf_tool, media_tool…). Files uploaded from the
/// phone are kept in the Claude session's workspace, where Read needs no extra permission, for 30 days.
public enum Attachments {
    public static let maxUpload = 60 * 1024 * 1024

    static var uploads: URL {
        let url = ElioPaths.claudeWorkspace.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves an uploaded file under a safe, unique name and returns its path.
    public static func store(_ data: Data, name: String) throws -> URL {
        cleanup()
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let file = uploads.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))-\(base.isEmpty ? "file" : base)")
        try data.write(to: file, options: .atomic)
        return file
    }

    /// The text Elio receives: the user's words, then one line per attachment with what it is.
    public static func compose(_ text: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let lines = paths.map { p -> String in
            let url = URL(fileURLWithPath: p)
            let type = UTType(filenameExtension: url.pathExtension)
            let kind = type?.conforms(to: .image) == true ? "immagine"
                : type?.conforms(to: .pdf) == true ? "PDF"
                : type?.conforms(to: .audiovisualContent) == true ? "audio/video" : "file"
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int).map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? ""
            return "- \(p) (\(kind)\(size.isEmpty ? "" : ", \(size)"))"
        }
        let ask = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ask.isEmpty ? "Guarda questi allegati." : ask) +
            "\n\n[Allegati dell'utente: aprili tu (Read per immagini e testo, pdf_tool, media_tool…)]\n" + lines.joined(separator: "\n")
    }

    private static func cleanup() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: uploads, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-30 * 86400)
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < limit {
            try? fm.removeItem(at: f)
        }
    }
}
