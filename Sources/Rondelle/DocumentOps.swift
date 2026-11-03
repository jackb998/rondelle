import AppKit
import PDFKit

enum DocumentOps {
    enum Target: String {
        case pdf, txt, docx, rtf, odt, html

        var documentType: NSAttributedString.DocumentType? {
            switch self {
            case .docx: return .officeOpenXML
            case .rtf: return .rtf
            case .odt: return .openDocument
            case .html: return .html
            case .pdf, .txt: return nil
            }
        }
    }

    /// Word, RTF, ODT, HTML, TXT… → another document format.
    /// B1: size limit first; everything is imported and written off the main thread, so the menu bar and the
    /// wheel stay responsive, except HTML/web archives (WebKit's importer needs the main thread): their stricter
    /// size limit keeps that short.
    static func convert(_ url: URL, to target: Target) async throws -> [URL] {
        try checkSize(url, forPDF: target == .pdf)
        // Word and OpenDocument into a format that can show what the importer alone would lose.
        if [.pdf, .docx].contains(target), ["docx", "odt"].contains(url.pathExtension.lowercased()) {
            let work = ArchiveOps.protectedZipWork.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            if let prepared = PackedImages.prepare(url, in: work) {
                let text = try PackedImages.finish(try await imported(prepared.copy), prepared, from: url)
                return [try writeNow(text, from: url, to: target, layout: prepared.layout)]
            }
        }
        return [try await write(try await imported(url), from: url, to: target)]
    }

    /// The document's text; web content on the main thread (see `convert`), the rest off it.
    static func imported(_ url: URL) async throws -> NSAttributedString {
        if isWebContent(url) {
            return try await MainActor.run { Handover(text: try NSAttributedString(url: url, options: [:], documentAttributes: nil)) }.text
        }
        var attributes: NSDictionary?
        let text = try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
        // A file that isn't what its name says comes back as plain text (bytes included): a wrong result, not a document.
        let packed = ["doc", "docx", "odt", "rtf", "rtfd"].contains(url.pathExtension.lowercased())
        if packed, attributes?[NSAttributedString.DocumentAttributeKey.documentType] as? NSAttributedString.DocumentType == .plain {
            throw OpError.unsupported(L("«%@» non è un documento %@ valido", url.lastPathComponent, url.pathExtension.uppercased()))
        }
        return text
    }

    /// The imported text crosses from the main thread to the job once and is never shared: safe to hand over.
    private struct Handover: @unchecked Sendable { let text: NSAttributedString }

    private static func isWebContent(_ url: URL) -> Bool {
        ["html", "htm", "webarchive"].contains(url.pathExtension.lowercased())
    }

    /// Size on disk; an .rtfd is a folder, so its contents (images) are added up.
    private static func byteSize(_ url: URL) -> Int {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return FileNaming.fileSize(url) }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        return (items?.allObjects as? [URL] ?? []).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// PDF output takes ≈ 1 s per MB of text to lay out, hence its own limit.
    static let maxBytesForPDF = 5_000_000

    /// The largest file of this kind that is accepted (also used by Shortcuts).
    static func sizeLimit(for url: URL) -> Int {
        if isWebContent(url) { return Limits.maxHTMLBytes }
        if ["docx", "odt"].contains(url.pathExtension.lowercased()) { return Limits.maxPackedDocumentBytes }
        return Limits.maxDocumentBytes
    }

    static func checkSize(_ url: URL, forPDF: Bool = false) throws {
        var limit = sizeLimit(for: url)
        if forPDF { limit = min(limit, maxBytesForPDF) }
        guard byteSize(url) <= limit else {
            throw OpError.unsupported(L("«%@» supera %@ MB, il massimo per i documenti di questo tipo", url.lastPathComponent, limit / 1_000_000))
        }
        try ContentLimits.check(url)
    }

