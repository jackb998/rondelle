import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image tools beyond plain re-encoding: geometry, Vision, collage, target size.
enum ImageTools {
    // MARK: Loading

    /// Full-size image with EXIF orientation applied, plus its type and metadata.
    static func load(_ url: URL) throws -> (image: CGImage, type: UTType, properties: [CFString: Any]) {
        let (raw, orientation, type, props) = try loadRaw(url)
        guard let image = orientation == .up ? raw : upright(raw, orientation) else { throw OpError.unreadable(url) }
        return (image, type, props)
    }

    /// The image as stored (decoded lazily, piece by piece, when drawn) and the EXIF orientation to apply,
    /// so callers that draw it anyway can rotate it in the same draw.
    static func loadRaw(_ url: URL) throws
        -> (raw: CGImage, orientation: CGImagePropertyOrientation, type: UTType, properties: [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw OpError.unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        try ImageOps.checkPixelCount(width: width, height: height, url: url)
        // Turned upright with a single draw: one copy of the pixels in memory instead of the two of an upright
        // full-size thumbnail.
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(props[kCGImagePropertyOrientation] as? Int ?? 1)) ?? .up
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw OpError.unreadable(url)
        }
        let type = ImageOps.keptType(CGImageSourceGetType(source).flatMap { UTType($0 as String) })
        var clean = props
        clean[kCGImagePropertyOrientation] = 1
        if var tiff = clean[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            clean[kCGImagePropertyTIFFDictionary] = tiff
        }
        return (raw, orientation, type, clean)
    }

    /// Draws `raw` as EXIF `orientation` says it should be shown.
    private static func upright(_ raw: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        let sideways = orientation.rawValue >= 5
        guard let ctx = context(width: sideways ? raw.height : raw.width, height: sideways ? raw.width : raw.height,
                                like: raw) else { return nil }
        ctx.concatenate(CIImage(cgImage: raw).orientationTransform(for: orientation))
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        return ctx.makeImage()
    }

    /// Bitmap context in the image's own RGB colour space (keeps Display P3 photos wide-gamut).
    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Geometry

    /// The five ways «Ruota» turns or flips a photo (the group of the image wheel).
    enum Turn: CaseIterable {
        case right, left, half, mirrorHorizontal, mirrorVertical

        /// New EXIF orientation = table[old − 1]. `right` and `mirrorHorizontal` checked pixel by pixel against ImageIO
        /// for all 8 orientations (0.7); the others are their compositions (left = right³, half = right², vertical =
        /// half ∘ horizontal), checked the same way by --test-rotations.
        var table: [Int] {
            switch self {
            case .right: return [6, 7, 8, 5, 2, 3, 4, 1]
            case .left: return [8, 5, 6, 7, 4, 1, 2, 3]
            case .half: return [3, 4, 1, 2, 7, 8, 5, 6]
            case .mirrorHorizontal: return [2, 1, 4, 3, 6, 5, 8, 7]
            case .mirrorVertical: return [4, 3, 2, 1, 8, 7, 6, 5]
            }
        }

        var suffix: String { self == .mirrorHorizontal || self == .mirrorVertical ? "specchiata" : "ruotata" }
        var swapsSides: Bool { self == .right || self == .left }

        /// The same turn on the pixels, in Core Graphics coordinates (origin bottom left), for the upright size.
        func apply(_ ctx: CGContext, _ size: CGSize) {
            switch self {
            case .right:   // clockwise: up by the new height, then −90°
                ctx.translateBy(x: 0, y: size.width)
                ctx.rotate(by: -.pi / 2)
            case .left:    // counterclockwise: right by the new width, then +90°
                ctx.translateBy(x: size.height, y: 0)
                ctx.rotate(by: .pi / 2)
            case .half:
                ctx.translateBy(x: size.width, y: size.height)
                ctx.rotate(by: .pi)
            case .mirrorHorizontal:
                ctx.translateBy(x: size.width, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            case .mirrorVertical:
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
        }
    }

    static func turn(_ url: URL, _ turn: Turn) throws -> [URL] {
        if let out = try reorient(url, suffix: turn.suffix, table: turn.table) { return out }
        return try redraw(url, suffix: turn.suffix, swapSides: turn.swapsSides, transform: turn.apply)
    }

    static func rotateRight(_ url: URL) throws -> [URL] { try turn(url, .right) }
    static func mirror(_ url: URL) throws -> [URL] { try turn(url, .mirrorHorizontal) }

    /// JPEG, HEIC and TIFF with one image: only the EXIF orientation changes (new = table[old − 1]) and the
    /// image data is copied as it is — no re-encoding, next to no memory. Tables checked pixel by pixel against
    /// ImageIO for all 8 orientations. Nil when this isn't possible: the caller redraws the pixels instead.
    private static func reorient(_ url: URL, suffix: String, table: [Int]) throws -> [URL]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let typeID = CGImageSourceGetType(source), let type = UTType(typeID as String),
              [UTType.jpeg, .heic, .tiff].contains(where: { type.conforms(to: $0) }) else { return nil }
        try ImageOps.checkPixelCount(of: url)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let current = props[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(current) else { return nil }
        // The lossless copy keeps all the metadata: with a position to leave out (GPS, IPTC or XMP place), redraw
        // instead (0.8-C2, 0.8.2-G2).
        if Settings.removeLocation, ImageOps.hasLocation(source, props) { return nil }
        // The copy would also keep what isn't the picture: an EXIF thumbnail (which may show something else),
        // data after the image (a Motion Photo's video), depth and gain maps (0.8.3-R1–R3).
        if ImageOps.hasHiddenExtras(source, url) { return nil }
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                           kCGImagePropertyTIFFOrientation, table[current - 1] as CFNumber) else { return nil }
        let out = FileNaming.output(for: url, ext: ImageOps.fileExtension(for: type) ?? url.pathExtension, suffix: suffix)
        let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary
        // Some formats accept the copy but ignore the new orientation (HEIC): read it back before trusting it.
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, typeID, 1, nil),
              CGImageDestinationCopyImageSource(dest, source, options, nil),
              let written = CGImageSourceCreateWithURL(out as CFURL, nil),
              (CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
                == table[current - 1] else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return [out]
    }

    private static func redraw(_ url: URL, suffix: String, swapSides: Bool,
                               transform: (CGContext, _ upright: CGSize) -> Void) throws -> [URL] {
        // One draw does both the EXIF orientation and the tool's own rotation or mirroring.
        let (raw, orientation, type, props) = try loadRaw(url)
        let sideways = orientation.rawValue >= 5
        let upright = CGSize(width: sideways ? raw.height : raw.width, height: sideways ? raw.width : raw.height)
        let width = Int(swapSides ? upright.height : upright.width)
        let height = Int(swapSides ? upright.width : upright.height)
        guard let ctx = context(width: width, height: height, like: raw) else { throw OpError.failed("disegno") }
        ctx.interpolationQuality = .high
        transform(ctx, upright)
        ctx.concatenate(CIImage(cgImage: raw).orientationTransform(for: orientation))
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard let result = ctx.makeImage() else { throw OpError.failed("disegno") }
        let out = FileNaming.output(for: url, ext: ImageOps.fileExtension(for: type) ?? "png", suffix: suffix)
        try ImageOps.write(result, to: out, type: type, quality: 0.92, properties: props)
        return [out]
    }

    // MARK: Vision

    /// Reads QR codes and barcodes; shows the text and copies it to the clipboard.
    static func readCodes(_ url: URL) async throws -> [URL] {
        let (image, _, _) = try load(url)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !payloads.isEmpty else { throw OpError.failed(L("nessun codice QR trovato in «%@»", url.lastPathComponent)) }
        let text = payloads.joined(separator: "\n")
        await MainActor.run {
            Clipboard.copyLocally(text)
            Notice.show(title: payloads.count == 1 ? L("Codice QR (copiato negli appunti)") : L("%@ codici (copiati negli appunti)", payloads.count),
                        text: text)
        }
        return []
    }

    /// Cuts out the subject (people, animals, objects) and saves a transparent PNG.
    @available(macOS 14.0, *)
    static func removeBackground(_ url: URL) throws -> [URL] {
        let (image, _, _) = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw OpError.failed(L("nessun soggetto trovato"))
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let cutout = CIContext().createCGImage(masked, from: masked.extent) else {
            throw OpError.failed(L("creazione dell'immagine"))
        }
        let out = FileNaming.output(for: url, ext: "png", suffix: L("senza sfondo"))
        try ImageOps.write(cutout, to: out, type: .png)
        return [out]
    }

    // MARK: Target size

    /// Largest quality (then, if needed, smaller dimensions) that fits under `maxBytes`.
    static func fit(_ url: URL, maxBytes: Int) throws -> [URL] {
        guard FileNaming.fileSize(url) > maxBytes else { throw OpError.alreadySmall }
        var (image, type, _) = try load(url)
        let lossy: [UTType] = [.jpeg, .heic]
        if !lossy.contains(where: { type.conforms(to: $0) }) {
            type = .jpeg
            image = ImageOps.flatten(image) ?? image
        }

        for _ in 0..<8 {
            var low: CGFloat = 0.05, high: CGFloat = 0.95
            var best: Data?
            for _ in 0..<7 {
                let quality = (low + high) / 2
                guard let data = encode(image, type: type, quality: quality) else { break }
                if data.count <= maxBytes { best = data; low = quality } else { high = quality }
            }
            if best == nil, let data = encode(image, type: type, quality: low), data.count <= maxBytes { best = data }
            if let best {
                let label = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
                let out = FileNaming.output(for: url, ext: ImageOps.fileExtension(for: type) ?? "jpg", suffix: label)
                try best.write(to: out)
                return [out]
            }
            guard let smaller = scaled(image, by: 0.75) else { break }
            image = smaller
        }
        throw OpError.failed(L("impossibile scendere sotto la dimensione richiesta"))
    }

    static func encode(_ image: CGImage, type: UTType, quality: CGFloat) -> Data? {
        if ImageOps.needsWebPEncoder(type) { return try? WebPEncoder.data(image, quality: quality) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(Int(CGFloat(image.width) * factor), 1)
        let height = max(Int(CGFloat(image.height) * factor), 1)
        guard let ctx = context(width: width, height: height, like: image) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

@MainActor
enum Notice {
    static func show(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Yes/no question from any thread (jobs run in the background); false when `Prompts.allowed` is off.
    nonisolated static func confirm(title: String, text: String, button: String) -> Bool {
        guard Prompts.allowed else { return false }
        let ask: @Sendable () -> Bool = {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = text
                alert.addButton(withTitle: button)
                alert.addButton(withTitle: L("Annulla"))
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
        return Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
    }

    enum WarningAnswer: Sendable { case proceed, change, cancel }

    /// A warning with an «Altro» disclosure under the text that shows `details` (a few lines, on demand), and three
    /// answers: go ahead, change (`change` button), cancel. Escape cancels, as when nobody can answer.
    nonisolated static func warn(title: String, text: String, details: String, proceed: String, change: String) -> WarningAnswer {
        guard Prompts.allowed else { return .cancel }
        let ask: @Sendable () -> WarningAnswer = {
            MainActor.assumeIsolated {
                let alert = detailsAlert(title: title, text: text, details: details, buttons: [proceed, change])
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn: return .proceed
                case .alertSecondButtonReturn: return .change
                default: return .cancel
                }
            }
        }
        return Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
    }

    /// `askPassword` from any thread (jobs run in the background); nil if cancelled or nobody can answer.
    nonisolated static func askPasswordFromJob(_ question: String, twice: Bool, withHint: Bool = false) -> String? {
        guard Prompts.allowed else { return nil }
        let ask: @Sendable () -> String? = { MainActor.assumeIsolated { askPassword(question, twice: twice, withHint: withHint) } }
        return Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
    }

    /// The alert of `warn`, also used by the DEBUG snapshot of it: `buttons`, then «Annulla» (Escape).
    static func detailsAlert(title: String, text: String, details: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.addButton(withTitle: L("Annulla"))
        // A warning: every answer takes a deliberate click (no Return button: macOS would also move it to the top),
        // Escape cancels. The buttons keep the order they were added in.
        alert.buttons.forEach { $0.keyEquivalent = "" }
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.accessoryView = DetailsDisclosure(details: details) { [weak alert] in alert?.layout() }
        return alert
    }

    /// Asks for a value before a job starts; nil if cancelled.
    static func ask(_ question: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("Annulla"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Asks for a password in hidden fields; with `twice`, until both fields match. Nil if cancelled.
    /// A question with a second line shows it as a note under the title (e.g. how the file can be opened).
    /// With `withHint` there is an optional hint too, and the answer is `PasswordHint.answer(password:hint:)`.
    static func askPassword(_ question: String, twice: Bool, withHint: Bool = false) -> String? {
        var problem: String?
        while true {
            let form = passwordForm(question, problem: problem, twice: twice, withHint: withHint)
            NSApp.activate(ignoringOtherApps: true)
            guard form.alert.runModal() == .alertFirstButtonReturn else { return nil }
            let password = form.first.stringValue
            if twice, password != form.second.stringValue {
                problem = L("Le due password non coincidono: riprova.")
                continue
            }
            guard withHint else { return password }
            let hint = PasswordHint.clean(form.hint.stringValue)
            if let wrong = PasswordHint.problem(hint: hint, password: password) {
                problem = wrong
                continue
            }
            return PasswordHint.answer(password: password, hint: hint, inName: form.inName.state == .on)
        }
    }

    /// The password alert and its fields (also used by its DEBUG snapshot).
    static func passwordForm(_ question: String, problem: String?, twice: Bool, withHint: Bool)
        -> (alert: NSAlert, first: NSSecureTextField, second: NSSecureTextField, hint: NSTextField, inName: NSButton) {
        let lines = question.split(separator: "\n", maxSplits: 1).map(String.init)
        let alert = NSAlert()
        alert.messageText = lines.first ?? question
        alert.informativeText = problem ?? (lines.count > 1 ? lines[1] : "")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("Annulla"))
        let width: CGFloat = 260
        let note = NSTextField(wrappingLabelWithString: L("Facoltativo. Chiunque abbia il file può leggerlo anche senza password: non scriverci la password."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 0, y: 26, width: width, height: 44)
        let hint = NSTextField(frame: NSRect(x: 0, y: 74, width: width, height: 24))
        hint.placeholderString = L("Suggerimento per ricordarla")
        let inName = NSButton(checkboxWithTitle: L("Mostralo anche nel nome del file"), target: nil, action: nil)
        inName.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        inName.frame = NSRect(x: 0, y: 0, width: width - 26, height: 20)
        let help = HintNameHelp(frame: NSRect(x: width - 22, y: -1, width: 22, height: 22))
        // Each row sits on the one below it; the hint, its note and its checkbox are only there when asked for.
        let bottom: CGFloat = withHint ? 104 : 0
        let second = NSSecureTextField(frame: NSRect(x: 0, y: bottom, width: width, height: 24))
        let first = NSSecureTextField(frame: NSRect(x: 0, y: bottom + (twice ? 30 : 0), width: width, height: 24))
        first.placeholderString = L("Password")
        second.placeholderString = L("Ripeti la password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: width, height: first.frame.maxY))
        fields.addSubview(first)
        if twice {
            fields.addSubview(second)
            first.nextKeyView = second
        }
        if withHint {
            fields.addSubview(hint)
            fields.addSubview(note)
            fields.addSubview(inName)
            fields.addSubview(help)
            (twice ? second : first).nextKeyView = hint
        }
        alert.accessoryView = fields
        alert.window.initialFirstResponder = first
        return (alert, first, second, hint, inName)
    }
}

/// The «?» next to «Mostralo anche nel nome del file»: where the hint can be seen, in a popover.
final class HintNameHelp: NSButton {
    private let popover = NSPopover()

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(show)
        toolTip = L("Dove si vede il suggerimento")
        let label = NSTextField(wrappingLabelWithString: L("Il suggerimento è salvato nel file: Rondelle lo mostra quando chiede la password (per gli ZIP anche Keka e 7-Zip). Anteprima, Acrobat, Utility Archivio e le altre app non lo mostrano: chiedono solo la password.\n\nCon questa casella il suggerimento finisce anche nel nome del file, così si vede ovunque, anche da chi riceve il file. Non scriverci la password."))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = 280
        let size = label.fittingSize
        label.frame = NSRect(x: 14, y: 12, width: size.width, height: size.height)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 28, height: size.height + 24))
        content.view.addSubview(label)
        popover.contentViewController = content
        popover.behavior = .transient
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func show() {
        if popover.isShown { popover.close() } else { popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX) }
    }
}

/// «▸ Altro»: a disclosure triangle that shows or hides a short explanation inside an alert.
final class DetailsDisclosure: NSView {
    private let toggle = NSButton()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let relayout: () -> Void
    private let width: CGFloat = 300

    init(details: String, relayout: @escaping () -> Void) {
        self.relayout = relayout
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        toggle.setButtonType(.pushOnPushOff)
        toggle.bezelStyle = .disclosure
        toggle.title = ""
        toggle.target = self
        toggle.action = #selector(flip)
        toggle.frame = NSRect(x: 0, y: 1, width: 20, height: 20)
        let caption = NSTextField(labelWithString: L("Altro"))
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.frame = NSRect(x: 20, y: 2, width: width - 20, height: 17)
        let click = NSClickGestureRecognizer(target: self, action: #selector(flipFromCaption))
        caption.addGestureRecognizer(click)
        label.stringValue = details
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        label.isHidden = true
        [toggle, caption, label].forEach(addSubview)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func flipFromCaption() {
        toggle.state = toggle.state == .on ? .off : .on
        flip()
    }

    @objc private func flip() {
        let open = toggle.state == .on
        label.isHidden = !open
        let textHeight = open ? ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height) : 0
        let height = 22 + (open ? textHeight + 6 : 0)
        setFrameSize(NSSize(width: width, height: height))
        // Flipped by hand: the disclosure stays on top, the text below it.
        toggle.frame.origin.y = height - 21
        subviews[1].frame.origin.y = height - 20
        label.frame = NSRect(x: 0, y: 0, width: width, height: textHeight)
        relayout()
    }
}
