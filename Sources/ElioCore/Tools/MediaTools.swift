import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Speech
import UniformTypeIdentifiers
import Vision

/// Images, audio and video, all on the Mac: Vision for background removal and OCR,
/// SpeechAnalyzer for transcription, sips and ffmpeg for everything else.
/// Results go to ~/Documents/Elio unless `output` says otherwise (outside it asks, like FileTools).
public enum MediaTools {
    // MARK: Images

    static let image = ElioTool(
        name: "image_tool",
        description: """
        Lavora sulle immagini (jpg, png, heic, webp, tiff, gif, raw). action: info; resize (max lato in px, oppure width/height); \
        convert (format: jpg, png, heic, webp, tiff, gif, pdf); compress (quality 1-100, default 70, anche max); \
        rotate (angle); flip (direction horizontal/vertical); remove_background (scontorna il soggetto: PNG trasparente, \
        oppure background "white"/"black"/#RRGGBB per uno sfondo pieno, crop=true per ritagliare sul soggetto); \
        ocr (legge il testo nell'immagine).
        """,
        properties: [
            "action": prop("info, resize, convert, compress, rotate, flip, remove_background, ocr"),
            "input": prop("Immagine di partenza"),
            "output": prop("File risultato (default: in ~/Documents/Elio con un suffisso)"),
            "max": prop("Lato lungo massimo in pixel", type: "integer"),
            "width": prop("Larghezza in pixel", type: "integer"),
            "height": prop("Altezza in pixel", type: "integer"),
            "format": prop("jpg, png, heic, webp, tiff, gif, pdf"),
            "quality": prop("Qualità 1-100 (compress)", type: "integer"),
            "angle": prop("Gradi (rotate)", type: "integer"),
            "direction": prop("horizontal o vertical (flip)"),
            "background": prop("Colore di sfondo per remove_background: white, black o #RRGGBB (default trasparente)"),
            "crop": prop("remove_background: ritaglia sul soggetto", type: "boolean"),
        ],
        required: ["action", "input"]
    ) { args, ctx in
        let action = args["action"] as? String ?? ""
        let input = try existing(args["input"] as? String)
        switch action {
        case "info":
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                throw ToolError("Immagine non leggibile: \(input.lastPathComponent)")
            }
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredFilenameExtension } ?? "?"
            return "\(input.lastPathComponent): \(w)×\(h) px, \(type), \(fileSize(input))."
        case "resize":
            let out = try await output(args, input: input, suffix: "ridimensionata", ext: input.pathExtension, ctx: ctx)
            var a: [String]
            if let max = args["max"] as? Int { a = ["-Z", "\(max)"] }
            else if let w = args["width"] as? Int, let h = args["height"] as? Int { a = ["-z", "\(h)", "\(w)"] }
            else if let w = args["width"] as? Int { a = ["--resampleWidth", "\(w)"] }
            else if let h = args["height"] as? Int { a = ["--resampleHeight", "\(h)"] }
            else { throw ToolError("Indica max, width o height") }
            _ = try await run("/usr/bin/sips", a + [input.path, "--out", out.path])
            return "Creata \(out.path) (\(dimensions(out)))."
        case "convert", "compress":
            let compress = action == "compress"
            var format = ((args["format"] as? String) ?? (compress ? "jpg" : "")).lowercased()
            if format == "jpeg" { format = "jpg" }
            guard !format.isEmpty else { throw ToolError("Indica il formato (jpg, png, heic, webp, tiff, gif, pdf)") }
            let out = try await output(args, input: input, suffix: compress ? "compressa" : "", ext: format, ctx: ctx)
            let quality = max(1, min(100, args["quality"] as? Int ?? 70))
            if format == "webp" {
                guard let magick = binary("magick") else { throw ToolError("Per il WebP serve ImageMagick: brew install imagemagick") }
                var a = [input.path]
                if let max = args["max"] as? Int { a += ["-resize", "\(max)x\(max)>"] }
                _ = try await run(magick, a + ["-quality", "\(quality)", out.path])
            } else {
                let sipsFormat = ["jpg": "jpeg", "png": "png", "heic": "heic", "tiff": "tiff", "gif": "gif", "pdf": "pdf", "bmp": "bmp"][format]
                guard let sipsFormat else { throw ToolError("Formato non supportato: \(format)") }
                var a = ["-s", "format", sipsFormat]
                if compress || args["quality"] != nil { a += ["-s", "formatOptions", "\(quality)"] }
                if let max = args["max"] as? Int { a += ["-Z", "\(max)"] }
                _ = try await run("/usr/bin/sips", a + [input.path, "--out", out.path])
            }
            return "Creata \(out.path) (\(fileSize(input)) → \(fileSize(out)))."
        case "rotate", "flip":
            let out = try await output(args, input: input, suffix: action == "rotate" ? "ruotata" : "specchiata", ext: input.pathExtension, ctx: ctx)
            let a = action == "rotate"
                ? ["-r", "\(args["angle"] as? Int ?? 90)"]
                : ["-f", (args["direction"] as? String ?? "horizontal").hasPrefix("v") ? "vertical" : "horizontal"]
            _ = try await run("/usr/bin/sips", a + [input.path, "--out", out.path])
            return "Creata \(out.path)."
        case "remove_background":
            let color = (args["background"] as? String).flatMap(parseColor)
            let out = try await output(args, input: input, suffix: "scontornata", ext: color == nil ? "png" : "jpg", ctx: ctx)
            try removeBackground(input, to: out, background: color, crop: args["crop"] as? Bool ?? false)
            return "Creata \(out.path) (\(dimensions(out)))."
        case "ocr":
            let text = try recognizeText(try uprightImage(input))
            return text.isEmpty ? "Non ho trovato testo nell'immagine." : try long(text, name: input.deletingPathExtension().lastPathComponent + "-testo")
        default:
            throw ToolError("Azione sconosciuta: \(action)")
        }
    }

    /// The image the way it's displayed (EXIF orientation applied), at full size.
    static func uprightImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ToolError("Immagine non leggibile: \(url.lastPathComponent)")
        }
        let side = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(side, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ToolError("Immagine non leggibile: \(url.lastPathComponent)")
        }
        return image
    }

    static func removeBackground(_ input: URL, to output: URL, background: CIColor?, crop: Bool) throws {
        let image = try uprightImage(input)
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let mask = request.results?.first, !mask.allInstances.isEmpty else {
            throw ToolError("Non ho trovato un soggetto in primo piano da scontornare.")
        }
        let buffer = try mask.generateMaskedImage(ofInstances: mask.allInstances, from: handler, croppedToInstancesExtent: crop)
        var result = CIImage(cvPixelBuffer: buffer)
        if let background {
            result = result.composited(over: CIImage(color: background).cropped(to: result.extent))
        }
        let context = CIContext()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: space) else {
            throw ToolError("Scontorno non riuscito")
        }
        try write(cg, to: output, type: background == nil ? .png : .jpeg)
    }

    static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError("Scrittura non riuscita: \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Scrittura non riuscita: \(url.lastPathComponent)") }
    }

    static func parseColor(_ s: String) -> CIColor? {
        switch s.lowercased() {
        case "", "none", "transparent", "trasparente": return nil
        case "white", "bianco": return .white
        case "black", "nero": return .black
        default:
            let hex = s.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard hex.count == 6, let v = Int(hex, radix: 16) else { return .white }
            return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255)
        }
    }

    // MARK: Audio and video

    static let media = ElioTool(
        name: "media_tool",
        description: """
        Lavora su audio e video (mp4, mov, mkv, webm, mp3, m4a, wav…). action: info; convert (format: mp4, mov, webm, mp3, \
        m4a, wav, gif…); compress (quality low/medium/high, default medium; height per ridurre la risoluzione, es. 720); \
        trim (start ed end o duration, in secondi o hh:mm:ss); extract_audio (format mp3 o m4a); mute (toglie l'audio); \
        resize (height); gif (start, duration, width); frame (fotogramma al tempo start, PNG); normalize (volume uniforme); \
        transcribe (trascrizione on-device, language default it-IT; srt=true salva anche i sottotitoli); \
        subtitle (crea i sottotitoli .srt e, per un video, una copia con la traccia sottotitoli inclusa). \
        Lavori lunghi (video di molti minuti): meglio dentro mac_task.
        """,
        properties: [
            "action": prop("info, convert, compress, trim, extract_audio, mute, resize, gif, frame, normalize, transcribe, subtitle"),
            "input": prop("File audio o video di partenza"),
            "output": prop("File risultato (default: in ~/Documents/Elio con un suffisso)"),
            "format": prop("Formato di uscita (convert, extract_audio)"),
            "quality": prop("low, medium, high (compress)"),
            "height": prop("Altezza massima in pixel (compress, resize)", type: "integer"),
            "width": prop("Larghezza in pixel (gif, default 480)", type: "integer"),
            "start": prop("Inizio: secondi o hh:mm:ss"),
            "end": prop("Fine: secondi o hh:mm:ss"),
            "duration": prop("Durata: secondi o hh:mm:ss"),
            "language": prop("Lingua per transcribe/subtitle, es. it-IT, en-US"),
            "srt": prop("transcribe: salva anche il file .srt", type: "boolean"),
        ],
        required: ["action", "input"]
    ) { args, ctx in
        let action = args["action"] as? String ?? ""
        let input = try existing(args["input"] as? String)
        let ext = input.pathExtension.lowercased()
        let isVideo = videoExtensions.contains(ext)
        switch action {
        case "info":
            guard let probe = binary("ffprobe") else { throw missingFFmpeg }
            return try await run(probe, ["-v", "error", "-show_entries",
                                         "format=duration,size,bit_rate:stream=codec_type,codec_name,width,height,sample_rate,channels",
                                         "-of", "compact=p=0", input.path])
        case "transcribe", "subtitle":
            let segments = try await transcribe(input, language: args["language"] as? String ?? "it-IT")
            guard !segments.isEmpty else { return "Non ho sentito parole nel file." }
            let base = input.deletingPathExtension().lastPathComponent
            var notes: [String] = []
            if action == "subtitle" || args["srt"] as? Bool == true {
                let srt = try await output([:], input: input, suffix: "", ext: "srt", ctx: ctx)
                try srtText(segments).write(to: srt, atomically: true, encoding: .utf8)
                notes.append("Sottotitoli: \(srt.path)")
                if action == "subtitle", isVideo {
                    let out = try await output(args, input: input, suffix: "sottotitolato", ext: "mp4", ctx: ctx)
                    let lang = String((args["language"] as? String ?? "it").prefix(2)) == "en" ? "eng" : "ita"
                    _ = try await ffmpeg(["-i", input.path, "-i", srt.path, "-map", "0:v", "-map", "0:a?", "-map", "1",
                                          "-c:v", "copy", "-c:a", "aac", "-c:s", "mov_text",
                                          "-metadata:s:s:0", "language=\(lang)", out.path])
                    notes.append("Video con sottotitoli: \(out.path)")
                }
            }
            if action == "subtitle" { return notes.joined(separator: "\n") }
            let text = segments.map(\.text).joined(separator: " ")
            return try long(text, name: base + "-trascrizione") + (notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n"))
        case "convert":
            let format = (args["format"] as? String ?? "").lowercased()
            guard !format.isEmpty else { throw ToolError("Indica il formato") }
            if format == "gif" { return try await gif(input, args: args, ctx: ctx) }
            let out = try await output(args, input: input, suffix: "", ext: format, ctx: ctx)
            _ = try await ffmpeg(["-i", input.path] + encoding(for: format) + [out.path])
            return "Creato \(out.path) (\(fileSize(out)))."
        case "compress":
            let crf = ["low": 32, "high": 23][args["quality"] as? String ?? ""] ?? 28
            if isVideo {
                let out = try await output(args, input: input, suffix: "compresso", ext: "mp4", ctx: ctx)
                var a = ["-i", input.path, "-c:v", "libx264", "-preset", "faster", "-crf", "\(crf)",
                         "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
                if let h = args["height"] as? Int { a += ["-vf", "scale=-2:'min(\(h),ih)'"] }
                _ = try await ffmpeg(a + [out.path])
                return "Creato \(out.path) (\(fileSize(input)) → \(fileSize(out)))."
            }
            let bitrate = ["low": "64k", "high": "160k"][args["quality"] as? String ?? ""] ?? "96k"
            let out = try await output(args, input: input, suffix: "compresso", ext: "m4a", ctx: ctx)
            _ = try await ffmpeg(["-i", input.path, "-vn", "-c:a", "aac", "-b:a", bitrate, out.path])
            return "Creato \(out.path) (\(fileSize(input)) → \(fileSize(out)))."
        case "trim":
            guard args["start"] != nil || args["end"] != nil || args["duration"] != nil else {
                throw ToolError("Indica start, end o duration")
            }
            let out = try await output(args, input: input, suffix: "tagliato", ext: ext, ctx: ctx)
            _ = try await ffmpeg(["-i", input.path] + window(args) + encoding(for: ext) + [out.path])
            return "Creato \(out.path)."
        case "extract_audio":
            let format = (args["format"] as? String ?? "mp3").lowercased()
            let out = try await output(args, input: input, suffix: "audio", ext: format, ctx: ctx)
            _ = try await ffmpeg(["-i", input.path, "-vn"] + encoding(for: format) + [out.path])
            return "Creato \(out.path) (\(fileSize(out)))."
        case "mute":
            let out = try await output(args, input: input, suffix: "muto", ext: ext, ctx: ctx)
            _ = try await ffmpeg(["-i", input.path, "-an", "-c:v", "copy", out.path])
            return "Creato \(out.path)."
        case "resize":
            guard let h = args["height"] as? Int else { throw ToolError("Indica height, es. 720") }
            let out = try await output(args, input: input, suffix: "\(h)p", ext: "mp4", ctx: ctx)
            _ = try await ffmpeg(["-i", input.path, "-vf", "scale=-2:\(h)"] + encoding(for: "mp4") + [out.path])
            return "Creato \(out.path) (\(fileSize(out)))."
        case "gif":
            return try await gif(input, args: args, ctx: ctx)
        case "frame":
            let out = try await output(args, input: input, suffix: "fotogramma", ext: "png", ctx: ctx)
            _ = try await ffmpeg(["-ss", time(args["start"]) ?? "0", "-i", input.path, "-frames:v", "1", out.path])
            return "Creato \(out.path)."
        case "normalize":
            let out = try await output(args, input: input, suffix: "normalizzato", ext: ext, ctx: ctx)
            var a = ["-i", input.path, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
            a += isVideo ? ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] : encoding(for: ext)
            _ = try await ffmpeg(a + [out.path])
            return "Creato \(out.path)."
        default:
            throw ToolError("Azione sconosciuta: \(action)")
        }
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts"]

    /// Codec flags with sensible defaults for an output extension.
    static func encoding(for ext: String) -> [String] {
        switch ext.lowercased() {
        case "mp4", "m4v", "mov": ["-c:v", "libx264", "-preset", "faster", "-crf", "23", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "webm": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "mp3": ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac": ["-c:a", "aac", "-b:a", "192k"]
        case "wav": ["-c:a", "pcm_s16le"]
        case "flac": ["-c:a", "flac"]
        case "ogg", "opus": ["-c:a", "libopus", "-b:a", "128k"]
        default: []
        }
    }

    static func gif(_ input: URL, args: [String: Any], ctx: ToolContext) async throws -> String {
        let out = try await output(args, input: input, suffix: "", ext: "gif", ctx: ctx)
        let width = args["width"] as? Int ?? 480
        let filter = "fps=12,scale=\(width):-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
        _ = try await ffmpeg(window(args) + ["-i", input.path, "-filter_complex", filter, "-loop", "0", out.path])
        return "Creata \(out.path) (\(fileSize(out)))."
    }

    /// -ss / -to / -t from the start, end and duration arguments.
    static func window(_ args: [String: Any]) -> [String] {
        var a: [String] = []
        if let s = time(args["start"]) { a += ["-ss", s] }
        if let e = time(args["end"]) { a += ["-to", e] }
        else if let d = time(args["duration"]) { a += ["-t", d] }
        return a
    }

    static func time(_ value: Any?) -> String? {
        switch value {
        case let n as Int: "\(n)"
        case let n as Double: "\(n)"
        case let s as String where !s.trimmingCharacters(in: .whitespaces).isEmpty: s.trimmingCharacters(in: .whitespaces)
        default: nil
        }
    }

    // MARK: Transcription

    struct Segment {
        let start: Double, end: Double, text: String
    }

    /// On-device transcription with timings (SpeechAnalyzer). Anything AVAudioFile can't read
    /// (video, ogg, webm…) is converted to WAV with ffmpeg first.
    static func transcribe(_ input: URL, language: String) async throws -> [Segment] {
        var audio = input
        var temp: URL?
        if !["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"].contains(input.pathExtension.lowercased()) {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("elio-\(UUID().uuidString).wav")
            _ = try await ffmpeg(["-i", input.path, "-vn", "-ac", "1", "-ar", "16000", wav.path])
            audio = wav
            temp = wav
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw ToolError("Lingua non supportata per la trascrizione: \(language)")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [Segment] in
            var segments: [Segment] = []
            for try await result in transcriber.results {
                // Results are whole phrases: cut them into subtitle-sized cues on word timings.
                var cue = "", start: Double?, end = 0.0
                func flush() {
                    let text = cue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, let s = start { segments.append(Segment(start: s, end: end, text: text)) }
                    cue = ""; start = nil
                }
                for run in result.text.runs {
                    let word = String(result.text[run.range].characters)
                    if let range = run.audioTimeRange {
                        if start == nil { start = range.start.seconds }
                        end = range.end.seconds
                    }
                    cue += word
                    let trimmed = word.trimmingCharacters(in: .whitespaces)
                    if cue.count >= 42 || (cue.count >= 12 && [".", "?", "!"].contains(trimmed.last.map(String.init) ?? "")) { flush() }
                }
                if start == nil { start = result.range.start.seconds; end = result.range.end.seconds }
                flush()
            }
            return segments
        }
        let file = try AVAudioFile(forReading: audio)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    static func srtText(_ segments: [Segment]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start)) --> \(stamp(s.end))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    static func existing(_ path: String?) throws -> URL {
        guard let path, !path.isEmpty else { throw ToolError("Indica il file") }
        let url = FileTools.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("File non trovato: \(url.path)") }
        return url
    }

    /// The `output` argument, or "<name>-<suffix>.<ext>" in ~/Documents/Elio without replacing anything there.
    static func output(_ args: [String: Any], input: URL, suffix: String, ext: String, ctx: ToolContext) async throws -> URL {
        if let o = args["output"] as? String, !o.isEmpty {
            let url = FileTools.resolve(o)
            try await FileTools.checkWrite(url, ctx: ctx)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard url.standardizedFileURL != input.standardizedFileURL else { throw ToolError("Il risultato non può sovrascrivere l'originale") }
            return url
        }
        let base = input.deletingPathExtension().lastPathComponent + (suffix.isEmpty ? "" : "-\(suffix)")
        var url = ElioPaths.outputDir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = ElioPaths.outputDir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Long text: returned inline up to a limit, saved to a .txt in ~/Documents/Elio beyond it.
    static func long(_ text: String, name: String) throws -> String {
        guard text.count > 12_000 else { return text }
        let url = ElioPaths.outputDir.appendingPathComponent("\(name).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return String(text.prefix(12_000)) + "\n…[troncato: testo completo in \(url.path)]"
    }

    static func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func dimensions(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return fileSize(url) }
        return "\(w)×\(h) px, \(fileSize(url))"
    }

    static func binary(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let missingFFmpeg = ToolError("Manca ffmpeg: installalo con `brew install ffmpeg` (puoi farlo tu con Bash) e riprova.")

    static func ffmpeg(_ args: [String]) async throws -> String {
        guard let path = binary("ffmpeg") else { throw missingFFmpeg }
        return try await run(path, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args)
    }

    /// Runs a command-line tool without holding a thread while it works. Output goes to temp files,
    /// so a chatty tool (ffmpeg) can't fill a pipe and hang; a failure reports the end of stderr.
    static func run(_ path: String, _ args: [String]) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("elio-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("elio-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch {
                p.terminationHandler = nil
                c.resume(throwing: error)
            }
        }
        guard p.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let tail = err.split(separator: "\n").suffix(3).joined(separator: " ")
            throw ToolError("\(URL(fileURLWithPath: path).lastPathComponent) non riuscito: \(tail.isEmpty ? "exit \(p.terminationStatus)" : tail)")
        }
        return (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    }
}