    /// PDF → Word/RTF, keeping its pages as far as each format can: see `PDFToWord`.
    /// Off the main thread, page by page: long PDFs need a confirmation (B2) and «Annulla» works.
    /// `plain`: only the text, in paragraphs, as a document of the system's defaults.
    static func fromPDF(_ url: URL, to target: Target, plain: Bool = false) async throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        guard !doc.isLocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        try PDFOps.confirmPages(doc.pageCount, of: url)
        let largest = try PDFTextScan.check(url)
        let noText = OpError.failed(L("il PDF non contiene testo (forse è una scansione)"))
        guard target == .docx, !plain else {
            let pages = try PDFToWord.read(url, into: nil, largestStream: largest)
            let text = plain ? PDFToWord.plainText(pages) : PDFToWord.attributedText(pages)
            guard !text.string.allSatisfy(\.isWhitespace) else { throw noText }
            return [try await write(text, from: url, to: target)]
        }
        // In the app's own folder, not next to the result: a sync service could upload the pieces (C1).
        let work = ArchiveOps.protectedZipWork.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let media = work.appendingPathComponent("word/media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let pages = try PDFToWord.read(url, into: media, largestStream: largest)
        guard pages.contains(where: { !$0.paragraphs.isEmpty }) else { throw noText }
        try PDFToWord.writeParts(pages, in: work)
        let out = FileNaming.output(for: url, ext: target.rawValue)
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        try ArchiveOps.pack(work, to: temp)
        try FileNaming.replace(out, with: temp)
        return [out]
    }

    /// Every output format is written off the main thread.
    private static func write(_ text: NSAttributedString, from source: URL, to target: Target) async throws -> URL {
        try writeNow(text, from: source, to: target)
    }

