import AppKit
import CoreImage
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Crop, annotate and cover parts of a photo before sharing it.
/// Marks are kept in the photo's pixel coordinates (top-left origin) and burnt into a new image when saving:
/// nothing under «Copri» survives, and no metadata of the original is copied (GPS, camera, and the EXIF
/// thumbnail, which would still show the covered parts).
enum PhotoEditor {
    enum Tool: String, CaseIterable, Identifiable {
        case adjust = "Regola", crop = "Ritaglia", pen = "Penna", box = "Riquadro", arrow = "Freccia", text = "Testo", cover = "Copri"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .adjust: return "slider.horizontal.3"
            case .crop: return "crop"
            case .pen: return "pencil.tip"
            case .box: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .text: return "textformat"
            case .cover: return "rectangle.fill"
            }
        }
        var hint: String {
            switch self {
            case .adjust: return L("Muovi i cursori: l'anteprima cambia subito. Ritaglio e segni si applicano sopra.")
            case .crop: return L("Trascina per scegliere l'area da tenere.")
            case .pen: return L("Disegna a mano libera.")
            case .box: return L("Trascina per disegnare un riquadro.")
            case .arrow: return L("Trascina dalla coda alla punta della freccia.")
            case .text: return L("Fai clic dove vuoi scrivere.")
            case .cover: return L("Trascina sopra la parte da nascondere: viene coperta di nero, in modo definitivo.")
            }
        }
    }

    struct RGBA: Equatable, Sendable {
        var r: Double, g: Double, b: Double
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    struct Mark: Equatable, Sendable {
        enum Shape: Equatable, Sendable {
            case pen([CGPoint]), box(CGRect), arrow(CGPoint, CGPoint), text(String, CGPoint), cover(CGRect)
        }
        var shape: Shape
        var color: RGBA
        /// Line width in photo pixels; text is 6 times as tall.
        var width: CGFloat
    }

    @MainActor
    static func open(_ urls: [URL]) {
        for url in urls.prefix(4) {
            ToolWindows.show(L("Modifica — %@", url.lastPathComponent), tool: L("Modifica"), symbol: "pencil.tip.crop.circle",
                             detail: url.lastPathComponent, size: NSSize(width: 960, height: 720),
                             EditorView(model: EditorModel(url: url)))
        }
    }

    /// Draws `marks` on the full-size photo, then crops it. `image` is the photo as stored and `orientation` its
    /// EXIF orientation, applied in the same draw; `opaque` (JPEG…) draws on white instead of keeping transparency.
    /// One copy of the pixels in memory.
    static func render(_ image: CGImage, orientation: CGImagePropertyOrientation = .up, opaque: Bool = false,
                       marks: [Mark], crop: CGRect?, adjustments: Adjustments = .init()) -> CGImage? {
        let sideways = orientation.rawValue >= 5
        let w = sideways ? image.height : image.width, h = sideways ? image.width : image.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        let info = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)
        else { return nil }
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        if adjustments.isIdentity {
            ctx.saveGState()
            ctx.concatenate(CIImage(cgImage: image).orientationTransform(for: orientation))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.restoreGState()
        } else {
            // Turned upright and adjusted by Core Image straight into this context's pixels: one copy of the
            // photo instead of three (upright, adjusted, final; D1).
            let output = adjustments.apply(to: CIImage(cgImage: image).oriented(orientation))
            let upright = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
            guard let data = ctx.data else { return nil }
            Adjustments.context.render(upright, toBitmap: data, rowBytes: ctx.bytesPerRow,
                                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                       colorSpace: ctx.colorSpace)
            if opaque {   // JPEG and the like: no transparency, as on white
                ctx.saveGState()
                ctx.setBlendMode(.destinationOver)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()
            }
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)   // top-left origin, like the marks
        for mark in marks { draw(mark, in: ctx) }
        guard let full = ctx.makeImage() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        guard let crop = crop?.integral.intersection(bounds), !crop.isEmpty, crop != bounds else { return full }
        return full.cropping(to: crop)
    }

    /// Draws one mark in a context whose origin is the top-left corner (y grows downwards).
    static func draw(_ mark: Mark, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(mark.color.cgColor)
        ctx.setFillColor(mark.color.cgColor)
        ctx.setLineWidth(mark.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark.shape {
        case .pen(let points):
            guard let first = points.first else { return }
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            if points.count == 1 { ctx.addLine(to: first) }
            ctx.strokePath()
        case .box(let rect):
            ctx.stroke(rect)
        case .arrow(let from, let to):
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = max(mark.width * 4, 12)
            ctx.move(to: from)
            ctx.addLine(to: to)
            for side in [-1.0, 1.0] {
                ctx.move(to: to)
                ctx.addLine(to: CGPoint(x: to.x - head * cos(angle + side * .pi / 7), y: to.y - head * sin(angle + side * .pi / 7)))
            }
            ctx.strokePath()
        case .cover(let rect):
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(rect)
        case .text(let string, let point):
            let size = mark.width * 6
            let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): mark.color.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            ctx.translateBy(x: point.x, y: point.y)
            ctx.scaleBy(x: 1, y: -1)   // text upright in the flipped context; `point` is its top-left corner
            ctx.textPosition = CGPoint(x: 0, y: -ascent)
            CTLineDraw(line, ctx)
        }
    }

    /// Saves "name (modificata).ext" in the original format, without the original's metadata.
    /// The editor's own, lower limit (A3), on top of the general one.
    static func checkEditorSize(_ url: URL) throws {
        try ImageOps.checkPixelCount(of: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw OpError.unreadable(url) }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width * height <= Limits.maxEditorPixels else {
            throw OpError.unsupported(L("la modifica ammette foto fino a %@ megapixel (questa è %@ × %@): riducila prima, per esempio con «50%%»", Limits.maxEditorPixels / 1_000_000, width, height))
        }
    }

    static func save(_ url: URL, marks: [Mark], crop: CGRect?, adjustments: Adjustments = .init()) throws -> URL {
        try checkEditorSize(url)
        let (raw, orientation, type, _) = try ImageTools.loadRaw(url)
        let opaque = !ImageOps.supportsAlpha(type)
        // Upright, then light and colour; marks and crop go on top, as in the preview.
        guard let result = render(raw, orientation: orientation, opaque: opaque, marks: marks, crop: crop, adjustments: adjustments) else {
            throw OpError.failed(L("modifica della foto"))
        }
        let out = FileNaming.output(for: url, ext: ImageOps.fileExtension(for: type) ?? "png", suffix: "modificata")
        try ImageOps.write(result, to: out, type: type, quality: 0.92)
        return out
    }
}

