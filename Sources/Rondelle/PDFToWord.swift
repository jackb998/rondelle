import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF → Word that keeps the pages: same size and margins, one Word page per PDF page, paragraphs rather than one per
/// line, fonts and colours, pictures where they were and, behind the text, a picture of what the PDF draws (table
/// borders, coloured bands, charts). What stays text can be edited; what is drawn can't, and gradients aren't redrawn.
enum PDFToWord {
    /// Pictures and drawings inside one document: past this the file would be of little use, and it has to fit on disk.
    static let maxMediaBytes = 500_000_000
    static let drawingsDPI: CGFloat = 150
    /// The longest side of what is drawn in memory for one page: ≈ 45 MB on A4 proportions.
    static let maxDrawingSide: CGFloat = 4_000

    // MARK: What a page holds

    struct Run {
        var text: String
        let font: NSFont?
        let family: String
        let size: CGFloat
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let color: NSColor?
        var hex: String? {
            guard let c = color?.usingColorSpace(.sRGB) else { return nil }
            let value = String(format: "%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
            return value == "000000" ? nil : value
        }
    }

    /// One piece of text on one line, in points from the top left of the page as it is shown.
    struct Segment {
        var runs: [Run]
        var x: CGFloat
        var right: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var size: CGFloat { runs.map(\.size).max() ?? 12 }
        var text: String { runs.map(\.text).joined() }
    }

    enum Alignment { case left, center, right, justified }

    struct Paragraph {
        var runs: [Run]
        var top: CGFloat
        var left: CGFloat
        var firstLine: CGFloat = 0
        var right: CGFloat
        var leading: CGFloat
        var lines = 1
        var alignment = Alignment.left
        /// Where the other pieces of a row start, for a row laid out in columns.
        var tabs: [CGFloat] = []
        var lineRights: [CGFloat] = []
    }

    struct Picture {
        let file: String
        let rect: CGRect
        var behindText: Bool
    }

    struct Page {
        var size: CGSize
        /// Where the text starts and ends on pages of this size: the margins.
        var bodyLeft: CGFloat
        var bodyRight: CGFloat
        var paragraphs: [Paragraph]
        var pictures: [Picture]
    }

    // MARK: Reading the text

    private static func cleanFamily(_ font: NSFont) -> String {
        // Fonts embedded in a PDF are named «ABCDEF+Arial-BoldMT»; a font that isn't on this Mac has only that name.
        var name = font.familyName ?? font.fontName
        if name.count > 7, name[name.index(name.startIndex, offsetBy: 6)] == "+" { name = String(name.dropFirst(7)) }
        if let dash = name.firstIndex(of: "-") { name = String(name[..<dash]) }
        return name
    }

    private static func runs(of text: NSAttributedString) -> [Run] {
        var result: [Run] = []
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            let piece = text.attributedSubstring(from: range).string.replacingOccurrences(of: "\n", with: "")
            guard !piece.isEmpty else { return }
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let name = font?.fontName.lowercased() ?? ""
            result.append(Run(text: piece, font: font, family: font.map(cleanFamily) ?? "Helvetica", size: font?.pointSize ?? 12,
                              bold: traits.contains(.bold) || name.contains("bold") || name.contains("black"),
                              italic: traits.contains(.italic) || name.contains("italic") || name.contains("oblique"),
                              underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                              color: attributes[.foregroundColor] as? NSColor))
        }
        return result
    }

