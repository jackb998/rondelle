import AppKit
import CoreText
import PDFKit
import Vision

@MainActor
enum Clipboard {
    /// Copies text for this Mac only: OCR'd documents and QR codes can be private, so they
    /// aren't sent to the iPhone or iPad through Universal Clipboard.
    static func copyLocally(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }
}

/// OCR with Apple's Vision, entirely on device.
enum TextRecognition {
    static let languages = ["it-IT", "en-US", "fr-FR", "de-DE", "es-ES", "pt-BR"]

    struct Line {
        let text: String
        /// Normalised box (0…1, origin bottom-left).
        let box: CGRect
    }

    /// The models tried in order. The current accurate model sometimes fails to start (macOS 27.0.1:
    /// "e5rtError 13"); the previous accurate revision is as precise, the fast one is the last resort.
    /// A model that failed is skipped until the app quits.
    private enum Model: CaseIterable {
        case accurate, accuratePrevious, fast
    }

    static func lines(in image: CGImage) throws -> [Line] {
        var lastError: Error = OpError.failed(L("riconoscimento del testo"))
        for model in Model.allCases where !failed.contains(model) {
            do {
                return try recognize(image, model)
            } catch {
                failed.insert(model)
                lastError = error
            }
        }
        throw lastError
    }

    /// The first recognition after the Mac starts waits ≈ 30 s while macOS prepares the model; doing it in the
    /// background at launch means «Testo» and «OCR» answer at once later.
    static func warmUp() {
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let size = CGSize(width: 240, height: 60)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            let font = CTFontCreateUIFontForLanguage(.system, 28, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 28, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            ctx.textPosition = CGPoint(x: 12, y: 18)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Rondelle", attributes: attributes)), ctx)
            if let image = ctx.makeImage() { _ = try? lines(in: image) }
        }
    }

    private final class FailedModels: @unchecked Sendable {
        private let lock = NSLock()
        private var models: Set<Model> = []
        func contains(_ model: Model) -> Bool { lock.lock(); defer { lock.unlock() }; return models.contains(model) }
        func insert(_ model: Model) { lock.lock(); models.insert(model); lock.unlock() }
    }
    private static let failed = FailedModels()

    private static func recognize(_ image: CGImage, _ model: Model) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        switch model {
        case .accurate:
            request.recognitionLevel = .accurate
        case .accuratePrevious:
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequestRevision2
        case .fast:
            request.recognitionLevel = .fast
        }
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Line(text: $0.string, box: observation.boundingBox) }
        }
    }

    /// Text of a photo or screenshot: saved as .txt and copied to the clipboard.
    static func imageToText(_ url: URL) async throws -> [URL] {
        let text = try lines(in: ImageTools.load(url).image).map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw OpError.failed(L("nessun testo riconosciuto in «%@»", url.lastPathComponent)) }
        let out = FileNaming.output(for: url, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        await MainActor.run { Clipboard.copyLocally(text) }
        return [out]
    }

    /// «Copia testo»: the text of the images on the clipboard and no file; the result card says so.
    static func copyImagesText(_ urls: [URL]) async throws -> [URL] {
        var parts: [String] = []
        for url in FileNaming.sortedNaturally(urls) {
            try PDFOps.checkCancelled()
            let text = try lines(in: ImageTools.load(url).image).map(\.text).joined(separator: "\n")
            if !text.isEmpty { parts.append(text) }
        }
        guard !parts.isEmpty else {
            throw OpError.failed(urls.count == 1 ? L("nessun testo riconosciuto in «%@»", urls[0].lastPathComponent) : L("nessun testo riconosciuto"))
        }
        let text = parts.joined(separator: "\n\n")
        await MainActor.run { Clipboard.copyLocally(text) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["RONDELLE_PRINT_TEXT"] != nil { print(text) }
        #endif
        return []
    }

    /// Text of a PDF: the embedded text if there is some, otherwise OCR of every page.
    static func pdfToText(_ url: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        try PDFTextScan.check(url)
        var text = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { try PDFTextScan.warnHiddenTextOnce() }
        if text.isEmpty, let cg = CGPDFDocument(url as CFURL), cg.numberOfPages > 0 {
            try PDFOps.confirmPages(cg.numberOfPages, of: url)
            text = try (1...cg.numberOfPages).compactMap { i -> String? in
                try PDFOps.checkCancelled()
                guard let page = cg.page(at: i), let image = PDFOps.render(page, dpi: 200) else { return nil }
                return try lines(in: image).map(\.text).joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        guard !text.isEmpty else { throw OpError.failed(L("nessun testo trovato")) }
        let out = FileNaming.output(for: url, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return [out]
    }

    /// Scanned PDF → the same pages with an invisible text layer on top: searchable and selectable.
    static func searchablePDF(_ url: URL) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw OpError.unreadable(url) }
        guard !doc.isEncrypted || doc.isUnlocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        try PDFOps.confirmPages(doc.numberOfPages, of: url)
        try PDFTextScan.checkForDrawing(url)   // drawing a page can't be stopped halfway
        let out = FileNaming.output(for: url, ext: "pdf", suffix: "ricercabile")
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw OpError.failed(L("creazione del PDF")) }
        var found = 0
        for i in 1...doc.numberOfPages {
            guard (try? PDFOps.checkCancelled()) != nil else {
                ctx.closePDF()
                try? FileManager.default.removeItem(at: out)   // a half-made PDF is no use
                throw CancellationError()
            }
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.cropBox)
            let size = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            var media = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &media)
            // The original page, untouched (vector text and images stay as they were).
            ctx.saveGState()
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: media, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            // Invisible text where Vision read it.
            if let image = PDFOps.render(page, dpi: 200) {
                for line in try lines(in: image) {
                    drawInvisible(line, in: media, context: ctx)
                    found += 1
                }
            }
            ctx.endPage()
        }
        ctx.closePDF()
        try PDFOps.checkCancelled()   // during the last page: `cleaningUpOnFailure` removes the result
        guard found > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw OpError.failed(L("nessun testo riconosciuto"))
        }
        try? PDFOps.neutralizeInfo(out, pages: doc.numberOfPages)   // as «Numeri»: the pages are the job here
        return [out]
    }

    /// Text sized to its box and drawn in invisible mode, so viewers can find and select it.
    private static func drawInvisible(_ line: Line, in page: CGRect, context: CGContext) {
        let rect = CGRect(x: line.box.minX * page.width, y: line.box.minY * page.height,
                          width: line.box.width * page.width, height: line.box.height * page.height)
        guard rect.width > 1, rect.height > 1 else { return }
        var font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
        var ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        if natural > 0 {
            // Stretch the font so the line spans the same width as on the page.
            font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85 * min(rect.width / natural, 3), nil)
            ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}