// MARK: Model

@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    @Published private(set) var preview: CGImage?
    /// The screen-sized photo before «Regola»: each change re-renders `preview` from it.
    private var original: CGImage?
    @Published var adjustments = PhotoEditor.Adjustments() { didSet { if adjustments != oldValue { scheduleAdjust() } } }
    private var adjustTask: Task<Void, Never>?
    @Published private(set) var pixelSize = CGSize(width: 1, height: 1)
    @Published private(set) var error: String?
    @Published private(set) var marks: [PhotoEditor.Mark] = []
    @Published private(set) var crop: CGRect?
    /// The mark or crop being dragged right now.
    @Published var draft: PhotoEditor.Mark?
    @Published var draftCrop: CGRect?
    @Published var tool = PhotoEditor.Tool.adjust
    @Published var color = Color.red
    @Published var thickness = 1.0
    @Published private(set) var saving = false
    private var history: [([PhotoEditor.Mark], CGRect?)] = []

    init(url: URL) { self.url = url }

    /// A screen-sized copy for the window; the full photo is read again only when saving.
    func load() async {
        let url = self.url
        let result = await Task.detached { () -> Result<(CGImage, CGSize), Error> in
            Result {
                try PhotoEditor.checkEditorSize(url)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int else { throw OpError.unreadable(url) }
                // Upright, like the saved photo: EXIF orientations 5–8 swap the sides.
                let sideways = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
                let size = sideways ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 2400),
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    throw OpError.unreadable(url)
                }
                return (image, size)
            }
        }.value
        switch result {
        case .success(let (image, size)):
            original = image
            preview = image
            pixelSize = size
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    /// Renders the adjusted preview off the main thread; a newer change cancels the one in progress.
    private func scheduleAdjust() {
        adjustTask?.cancel()
        guard let original else { return }
        let adjustments = self.adjustments
        adjustTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { adjustments.render(original) }.value
            guard !Task.isCancelled, let image else { return }
            self?.preview = image
        }
    }

    /// Line width in photo pixels: thin on a phone screenshot, thicker on a 48 MP photo.
    var lineWidth: CGFloat { max(2, min(pixelSize.width, pixelSize.height) * 0.004) * thickness }

    var rgba: PhotoEditor.RGBA {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .red
        return .init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    var canUndo: Bool { !history.isEmpty }

    func begin(at p: CGPoint) {
        let mark = { (shape: PhotoEditor.Mark.Shape) in PhotoEditor.Mark(shape: shape, color: self.rgba, width: self.lineWidth) }
        switch tool {
        case .crop: draftCrop = CGRect(origin: p, size: .zero)
        case .pen: draft = mark(.pen([p]))
        case .box: draft = mark(.box(CGRect(origin: p, size: .zero)))
        case .arrow: draft = mark(.arrow(p, p))
        case .cover: draft = mark(.cover(CGRect(origin: p, size: .zero)))
        case .text, .adjust: break
        }
    }

    func drag(from start: CGPoint, to p: CGPoint) {
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if tool == .crop { draftCrop = rect; return }
        guard var mark = draft else { return }
        switch mark.shape {
        case .pen(let points): mark.shape = .pen(points + [p])
        case .box: mark.shape = .box(rect)
        case .cover: mark.shape = .cover(rect)
        case .arrow(let from, _): mark.shape = .arrow(from, p)
        case .text: break
        }
        draft = mark
    }

    func end(at p: CGPoint) {
        if tool == .adjust { return }
        if tool == .text {
            if let text = Notice.ask(L("Testo da aggiungere:"), defaultValue: ""), !text.isEmpty {
                commit(marks + [PhotoEditor.Mark(shape: .text(text, p), color: rgba, width: lineWidth)], crop)
            }
            return
        }
        if let rect = draftCrop {
            draftCrop = nil
            if rect.width >= 8, rect.height >= 8 { commit(marks, rect) }
            return
        }
        guard let mark = draft else { return }
        draft = nil
        switch mark.shape {   // a click without dragging draws nothing
        case .box(let r), .cover(let r): guard r.width >= 3, r.height >= 3 else { return }
        case .arrow(let a, let b): guard hypot(b.x - a.x, b.y - a.y) >= 3 else { return }
        default: break
        }
        commit(marks + [mark], crop)
    }

    func clearCrop() { commit(marks, nil) }

    func undo() {
        guard let (m, c) = history.popLast() else { return }
        marks = m
        crop = c
    }

    private func commit(_ newMarks: [PhotoEditor.Mark], _ newCrop: CGRect?) {
        history.append((marks, crop))
        marks = newMarks
        crop = newCrop
    }

    func save() async throws -> URL {
        saving = true
        defer { saving = false }
        let (url, marks, crop, adjustments) = (self.url, self.marks, self.crop, self.adjustments)
        return try await Task.detached(priority: .userInitiated) {
            try await FileNaming.cleaningUpOnFailure { try PhotoEditor.save(url, marks: marks, crop: crop, adjustments: adjustments) }
        }.value
    }
}