    private static func segments(of page: PDFPage) -> (items: [Segment], size: CGSize) {
        let bounds = page.bounds(for: .cropBox)
        let transform = page.transform(for: .cropBox)
        let shown = bounds.applying(transform)
        var items: [Segment] = []
        for line in page.selection(for: bounds)?.selectionsByLine() ?? [] {
            guard let text = line.attributedString else { continue }
            let pieces = runs(of: text)
            guard !pieces.isEmpty, !pieces.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) else { continue }
            let rect = line.bounds(for: page).applying(transform)
            let whole = Segment(runs: pieces, x: rect.minX - shown.minX, right: rect.maxX - shown.minX,
                                top: shown.maxY - rect.maxY, bottom: shown.maxY - rect.minY)
            items += columns(of: whole, line: line, text: text, page: page, transform: transform, left: shown.minX)
        }
        return (items, shown.size)
    }

    /// PDFKit gives a table's row as one line: «Voce   100   200». Gaps wider than a line and a half separate its columns.
    /// Characters are measured only on lines wider than their text would be, so ordinary text costs nothing here.
    private static func columns(of whole: Segment, line: PDFSelection, text: NSAttributedString, page: PDFPage, transform: CGAffineTransform, left: CGFloat) -> [Segment] {
        guard line.numberOfTextRanges(on: page) == 1 else { return [whole] }
        let characters = line.range(at: 0, on: page)
        guard characters.location != NSNotFound, characters.length > 2,
              (whole.right - whole.x) / CGFloat(characters.length) > whole.size * 0.55 else { return [whole] }
        var result: [Segment] = []
        var start = characters.location
        var startX = whole.x
        var previous = page.characterBounds(at: start).applying(transform)
        func piece(_ range: NSRange, x: CGFloat, right: CGFloat) {
            guard let selected = page.selection(for: range)?.attributedString else { return }
            let found = runs(of: selected)
            if !found.isEmpty, !found.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) {
                result.append(Segment(runs: found, x: x, right: right, top: whole.top, bottom: whole.bottom))
            }
        }
        for i in (characters.location + 1)..<(characters.location + characters.length) {
            let bounds = page.characterBounds(at: i).applying(transform)
            // A space PDFKit puts between far pieces of text spans the gap: no glyph is that wide. And some have no width.
            guard bounds.width > 0.01, bounds.width < whole.size * 1.5 else { continue }
            if bounds.minX - previous.maxX > whole.size * 1.5 {
                piece(NSRange(location: start, length: i - start), x: startX, right: previous.maxX - left)
                start = i
                startX = bounds.minX - left
            }
            previous = bounds
        }
        guard !result.isEmpty else { return [whole] }
        piece(NSRange(location: start, length: characters.upperBound - start), x: startX, right: whole.right)
        return result
    }

    /// Segments side by side on the same line, top to bottom.
    private static func rows(_ segments: [Segment]) -> [[Segment]] {
        var result: [[Segment]] = []
        for segment in segments.sorted(by: { $0.top < $1.top }) {
            let middle = (segment.top + segment.bottom) / 2
            if let last = result.last?.first, middle > last.top, middle < last.bottom,
               (last.top + last.bottom) / 2 > segment.top, (last.top + last.bottom) / 2 < segment.bottom {
                result[result.count - 1].append(segment)
            } else {
                result.append([segment])
            }
        }
        return result.map { row in
            // Pieces with a word's space between them are one piece.
            var joined: [Segment] = []
            for segment in row.sorted(by: { $0.x < $1.x }) {
                if var last = joined.last, segment.x - last.right < last.size {
                    if segment.x - last.right > last.size * 0.15, var space = last.runs.last {
                        space.text = " "
                        last.runs.append(space)
                    }
                    last.runs += segment.runs
                    last.right = max(last.right, segment.right)
                    last.top = min(last.top, segment.top)
                    last.bottom = max(last.bottom, segment.bottom)
                    joined[joined.count - 1] = last
                } else {
                    joined.append(segment)
                }
            }
            return joined
        }
    }

    // MARK: Lines into paragraphs

    /// The text of a line wrapped here on its own: the next line's first word wouldn't have fitted on it.
    private static func wrapped(_ line: Segment, _ next: Segment, limit: CGFloat) -> Bool {
        let text = next.text
        let word = text.prefix { !$0.isWhitespace }
        guard !word.isEmpty, !text.isEmpty else { return false }
        let width = (next.right - next.x) * CGFloat(word.count + 1) / CGFloat(text.count)
        return line.right + width >= limit - 2
    }

    private static func startsAList(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•·‣▪◦–—-*".contains(first) { return true }
        let head = text.prefix(4)
        return head.first?.isNumber == true && (head.contains(".") || head.contains(")")) && head.contains(" ")
    }

    private static func paragraphs(of rows: [[Segment]], bodyLeft: CGFloat, bodyRight: CGFloat) -> [Paragraph] {
        var result: [Paragraph] = []
        var previous: Segment?
        for row in rows {
            guard row.count == 1 else {
                let first = row[0]
                result.append(Paragraph(runs: row.enumerated().flatMap { index, segment -> [Run] in
                    guard index > 0, var tab = segment.runs.first else { return segment.runs }
                    tab.text = "\t"
                    return [tab] + segment.runs
                }, top: row.map(\.top).min() ?? first.top, left: first.x - bodyLeft, right: 0,
                   leading: max(first.bottom - first.top, first.size * 1.1), tabs: row.dropFirst().map { $0.x - bodyLeft }))
                previous = nil
                continue
            }
            let line = row[0]
            if let last = previous, var paragraph = result.last {
                let distance = line.top - last.top
                let flush = abs(line.x - bodyLeft - paragraph.left - paragraph.firstLine) < 3 || abs(line.x - bodyLeft - paragraph.left) < 3
                let indented = paragraph.lines == 1 && last.x - line.x > 3 && last.x - line.x < 40
                let sameSize = abs(line.size - last.size) < 0.6
                let steady = distance > line.size * 0.9 && distance < line.size * 1.8
                    && (paragraph.lines == 1 || abs(distance - paragraph.leading) < 1.5)
                if sameSize, steady, flush || indented, wrapped(last, line, limit: bodyRight), !startsAList(line.text) {
                    if var space = paragraph.runs.last {
                        if space.text.hasSuffix("-"), line.text.first?.isLowercase == true, space.text.count > 1 {
                            paragraph.runs[paragraph.runs.count - 1].text.removeLast()
                        } else if !space.text.hasSuffix(" ") {
                            space.text = " "
                            paragraph.runs.append(space)
                        }
                    }
                    if indented {
                        paragraph.firstLine = last.x - line.x
                        paragraph.left = line.x - bodyLeft
                    }
                    paragraph.runs += line.runs
                    paragraph.leading = paragraph.lines == 1 ? distance : (paragraph.leading * CGFloat(paragraph.lines - 1) + distance) / CGFloat(paragraph.lines)
                    paragraph.lines += 1
                    paragraph.lineRights.append(line.right)
                    paragraph.right = max(paragraph.right, line.right)
                    result[result.count - 1] = paragraph
                    previous = line
                    continue
                }
            }
            result.append(Paragraph(runs: line.runs, top: line.top, left: line.x - bodyLeft, right: line.right,
                                    leading: max(line.bottom - line.top, line.size * 1.1), lineRights: [line.right]))
            previous = line
        }
        return result.map { finished($0, bodyLeft: bodyLeft, bodyRight: bodyRight) }
    }

    /// Alignment, from where the lines end; and `right` from the page's right edge from now on.
    private static func finished(_ paragraph: Paragraph, bodyLeft: CGFloat, bodyRight: CGFloat) -> Paragraph {
        var result = paragraph
        guard paragraph.tabs.isEmpty else { return result }
        let width = bodyRight - bodyLeft
        let gapLeft = paragraph.left, gapRight = bodyRight - paragraph.right
        if paragraph.lines == 1 {
            if gapLeft > 15, abs(gapLeft - gapRight) < 4 {
                result.alignment = .center
                result.left = 0
                result.right = 0
                return result
            }
            if gapRight < 2, gapLeft > width * 0.3 {
                result.alignment = .right
                result.left = 0
                result.right = 0
                return result
            }
            result.right = 0   // a single line: room to the right does no harm, and a wider font doesn't wrap
            return result
        }
        let ends = paragraph.lineRights.dropLast()
        if paragraph.lines >= 3, let low = ends.min(), let high = ends.max(), high - low < 1.5 { result.alignment = .justified }
        result.right = max(0, gapRight - 0.5)
        return result
    }

    // MARK: Pictures and drawings

    /// Replays what a page draws, leaving out the text: on a bitmap for what is drawn, as a list for the pictures.
    /// Bounded like every other reading of a page: `PDFTextScan.check` has already counted these operators.
    private final class Replay {
        struct Found { let stream: CGPDFStreamRef; let rect: CGRect }

        let context: CGContext
        let origin: CGAffineTransform
        let height: CGFloat
        var found: [Found] = []
        var invisibleText = false
        var visibleText = false
        private var textMode = 0
        private var depth = 0
        private var pendingClip: CGPathFillRule?
        private struct Paint { var fillAlpha: CGFloat = 1; var strokeAlpha: CGFloat = 1; var fillSpace = Space.other; var strokeSpace = Space.other; var skipFill = false; var skipStroke = false }
        private enum Space { case pattern, tint, other }
        private var paint = Paint()
        private var saved: [Paint] = []

        init?(_ page: CGPDFPage, size: CGSize, scale: CGFloat) {
            guard let context = CGContext(data: nil, width: max(Int(size.width * scale), 1), height: max(Int(size.height * scale), 1), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            self.context = context
            height = size.height
            context.scaleBy(x: scale, y: scale)
            origin = context.ctm
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        }

        func run(_ page: CGPDFPage) {
            scan(CGPDFContentStreamCreateWithPage(page))
        }

        private func scan(_ stream: CGPDFContentStreamRef) {
            let scanner = CGPDFScannerCreate(stream, Self.table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
        }

        private func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
            var values = [CGFloat](repeating: 0, count: count)
            for i in stride(from: count - 1, through: 0, by: -1) {
                var number: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &number) else { return nil }
                values[i] = number
            }
            return values
        }

        private func finishPath(_ draw: CGPathDrawingMode?) {
            let path = pendingClip != nil ? context.path : nil
            if let draw {
                // What can't be painted (a pattern, a shading) is left out, not drawn in the wrong colour.
                let even = draw == .eoFill || draw == .eoFillStroke
                let fills = draw != .stroke && !paint.skipFill
                let strokes = (draw == .stroke || draw == .fillStroke || draw == .eoFillStroke) && !paint.skipStroke
                if fills || strokes {
                    context.setAlpha(fills ? paint.fillAlpha : paint.strokeAlpha)
                    context.drawPath(using: fills && strokes ? (even ? .eoFillStroke : .fillStroke) : fills ? (even ? .eoFill : .fill) : .stroke)
                } else {
                    context.beginPath()
                }
            } else {
                context.beginPath()
            }
            if let rule = pendingClip {
                if let path { context.addPath(path) }
                context.clip(using: rule)
                pendingClip = nil
            }
        }

        private func setColor(_ scanner: CGPDFScannerRef, stroke: Bool) {
            let space = stroke ? paint.strokeSpace : paint.fillSpace
            var values: [CGFloat] = []
            var number: CGPDFReal = 0
            while values.count < 32, CGPDFScannerPopNumber(scanner, &number) { values.insert(number, at: 0) }
            if space == .pattern || values.isEmpty {
                if stroke { paint.skipStroke = true } else { paint.skipFill = true }
                return
            }
            if stroke { paint.skipStroke = false } else { paint.skipFill = false }
            let color: CGColor?
            switch (space, values.count) {
            case (.tint, _): color = CGColor(gray: 1 - (values.first ?? 1), alpha: 1)   // a spot colour: its tint, in grey
            case (_, 1): color = CGColor(gray: values[0], alpha: 1)
            case (_, 3): color = CGColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: 1)
            case (_, 4): color = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.genericCMYK)!, components: values + [1])
            default: color = nil
            }
            guard let color else {
                if stroke { paint.skipStroke = true } else { paint.skipFill = true }
                return
            }
            if stroke { context.setStrokeColor(color) } else { context.setFillColor(color) }
        }

        private func setSpace(_ scanner: CGPDFScannerRef, stroke: Bool) {
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            var space = Space.other
            if strcmp(name, "Pattern") == 0 {
                space = .pattern
            } else if let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ColorSpace", name) {
                var array: CGPDFArrayRef?
                var kind: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetName(array, 0, &kind), let kind {
                    if strcmp(kind, "Pattern") == 0 { space = .pattern }
                    if strcmp(kind, "Separation") == 0 || strcmp(kind, "DeviceN") == 0 { space = .tint }
                }
            }
            if stroke {
                paint.strokeSpace = space
                paint.skipStroke = space == .pattern
                context.setStrokeColor(gray: 0, alpha: 1)
            } else {
                paint.fillSpace = space
                paint.skipFill = space == .pattern
                context.setFillColor(gray: 0, alpha: 1)
            }
        }

        private func setState(_ scanner: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            var state: CGPDFDictionaryRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name),
                  CGPDFObjectGetValue(object, .dictionary, &state), let state else { return }
            var value: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(state, "ca", &value) { paint.fillAlpha = value }
            if CGPDFDictionaryGetNumber(state, "CA", &value) { paint.strokeAlpha = value }
            if CGPDFDictionaryGetNumber(state, "LW", &value) { context.setLineWidth(value) }
        }

        private func drawObject(_ scanner: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            if strcmp(subtype, "Image") == 0 {
                // The unit square, from the page's coordinates to the top left ones of the document.
                let matrix = context.ctm.concatenating(origin.inverted())
                let box = CGRect(x: 0, y: 0, width: 1, height: 1).applying(matrix)
                found.append(Found(stream: stream, rect: CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)))
                return
            }
            guard strcmp(subtype, "Form") == 0, depth < PDFTextScan.maxFormDepth else { return }
            context.saveGState()
            saved.append(paint)
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                var v = [CGPDFReal](repeating: 0, count: 6)
                if (0..<6).allSatisfy({ CGPDFArrayGetNumber(array, $0, &v[$0]) }) {
                    context.concatenate(CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]))
                }
            }
            if CGPDFDictionaryGetArray(dictionary, "BBox", &array), let array, CGPDFArrayGetCount(array) == 4 {
                var v = [CGPDFReal](repeating: 0, count: 4)
                if (0..<4).allSatisfy({ CGPDFArrayGetNumber(array, $0, &v[$0]) }) {
                    context.clip(to: CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]))
                }
            }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            depth += 1
            scan(CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, CGPDFScannerGetContentStream(scanner)))
            depth -= 1
            if let last = saved.popLast() { paint = last }
            context.restoreGState()
        }

        private static func me(_ info: UnsafeMutableRawPointer?) -> Replay { Unmanaged<Replay>.fromOpaque(info!).takeUnretainedValue() }

        // Built once: callbacks can't capture, each finds the replay from `info`.
        nonisolated(unsafe) private static let table: CGPDFOperatorTableRef = {
            let table = CGPDFOperatorTableCreate()!
            func on(_ name: String, _ callback: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, callback) }
            on("q") { _, i in let r = me(i); r.context.saveGState(); r.saved.append(r.paint) }
            on("Q") { _, i in let r = me(i); if let last = r.saved.popLast() { r.paint = last; r.context.restoreGState() } }
            on("cm") { s, i in let r = me(i); if let v = r.numbers(s, 6) { r.context.concatenate(CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])) } }
            on("w") { s, i in let r = me(i); if let v = r.numbers(s, 1) { r.context.setLineWidth(v[0]) } }
            on("J") { s, i in let r = me(i); if let v = r.numbers(s, 1) { r.context.setLineCap(CGLineCap(rawValue: Int32(v[0])) ?? .butt) } }
            on("j") { s, i in let r = me(i); if let v = r.numbers(s, 1) { r.context.setLineJoin(CGLineJoin(rawValue: Int32(v[0])) ?? .miter) } }
            on("M") { s, i in let r = me(i); if let v = r.numbers(s, 1) { r.context.setMiterLimit(v[0]) } }
            on("d") { s, i in
                let r = me(i)
                var phase: CGPDFReal = 0
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopNumber(s, &phase), CGPDFScannerPopArray(s, &array), let array else { return }
                var lengths: [CGFloat] = []
                for k in 0..<min(CGPDFArrayGetCount(array), 32) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(array, k, &v) { lengths.append(v) }
                }
                r.context.setLineDash(phase: phase, lengths: lengths)
            }
            on("m") { s, i in let r = me(i); if let v = r.numbers(s, 2) { r.context.move(to: CGPoint(x: v[0], y: v[1])) } }
            on("l") { s, i in let r = me(i); if let v = r.numbers(s, 2), !r.context.isPathEmpty { r.context.addLine(to: CGPoint(x: v[0], y: v[1])) } }
            on("c") { s, i in let r = me(i); if let v = r.numbers(s, 6), !r.context.isPathEmpty { r.context.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3])) } }
            on("v") { s, i in let r = me(i); if let v = r.numbers(s, 4), !r.context.isPathEmpty { r.context.addCurve(to: CGPoint(x: v[2], y: v[3]), control1: r.context.currentPointOfPath, control2: CGPoint(x: v[0], y: v[1])) } }
            on("y") { s, i in let r = me(i); if let v = r.numbers(s, 4), !r.context.isPathEmpty { r.context.addCurve(to: CGPoint(x: v[2], y: v[3]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3])) } }
            on("h") { _, i in let r = me(i); if !r.context.isPathEmpty { r.context.closePath() } }
            on("re") { s, i in let r = me(i); if let v = r.numbers(s, 4) { r.context.addRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) } }
            on("S") { _, i in me(i).finishPath(.stroke) }
            on("s") { _, i in let r = me(i); if !r.context.isPathEmpty { r.context.closePath() }; r.finishPath(.stroke) }
            for name in ["f", "F"] { on(name) { _, i in me(i).finishPath(.fill) } }
            on("f*") { _, i in me(i).finishPath(.eoFill) }
            on("B") { _, i in me(i).finishPath(.fillStroke) }
            on("B*") { _, i in me(i).finishPath(.eoFillStroke) }
            on("b") { _, i in let r = me(i); if !r.context.isPathEmpty { r.context.closePath() }; r.finishPath(.fillStroke) }
            on("b*") { _, i in let r = me(i); if !r.context.isPathEmpty { r.context.closePath() }; r.finishPath(.eoFillStroke) }
            on("n") { _, i in me(i).finishPath(nil) }
            on("W") { _, i in me(i).pendingClip = .winding }
            on("W*") { _, i in me(i).pendingClip = .evenOdd }
            on("g") { s, i in let r = me(i); r.paint.fillSpace = .other; r.setColor(s, stroke: false) }
            on("G") { s, i in let r = me(i); r.paint.strokeSpace = .other; r.setColor(s, stroke: true) }
            on("rg") { s, i in let r = me(i); r.paint.fillSpace = .other; r.setColor(s, stroke: false) }
            on("RG") { s, i in let r = me(i); r.paint.strokeSpace = .other; r.setColor(s, stroke: true) }
            on("k") { s, i in let r = me(i); r.paint.fillSpace = .other; r.setColor(s, stroke: false) }
            on("K") { s, i in let r = me(i); r.paint.strokeSpace = .other; r.setColor(s, stroke: true) }
            on("cs") { s, i in me(i).setSpace(s, stroke: false) }
            on("CS") { s, i in me(i).setSpace(s, stroke: true) }
            for name in ["sc", "scn"] { on(name) { s, i in me(i).setColor(s, stroke: false) } }
            for name in ["SC", "SCN"] { on(name) { s, i in me(i).setColor(s, stroke: true) } }
            on("gs") { s, i in me(i).setState(s) }
            on("Do") { s, i in me(i).drawObject(s) }
            on("Tr") { s, i in let r = me(i); if let v = r.numbers(s, 1) { r.textMode = Int(v[0]) } }
            let shown: CGPDFOperatorCallback = { _, i in let r = me(i); if r.textMode == 3 { r.invisibleText = true } else { r.visibleText = true } }
            for name in ["Tj", "TJ", "'", "\""] { on(name, shown) }
            return table
        }()
    }

    /// The bitmap as a file, unless nothing but white or nothing at all was drawn on it.
    private static func drawingsFile(_ context: CGContext, into folder: URL, name: String) throws -> String? {
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var blank = true
        outer: for y in 0..<context.height {
            let row = bytes + y * context.bytesPerRow
            for x in 0..<context.width where row[x * 4 + 3] > 8 && (row[x * 4] < 245 || row[x * 4 + 1] < 245 || row[x * 4 + 2] < 245) {
                blank = false
                break outer
            }
        }
        guard !blank, let image = context.makeImage() else { return nil }
        let file = name + ".png"
        try writeImage(image, to: folder.appendingPathComponent(file), type: .png)
        return file
    }

    /// Through ImageIO with no properties: what a photo in the PDF says about itself (where it was taken…) stays out.
    private static func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw OpError.failed(L("scrittura del DOCX")) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw OpError.failed(L("scrittura del DOCX")) }
    }

    /// The picture a PDF image holds. Nil when it's of a kind not read here, or can't safely be unpacked: the page's own
    /// drawing is used for that area instead.
    private static func decode(_ stream: CGPDFStreamRef, depth: Int = 0) -> (image: CGImage, opaque: Bool)? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0, width * height <= Limits.maxEditorPixels else { return nil }
        var stencil: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &stencil), stencil != 0 { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        var image: CGImage?
        if format == .raw {
            image = raw(data, dictionary, width: width, height: height)
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        // A transparency mask: only here, one level down.
        var soft: CGPDFStreamRef?
        if depth == 0, CGPDFDictionaryGetStream(dictionary, "SMask", &soft), let soft, let mask = decode(soft, depth: 1)?.image,
           let masked = applying(mask, to: image) {
            return (masked, false)
        }
        return (image, true)
    }

    private static func applying(_ mask: CGImage, to image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let alpha = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        alpha.draw(mask, in: box)
        guard let values = alpha.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: box)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<image.height {
            let row = pixels + y * context.bytesPerRow
            let source = values + y * alpha.bytesPerRow
            for x in 0..<image.width {
                let a = UInt16(source[x])
                row[x * 4] = UInt8(UInt16(row[x * 4]) * a / 255)
                row[x * 4 + 1] = UInt8(UInt16(row[x * 4 + 1]) * a / 255)
                row[x * 4 + 2] = UInt8(UInt16(row[x * 4 + 2]) * a / 255)
                row[x * 4 + 3] = UInt8(a)
            }
        }
        return context.makeImage()
    }

    private static func raw(_ data: Data, _ dictionary: CGPDFDictionaryRef, width: Int, height: Int) -> CGImage? {
        var bits: CGPDFInteger = 8
        CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
        guard let (space, components) = colorSpace(dictionary), [1, 2, 4, 8].contains(bits) else { return nil }
        let bytesPerRow = (width * components * bits + 7) / 8
        guard data.count >= bytesPerRow * height, let provider = CGDataProvider(data: data as CFData) else { return nil }
        var decode: [CGFloat]?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Decode", &array), let array, CGPDFArrayGetCount(array) == components * 2 {
            var values = [CGFloat](repeating: 0, count: components * 2)
            if (0..<(components * 2)).allSatisfy({ CGPDFArrayGetNumber(array, $0, &values[$0]) }) { decode = values }
        }
        return CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: decode, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func device(_ components: Int) -> CGColorSpace? {
        switch components {
        case 1: return CGColorSpaceCreateDeviceGray()
        case 3: return CGColorSpace(name: CGColorSpace.sRGB)
        case 4: return CGColorSpace(name: CGColorSpace.genericCMYK)
        default: return nil
        }
    }

    private static func colorSpace(_ dictionary: CGPDFDictionaryRef) -> (CGColorSpace, Int)? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            let components = strcmp(name, "DeviceGray") == 0 ? 1 : strcmp(name, "DeviceRGB") == 0 ? 3 : strcmp(name, "DeviceCMYK") == 0 ? 4 : 0
            return device(components).map { ($0, components) }
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array, CGPDFArrayGetName(array, 0, &name), let name else { return nil }
        return arraySpace(array, kind: name)
    }

    private static func baseComponents(_ array: CGPDFArrayRef, at index: Int) -> Int? {
        var name: UnsafePointer<CChar>?
        if CGPDFArrayGetName(array, index, &name), let name {
            return strcmp(name, "DeviceGray") == 0 ? 1 : strcmp(name, "DeviceRGB") == 0 ? 3 : strcmp(name, "DeviceCMYK") == 0 ? 4 : nil
        }
        var inner: CGPDFArrayRef?
        var stream: CGPDFStreamRef?
        var count: CGPDFInteger = 0
        guard CGPDFArrayGetArray(array, index, &inner), let inner, CGPDFArrayGetName(inner, 0, &name), let name, strcmp(name, "ICCBased") == 0,
              CGPDFArrayGetStream(inner, 1, &stream), let stream, let info = CGPDFStreamGetDictionary(stream),
              CGPDFDictionaryGetInteger(info, "N", &count) else { return nil }
        return count
    }

    private static func arraySpace(_ array: CGPDFArrayRef, kind: UnsafePointer<CChar>) -> (CGColorSpace, Int)? {
        if strcmp(kind, "ICCBased") == 0 {
            var stream: CGPDFStreamRef?
            var count: CGPDFInteger = 0
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let info = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetInteger(info, "N", &count) else { return nil }
            return device(count).map { ($0, count) }
        }
        if strcmp(kind, "Indexed") == 0 || strcmp(kind, "I") == 0 {
            var last: CGPDFInteger = 0
            guard let components = baseComponents(array, at: 1), let base = device(components),
                  CGPDFArrayGetInteger(array, 2, &last), last >= 0, last <= 255 else { return nil }
            var table: Data?
            var text: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            if CGPDFArrayGetString(array, 3, &text), let text, let bytes = CGPDFStringGetBytePtr(text) {
                table = Data(bytes: bytes, count: CGPDFStringGetLength(text))
            } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
                table = CGPDFStreamCopyData(stream, &format) as Data?
            }
            guard let table, table.count >= (last + 1) * components else { return nil }
            let space = table.withUnsafeBytes { CGColorSpace(indexedBaseSpace: base, last: last, colorTable: $0.bindMemory(to: UInt8.self).baseAddress!) }
            return space.map { ($0, 1) }
        }
        return nil
    }

    // MARK: Building the document

    /// `media` nil: the text only, as RTF can't hold the rest.
    static func read(_ url: URL, into media: URL?, largestStream: Int) throws -> [Page] {
        guard let doc = PDFDocument(url: url), let graphics = CGPDFDocument(url as CFURL) else { throw OpError.unreadable(url) }
        var measured: [(rows: [[Segment]], size: CGSize)] = []
        for i in 0..<doc.pageCount {
            try PDFOps.checkCancelled()
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let found = segments(of: page)
                measured.append((rows(found.items), found.size))
            }
        }
        // Margins for the whole document, so that all pages line up as they do in the PDF.
        var pages: [Page] = []
        var mediaBytes = 0
        var known: [Int: String] = [:]
        var bodies: [String: (left: CGFloat, right: CGFloat)] = [:]
        for size in Set(measured.map { "\($0.size)" }) { bodies[size] = body(of: measured.filter { "\($0.size)" == size }) }
        for (i, item) in measured.enumerated() {
            try PDFOps.checkCancelled()
            let bounds = bodies["\(item.size)"] ?? (56, item.size.width - 56)
            var result = Page(size: item.size, bodyLeft: bounds.left, bodyRight: bounds.right,
                              paragraphs: paragraphs(of: item.rows, bodyLeft: bounds.left, bodyRight: bounds.right), pictures: [])
            try autoreleasepool {
                guard let media, let page = graphics.page(at: i + 1) else { return }
                try addPictures(to: &result, page: page, index: i, rows: item.rows, media: media, largestStream: largestStream, known: &known, bytes: &mediaBytes)
            }
            pages.append(result)
        }
        return pages
    }

    private static func addPictures(to result: inout Page, page: CGPDFPage, index: Int, rows: [[Segment]], media: URL, largestStream: Int,
                                    known: inout [Int: String], bytes: inout Int) throws {
        let size = result.size
        let scale = min(drawingsDPI / 72, maxDrawingSide / max(size.width, size.height, 1))
        guard let replay = Replay(page, size: size, scale: scale) else { return }
        replay.run(page)
        let text = rows.flatMap { $0 }
        func covered(_ rect: CGRect) -> Bool {
            text.contains { rect.intersects(CGRect(x: $0.x, y: $0.top, width: $0.right - $0.x, height: $0.bottom - $0.top)) }
        }
        func add(_ file: String, _ rect: CGRect) {
            bytes += FileNaming.fileSize(media.appendingPathComponent(file))
            result.pictures.append(Picture(file: file, rect: rect, behindText: covered(rect)))
        }
        if let file = try drawingsFile(replay.context, into: media, name: "disegni\(index + 1)") {
            add(file, CGRect(origin: .zero, size: size))
            result.pictures[result.pictures.count - 1].behindText = true
        }
        let pageArea = size.width * size.height
        var whole: CGImage?
        for (n, item) in replay.found.enumerated() {
            try PDFOps.checkCancelled()
            guard item.rect.width >= 2, item.rect.height >= 2 else { continue }
            // A scan with its recognized text hidden on top: the text is what a Word document is for.
            if replay.invisibleText, !replay.visibleText, item.rect.width * item.rect.height > pageArea * 0.7 { continue }
            let key = unsafeBitCast(item.stream, to: Int.self)
            if let seen = known[key] {
                add(seen, item.rect)
                continue
            }
            var file: String?
            if largestStream <= PDFTextScan.maxBytesToReadMaps, let decoded = decode(item.stream) {
                let type: UTType = decoded.opaque && decoded.image.width * decoded.image.height > 250_000 ? .jpeg : .png
                let name = "immagine\(index + 1)_\(n + 1).\(type == .jpeg ? "jpeg" : "png")"
                try writeImage(decoded.image, to: media.appendingPathComponent(name), type: type)
                file = name
                known[key] = name
            } else {
                // Of a kind not read here: that area of the page as it is drawn, whatever lies on top of it included.
                if whole == nil { whole = PDFOps.render(page, dpi: min(200, maxDrawingSide * 72 / max(size.width, size.height, 1))) }
                if let whole {
                    let k = CGFloat(whole.width) / size.width
                    let crop = CGRect(x: item.rect.minX * k, y: item.rect.minY * k, width: item.rect.width * k, height: item.rect.height * k)
                    if let piece = whole.cropping(to: crop) {
                        let name = "immagine\(index + 1)_\(n + 1).png"
                        try writeImage(piece, to: media.appendingPathComponent(name), type: .png)
                        file = name
                    }
                }
            }
            if let file { add(file, item.rect) }
            if bytes > maxMediaBytes { throw OpError.unsupported(L("le immagini del PDF superano %@ MB", maxMediaBytes / 1_000_000)) }
        }
    }

    private static func body(of pages: [(rows: [[Segment]], size: CGSize)]) -> (left: CGFloat, right: CGFloat) {
        let all = pages.flatMap { $0.rows.flatMap { $0 } }
        return (all.map(\.x).min() ?? 56, all.map(\.right).max() ?? (pages.first?.size.width ?? 595) - 56)
    }

    // MARK: Word's XML

    private static func twips(_ points: CGFloat) -> Int { Int((points * 20).rounded()) }
    private static func emu(_ points: CGFloat) -> Int { Int((points * 12700).rounded()) }

    private static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // What XML 1.0 can't hold is left out: Word would refuse the whole file.
                let v = scalar.value
                if v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    private static func xml(_ run: Run) -> String {
        var properties = "<w:rFonts w:ascii=\"\(escaped(run.family))\" w:hAnsi=\"\(escaped(run.family))\" w:cs=\"\(escaped(run.family))\"/>"
        if run.bold { properties += "<w:b/>" }
        if run.italic { properties += "<w:i/>" }
        if let hex = run.hex { properties += "<w:color w:val=\"\(hex)\"/>" }
        let half = max(2, Int((run.size * 2).rounded()))
        properties += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        if run.underline { properties += "<w:u w:val=\"single\"/>" }
        let content = run.text == "\t" ? "<w:tab/>" : "<w:t xml:space=\"preserve\">\(escaped(run.text))</w:t>"
        return "<w:r><w:rPr>\(properties)</w:rPr>\(content)</w:r>"
    }

    private static func drawing(_ picture: Picture, id: Int, relation: String) -> String {
        let x = emu(picture.rect.minX), y = emu(picture.rect.minY), cx = emu(picture.rect.width), cy = emu(picture.rect.height)
        return """
        <w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="\(id)" behindDoc="\(picture.behindText ? 1 : 0)" locked="0" layoutInCell="1" allowOverlap="1">\
        <wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>\(x)</wp:posOffset></wp:positionH>\
        <wp:positionV relativeFrom="page"><wp:posOffset>\(y)</wp:posOffset></wp:positionV>\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/><wp:docPr id="\(id)" name="Immagine \(id)"/><wp:cNvGraphicFramePr/>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="Immagine \(id)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relation)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>\
        </wp:anchor></w:drawing></w:r>
        """
    }

    /// Writes the document's parts in `folder`, next to the pictures already in `folder`/word/media.
    static func writeParts(_ pages: [Page], in folder: URL) throws {
        var relations: [String: String] = [:]
        func relation(_ file: String) -> String {
            if let known = relations[file] { return known }
            let id = "rId\(relations.count + 10)"
            relations[file] = id
            return id
        }
        var body = ""
        var nextID = 1
        func top(_ page: Page) -> CGFloat {
            max(0, (pages.filter { $0.size == page.size }.flatMap(\.paragraphs).map(\.top).min() ?? 56) - 2)
        }
        var tops: [String: CGFloat] = [:]
        for page in pages where tops["\(page.size)"] == nil { tops["\(page.size)"] = top(page) }
        func section(_ page: Page) -> String {
            // Word's largest page; 14 points at the foot, so that a slightly wider font doesn't spill onto a new page.
            let w = min(twips(page.size.width), 31_680), h = min(twips(page.size.height), 31_680)
            let right = max(0, page.size.width - page.bodyRight - 1)
            return "<w:sectPr><w:pgSz w:w=\"\(w)\" w:h=\"\(h)\"\(w > h ? " w:orient=\"landscape\"" : "")/>"
                + "<w:pgMar w:top=\"\(twips(tops["\(page.size)"] ?? 56))\" w:right=\"\(twips(right))\" w:bottom=\"\(twips(14))\" w:left=\"\(twips(max(0, page.bodyLeft)))\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/></w:sectPr>"
        }
        for (index, page) in pages.enumerated() {
            let top = tops["\(page.size)"] ?? 56
            var cursor = top
            var anchors = ""
            for picture in page.pictures {
                anchors += drawing(picture, id: nextID, relation: relation(picture.file))
                nextID += 1
            }
            let sizeChanges = index + 1 < pages.count && pages[index + 1].size != page.size
            let list = page.paragraphs.isEmpty ? [Paragraph(runs: [], top: top, left: 0, right: 0, leading: 12)] : page.paragraphs
            for (n, paragraph) in list.enumerated() {
                var properties = ""
                if n == 0, index > 0 { properties += "<w:pageBreakBefore/>" }
                if !paragraph.tabs.isEmpty {
                    properties += "<w:tabs>" + paragraph.tabs.map { "<w:tab w:val=\"left\" w:pos=\"\(twips($0))\"/>" }.joined() + "</w:tabs>"
                }
                let before = max(0, paragraph.top - cursor)
                properties += "<w:spacing w:before=\"\(twips(before))\" w:after=\"0\" w:line=\"\(twips(paragraph.leading))\" w:lineRule=\"exact\"/>"
                properties += "<w:ind w:left=\"\(twips(paragraph.left))\" w:right=\"\(twips(paragraph.right))\"\(paragraph.firstLine > 0 ? " w:firstLine=\"\(twips(paragraph.firstLine))\"" : "")/>"
                switch paragraph.alignment {
                case .left: break
                case .center: properties += "<w:jc w:val=\"center\"/>"
                case .right: properties += "<w:jc w:val=\"right\"/>"
                case .justified: properties += "<w:jc w:val=\"both\"/>"
                }
                if n == list.count - 1, sizeChanges { properties += section(page) }
                body += "<w:p><w:pPr>\(properties)</w:pPr>\(n == 0 ? anchors : "")\(paragraph.runs.map(xml).joined())</w:p>"
                cursor = max(cursor, paragraph.top) + paragraph.leading * CGFloat(paragraph.lines)
            }
        }
        body += pages.last.map(section) ?? ""

        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let word = folder.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.createDirectory(at: word.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        func write(_ text: String, _ path: String) throws { try Data(text.utf8).write(to: folder.appendingPathComponent(path)) }
        try write(declaration + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>\(body)</w:body></w:document>", "word/document.xml")
        try write(declaration + "<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>", "word/settings.xml")
        let links = relations.sorted { $0.key < $1.key }.map { "<Relationship Id=\"\($0.value)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\($0.key)\"/>" }.joined()
        try write(declaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>\(links)</Relationships>", "word/_rels/document.xml.rels")
        try write(declaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>", "_rels/.rels")
        try write(declaration + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/></Types>", "[Content_Types].xml")
    }

    // MARK: Text alone

    static func plainText(_ pages: [Page]) -> NSAttributedString {
        let paragraphs = pages.flatMap(\.paragraphs).map { $0.runs.map(\.text).joined() }
        return NSAttributedString(string: paragraphs.joined(separator: "\n"))
    }

    // MARK: RTF, which holds the text and its look but neither pictures nor pages of a set size

    static func attributedText(_ pages: [Page]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, page) in pages.enumerated() {
            var cursor = page.paragraphs.first?.top ?? 0
            for (n, paragraph) in page.paragraphs.enumerated() {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = n == 0 ? 0 : max(0, paragraph.top - cursor)
                style.firstLineHeadIndent = paragraph.left + paragraph.firstLine
                style.headIndent = paragraph.left
                style.tabStops = paragraph.tabs.map { NSTextTab(textAlignment: .left, location: $0) }
                switch paragraph.alignment {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                case .justified: style.alignment = .justified
                }
                for run in paragraph.runs {
                    var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .font: run.font ?? NSFont.systemFont(ofSize: run.size)]
                    if let color = run.color { attributes[.foregroundColor] = color }
                    if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    result.append(NSAttributedString(string: run.text, attributes: attributes))
                }
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
                cursor = max(cursor, paragraph.top) + paragraph.leading * CGFloat(paragraph.lines)
            }
            if index + 1 < pages.count { result.append(NSAttributedString(string: "\u{0C}")) }
        }
        return result
    }
}
