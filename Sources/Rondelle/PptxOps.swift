import AppKit
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PowerPoint (PPTX): to PDF, images and text, and from PDFs and images (one slide each). See `PptxReader` for what
/// is read and `PptxRenderer` for how it is drawn. A PPTX made here has one picture per slide: it looks like the
/// page, and the page's text goes in the picture's alternative text; it is not editable text.
enum PptxOps {
    // MARK: Limits

    /// Bytes of distinct pictures that go into a Keynote file made from a PPTX (cropped pictures are new PNGs).
    static let maxPictureBytes = 400_000_000

    /// A PPTX is a ZIP: 50 MB of it is accepted, the XML parts are bounded as for Word (`ContentLimits`).
    static func check(_ url: URL) throws {
        guard FileNaming.fileSize(url) <= Limits.maxDocumentBytes else {
            throw OpError.unsupported(L("«%@» supera %@ MB, il massimo per i documenti di questo tipo", url.lastPathComponent, Limits.maxDocumentBytes / 1_000_000))
        }
        try ContentLimits.check(url)
    }

    private static func open(_ url: URL) throws -> PptxReader.Deck {
        let isKeynote = url.pathExtension.lowercased() == "key"
        if !isKeynote { try check(url) }
        let deck = isKeynote ? try KeynoteReader.read(url) : try PptxReader.read(url)
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
                case .shape(_, _, _, _, let text?):
                    // A list's bullet or number stays in the text.
                    lines.append(text.paragraphs.map { p in (p.bullet.map { $0 + " " } ?? "") + p.runs.map(\.text).joined() }.joined(separator: "\n"))
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

    // MARK: To Keynote

    /// The text of the slides as Keynote slides: the biggest text of a slide is its title, the other texts (top to bottom,
    /// left to right) are the body, a table's rows are body lines, the notes are the notes. Pictures and looks stay out.
    static func keynoteSlides(_ deck: PptxReader.Deck) -> [KeynoteWriter.Slide] {
        // Every picture is read once (by its path in the package and its crop), and the same bytes (by digest) are
        // one Data shared by all the slides that use them; past `maxPictureBytes` of distinct pictures the others stay out.
        var read: [String: KeynoteWriter.Picture?] = [:]
        var byDigest: [SHA256.Digest: Data] = [:]
        var distinct = 0
        return deck.slides.map { slide in
            var boxes: [(frame: PptxReader.Frame, size: Double, lines: [String])] = []
            for item in slide.items where item.layer == 2 {
                switch item.content {
                case .shape(_, _, _, _, let text?) where !text.isEmpty:
                    let lines = text.paragraphs.map { $0.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let size = text.paragraphs.first { !$0.runs.isEmpty }?.runs.first?.size ?? 0
                    if !lines.isEmpty { boxes.append((item.frame, size, lines)) }
                case .table(_, let rows):
                    let lines = rows.map { $0.cells.map { $0.text.plain.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") }
                    boxes.append((item.frame, 0, lines))
                default: break
                }
            }
            var title: [String] = []
            if let at = boxes.indices.filter({ boxes[$0].size > 0 }).max(by: { (boxes[$0].size, -boxes[$0].frame.y) < (boxes[$1].size, -boxes[$1].frame.y) }) {
                title = boxes.remove(at: at).lines
            }
            boxes.sort { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
            var pictures: [KeynoteWriter.Picture] = []
            for item in slide.items where item.layer == 2 {
                guard case .picture(let path, let crop, _) = item.content, item.frame.w > 0, item.frame.h > 0 else { continue }
                let key = "\(path)|\(crop.l),\(crop.t),\(crop.r),\(crop.b)"
                if read[key] == nil {
                    var picture = keynotePicture(deck, path: path, crop: crop, frame: item.frame)
                    if let p = picture {
                        let digest = SHA256.hash(data: p.data)
                        if let known = byDigest[digest] {
                            picture?.data = known
                        } else if distinct + p.data.count <= maxPictureBytes {
                            byDigest[digest] = p.data
                            distinct += p.data.count
                        } else {
                            picture = nil
                        }
                    }
                    read[key] = .some(picture)
                }
                if var picture = read[key] ?? nil {
                    picture.frame = CGRect(x: item.frame.x, y: item.frame.y, width: item.frame.w, height: item.frame.h)
                    pictures.append(picture)
                }
            }
            return KeynoteWriter.Slide(title: title.joined(separator: " "), body: boxes.flatMap(\.lines),
                                       notes: slide.notes.trimmingCharacters(in: .whitespacesAndNewlines), pictures: pictures)
        }
    }

    /// A slide's picture as a file Keynote reads: JPEG and PNG as they are, anything else (and a cropped picture) as PNG.
    /// Pictures that the system can't decode (EMF, WMF, SVG) are left out.
    private static func keynotePicture(_ deck: PptxReader.Deck, path: String, crop: PptxReader.Crop, frame: PptxReader.Frame) -> KeynoteWriter.Picture? {
        guard let data = deck.imageData(path), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0,
              w * h <= PptxRenderer.Pictures.maxPixels, let type = CGImageSourceGetType(source) as String? else { return nil }
        let cropped = crop.l + crop.t + crop.r + crop.b > 0 && crop.l + crop.r < 1 && crop.t + crop.b < 1
        var bytes = data, ext = type == "public.jpeg" ? "jpg" : (type == "public.png" ? "png" : "")
        var pixels = CGSize(width: w, height: h)
        if cropped || ext.isEmpty {
            guard var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            if cropped {
                let part = CGRect(x: crop.l * Double(w), y: crop.t * Double(h), width: (1 - crop.l - crop.r) * Double(w), height: (1 - crop.t - crop.b) * Double(h)).integral
                guard let piece = image.cropping(to: part) else { return nil }
                image = piece
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            bytes = out as Data
            ext = "png"
            pixels = CGSize(width: image.width, height: image.height)
        }
        return KeynoteWriter.Picture(data: bytes, ext: ext, pixels: pixels, frame: CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h))
    }

    /// A PowerPoint file as a Keynote file: one slide per slide, with its text and notes.
    static func toKeynote(_ url: URL) throws -> [URL] {
        let deck = try open(url)
        let out = FileNaming.output(for: url, ext: "key")
        try KeynoteWriter.write(keynoteSlides(deck), sourceSize: deck.size, to: out)
        return [out]
    }

    // MARK: To PowerPoint

    /// A Keynote file as a PowerPoint one: every slide drawn as a picture, with the slide's text as its alternative text.
    static func fromKeynote(_ url: URL) throws -> [URL] {
        let deck = try open(url)
        let scale = min(2.0, Limits.maxRenderSide / max(deck.size.width, deck.size.height))
        let width = max(Int(deck.size.width * scale), 1), height = max(Int(deck.size.height * scale), 1)
        let pictures = PptxRenderer.Pictures()
        return try build(from: url, name: url.deletingPathExtension().lastPathComponent) { builder in
            for slide in deck.slides {
                try PDFOps.checkCancelled()
                var failure: Error?
                autoreleasepool {
                    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { failure = OpError.failed(L("creazione dell'immagine")); return }
                    ctx.scaleBy(x: scale, y: scale)
                    PptxRenderer.draw(slide, of: deck, in: ctx, pictures: pictures)
                    guard let image = ctx.makeImage() else { failure = OpError.failed(L("creazione dell'immagine")); return }
                    var lines: [String] = []
                    for item in slide.items { if case .shape(_, _, _, _, let text?) = item.content { lines.append(text.plain) } }
                    do { try builder.add(image, alt: lines.joined(separator: "\n")) } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
    }


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
