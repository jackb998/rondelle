import AppKit
import CoreText
import PDFKit

/// PDF password, page numbers and watermark.
enum PDFTools {
    // MARK: Password

    /// PDFKit encrypts with 128-bit RC4 (the same as Preview): a long password is what keeps it safe.
    static let minPasswordLength = 8

    static func protect(_ url: URL, password: String, hint: String? = nil, hintInName: Bool = false) throws -> [URL] {
        guard password.count >= minPasswordLength else {
            throw OpError.failed(L("la password deve avere almeno %@ caratteri", minPasswordLength))
        }
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        guard !doc.isEncrypted else {
            throw OpError.unsupported(L("«%@» è già protetto: toglila prima con «Sblocca»", url.lastPathComponent))
        }
        let out = FileNaming.output(for: url, ext: "pdf", suffix: PasswordHint.nameSuffix(hint, inName: hintInName))
        guard doc.write(to: out, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
            throw OpError.failed(L("scrittura del PDF"))
        }
        if let hint { try PasswordHint.writeToPDF(out, hint: hint) }
        return [out]
    }

    /// Needs the owner's password: the one that only opens the file can't lift the restrictions set with it.
    /// The pages are copied into a new document, since PDFKit re-encrypts a document it has unlocked.
    static func unlock(_ url: URL, password: String) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        guard doc.isEncrypted else { throw OpError.unsupported(L("«%@» non ha una password", url.lastPathComponent)) }
        guard doc.unlock(withPassword: password) else { throw OpError.failed(L("password errata")) }
        guard doc.permissionsStatus == .owner else {
            throw OpError.failed(L("questa password apre il PDF ma non permette di togliere la protezione: serve quella del proprietario"))
        }
        try PDFOps.confirmPages(doc.pageCount, of: url)
        try PDFTextScan.checkForRewriting(url, password: password)
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            try PDFOps.checkCancelled()
            if let page = doc.page(at: i)?.copy() as? PDFPage { clean.insert(page, at: clean.pageCount) }
        }
        clean.documentAttributes = doc.documentAttributes
        let out = FileNaming.output(for: url, ext: "pdf", suffix: L("senza password"))
        guard clean.write(to: out) else { throw OpError.failed(L("scrittura del PDF")) }
        try? PDFOps.neutralizeInfo(out, pages: clean.pageCount)   // as «Numeri»: the pages are the job here
        return [out]
    }

    // MARK: Rotation

    /// Every page turned clockwise by `degrees`, in a new file. One page at a time: «Organizza».
    static func rotate(_ url: URL, degrees: Int, suffix: String) throws -> [URL] {
        try PDFTextScan.checkForRewriting(url)
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        guard !doc.isLocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        try PDFOps.confirmPages(doc.pageCount, of: url)
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            try PDFOps.checkCancelled()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + degrees) % 360
            clean.insert(page, at: clean.pageCount)
        }
        guard clean.pageCount > 0 else { throw OpError.unreadable(url) }
        let out = FileNaming.output(for: url, ext: "pdf", suffix: L(suffix))
        guard clean.write(to: out) else { throw OpError.failed(L("scrittura del PDF")) }
        try? PDFOps.neutralizeInfo(out, pages: clean.pageCount)   // as «Numeri»: the pages are the job here
        return [out]
    }

    // MARK: Stamps

    /// Number at the bottom centre of every page.
    static func pageNumbers(_ url: URL) throws -> [URL] {
        try stamp(url, suffix: "numerato") { ctx, box, number, _ in
            let size = max(8, min(box.width, box.height) * 0.018)
            let line = textLine("\(number)", size: size, color: CGColor(gray: 0.15, alpha: 1))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: box.midX - width / 2, y: box.minY + max(box.height * 0.03, size))
            CTLineDraw(line, ctx)
        }
    }

    /// Text across every page, diagonal and translucent, drawn into the page itself (not an annotation).
    static func watermark(_ url: URL, text: String) throws -> [URL] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpError.failed(L("testo della filigrana vuoto")) }
        guard text.count <= 100 else { throw OpError.failed(L("testo della filigrana troppo lungo (massimo 100 caratteri)")) }
        return try stamp(url, suffix: "filigrana") { ctx, box, _, _ in
            let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
            // Sized so the text spans about 70% of the diagonal.
            let probe = textLine(text, size: 100, color: .black)
            let size = min(100 * diagonal * 0.7 / max(CTLineGetTypographicBounds(probe, nil, nil, nil), 1), box.height / 4)
            let line = textLine(text, size: size, color: CGColor(gray: 0.5, alpha: 0.3))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            ctx.saveGState()
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: atan2(box.height, box.width))
            ctx.textPosition = CGPoint(x: -width / 2, y: (descent - ascent) / 2)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// Redraws every page upright into a new PDF and lets `draw` add to it. The pages keep their text and
    /// vector graphics; links, form fields and bookmarks are not carried over.
    private static func stamp(_ url: URL, suffix: String,
                              draw: (CGContext, CGRect, _ number: Int, _ count: Int) -> Void) throws -> [URL] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw OpError.unreadable(url) }
        guard !doc.isEncrypted else {
            throw OpError.unsupported(L("PDF protetto da password: toglila prima con «Sblocca»"))
        }
        try PDFOps.confirmPages(doc.numberOfPages, of: url)
        try PDFTextScan.checkForDrawing(url)   // drawing a page can't be stopped halfway
        let out = FileNaming.output(for: url, ext: "pdf", suffix: suffix)
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw OpError.failed(L("creazione del PDF")) }
        let count = doc.numberOfPages
        for number in 1...count {
            try PDFOps.checkCancelled()
            autoreleasepool {
                guard let page = doc.page(at: number) else { return }
                var box = CGRect(origin: .zero, size: PDFOps.displaySize(page))
                ctx.beginPage(mediaBox: &box)
                ctx.saveGState()
                ctx.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(page)
                ctx.restoreGState()
                draw(ctx, box, number, count)
                ctx.endPage()
            }
        }
        ctx.closePDF()
        try PDFOps.checkCancelled()   // during the last page: `cleaningUpOnFailure` removes the result
        // Producer and dates as in «Metadati», not macOS's version and the exact time (0.7.1-A7). Best effort:
        // numbering a page is the job here, so a layout that can't be patched keeps them.
        try? PDFOps.neutralizeInfo(out, pages: count)
        return [out]
    }

    private static func textLine(_ text: String, size: CGFloat, color: CGColor) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}
