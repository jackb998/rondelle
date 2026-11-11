import AppKit

/// A Keynote file → the slides as `PptxReader.Deck`, so that the PowerPoint code draws them (PDF, images) and
/// lists their text. Read: the slides in order (skipped ones are left out), the text of every text box and
/// placeholder with its size, bold, italic and bullets, the pictures, the speaker notes. Not read: tables, charts,
/// shapes, groups, builds, transitions, backgrounds and the look of the theme (every slide is white).
///
/// A `.key` file is a ZIP (or a folder) with `Index/Document.iwa` (the show and its slide tree),
/// `Index/Slide-N.iwa` (one per slide), `Index/DocumentStylesheet.iwa` and `Data/` (pictures). The message
/// layouts are those of Apple's own `KNArchives`, `TSWPArchives` and `TSDArchives`.
enum KeynoteReader {
    typealias PB = PagesWriter.PB
    private typealias Objects = IWorkFile.Objects

    static let maxSlides = 1000
    /// Pictures kept in memory: a deck of photos must not fill it.
    private static let maxPictureBytes = 40_000_000
    private static let maxPicturesTotal = 300_000_000

    static func read(_ file: URL) throws -> PptxReader.Deck {
        let app = "Keynote"
        let bad = IWorkFile.unreadable(app)
        let objects = try IWorkFile.objects(of: file, app: app) {
            $0 == "Document.iwa" || $0 == "DocumentStylesheet.iwa" || ($0.hasPrefix("Slide-") && $0.hasSuffix(".iwa")) || $0 == "Metadata.iwa"
        }
        // The show: the document's field 2, else the one object of type 2.
        let document = objects.first { $0.value.type == 1 }.map { IWorkFile.fields(Array($0.value.payload)) }
        guard let showID = document.flatMap({ IWorkFile.ref($0, 2) }) ?? objects.first(where: { $0.value.type == 2 })?.key,
              let show = objects[showID], show.type == 2 else { throw bad }
        let showFields = IWorkFile.fields(show.payload)
        let size = IWorkFile.message(showFields, 4)
        let width = IWorkFile.float(size?.first { $0.num == 1 }) ?? 1024, height = IWorkFile.float(size?.first { $0.num == 2 }) ?? 768
        guard (10...6000).contains(width), (10...6000).contains(height) else { throw bad }

        // The slides in order: the tree's `slides`, else its root node and the children below it, else all of them by identifier.
        var nodeIDs: [UInt64] = []
        if let tree = IWorkFile.message(showFields, 3) {
            nodeIDs = IWorkFile.refs(tree, 2)
            if nodeIDs.isEmpty, let root = IWorkFile.ref(tree, 1) { nodeIDs = [root] }
        }
        var slideIDs: [UInt64] = []
        var seen = Set<UInt64>()
        func visit(_ id: UInt64, depth: Int) {
            guard depth < 12, seen.insert(id).inserted, let node = objects[id], node.type == 4 else { return }
            let fields = IWorkFile.fields(node.payload)
            let skipped = fields.first { $0.num == 4 }?.value == 1
            if let slide = IWorkFile.ref(fields, 2), !skipped { slideIDs.append(slide) }
            for child in IWorkFile.refs(fields, 1) { visit(child, depth: depth + 1) }
        }
        for id in nodeIDs { visit(id, depth: 0) }
        if slideIDs.isEmpty {
            slideIDs = objects.filter { $0.value.type == 5 && IWorkFile.fields($0.value.payload).contains { $0.num == 19 && $0.value == 1 } }.keys.sorted()
        }
        guard !slideIDs.isEmpty else { throw bad }
        guard slideIDs.count <= maxSlides else {
            throw OpError.unsupported(L("«%@» ha troppe diapositive (massimo %@)", file.lastPathComponent, maxSlides))
        }

        // Pictures: identifier → name of the file in `Data/` («name-ID.ext»).
        var pictureFiles: [UInt64: String] = [:]
        let dataNames = IWorkFile.names(file).filter { $0.hasPrefix("Data/") }
        for name in dataNames {
            let stem = (name as NSString).deletingPathExtension
            if let dash = stem.lastIndex(of: "-"), let id = UInt64(stem[stem.index(after: dash)...]) { pictureFiles[id] = name }
        }
        var images: [String: Data] = [:]
        var imageBytes = 0

        var slides: [PptxReader.Slide] = []
        for id in slideIDs {
            try PDFOps.checkCancelled()
            guard let slide = objects[id], slide.type == 5 else { continue }
            let fields = IWorkFile.fields(slide.payload)
            var order = IWorkFile.refs(fields, 42)
            if order.isEmpty { order = IWorkFile.refs(fields, 7) }
            var items: [PptxReader.Item] = []
            for drawable in order {
                guard let object = objects[drawable] else { continue }
                let parts = IWorkFile.fields(object.payload)
                switch object.type {
                case 7, 2011:   // a placeholder or a text box: its geometry and its text storage
                    let shape = object.type == 7 ? (IWorkFile.message(parts, 1) ?? []) : parts
                    let frame = geometry(of: shape, path: [1, 1, 1])
                    guard let frame, let storageID = IWorkFile.ref(shape, 4) ?? IWorkFile.ref(shape, 2),
                          let text = text(of: storageID, objects) else { continue }
                    items.append(PptxReader.Item(frame: frame, content: .shape(.rect, fill: nil, line: nil, lineWidth: 0, text: text), layer: 2))
                case 3005:      // a picture
                    guard let frame = geometry(of: parts, path: [1, 1]),
                          let dataID = IWorkFile.ref(parts, 11) ?? IWorkFile.ref(parts, 13) ?? IWorkFile.ref(parts, 12) ?? IWorkFile.ref(parts, 15),
                          let name = pictureFiles[dataID] else { continue }
                    let key = "key:\(dataID)"
                    if images[key] == nil {
                        guard imageBytes < maxPicturesTotal, let data = IWorkFile.data(name, in: file, max: maxPictureBytes) else { continue }
                        images[key] = data
                        imageBytes += data.count
                    }
                    items.append(PptxReader.Item(frame: frame, content: .picture(path: key, crop: PptxReader.Crop(), clip: nil), layer: 2))
                default: break
                }
            }
            var notes = ""
            if let noteID = IWorkFile.ref(fields, 27), let note = objects[noteID], note.type == 15,
               let storageID = IWorkFile.ref(IWorkFile.fields(note.payload), 1),
               let attributed = attributed(of: storageID, objects) {
                notes = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            slides.append(PptxReader.Slide(background: nil, items: items, notes: notes))
        }
        guard !slides.isEmpty else { throw bad }
        return PptxReader.Deck(size: CGSize(width: width, height: height), slides: slides, images: images)
    }

    // MARK: Pieces

    /// A drawable's frame: `path` leads from `fields` through the nested messages to the drawable's field 1 (geometry).
    private static func geometry(of fields: [PB.Field], path: [Int]) -> PptxReader.Frame? {
        var current = fields
        for number in path.dropLast() {
            guard let next = IWorkFile.message(current, number) else { return nil }
            current = next
        }
        guard let geometry = IWorkFile.message(current, path.last!),
              let position = IWorkFile.message(geometry, 1), let size = IWorkFile.message(geometry, 2),
              let x = IWorkFile.float(position.first { $0.num == 1 }), let y = IWorkFile.float(position.first { $0.num == 2 }),
              let w = IWorkFile.float(size.first { $0.num == 1 }), let h = IWorkFile.float(size.first { $0.num == 2 }),
              [x, y, w, h].allSatisfy(\.isFinite), w >= 0, h >= 0 else { return nil }
        var frame = PptxReader.Frame(x: x, y: y, w: w, h: h)
        frame.rot = IWorkFile.float(geometry.first { $0.num == 4 }) ?? 0
        return frame
    }

    /// The storage's text with the look its styles give it (the Pages code does it), or nil if it is empty.
    private static func attributed(of id: UInt64, _ objects: Objects) -> NSAttributedString? {
        guard let object = objects[id], object.type == 2001 else { return nil }
        let fields = IWorkFile.fields(object.payload)
        let text = fields.filter { $0.num == 3 && $0.wire == 2 }.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))).isEmpty else { return nil }
        guard let result = try? PagesReader.render(text: text, fields: fields, objects: objects) else { return nil }
        return result.length > 0 ? result : nil
    }

    private static func text(of id: UInt64, _ objects: Objects) -> PptxReader.Text? {
        guard let source = attributed(of: id, objects) else { return nil }
        let whole = source.string as NSString
        var paragraphs: [PptxReader.Paragraph] = []
        var location = 0
        while location < whole.length {
            let range = whole.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var body = range
            while body.length > 0, [10, 13].contains(whole.character(at: NSMaxRange(body) - 1)) { body.length -= 1 }
            var runs: [PptxReader.Run] = []
            var firstSize = 18.0
            // The Pages code puts a list's bullet or number in the text («•» or «1.» and a tab): here it is the paragraph's
            // bullet, as in a PowerPoint paragraph (a tab right after the margin would push the text out of the box).
            var bullet: String?
            if body.length > 2 {
                let head = whole.substring(with: NSRange(location: body.location, length: min(body.length, 12)))
                if let tab = head.firstIndex(of: "\t"), head.distance(from: head.startIndex, to: tab) <= 5,
                   head[..<tab] == "•" || head[..<tab].allSatisfy({ $0.isNumber || $0 == "." }) {
                    bullet = String(head[..<tab])
                    let cut = (head[..<tab].utf16.count) + 1
                    body = NSRange(location: body.location + cut, length: body.length - cut)
                }
            }
            if body.length > 0 {
                source.enumerateAttributes(in: body, options: []) { attributes, runRange, _ in
                    let piece = whole.substring(with: runRange).replacingOccurrences(of: "\u{2028}", with: "\n")
                    guard !piece.isEmpty else { return }
                    let font = attributes[.font] as? NSFont
                    let traits = font?.fontDescriptor.symbolicTraits ?? []
                    let size = Double(font?.pointSize ?? 18)
                    if runs.isEmpty { firstSize = size }
                    runs.append(PptxReader.Run(text: piece, font: nil, size: size, bold: traits.contains(.bold), italic: traits.contains(.italic),
                                               underline: false, color: .black))
                }
            }
            paragraphs.append(PptxReader.Paragraph(runs: runs, align: .left, marL: bullet == nil ? 0 : 24, indent: bullet == nil ? 0 : -24, bullet: bullet,
                                                   spaceBefore: 0, spaceAfter: 4,
                                                   lineMultiple: 1, emptySize: firstSize))
        }
        guard !paragraphs.isEmpty else { return nil }
        return PptxReader.Text(paragraphs: paragraphs)
    }
}
