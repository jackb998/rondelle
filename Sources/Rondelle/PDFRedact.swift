import AppKit
import CoreGraphics
import PDFKit

/// Redaction that removes what it covers. A rectangle drawn over a PDF leaves the text under it, for anyone to select:
/// here a page with covered areas is rebuilt as a picture of itself, with the areas already black in its pixels, so
/// that no text, picture or note of the old page goes into the new file. The other pages are copied as they are; the
/// document's own information, bookmarks and attachments stay behind.
enum PDFRedact {
    struct Area: Sendable {
        let page: Int
        /// In the page's own coordinates.
        let rect: CGRect
    }

    static let dpi: CGFloat = 200
    static let maxSide: CGFloat = 5_000

    /// Every place `text` appears, line by line. Off the main thread is fine: a document of its own.
    static func areas(of text: String, in url: URL) throws -> [Area] {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        return areas(of: text, in: doc)
    }

    static func areas(of text: String, in doc: PDFDocument) -> [Area] {
        doc.findString(text, withOptions: [.caseInsensitive]).flatMap { found -> [Area] in
            found.selectionsByLine().flatMap { line in
                line.pages.compactMap { page in
                    let index = doc.index(for: page)
                    return index == NSNotFound ? nil : Area(page: index, rect: line.bounds(for: page))
                }
            }
        }
    }

    static func apply(_ url: URL, areas: [Area]) throws -> [URL] {
        guard !areas.isEmpty else { throw OpError.failed(L("nessuna parte da oscurare")) }
        try PDFTextScan.checkForDrawing(url)
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        guard !doc.isLocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        let byPage = Dictionary(grouping: areas, by: \.page)
        let clean = PDFDocument()
        var rebuilt: [PDFDocument] = []   // alive until the file is written: their pages are in `clean`
        var redacted: [Int] = []
        for i in 0..<doc.pageCount {
            try PDFOps.checkCancelled()
            try autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                if let covered = byPage[i] {
                    guard let single = picture(of: page, covering: covered.map(\.rect)), let new = single.page(at: 0) else {
                        throw OpError.failed(L("creazione del PDF"))
                    }
                    rebuilt.append(single)
                    clean.insert(new, at: clean.pageCount)
                    redacted.append(i)
                } else if let copy = page.copy() as? PDFPage {
                    clean.insert(copy, at: clean.pageCount)
                }
            }
        }
        try PDFOps.checkCancelled()
        clean.documentAttributes = [:]
        let out = FileNaming.output(for: url, ext: "pdf", suffix: L("oscurato"))
        guard clean.write(to: out) else { throw OpError.failed(L("scrittura del PDF")) }
        try PDFOps.neutralizeInfo(out, pages: clean.pageCount)
        // A file called redacted must be: read back, the rebuilt pages hold no text at all.
        guard let check = PDFDocument(url: out), check.pageCount == doc.pageCount,
              redacted.allSatisfy({ (check.page(at: $0)?.string ?? "").allSatisfy(\.isWhitespace) }) else {
            throw OpError.failed(L("verifica dell'oscuramento non riuscita: nessun file creato"))
        }
        return [out]
    }

    /// A one-page PDF holding only a JPEG of the page: the black is in the pixels before the JPEG is made.
    private static func picture(of page: PDFPage, covering rects: [CGRect]) -> PDFDocument? {
        let transform = page.transform(for: .cropBox)
        let shown = page.bounds(for: .cropBox).applying(transform)
        guard shown.width.isFinite, shown.height.isFinite, shown.width > 0, shown.height > 0 else { return nil }
        let scale = min(dpi / 72, maxSide / max(shown.width, shown.height))
        guard let bitmap = CGContext(data: nil, width: max(Int(shown.width * scale), 1), height: max(Int(shown.height * scale), 1),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        bitmap.saveGState()
        bitmap.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: bitmap)
        bitmap.restoreGState()
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            let area = rect.insetBy(dx: -0.5, dy: -0.5).applying(transform)
            bitmap.fill(CGRect(x: (area.minX - shown.minX) * scale, y: (area.minY - shown.minY) * scale, width: area.width * scale, height: area.height * scale))
        }
        guard let image = bitmap.makeImage(), let jpeg = PDFOps.jpegImage(image, quality: 0.9) else { return nil }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: shown.size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPage(mediaBox: &box)
        context.draw(jpeg, in: box)
        context.endPage()
        context.closePDF()
        return PDFDocument(data: data as Data)
    }
}

