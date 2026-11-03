import AVFoundation
import Foundation
import ImageIO

/// One short line about a file format, in the hub of the wheel: what it is mostly used for.
enum FileHints {
    private static let formats = [
        "JPG": "Foto, si apre ovunque",
        "PNG": "Grafica e trasparenza",
        "HEIC": "Foto di iPhone, leggere",
        "WEBP": "Immagini per i siti web",
        "AVIF": "Immagini per il web, molto leggere",
        "TIFF": "Stampa e archivio",
        "GIF": "Piccole animazioni",
        "BMP": "Programmi molto vecchi",
        "SVG": "Grafica per il web",
        "ICNS": "Icone per app del Mac",
        "ICO": "Icone per Windows e siti web",
        "PDF": "Da leggere e stampare",
        "DOCX": "Word, da modificare",
        "DOC": "Vecchio Word",
        "RTF": "Testo con stili, ovunque",
        "RTFD": "Testo con immagini, Mac",
        "ODT": "LibreOffice, da modificare",
        "HTML": "Pagina web",
        "WEBARCHIVE": "Pagina web salvata da Safari",
        "TXT": "Solo testo",
        "MD": "Testo con marcatori",
        "XLSX": "Excel",
        "ODS": "LibreOffice Calc",
        "CSV": "Dati, per ogni programma",
        "TSV": "Dati in colonne",
        "MP4": "Video, si apre ovunque",
        "MOV": "Video Apple e montaggio",
        "M4V": "Video per Apple TV",
        "M4A": "Audio Apple, leggero",
        "WAV": "Audio senza perdite, pesante",
        "AIFF": "Audio Apple senza perdite",
        "FLAC": "Musica senza perdite",
        "MP3": "Musica, si apre ovunque",
        "SRT": "Sottotitoli, ovunque",
        "VTT": "Sottotitoli per il web",
        "ZIP": "Archivio, si apre ovunque",
        "TAR.GZ": "Archivio per Mac e Linux",
        "RAR": "Archivio, serve un programma",
        "7Z": "Archivio molto compresso",
    ]
    private static let aliases = ["JPEG": "JPG", "TIF": "TIFF", "HTM": "HTML", "AIF": "AIFF", "TGZ": "TAR.GZ", "MARKDOWN": "MD"]

    /// One name for one format, everywhere: as the wheels write it, whatever the file's extension.
    static func name(ofExtension ext: String) -> String {
        let special = ["jpeg": "JPG", "jpg": "JPG", "webp": "WebP", "tif": "TIFF", "htm": "HTML", "aif": "AIFF", "webarchive": "WebArchive", "pages": "Pages", "numbers": "Numbers", "markdown": "MD"]
        return special[ext.lowercased()] ?? ext.uppercased()
    }

    /// What a format on the wheel is for, or what a tool does.
    static func line(for key: String) -> String? {
        let upper = key.uppercased()
        if let format = formats[aliases[upper] ?? upper] { return L(format) }
        return OptionsView.hint(key)
    }

    /// What the dragged files are, when they are all of one format.
    static func line(forFiles urls: [URL]) -> String? {
        let extensions = Set(urls.map { $0.pathExtension.uppercased() })
        guard extensions.count == 1, let ext = extensions.first, !ext.isEmpty else { return nil }
        return formats[aliases[ext] ?? ext].map(L)
    }

    /// What the savings of a job that makes files smaller look like: «1,2 MB → 340 KB (−72%)». Nil if it didn't.
    static func savings(from inputs: [URL], to outputs: [URL]) -> String? {
        let before = inputs.map(FileNaming.fileSize).reduce(0, +), after = outputs.map(FileNaming.fileSize).reduce(0, +)
        guard before > 0, after > 0, after < before else { return nil }
        let percent = Int((Double(before - after) / Double(before) * 100).rounded())
        guard percent >= 1 else { return nil }
        func text(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        return "\(text(before)) → \(text(after)) (−\(percent)%)"
    }

    /// «foto.heic · 3,2 MB · 4032 × 3024», under the wheel. Reads headers only, off the main thread, only regular files:
    /// the file hasn't been dropped yet, and may never be.
    nonisolated static func card(for urls: [URL]) async -> String? {
        guard let first = urls.first else { return nil }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func text(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        if urls.count > 1 { return L("%@ file", urls.count) + " · " + text(urls.map(size).reduce(0, +)) }
        var parts = [first.lastPathComponent]
        guard (try? first.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return parts[0] }
        parts.append(text(size(first)))
        switch FileKind(first) {
        case .image:
            if let source = CGImageSourceCreateWithURL(first as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth], let height = properties[kCGImagePropertyPixelHeight] {
                parts.append("\(width) × \(height)")
            }
        case .pdf:
            if let pages = CGPDFDocument(first as CFURL)?.numberOfPages, pages > 0 { parts.append(pages == 1 ? L("1 pagina") : L("%@ pagine", pages)) }
        case .video, .audio:
            let seconds = try? await AVURLAsset(url: first).load(.duration).seconds
            if let seconds, seconds.isFinite, seconds > 0 {
                let s = Int(seconds.rounded())
                parts.append(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
            }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }
}
