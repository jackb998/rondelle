import AppKit
import ImageIO

/// Draws the slides `PptxReader` read: background, plain shapes, pictures, tables and text, in the slide's own
/// size (points). Text is drawn as text, so a PDF made from a PPTX keeps it selectable. It is a plain
/// rendering, not PowerPoint's: fonts that aren't installed are replaced, and what the reader skips is missing.
enum PptxRenderer {
    /// Decoded pictures, a few at a time: a logo on the master is used by every slide, a photo by one.
    final class Pictures {
        private var store: [String: CGImage] = [:]
        private var order: [String] = []
        /// 60 MP is ≈ 240 MB decoded.
        static let maxPixels = 60_000_000

        func image(_ path: String, in deck: PptxReader.Deck) -> CGImage? {
            if let hit = store[path] { return hit }
            guard let data = deck.imageData(path), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w * h <= Self.maxPixels,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            store[path] = image
            order.append(path)
            if order.count > 6 { store[order.removeFirst()] = nil }
            return image
        }
    }

    /// One slide into `ctx`, whose origin is the bottom left corner and whose size is `deck.size`.
    static func draw(_ slide: PptxReader.Slide, of deck: PptxReader.Deck, in ctx: CGContext, pictures: Pictures) {
        let size = deck.size
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        switch slide.background {
        case .color(let color)?:
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        case .picture(let path)?:
            if let image = pictures.image(path, in: deck) { ctx.draw(image, in: CGRect(origin: .zero, size: size)) }
        case nil: break
        }
        ctx.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for item in slide.items { drawItem(item, deck, ctx, pictures) }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private static func drawItem(_ item: PptxReader.Item, _ deck: PptxReader.Deck, _ ctx: CGContext, _ pictures: Pictures) {
        let f = item.frame
        let rect = CGRect(x: f.x, y: deck.size.height - f.y - f.h, width: f.w, height: f.h)
        guard rect.width.isFinite, rect.height.isFinite else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.midX, y: rect.midY)
        if f.rot != 0 { ctx.rotate(by: -f.rot * .pi / 180) }
        ctx.translateBy(x: -rect.midX, y: -rect.midY)

        switch item.content {
        case .picture(let path, let crop, let clip):
            guard var image = pictures.image(path, in: deck) else { return }
            if crop.l + crop.t + crop.r + crop.b > 0, crop.l + crop.r < 1, crop.t + crop.b < 1 {
                let w = Double(image.width), h = Double(image.height)
                let part = CGRect(x: crop.l * w, y: crop.t * h, width: (1 - crop.l - crop.r) * w, height: (1 - crop.t - crop.b) * h).integral
                if let cropped = image.cropping(to: part) { image = cropped }
            }
            if let clip { ctx.addPath(outline(clip, rect)); ctx.clip() }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: f.flipH ? -1 : 1, y: f.flipV ? -1 : 1)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
            ctx.draw(image, in: rect)

        case .shape(let geometry, let fill, let line, let lineWidth, let text):
            if geometry == .line {
                guard let line else { return }
                ctx.setStrokeColor(line.cgColor)
                ctx.setLineWidth(lineWidth)
                let down = f.flipV, back = f.flipH
                ctx.move(to: CGPoint(x: back ? rect.maxX : rect.minX, y: down ? rect.minY : rect.maxY))
                ctx.addLine(to: CGPoint(x: back ? rect.minX : rect.maxX, y: down ? rect.maxY : rect.minY))
                ctx.strokePath()
                return
            }
            if fill != nil || line != nil {
                let path = outline(geometry, rect)
                if let fill { ctx.setFillColor(fill.cgColor); ctx.addPath(path); ctx.fillPath() }
                if let line { ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(lineWidth); ctx.addPath(path); ctx.strokePath() }
            }
            if let text { drawText(text, in: rect) }

        case .table(let columns, let rows):
            var top = rect.maxY
            for row in rows {
                // A row grows with its text, as in PowerPoint.
                var x = rect.minX
                var height = row.height
                for (i, cell) in row.cells.enumerated() where i < columns.count {
                    height = max(height, measure(cell.text, width: columns[i]) + cell.text.insets.t + cell.text.insets.b)
                }
                for (i, cell) in row.cells.enumerated() where i < columns.count {
                    let box = CGRect(x: x, y: top - height, width: columns[i], height: height)
                    if let fill = cell.fill { ctx.setFillColor(fill.cgColor); ctx.fill(box) }
                    ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
                    ctx.setLineWidth(0.5)
                    ctx.stroke(box)
                    drawText(cell.text, in: box)
                    x += columns[i]
                }
                top -= height
            }
        }
    }

    /// The outline of a shape in `rect`.
    private static func outline(_ geometry: PptxReader.Geometry, _ rect: CGRect) -> CGPath {
        switch geometry {
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        case .roundRect:
            let r = min(rect.width, rect.height) / 6
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .custom(let c):
            // The outline is in a square of side 1 with y pointing down.
            var transform = CGAffineTransform(translationX: rect.minX, y: rect.maxY).scaledBy(x: rect.width, y: -rect.height)
            return c.path.copy(using: &transform) ?? CGPath(rect: rect, transform: nil)
        default: return CGPath(rect: rect, transform: nil)
        }
    }

    // MARK: Text

    private static func measure(_ text: PptxReader.Text, width: Double) -> Double {
        guard !text.paragraphs.isEmpty else { return 0 }
        let box = attributed(text).boundingRect(with: CGSize(width: max(width - text.insets.l - text.insets.r, 1), height: 100_000),
                                                options: [.usesLineFragmentOrigin])
        return ceil(box.height)
    }

    /// `text` in `rect` (unflipped coordinates), placed by the shape's insets and anchor.
    private static func drawText(_ text: PptxReader.Text, in rect: CGRect) {
        guard !text.paragraphs.isEmpty else { return }
        let width = max(rect.width - text.insets.l - text.insets.r, 1)
        let available = rect.height - text.insets.t - text.insets.b
        let attributedText = attributed(text)
        let height = ceil(attributedText.boundingRect(with: CGSize(width: width, height: 100_000), options: [.usesLineFragmentOrigin]).height)
        var top = rect.maxY - text.insets.t
        switch text.anchor {
        case .top: break
        case .middle: top -= (available - height) / 2
        case .bottom: top -= available - height
        }
        attributedText.draw(with: CGRect(x: rect.minX + text.insets.l, y: top - height, width: width, height: height),
                            options: [.usesLineFragmentOrigin])
    }

    static func attributed(_ text: PptxReader.Text) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in text.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.alignment = p.align
            style.headIndent = max(p.marL, 0)
            style.firstLineHeadIndent = max(p.marL + p.indent, 0)
            style.tabStops = [NSTextTab(textAlignment: .left, location: max(p.marL, 0))]
            style.paragraphSpacingBefore = i == 0 ? 0 : p.spaceBefore
            style.paragraphSpacing = p.spaceAfter
            style.lineHeightMultiple = max(p.lineMultiple, 0.5)
            let paragraph = NSMutableAttributedString()
            func piece(_ s: String, _ run: PptxReader.Run) {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(run.font, size: run.size, bold: run.bold, italic: run.italic),
                    .foregroundColor: run.color,
                ]
                if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                paragraph.append(NSAttributedString(string: s, attributes: attributes))
            }
            if let bullet = p.bullet, let first = p.runs.first(where: { !$0.text.isEmpty }) { piece(bullet + "\t", first) }
            for run in p.runs where !run.text.isEmpty { piece(run.text, run) }
            if paragraph.length == 0 {
                // An empty paragraph still takes a line.
                paragraph.append(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: max(p.emptySize, 1))]))
            }
            if i < text.paragraphs.count - 1 { paragraph.append(NSAttributedString(string: "\n")) }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            out.append(paragraph)
        }
        return out
    }

    private static func font(_ name: String?, size: Double, bold: Bool, italic: Bool) -> NSFont {
        let size = CGFloat(min(max(size, 1), 1000))
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let name, let found = NSFontManager.shared.font(withFamily: name, traits: traits, weight: 5, size: size) { return found }
        return NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: traits)
    }
}