    static func writeNow(_ text: NSAttributedString, from source: URL, to target: Target, suffix: String? = nil,
                         layout page: PackedImages.PageLayout = .init()) throws -> URL {
        let out = FileNaming.output(for: source, ext: target.rawValue, suffix: suffix)
        switch target {
        case .txt:
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case .pdf:
            try renderPDF(text, to: out, page: page)
        default:
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: target.documentType!])
            try withoutSystemMarks(data, target).write(to: out)
            // In the packed formats the same mark is one entry of the archive.
            if target == .docx { try ArchiveOps.neutralizeGenerator(in: out, entry: "docProps/meta.xml") }
            if target == .odt { try ArchiveOps.neutralizeGenerator(in: out, entry: "meta.xml") }
        }
        return out
    }

    /// AppKit's writers sign what they write with their version, which tells the version of macOS.
    private static func withoutSystemMarks(_ data: Data, _ target: Target) -> Data {
        var result = data
        // Only at the top of the file, where the writer puts them: the document's own text stays as it is.
        func remove(_ mark: String, upTo end: (UInt8) -> Bool, including: Bool) {
            let head = result.startIndex..<min(result.startIndex + 4096, result.endIndex)
            guard let found = result.range(of: Data(mark.utf8), in: head) else { return }
            var stop = found.upperBound
            while stop < result.endIndex, !end(result[stop]) { stop += 1 }
            if including, stop < result.endIndex { stop += 1 }
            if including, stop < result.endIndex, result[stop] == 0x0A { stop += 1 }
            result.removeSubrange(found.lowerBound..<stop)
        }
        switch target {
        case .html:
            for mark in [#"<meta name="Generator""#, #"<meta name="CocoaVersion""#] {
                remove(mark, upTo: { $0 == 0x3E }, including: true)
            }
        case .rtf:
            for mark in [#"\cocoartf"#, #"\cocoasubrtf"#, #"\cocoatextscaling"#, #"\cocoaplatform"#] {
                remove(mark, upTo: { !(0x30...0x39).contains($0) }, including: false)
            }
        default:
            break
        }
        return result
    }

    /// A spreadsheet's HTML table → PDF. HTML import needs the main thread; the layout then runs off it.
    static func pdf(fromHTML html: String, source: URL) async throws -> URL {
        let text = try await MainActor.run {
            Handover(text: try NSAttributedString(data: Data(html.utf8),
                                                  options: [.documentType: NSAttributedString.DocumentType.html,
                                                            .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil))
        }.text
        let out = FileNaming.output(for: source, ext: "pdf")
        try renderPDF(text, to: out)
        return out
    }

    /// Lays the text out on A4 pages with 2 cm margins, like TextEdit's "Export as PDF", with TextKit
    /// drawing straight into a PDF context: no view and no print operation, so it runs off the main thread (B1).
    /// One layout pass in a single tall column, then pages break between lines, as printing does.
    private static func renderPDF(_ text: NSAttributedString, to out: URL, page format: PackedImages.PageLayout = .init()) throws {
        let paper = format.paper
        let body = CGSize(width: paper.width - format.left - format.right, height: paper.height - format.top - format.bottom)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: body.width, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var pages: [(glyphs: NSRange, top: CGFloat)] = []
        var start = 0, top: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, line, _ in
            let first = layout.characterIndexForGlyph(at: line.location)
            let breaksHere = first > 0 && text.attribute(PackedImages.pageBreak, at: first - 1, effectiveRange: nil) != nil
            if rect.maxY - top > body.height || breaksHere, line.location > start {
                pages.append((NSRange(location: start, length: line.location - start), top))
                start = line.location
                top = rect.minY
            }
        }
        pages.append((NSRange(location: start, length: layout.numberOfGlyphs - start), top))

        var media = CGRect(origin: .zero, size: paper)
        guard let ctx = CGContext(out as CFURL, mediaBox: &media, nil) else { throw OpError.failed(L("creazione del PDF")) }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        for page in pages {
            try PDFOps.checkCancelled()
            autoreleasepool {
                ctx.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                ctx.saveGState()
                ctx.translateBy(x: 0, y: paper.height)
                ctx.scaleBy(x: 1, y: -1)   // TextKit draws top-down
                ctx.clip(to: CGRect(x: format.left, y: format.top, width: body.width, height: body.height))
                let origin = CGPoint(x: format.left, y: format.top - page.top)
                layout.drawBackground(forGlyphRange: page.glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: page.glyphs, at: origin)
                ctx.restoreGState()
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        guard FileNaming.fileSize(out) > 0 else { throw OpError.failed(L("creazione del PDF")) }
        try PDFOps.neutralizeInfo(out, pages: pages.count)   // on failure the job removes `out`
    }
}

enum SubtitleOps {
    static func convert(_ url: URL, to ext: String) throws -> [URL] {
        guard FileNaming.fileSize(url) <= maxBytes else { throw OpError.unsupported(L("file di sottotitoli troppo grande")) }
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let cues = parse(text)
        guard !cues.isEmpty else { throw OpError.failed(L("nessun sottotitolo trovato")) }
        let out = FileNaming.output(for: url, ext: ext)
        try render(cues, as: ext).write(to: out, atomically: true, encoding: .utf8)
        return [out]
    }

    /// The same cues with the same times, their text put through `translate` (one line per cue).
    static func translate(_ url: URL, to suffix: String, _ translate: ([String]) async throws -> [String]) async throws -> URL {
        guard FileNaming.fileSize(url) <= maxBytes else { throw OpError.unsupported(L("file di sottotitoli troppo grande")) }
        var cues = parse(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n"))
        guard !cues.isEmpty else { throw OpError.failed(L("nessun sottotitolo trovato")) }
        let texts = try await translate(cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") })
        for i in cues.indices { cues[i].text = texts[i] }
        let ext = url.pathExtension.lowercased()
        let out = FileNaming.output(for: url, ext: ext, suffix: suffix)
        try render(cues, as: ext).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func render(_ cues: [Cue], as ext: String) -> String {
        let output: String
        switch ext {
        case "vtt":
            output = "WEBVTT\n\n" + cues.map { "\(stamp($0.start, ".")) --> \(stamp($0.end, "."))\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        case "srt":
            output = cues.enumerated().map { i, cue in
                "\(i + 1)\n\(stamp(cue.start, ",")) --> \(stamp(cue.end, ","))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        default:
            output = cues.map(\.text).joined(separator: "\n") + "\n"
        }
        return output
    }

    /// New subtitles, from what was said.
    static func srt(_ cues: [(start: Double, end: Double, text: String)]) -> String {
        render(cues.map { Cue(start: $0.start, end: $0.end, text: $0.text) }, as: "srt")
    }

    private struct Cue { var start: Double; var end: Double; var text: String }

    /// Reads both SRT and WebVTT: every block with a "-->" line is a cue.
    private static func parse(_ text: String) -> [Cue] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[i].components(separatedBy: "-->")
            // VTT cue settings ("align:start…") follow the end time after a space.
            let endText = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let start = seconds(parts[0]), let end = seconds(endText) else { return nil }
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : Cue(start: start, end: end, text: body)
        }
    }

    /// "01:02:03,456", "02:03.456" → seconds.
    private static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count) else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total.isFinite && total >= 0 && total < 1_000_000 ? total : nil  // < ~277 hours
    }

    /// Subtitle files are text; anything bigger than this is not a subtitle.
    static let maxBytes = 50_000_000

    private static func stamp(_ t: Double, _ separator: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