// MARK: View

struct EditorView: View {
    @StateObject var model: EditorModel
    @State private var hostView: NSView?
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.tool) {
                    ForEach(PhotoEditor.Tool.allCases) { tool in
                        Label(L(tool.rawValue), systemImage: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ColorPicker(L("Colore"), selection: $model.color, supportsOpacity: false).labelsHidden()
                    .disabled(model.tool == .cover || model.tool == .crop || model.tool == .adjust)
                Slider(value: $model.thickness, in: 0.5...4) { Text(L("Spessore")) }.frame(width: 140)
                    .disabled(model.tool == .adjust)
                Spacer()
                if model.crop != nil {
                    Button { model.clearCrop() } label: { Label(L("Togli ritaglio"), systemImage: "crop") }.rondelleButton()
                }
                Button { model.undo() } label: { Label(L("Annulla modifica"), systemImage: "arrow.uturn.backward") }
                    .rondelleButton()
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                canvas
                if model.tool == .adjust {
                    Divider()
                    AdjustPanel(adjustments: $model.adjustments).frame(width: 330)
                }
            }
            Divider()
            HStack {
                Text(model.tool.hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Annulla")) { ToolWindows.close(containing: hostView) }.rondelleButton()
                Button(L("Salva copia")) { Task { await save() } }
                    .rondelleProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.preview == nil || model.saving
                              || (model.marks.isEmpty && model.crop == nil && model.adjustments.isIdentity))
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowFinder(view: $hostView))
        .task { await model.load() }
    }

    @ViewBuilder private var canvas: some View {
        if let error = model.error {
            Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.preview {
            GeometryReader { geo in
                let size = model.pixelSize
                let scale = min(geo.size.width / size.width, geo.size.height / size.height)
                let frame = CGSize(width: size.width * scale, height: size.height * scale)
                ZStack {
                    Image(decorative: preview, scale: 1).resizable().interpolation(.high)
                    Canvas { context, _ in
                        context.withCGContext { cg in
                            cg.scaleBy(x: scale, y: scale)
                            for mark in model.marks + (model.draft.map { [$0] } ?? []) { PhotoEditor.draw(mark, in: cg) }
                        }
                        if let crop = model.draftCrop ?? model.crop {
                            let r = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
                            var outside = Path(CGRect(origin: .zero, size: frame))
                            outside.addRect(r)
                            context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                            context.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        }
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let p = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                    if dragStart == nil {
                        let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                        dragStart = start
                        model.begin(at: start)
                    }
                    model.drag(from: dragStart!, to: clamp(p, size))
                }.onEnded { value in
                    let p = clamp(CGPoint(x: value.location.x / scale, y: value.location.y / scale), size)
                    dragStart = nil
                    model.end(at: model.tool == .text ? CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale) : p)
                })
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(16)
        } else {
            ProgressView(L("Apertura della foto…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clamp(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }

    private func save() async {
        do {
            let out = try await model.save()
            JobHistory.record(L("Modifica"), outputs: [out])
            Settings.reveal([out])
            if Settings.playSound { NSSound(named: "Glass")?.play() }
            CompletionAnimation.play()
            ToolWindows.close(containing: hostView)
        } catch {
            Notice.show(title: L("Foto non salvata"), text: error.localizedDescription)
        }
    }
}

/// «Regola»: one slider per adjustment, in groups, each with its value and a reset button.
private struct AdjustPanel: View {
    @Binding var adjustments: PhotoEditor.Adjustments

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(PhotoEditor.Adjustments.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L(group.title)).font(.headline).foregroundStyle(.secondary)
                        ForEach(group.keys) { key in row(key) }
                    }
                }
                Button(L("Ripristina tutte le regolazioni")) { adjustments = .init() }
                    .rondelleButton()
                    .disabled(adjustments.isIdentity)
            }
            .padding(14)
        }
    }

    private func row(_ key: PhotoEditor.Adjustments.Key) -> some View {
        HStack(spacing: 8) {
            Text(key.title).frame(width: 92, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
            Slider(value: Binding(get: { adjustments[key] }, set: { adjustments[key] = $0.rounded() }), in: -100...100)
                .controlSize(.small)
            Text(key.label(adjustments[key])).monospacedDigit().font(.callout)
                .frame(width: 66, alignment: .trailing)
                .foregroundStyle(adjustments[key] == 0 ? .secondary : .primary)
            Button { adjustments[key] = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help(L("Azzera"))
                .disabled(adjustments[key] == 0)
        }
    }
}
