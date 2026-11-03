import AppKit
import ImageIO

/// What the system's importer of DOCX and ODT leaves out: pictures, page breaks and the size of the page. A copy of the
/// document goes through it with a mark where each of those was, and the marks then become what they stand for.
enum PackedImages {
    /// Pages and margins, in points.
    struct PageLayout {
        var paper = CGSize(width: 595, height: 842)
        var top: CGFloat = 56, left: CGFloat = 56, bottom: CGFloat = 56, right: CGFloat = 56

        /// A document can say anything: sizes no paper has, or margins wider than the page, fall back on A4.
        var sane: PageLayout {
            let fine = (100...5000).contains(paper.width) && (100...5000).contains(paper.height) && min(top, left, bottom, right) >= 0
                && paper.width - left - right >= 72 && paper.height - top - bottom >= 72
            return fine ? self : PageLayout()
        }
    }

    /// The line break that ends a page in the text handed to `DocumentOps.renderPDF`.
    static let pageBreak = NSAttributedString.Key("RondellePageBreak")
    static let maxPictures = 2_000
    /// A picture's longest side once in the document: enough for A4 at 300 dpi.
    static let maxSide = 3_508
    private static let open = "\u{E100}", close = "\u{E101}", breakMark = "\u{E102}"

    fileprivate struct Picture { let entry: String; let size: CGSize }
    struct Prepared { let copy: URL; let layout: PageLayout; fileprivate let pictures: [Picture] }