/// Where the areas to cover are chosen: dragging over the page or selecting its text, and searching for words.
@MainActor
final class RedactWindow: NSObject, NSSearchFieldDelegate {
    private static var open: [RedactWindow] = []
    private let url: URL
    private let doc: PDFDocument
    private let window: NSWindow
    private let pdfView = RedactPDFView()
    private let status = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L("Salva copia oscurata"), target: nil, action: nil)
    private let undoButton = NSButton(title: L("Togli l'ultima"), target: nil, action: nil)
    private var marks: [(area: PDFRedact.Area, preview: PDFAnnotation)] = []

    /// Checked off the main thread, before anything is drawn on it.
    static func open(_ urls: [URL]) {
        for url in urls.prefix(4) {
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) { try PDFTextScan.checkForDrawing(url) }.value
                    guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
                    guard !doc.isLocked else { throw OpError.unsupported(L("PDF protetto da password")) }
                    let window = RedactWindow(url: url, doc: doc)
                    open.append(window)
                    window.show()
                } catch {
                    Notice.show(title: L("Oscura"), text: error.localizedDescription)
                }
            }
        }
    }

    private init(url: URL, doc: PDFDocument) {
        self.url = url
        self.doc = doc
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = L("Oscura — %@", url.lastPathComponent)
        window.titlebarAppearsTransparent = true   // AppKit content: the title stays, the bar takes the window's colour
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Self.open.removeAll { $0 === self } }
        }

        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.onArea = { [weak self] page, rect in self?.mark(page: page, rect: rect) }
        pdfView.onSelection = { [weak self] selection in self?.mark(selection) }

        let tools = NSSegmentedControl(labels: [L("Trascina un'area"), L("Seleziona il testo")], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        tools.selectedSegment = 0
        let search = NSSearchField()
        search.placeholderString = L("Oscura ogni parola uguale a…")
        search.sendsWholeSearchString = true
        search.target = self
        search.action = #selector(searched(_:))
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        undoButton.target = self
        undoButton.action = #selector(removeLast)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [tools, search, spacer, undoButton, saveButton])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let foot = NSStackView(views: [status])
        foot.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        let column = NSStackView(views: [bar, pdfView, foot])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        for view in [bar, pdfView, foot] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        pdfView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = column
        window.center()
        refresh()
    }

    #if DEBUG
    /// The window as it looks with an area and a word marked (`--render-window oscura`).
    static func snapshot(_ url: URL, to path: String, word: String) -> Bool {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return false }
        let window = RedactWindow(url: url, doc: doc)
        window.mark(page: page, rect: CGRect(x: 56, y: 500, width: 300, height: 120))
        for area in PDFRedact.areas(of: word, in: doc) { window.mark(page: page, rect: area.rect) }
        window.window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        guard let view = window.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return true
    }
    #endif

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        let pages = Set(marks.map(\.area.page)).count
        status.stringValue = marks.isEmpty
            ? L("Il file originale non cambia. Le pagine oscurate diventano immagini: lì il testo non si potrà più selezionare.")
            : L("Parti da oscurare: %@, su %@ pagine. Le pagine oscurate diventano immagini; le altre restano come sono.", marks.count, pages)
        saveButton.isEnabled = !marks.isEmpty
        undoButton.isEnabled = !marks.isEmpty
    }

    /// The black square on screen is only a preview, on this document in memory: it is never what gets saved.
    private func mark(page: PDFPage, rect: CGRect) {
        let index = doc.index(for: page)
        guard index != NSNotFound, rect.width >= 2, rect.height >= 2 else { return }
        let preview = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        preview.color = .black
        preview.interiorColor = .black
        page.addAnnotation(preview)
        marks.append((PDFRedact.Area(page: index, rect: rect), preview))
        refresh()
    }

    private func mark(_ selection: PDFSelection) {
        for line in selection.selectionsByLine() {
            for page in line.pages { mark(page: page, rect: line.bounds(for: page)) }
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        pdfView.drawsAreas = sender.selectedSegment == 0
    }

    @objc private func searched(_ sender: NSSearchField) {
        let word = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        let found = PDFRedact.areas(of: word, in: doc)
        if found.isEmpty { status.stringValue = L("«%@» non compare nel testo. In una scansione trascina un'area sopra la parola.", word); return }
        for area in found {
            if let page = doc.page(at: area.page) { mark(page: page, rect: area.rect) }
        }
        sender.stringValue = ""
    }

    @objc private func removeLast() {
        guard let last = marks.popLast() else { return }
        doc.page(at: last.area.page)?.removeAnnotation(last.preview)
        refresh()
    }

    @objc private func save() {
        let areas = marks.map(\.area)
        window.close()
        JobRunner.run(WheelAction.each("Oscura", "rectangle.inset.filled") { try PDFRedact.apply($0, areas: areas) }, urls: [url])
    }
}

/// PDFView that draws areas with a drag, or hands over the text selected.
private final class RedactPDFView: PDFView {
    var drawsAreas = true
    var onArea: ((PDFPage, CGRect) -> Void)?
    var onSelection: ((PDFSelection) -> Void)?
    private var start: (page: PDFPage, point: CGPoint)?
    private let band = NSView()

    override func mouseDown(with event: NSEvent) {
        guard drawsAreas else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return }
        start = (page, self.convert(point, to: page))
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        band.frame = NSRect(origin: point, size: .zero)
        addSubview(band)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawsAreas else { super.mouseDragged(with: event); return }
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        let origin = convert(start.point, from: start.page)
        band.frame = NSRect(x: min(point.x, origin.x), y: min(point.y, origin.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard drawsAreas else {
            super.mouseUp(with: event)
            if let selection = currentSelection, !(selection.string ?? "").isEmpty {
                onSelection?(selection)
                clearSelection()
            }
            return
        }
        band.removeFromSuperview()
        guard let start else { return }
        self.start = nil
        let end = convert(convert(event.locationInWindow, from: nil), to: start.page)
        let rect = CGRect(x: min(start.point.x, end.x), y: min(start.point.y, end.y), width: abs(end.x - start.point.x), height: abs(end.y - start.point.y))
        onArea?(start.page, rect.intersection(start.page.bounds(for: .cropBox)))
    }
}
