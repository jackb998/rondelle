import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PowerPoint (PPTX): to PDF, images and text, and from PDFs and images (one slide each). See `PptxReader` for what
/// is read and `PptxRenderer` for how it is drawn. A PPTX made here has one picture per slide: it looks like the
/// page, and the page's text goes in the picture's alternative text; it is not editable text.
enum PptxOps {
    // MARK: Limits

    /// A PPTX is a ZIP: 50 MB of it is accepted, the XML parts are bounded as for Word (`ContentLimits`).
    static func check(_ url: URL) throws {
        guard FileNaming.fileSize(url) <= Limits.maxDocumentBytes else {
            throw OpError.unsupported(L("«%@» supera %@ MB, il massimo per i documenti di questo tipo", url.lastPathComponent, Limits.maxDocumentBytes / 1_000_000))
        }
        try ContentLimits.check(url)
    }

    private static func open(_ url: URL) throws -> PptxReader.Deck {
        try check(url)
        let deck = try PptxReader.read(url)
        try PDFOps.confirmPages(deck.slides.count, of: url)
        return deck
    }

    // MARK: From PowerPoint

    static func toPDF(_ url: URL) throws -> [URL] {
        let deck = try open(url)
        let out = FileNaming.output(for: url, ext: "pdf")
        var media = CGRect(origin: .zero, size: deck.size)
        guard let ctx = CGContext(out as CFURL, mediaBox: &media, nil) else { throw OpError.failed(L("creazione del PDF")) }
        let pictures = PptxRenderer.Pictures()
        for slide in deck.slides {
            try PDFOps.checkCancelled()
            autoreleasepool {
                ctx.beginPDFPage(nil)
                PptxRenderer.draw(slide, of: deck, in: ctx, pictures: pictures)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        guard FileNaming.fileSize(out) > 0 else { throw OpError.failed(L("creazione del PDF")) }
        try PDFOps.neutralizeInfo(out, pages: deck.slides.count)   // on failure the job removes `out`
        return [out]
    }

    static func toImages(_ url: URL, type: UTType, dpi: CGFloat) throws -> [URL] {
        let deck = try open(url)
        guard let ext = ImageOps.fileExtension(for: type) else { throw OpError.unsupported(type.identifier) }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = deck.slides.count == 1 ? nil : try FileNaming.folder(for: url, suffix: "immagini")
        let scale = min(dpi / 72, Limits.maxRenderSide / max(deck.size.width, deck.size.height))
        let width = max(Int(deck.size.width * scale), 1), height = max(Int(deck.size.height * scale), 1)
        let pictures = PptxRenderer.Pictures()
        var outputs: [URL] = []
        for (i, slide) in deck.slides.enumerated() {
            try PDFOps.checkCancelled()
            var failure: Error?
            autoreleasepool {
                guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { failure = OpError.failed(L("creazione dell'immagine")); return }
                ctx.scaleBy(x: scale, y: scale)
                PptxRenderer.draw(slide, of: deck, in: ctx, pictures: pictures)
                guard let image = ctx.makeImage() else { failure = OpError.failed(L("creazione dell'immagine")); return }
                let out = folder.map { $0.appendingPathComponent("\(base) - s\(i + 1).\(ext)") } ?? FileNaming.output(for: url, ext: ext)
                do { try ImageOps.write(image, to: out, type: type, quality: 0.85); outputs.append(out) } catch { failure = error }
            }
            if let failure { throw failure }
        }
        try PDFOps.checkCancelled()
        return folder.map { [$0] } ?? outputs
    }

    /// The text of the slides, in order, with the speaker notes.
    static func text(_ deck: PptxReader.Deck) -> String {
        var blocks: [String] = []
        for (i, slide) in deck.slides.enumerated() {
            var lines: [String] = [L("Diapositiva %@", i + 1)]
            for item in slide.items where item.layer == 2 {
                switch item.content {
                case .shape(_, _, _, _, let text?): lines.append(text.plain)
                case .table(_, let rows): lines += rows.map { $0.cells.map { $0.text.plain.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
                default: break
                }
            }
            let notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { lines.append(L("Note") + ": " + notes) }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func toText(_ url: URL) throws -> [URL] {
        let deck = try open(url)
        let out = FileNaming.output(for: url, ext: "txt")
        try text(deck).write(to: out, atomically: true, encoding: .utf8)
        return [out]
    }

    // MARK: To PowerPoint

    /// One slide per page of the PDF: the page as a picture, with the page's text as alternative text.
    static func fromPDF(_ url: URL) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw OpError.unreadable(url) }
        guard !doc.isEncrypted || doc.isUnlocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        try PDFOps.confirmPages(doc.numberOfPages, of: url)
        _ = try PDFTextScan.check(url)
        try PDFTextScan.checkForDrawing(url)   // drawing a page can't be stopped halfway
        let words = PDFDocument(url: url)
        return try build(from: url, name: url.deletingPathExtension().lastPathComponent) { builder in
            for i in 1...doc.numberOfPages {
                try PDFOps.checkCancelled()
                var failure: Error?
                autoreleasepool {
                    guard let page = doc.page(at: i), let image = PDFOps.render(page, dpi: 150) else { return }
                    do { try builder.add(image, alt: words?.page(at: i - 1)?.string ?? "") } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
    }

    /// One slide per image, in natural filename order, the picture as large as the slide allows.
    static func fromImages(_ urls: [URL]) throws -> [URL] {
        let sorted = FileNaming.sortedNaturally(urls)
        guard let first = sorted.first else { throw OpError.failed(L("nessuna immagine valida")) }
        guard sorted.count <= PptxReader.maxSlides else { throw OpError.unsupported(L("troppe immagini (massimo %@)", PptxReader.maxSlides)) }
        let name = sorted.count == 1 ? first.deletingPathExtension().lastPathComponent : first.deletingLastPathComponent().lastPathComponent
        return try build(from: first, name: name) { builder in
            for url in sorted {
                try PDFOps.checkCancelled()
                var failure: Error?
                autoreleasepool {
                    do {
                        let image = try ImageOps.verifiedPageImage(url)
                        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw OpError.unreadable(url) }
                        try builder.add(cg, alt: url.deletingPathExtension().lastPathComponent)
                    } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
    }

    private static func build(from source: URL, name: String, _ fill: (PptxWriter.Builder) throws -> Void) throws -> [URL] {
        // In the app's own folder, not next to the result: a sync service could upload the pieces (C1).
        let work = ArchiveOps.protectedZipWork.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let builder = PptxWriter.Builder(folder: work)
        try fill(builder)
        let out = FileNaming.unique(FileNaming.directory(for: source).appendingPathComponent(name).appendingPathExtension("pptx"))
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        try builder.finish(to: temp)
        try FileNaming.replace(out, with: temp)
        return [out]
    }
}