    /// The marked copy in `work`. Nil when the document isn't laid out as expected: it is then imported as it is.
    static func prepare(_ url: URL, in work: URL) -> Prepared? {
        let isODT = url.pathExtension.lowercased() == "odt"
        let name = isODT ? "content.xml" : "word/document.xml"
        guard let data = try? ArchiveOps.entryData(in: url, entry: name, maxBytes: Int64(ContentLimits.maxPackedXML)),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let result = isODT ? markODT(xml, url) : markDOCX(xml, url)
        guard let result else { return nil }
        let copy = work.appendingPathComponent("documento." + url.pathExtension.lowercased())
        let file = work.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(result.xml.utf8).write(to: file)
            try FileManager.default.copyItem(at: url, to: copy)
            try ArchiveOps.update(copy, entry: name, in: work)
        } catch { return nil }
        return Prepared(copy: copy, layout: result.layout.sane, pictures: result.pictures)
    }

    /// Replaces the marks in the text that came out of the importer.
    static func finish(_ text: NSAttributedString, _ prepared: Prepared, from url: URL) throws -> NSAttributedString {
        var loaded: [String: CGImage?] = [:]
        let result = NSMutableAttributedString(attributedString: text)
        let string = result.string as NSString
        var cursor = string.length
        while cursor > 0 {
            let open = string.rangeOfCharacter(from: CharacterSet(charactersIn: self.open + breakMark), options: .backwards, range: NSRange(location: 0, length: cursor))
            guard open.location != NSNotFound else { break }
            cursor = open.location
            if string.substring(with: open) == breakMark {
                var attributes = result.attributes(at: open.location, effectiveRange: nil)
                attributes[pageBreak] = true
                result.replaceCharacters(in: open, with: NSAttributedString(string: "\n", attributes: attributes))
                continue
            }
            let tail = NSRange(location: open.upperBound, length: min(8, string.length - open.upperBound))
            let end = string.range(of: self.close, range: tail)
            guard end.location != NSNotFound, let index = Int(string.substring(with: NSRange(location: open.upperBound, length: end.location - open.upperBound))),
                  prepared.pictures.indices.contains(index) else { continue }
            try PDFOps.checkCancelled()
            let picture = prepared.pictures[index]
            if loaded[picture.entry] == nil { loaded[picture.entry] = load(picture.entry, from: url) }
            let whole = NSRange(location: open.location, length: end.upperBound - open.location)
            if let image = loaded[picture.entry] ?? nil {
                let attachment = NSTextAttachment()
                attachment.image = NSImage(cgImage: image, size: picture.size)
                attachment.bounds = CGRect(origin: .zero, size: picture.size)
                result.replaceCharacters(in: whole, with: NSAttributedString(attachment: attachment))
            } else {
                result.deleteCharacters(in: whole)
            }
        }
        return result
    }

    /// One picture, at most `maxSide`: its header can claim any size and the decoder only builds the reduced one.
    private static func load(_ entry: String, from url: URL) -> CGImage? {
        guard let data = try? ArchiveOps.entryData(in: url, entry: entry, maxBytes: Int64(Limits.maxPackedDocumentBytes)),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
    }

    // MARK: Reading the XML

    /// Each stretch from `start` to `end`, replaced by what `replace` makes of it (nil: left as it is).
    private static func replacing(_ xml: String, from start: String, to end: String, _ replace: (String) -> String?) -> String {
        let source = xml as NSString
        let out = NSMutableString()
        var position = 0
        while position < source.length {
            let found = source.range(of: start, range: NSRange(location: position, length: source.length - position))
            guard found.location != NSNotFound else { break }
            let rest = NSRange(location: found.upperBound, length: source.length - found.upperBound)
            let stop = source.range(of: end, range: rest)
            guard stop.location != NSNotFound else { break }
            let whole = NSRange(location: found.location, length: stop.upperBound - found.location)
            out.append(source.substring(with: NSRange(location: position, length: found.location - position)))
            out.append(replace(source.substring(with: whole)) ?? source.substring(with: whole))
            position = whole.upperBound
        }
        out.append(source.substring(from: min(position, source.length)))
        return out as String
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + "=\"") else { return nil }
        let rest = text[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    /// An entry a document may refer to, inside the package; anything else (another folder, a web address) isn't read.
    private static func safeEntry(_ path: String) -> String? {
        let bad = CharacterSet(charactersIn: "*?[]\\:").union(.controlCharacters)
        guard !path.isEmpty, !path.contains(".."), !path.hasPrefix("-"), path.rangeOfCharacter(from: bad) == nil else { return nil }
        return path
    }

    private static func markDOCX(_ xml: String, _ url: URL) -> (xml: String, layout: PageLayout, pictures: [Picture])? {
        var links: [String: String] = [:]
        if let data = try? ArchiveOps.entryData(in: url, entry: "word/_rels/document.xml.rels", maxBytes: 5_000_000), let rels = String(data: data, encoding: .utf8) {
            for piece in rels.components(separatedBy: "<Relationship ").dropFirst() {
                guard let id = attribute("Id", in: piece), let target = attribute("Target", in: piece), attribute("TargetMode", in: piece) == nil else { continue }
                let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
                if let safe = safeEntry(path) { links[id] = safe }
            }
        }
        var pictures: [Picture] = []
        func mark(_ piece: String) -> String? {
            guard pictures.count < maxPictures, let id = attribute("r:embed", in: piece) ?? attribute("r:id", in: piece), let entry = links[id] else { return "" }
            var size = CGSize(width: 200, height: 150)
            if let cx = attribute("cx", in: piece).flatMap(Double.init), let cy = attribute("cy", in: piece).flatMap(Double.init), cx > 0, cy > 0 {
                size = CGSize(width: cx / 12700, height: cy / 12700)
            }
            pictures.append(Picture(entry: entry, size: size))
            return "<w:t>\(open)\(pictures.count - 1)\(close)</w:t>"
        }
        var marked = replacing(xml, from: "<w:drawing", to: "</w:drawing>", mark)
        marked = marked.replacingOccurrences(of: "<w:br w:type=\"page\"/>", with: "<w:t>\(breakMark)</w:t>")
        var layout = PageLayout()
        // The last section's, which is the document's unless it changes along the way.
        if let start = xml.range(of: "<w:sectPr", options: .backwards) {
            let section = String(xml[start.lowerBound...])
            let size = section.range(of: "<w:pgSz").map { String(section[$0.upperBound...].prefix(200)) } ?? ""
            let margins = section.range(of: "<w:pgMar").map { String(section[$0.upperBound...].prefix(300)) } ?? ""
            func value(_ name: String, _ text: String, _ fallback: CGFloat) -> CGFloat {
                attribute("w:" + name, in: text).flatMap(Double.init).map { CGFloat($0) / 20 } ?? fallback
            }
            layout.paper = CGSize(width: value("w", size, layout.paper.width), height: value("h", size, layout.paper.height))
            layout.top = value("top", margins, layout.top)
            layout.bottom = value("bottom", margins, layout.bottom)
            layout.left = value("left", margins, layout.left)
            layout.right = value("right", margins, layout.right)
        }
        return (marked, layout, pictures)
    }

    private static func length(_ text: String?) -> CGFloat? {
        guard let text else { return nil }
        let units: [(String, Double)] = [("cm", 72 / 2.54), ("mm", 72 / 25.4), ("in", 72), ("pt", 1), ("px", 0.75)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count)).map { CGFloat($0 * factor) }
        }
        return nil
    }

    private static func markODT(_ xml: String, _ url: URL) -> (xml: String, layout: PageLayout, pictures: [Picture])? {
        var pictures: [Picture] = []
        let marked = replacing(xml, from: "<draw:frame", to: "</draw:frame>") { piece in
            guard piece.contains("<draw:image"), let path = attribute("xlink:href", in: piece) else { return nil }
            guard pictures.count < maxPictures, let entry = safeEntry(path.hasPrefix("./") ? String(path.dropFirst(2)) : path) else { return "" }
            let size = CGSize(width: length(attribute("svg:width", in: piece)) ?? 200, height: length(attribute("svg:height", in: piece)) ?? 150)
            pictures.append(Picture(entry: entry, size: size))
            return "<text:span>\(open)\(pictures.count - 1)\(close)</text:span>"
        }
        var layout = PageLayout()
        if let data = try? ArchiveOps.entryData(in: url, entry: "styles.xml", maxBytes: Int64(ContentLimits.maxPackedXML)), let styles = String(data: data, encoding: .utf8),
           let start = styles.range(of: "<style:page-layout-properties") {
            let piece = String(styles[start.upperBound...].prefix(800))
            if let w = length(attribute("fo:page-width", in: piece)), let h = length(attribute("fo:page-height", in: piece)) { layout.paper = CGSize(width: w, height: h) }
            layout.top = length(attribute("fo:margin-top", in: piece)) ?? layout.top
            layout.bottom = length(attribute("fo:margin-bottom", in: piece)) ?? layout.bottom
            layout.left = length(attribute("fo:margin-left", in: piece)) ?? layout.left
            layout.right = length(attribute("fo:margin-right", in: piece)) ?? layout.right
        }
        return (marked, layout, pictures)
    }
}
