import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFOps {
    // MARK: Limits (B2)

    /// More than `Limits.maxPagesWithoutAsking` pages: ask first (refused where nobody can answer).
    static func confirmPages(_ count: Int, of url: URL) throws {
        guard count > Limits.maxPagesWithoutAsking else { return }
        guard Notice.confirm(title: L("«%@» ha %@ pagine", url.lastPathComponent, count),
                             text: L("Elaborarle tutte può richiedere molto tempo. Puoi fermarti in qualsiasi momento con «Annulla» nella scheda di avanzamento. Continuare?"),
                             button: L("Continua")) else {
            throw OpError.failed(L("PDF di %@ pagine: operazione non avviata", count))
        }
    }

    /// Called once per page: stops the job as soon as the user presses «Annulla».
    static func checkCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    // MARK: Build

    /// One page per image, in natural filename order (1, 2, 10…).
    static func fromImages(_ urls: [URL]) throws -> [URL] {
        let sorted = FileNaming.sortedNaturally(urls)
        let pdf = PDFDocument()
        for url in sorted {
            guard let page = PDFPage(image: try ImageOps.verifiedPageImage(url)) else { continue }
            pdf.insert(page, at: pdf.pageCount)
        }
        guard pdf.pageCount > 0, let first = sorted.first else { throw OpError.failed(L("nessuna immagine valida")) }
        let sourceDir = first.deletingLastPathComponent()
        let name = sorted.count == 1 ? first.deletingPathExtension().lastPathComponent : sourceDir.lastPathComponent
        let out = FileNaming.unique(FileNaming.directory(for: first).appendingPathComponent(name).appendingPathExtension("pdf"))
        guard pdf.write(to: out) else { throw OpError.failed(L("scrittura del PDF")) }
        try neutralizeInfo(out, pages: pdf.pageCount)   // on failure the job removes `out`
        return [out]
    }

    /// One page of the Merge window: a PDF page (`page` = index) or a whole image (`page` = nil).
    struct PageRef: Sendable {
        let url: URL
        let page: Int?
        /// Extra clockwise rotation in degrees (0, 90, 180, 270).
        let rotation: Int
    }

    /// Builds a PDF from pages of several PDFs and images, in the given order and rotation.
    static func assemble(_ refs: [PageRef], to out: URL) throws {
        var documents: [URL: PDFDocument] = [:]
        let result = PDFDocument()
        for ref in refs {
            let page: PDFPage?
            if let index = ref.page {
                if documents[ref.url] == nil {
                    try PDFTextScan.checkForRewriting(ref.url)
                    documents[ref.url] = PDFDocument(url: ref.url)
                }
                guard let doc = documents[ref.url] else { throw OpError.unreadable(ref.url) }
                page = doc.page(at: index)?.copy() as? PDFPage
            } else {
                page = PDFPage(image: try ImageOps.verifiedPageImage(ref.url))
            }
            guard let page else { throw OpError.unreadable(ref.url) }
            page.rotation = (page.rotation + ref.rotation) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0 else { throw OpError.failed(L("nessuna pagina da unire")) }
        guard result.write(to: out) else { throw OpError.failed(L("scrittura del PDF")) }
        try? neutralizeInfo(out, pages: result.pageCount)   // as «Numeri»: the pages are the job here
    }

    static func split(_ url: URL) throws -> [URL] {
        try PDFTextScan.checkForDrawing(url)   // one page can't be stopped halfway
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        try confirmPages(doc.pageCount, of: url)
        let folder = try FileNaming.folder(for: url, suffix: "pagine")
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            try checkCancelled()
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            let file = folder.appendingPathComponent("\(base) - p\(i + 1).pdf")
            single.write(to: file)
            try? neutralizeInfo(file, pages: single.pageCount)   // as «Numeri»: the pages are the job here
        }
        return [folder]
    }

    // MARK: Convert

    static func toImages(_ url: URL, type: UTType, dpi: CGFloat = 150) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw OpError.unreadable(url) }
        guard let ext = ImageOps.fileExtension(for: type) else { throw OpError.unsupported(type.identifier) }
        try confirmPages(doc.numberOfPages, of: url)
        try PDFTextScan.checkForDrawing(url)   // drawing a page can't be stopped halfway
        let base = url.deletingPathExtension().lastPathComponent
        let folder = doc.numberOfPages == 1 ? nil : try FileNaming.folder(for: url, suffix: "immagini")
        var outputs: [URL] = []
        for i in 1...doc.numberOfPages {
            try checkCancelled()
            guard let page = doc.page(at: i), let image = render(page, dpi: dpi) else { continue }
            let out = folder.map { $0.appendingPathComponent("\(base) - p\(i).\(ext)") }
                ?? FileNaming.output(for: url, ext: ext)
            try ImageOps.write(image, to: out, type: type, quality: 0.85)
            outputs.append(out)
        }
        try checkCancelled()   // during the last page: `cleaningUpOnFailure` removes the results
        return folder.map { [$0] } ?? outputs
    }

    // MARK: Tools

    /// Rasterises every page to JPEG at `dpi`. Much smaller for scans and photos, but the text
    /// is no longer selectable — the same trade-off as Preview's "Reduce File Size", with better quality.
    static func compress(_ url: URL, dpi: CGFloat, quality: CGFloat, suffix: String) throws -> [URL] {
        let doc = try open(url)
        let out = FileNaming.output(for: url, ext: "pdf", suffix: suffix)
        try rasterize(doc, to: out, dpi: dpi, quality: quality)
        if FileNaming.fileSize(out) >= FileNaming.fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw OpError.notSmaller
        }
        return [out]
    }

    /// Tries progressively stronger settings until the PDF fits under `maxBytes`.
    static func fit(_ url: URL, maxBytes: Int) throws -> [URL] {
        guard FileNaming.fileSize(url) > maxBytes else { throw OpError.alreadySmall }
        let doc = try open(url)
        let label = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
        let out = FileNaming.output(for: url, ext: "pdf", suffix: label)
        let steps: [(dpi: CGFloat, quality: CGFloat, maxSide: CGFloat)] = [
            (200, 0.8, 3000), (150, 0.7, 2400), (150, 0.5, 2000), (120, 0.5, 1600),
            (100, 0.45, 1400), (90, 0.35, 1200), (72, 0.3, 1000), (60, 0.25, 800),
        ]
        for step in steps {
            try rasterize(doc, to: out, dpi: step.dpi, quality: step.quality, maxSide: step.maxSide)
            if FileNaming.fileSize(out) <= maxBytes { return [out] }
        }
        try? FileManager.default.removeItem(at: out)
        throw OpError.failed(L("impossibile scendere sotto %@ mantenendo il PDF leggibile", label))
    }

    private static func open(_ url: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw OpError.unreadable(url) }
        guard !doc.isEncrypted || doc.isUnlocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        try confirmPages(doc.numberOfPages, of: url)
        try PDFTextScan.checkForDrawing(url)   // drawing a page can't be stopped halfway
        return doc
    }

    /// `maxSide` caps the rendered pixels, for PDFs made from photos whose pages are metres wide.
    private static func rasterize(_ doc: CGPDFDocument, to out: URL, dpi: CGFloat, quality: CGFloat,
                                  maxSide: CGFloat = 2400) throws {
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw OpError.failed(L("creazione del PDF")) }
        for i in 1...doc.numberOfPages {
            try checkCancelled()
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let size = displaySize(page)
                let pageDPI = min(dpi, maxSide * 72 / max(size.width, size.height, 1))
                guard let raster = render(page, dpi: pageDPI),
                      let jpeg = jpegImage(raster, quality: quality) else { return }
                var box = CGRect(origin: .zero, size: size)
                ctx.beginPage(mediaBox: &box)
                ctx.draw(jpeg, in: box)
                ctx.endPage()
            }
        }
        ctx.closePDF()
        try checkCancelled()   // during the last page: `cleaningUpOnFailure` removes the result
        try? neutralizeInfo(out, pages: doc.numberOfPages)   // as «Numeri»: the pages are the job here
    }

    /// E1: the pages are copied into a brand-new document, so the old catalogue — with its XMP /Metadata
    /// stream (author, software…) — is left behind, not just the Info dictionary.
    static func stripMetadata(_ url: URL) throws -> [URL] {
        try PDFTextScan.checkForRewriting(url)
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage { clean.insert(page, at: clean.pageCount) }
        }
        clean.documentAttributes = [:]
        let out = FileNaming.output(for: url, ext: "pdf", suffix: L("senza metadati"))
        guard clean.write(to: out) else { throw OpError.failed(L("scrittura del PDF")) }
        try neutralizeInfo(out, pages: clean.pageCount)   // on failure the job removes `out`
        return [out]
    }

    /// PDFKit always writes its own Producer (macOS version and build) and the time of writing. They are
    /// overwritten in place with values of the same length, so every offset in the file stays valid, and only
    /// inside the information dictionary the trailer points to (a note or a link that merely contains the text
    /// "/Producer" doesn't count). When that isn't possible, or the check afterwards fails, the job fails with a
    /// visible error: a file named "senza metadati" must never carry them.
    static func neutralizeInfo(_ url: URL, pages: Int) throws {
        let failure = OpError.failed(L("non è stato possibile togliere dal PDF i dati scritti da macOS (versione del sistema, data e ora): nessun file creato"))
        guard var data = try? Data(contentsOf: url), let info = infoObjectRange(in: data) else { throw failure }
        let neutralDate = "D:20000101000000Z00'00'"
        let fields = [("Producer", "Rondelle"), ("CreationDate", neutralDate), ("ModDate", neutralDate)]
        for (key, value) in fields {
            guard overwriteLiteral(&data, in: info, key: key, with: value) != .failed else { throw failure }
        }
        do { try data.write(to: url) } catch { throw failure }
        guard let check = CGPDFDocument(url as CFURL), check.numberOfPages == pages else { throw failure }
        if let dict = check.info {
            for (key, value) in fields {
                var string: CGPDFStringRef?
                guard CGPDFDictionaryGetString(dict, key, &string), let string else { continue }   // absent: nothing to hide
                let text = (CGPDFStringCopyTextString(string) as String? ?? "").trimmingCharacters(in: .whitespaces)
                guard text == value else { throw failure }
            }
        }
    }

    /// Bytes of the "N G obj … endobj" object the last trailer's /Info points to; nil if the file isn't laid out
    /// that way (e.g. a cross-reference stream) or the object isn't found exactly once.
    private static func infoObjectRange(in data: Data) -> Range<Data.Index>? {
        guard let trailer = data.range(of: Data("trailer".utf8), options: .backwards),
              let key = data.range(of: Data("/Info".utf8), in: trailer.upperBound..<data.endIndex) else { return nil }
        func number(from index: inout Data.Index) -> Int? {
            while index < data.endIndex, [0x20, 0x0A, 0x0D, 0x09].contains(data[index]) { index += 1 }
            var value = 0, digits = 0
            while index < data.endIndex, (0x30...0x39).contains(data[index]), digits < 10 {
                value = value * 10 + Int(data[index] - 0x30); digits += 1; index += 1
            }
            return digits > 0 ? value : nil
        }
        var i = key.upperBound
        guard let object = number(from: &i), let generation = number(from: &i) else { return nil }
        let header = Data("\n\(object) \(generation) obj".utf8)
        guard let start = data.range(of: header),
              data.range(of: header, in: start.upperBound..<data.endIndex) == nil,
              let end = data.range(of: Data("endobj".utf8), in: start.upperBound..<data.endIndex) else { return nil }
        return start.upperBound..<end.lowerBound
    }

    private enum Overwrite { case replaced, absent, failed }

    /// Replaces the bytes of `/key (…)` inside `range` with `value` padded with spaces to the same length.
    /// `.absent` when the key isn't there; `.failed` when it is but not exactly once as a plain literal string.
    private static func overwriteLiteral(_ data: inout Data, in range: Range<Data.Index>, key: String, with value: String) -> Overwrite {
        let marker = Data("/\(key)".utf8)
        guard let first = data.range(of: marker, in: range) else { return .absent }
        guard data.range(of: marker, in: first.upperBound..<range.upperBound) == nil else { return .failed }
        var open = first.upperBound   // PDFKit may put a space or a line break before the "("
        while open < range.upperBound, [0x20, 0x0A, 0x0D, 0x09].contains(data[open]) { open += 1 }
        guard open < range.upperBound, data[open] == UInt8(ascii: "(") else { return .failed }
        // Find the closing parenthesis: literal strings may contain balanced or escaped parentheses.
        var depth = 1, i = open + 1
        while i < range.upperBound, depth > 0 {
            switch data[i] {
            case UInt8(ascii: "\\"): i += 1
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"): depth -= 1
            default: break
            }
            if depth > 0 { i += 1 }
        }
        guard depth == 0 else { return .failed }
        let slot = (open + 1)..<i
        let bytes = Array(value.utf8.prefix(slot.count))
        data.replaceSubrange(slot, with: bytes + Array(repeating: UInt8(ascii: " "), count: slot.count - bytes.count))
        return .replaced
    }

    // MARK: Rendering

    /// Page size in points as it appears on screen (crop box, /Rotate applied).
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    static func render(_ page: CGPDFPage, dpi: CGFloat) -> CGImage? {
        let size = displaySize(page)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(dpi / 72, Limits.maxRenderSide / max(size.width, size.height))
        let width = max(Int(size.width * scale), 1), height = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// A CGImage backed by JPEG data, which Quartz embeds in the PDF as-is (DCT) instead of re-encoding.
    static func jpegImage(_ image: CGImage, quality: CGFloat) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
