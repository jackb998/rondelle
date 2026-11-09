import AppKit

/// Any document → a Pages file, written by Rondelle itself.
///
/// A `.pages` file is a ZIP of `.iwa` archives (Snappy-compressed protobuf). Rondelle takes the empty
/// document that the installed Pages ships as a template, replaces the text of its body and the tables of
/// paragraph, character and list styles, and zips the result again. Nothing is sent to Pages: no Apple
/// Events, no new permission. The template is read from the installed app each time and never copied into
/// Rondelle, so without Pages there is no conversion (the wheel doesn't offer it then).
///
/// Supported: text, paragraphs, Title/Heading/Body styles (chosen from the font size), bold, italic,
/// bold italic, bullet and numbered lists (one level). Not supported yet: tables, pictures, nested lists.
enum PagesWriter {
    // Objects of the template (`00B_Blank_Portrait`): the body's text storage and the styles of its stylesheet.
    private static let bodyStorage: UInt64 = 69187
    private static let titleStyle: UInt64 = 68330, headingStyle: UInt64 = 68331, bodyStyle: UInt64 = 68332
    private static let boldStyle: UInt64 = 68351, italicStyle: UInt64 = 68350
    private static let listNone: UInt64 = 68320, listBullet: UInt64 = 68321, listNumbered: UInt64 = 68325
    /// A character style Rondelle adds (bold and italic together); the template has none.
    private static let boldItalicStyle: UInt64 = 70000
    private static let templateText = "Blank Book\u{4}Heading"

    // MARK: Public

    /// Writes `text` as a Pages document at `out`.
    static func write(_ text: NSAttributedString, to out: URL) throws {
        let content = Content(text)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("rondelle-pages-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try run("/usr/bin/unzip", ["-q", "-o", try templateURL().path, "-d", work.path])
        let documentURL = work.appendingPathComponent("Index/Document.iwa")
        guard let raw = fm.contents(atPath: documentURL.path) else { throw unknownTemplate }
        let patched = try patch(try IWA.decode([UInt8](raw)), with: content)
        try Data(IWA.encode(patched)).write(to: documentURL)

        let archive = work.appendingPathComponent("out.pages")
        try run("/usr/bin/zip", ["-0", "-X", "-q", "-r", archive.path, "Index", "Metadata"], in: work)
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.moveItem(at: archive, to: out)
    }

    /// The text of the body of a Pages file written by `write` (for the tests).
    static func bodyText(of file: URL) throws -> String {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rondelle-pages-\(UUID().uuidString).iwa")
        defer { try? FileManager.default.removeItem(at: work) }
        _ = FileManager.default.createFile(atPath: work.path, contents: nil)
        let handle = try FileHandle(forWritingTo: work)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", file.path, "Index/Document.iwa"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); try handle.close()
        guard process.terminationStatus == 0, let raw = FileManager.default.contents(atPath: work.path) else { throw unknownTemplate }
        for object in try Archive.parse(try IWA.decode([UInt8](raw))) where object.id == bodyStorage {
            if let field = try PB.parse(object.payloads[0]).first(where: { $0.num == 3 }) { return String(decoding: field.data, as: UTF8.self) }
        }
        throw unknownTemplate
    }

    private static var unknownTemplate: OpError {
        .unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle"))
    }

    // MARK: Template

    private static func templateURL() throws -> URL {
        guard let app = IWorkOps.App.pages.installed else {
            throw OpError.unsupported(L("Per creare un file Pages serve Pages installato"))
        }
        let folder = app.appendingPathComponent("Contents/SharedSupport/Templates/00B_Blank_Portrait", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".template") }.sorted()
        guard let name = names.first(where: { $0 == "ISO.template" }) ?? names.first else { throw unknownTemplate }
        return folder.appendingPathComponent(name)
    }

    private static func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpError.failed(L("Creazione del file Pages non riuscita")) }
    }

    // MARK: The document's content

    /// Paragraphs and runs, as the tables of the storage need them (indexes in UTF-16 units, like NSString).
    private struct Content {
        var text = ""
        var paragraphs: [(start: Int, style: UInt64)] = []
        var lists: [(start: Int, style: UInt64)] = []
        var runs: [(start: Int, style: UInt64?)] = []   // character style from `start`; nil = none

        init(_ source: NSAttributedString) {
            struct Run { var text: String; var bold: Bool; var italic: Bool; var size: CGFloat }
            struct Paragraph { var runs: [Run]; var list: UInt64 }
            var found: [Paragraph] = []
            let whole = source.string as NSString
            var location = 0
            while location < whole.length {
                let range = whole.paragraphRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                var body = range
                while body.length > 0, [10, 13, 0x2029].contains(whole.character(at: NSMaxRange(body) - 1)) { body.length -= 1 }
                // A list's marker is written into the text («\t•\t», «\t1\t»): it is dropped, Pages draws its own.
                // Some importers (RTF, HTML) also declare the list; Word files only have the marker.
                var list = listNone
                if body.length > 0 {
                    let head = whole.substring(with: NSRange(location: body.location, length: min(body.length, 12)))
                    let marker = head.hasPrefix("\t") ? head.dropFirst().prefix(while: { $0 != "\t" }) : ""
                    let closed = head.hasPrefix("\t") && head.dropFirst().contains("\t")
                    let symbols: Set<Character> = ["•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "–", "-", "*"]
                    let isSymbol = marker.count == 1 && symbols.contains(marker.first!)
                    let isNumber = !marker.isEmpty && marker.count <= 5 && marker.allSatisfy { $0.isNumber || $0.isLetter || $0 == "." || $0 == ")" }
                        && marker.contains(where: { $0.isNumber || ($0.isLetter && marker.count <= 2) })
                    let declared = (source.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last
                    if closed, declared != nil || isSymbol || isNumber {
                        let bullets = ["disc", "circle", "square", "diamond", "hyphen", "check", "box"]
                        let bullet = declared.map { format in bullets.contains { format.markerFormat.rawValue.contains($0) } } ?? isSymbol
                        list = bullet ? listBullet : listNumbered
                        let drop = 1 + marker.utf16.count + 1
                        body = NSRange(location: body.location + drop, length: body.length - drop)
                    }
                }
                var runs: [Run] = []
                if body.length > 0 {
                    source.enumerateAttributes(in: body, options: []) { attributes, runRange, _ in
                        var piece = whole.substring(with: runRange)
                        piece = String(piece.unicodeScalars.compactMap { scalar -> Character? in
                            if scalar == "\u{2028}" || scalar == "\u{B}" { return "\u{2028}" }
                            if scalar == "\t" { return "\t" }
                            if scalar.value < 0x20 || scalar == "\u{FFFC}" || scalar == "\u{2029}" { return nil }
                            return Character(scalar)
                        })
                        guard !piece.isEmpty else { return }
                        let font = attributes[.font] as? NSFont
                        let traits = font?.fontDescriptor.symbolicTraits ?? []
                        runs.append(Run(text: piece, bold: traits.contains(.bold), italic: traits.contains(.italic), size: font?.pointSize ?? 12))
                    }
                }
                found.append(Paragraph(runs: runs, list: list))
            }
            if found.isEmpty { found = [Paragraph(runs: [], list: listNone)] }

            // The body size is the one most of the characters have; bigger text is a heading or the title.
            var weight: [CGFloat: Int] = [:]
            for paragraph in found { for run in paragraph.runs { weight[run.size, default: 0] += run.text.utf16.count } }
            let base = weight.max { $0.value < $1.value }?.key ?? 12

            var total = 0   // UTF-16 length of `text`, kept by hand (counting it each time is slow on long texts)
            for (index, paragraph) in found.enumerated() {
                if index > 0 { text += "\n"; total += 1 }
                let start = total
                var sizes: [CGFloat: Int] = [:]
                for run in paragraph.runs { sizes[run.size, default: 0] += run.text.utf16.count }
                let size = sizes.max { $0.value < $1.value }?.key ?? base
                let length = paragraph.runs.reduce(0) { $0 + $1.text.utf16.count }
                let allBold = !paragraph.runs.isEmpty && paragraph.runs.allSatisfy(\.bold)
                var style = bodyStyle
                if paragraph.list == listNone {
                    if size >= base * 2 { style = titleStyle }
                    else if size >= base * 1.2 || (allBold && size >= base * 1.1 && length < 100) { style = headingStyle }
                }
                paragraphs.append((start, style))
                lists.append((start, paragraph.list))
                for run in paragraph.runs {
                    // Titles and headings are bold by their style already.
                    let bold = run.bold && style == bodyStyle, italic = run.italic
                    let character: UInt64? = bold && italic ? boldItalicStyle : bold ? boldStyle : italic ? italicStyle : nil
                    runs.append((total, character))
                    text += run.text
                    total += run.text.utf16.count
                    runs.append((total, nil))
                }
            }
            // Compact the runs; an entry at the very end of the text would make Pages drop the whole table.
            var compact: [(start: Int, style: UInt64?)] = []
            var current: UInt64?
            for entry in runs {
                if entry.style == current { continue }
                if let last = compact.last, last.start == entry.start { compact[compact.count - 1] = entry } else { compact.append(entry) }
                current = entry.style
            }
            if compact.first?.start != 0 { compact.insert((0, nil), at: 0) }
            runs = compact.filter { $0.start < total }
        }
    }

    // MARK: Patching Document.iwa

    private static func patch(_ document: [UInt8], with content: Content) throws -> [UInt8] {
        var objects = try Archive.parse(document)
        guard let at = objects.firstIndex(where: { $0.id == bodyStorage }),
              let first = try PB.parse(objects[at].payloads[0]).first(where: { $0.num == 3 }),
              String(decoding: first.data, as: UTF8.self) == templateText else { throw unknownTemplate }

        func entry(_ index: Int, _ ref: UInt64? = nil) -> PB.Field {
            var inner = [PB.Field.int(1, UInt64(index))]
            if let ref { inner.append(.bytes(2, PB.build([.int(1, ref)]))) }
            return .bytes(1, PB.build(inner))
        }
        let starts = content.paragraphs.map(\.start)
        let firstEnd = starts.count > 1 ? starts[1] - 1 : 0

        var fields: [PB.Field] = []
        for field in try PB.parse(objects[at].payloads[0]) {
            switch field.num {
            case 3:
                fields.append(.bytes(3, [UInt8](content.text.utf8)))
            case 5:
                fields.append(.bytes(5, PB.build(content.paragraphs.map { entry($0.start, $0.style) })))
            case 7:
                fields.append(.bytes(7, PB.build(content.lists.map { entry($0.start, $0.style) })))
            case 11, 17, 19:
                // The template's own per-paragraph data: the first paragraph keeps the first entry, the rest the last one.
                let entries = try PB.parse(field.data)
                let head = Array(try PB.parse(entries[0].data).dropFirst())
                let tail = Array(try PB.parse(entries[entries.count - 1].data).dropFirst())
                var table: [PB.Field] = [.bytes(1, PB.build([.int(1, 0)] + head))]
                if starts.count > 1 {
                    if firstEnd > 0 { table.append(entry(firstEnd)) }
                    table.append(.bytes(1, PB.build([.int(1, UInt64(starts[1]))] + tail)))
                }
                fields.append(.bytes(field.num, PB.build(table)))
            default:
                fields.append(field)
            }
        }
        // Character styles: a table the blank document doesn't have.
        fields.append(.bytes(8, PB.build(content.runs.map { entry($0.start, $0.style) })))
        fields.sort { $0.num < $1.num }
        objects[at].payloads[0] = PB.build(fields)

        // Everything the body refers to is listed in its header.
        var used: Set<UInt64> = []
        for (_, style) in content.paragraphs { used.insert(style) }
        for (_, style) in content.lists { used.insert(style) }
        for (_, style) in content.runs { if let style { used.insert(style) } }
        try objects[at].addReferences(used.intersection([bodyStyle, boldStyle, italicStyle, listBullet, listNumbered]))

        if used.contains(boldItalicStyle) {
            let header = PB.build([.bytes(1, [UInt8]("Bold Italic".utf8)), .bytes(5, PB.build([.int(1, 69271)]))])
            let payload = PB.build([.bytes(1, header), .int(10, 1), .bytes(11, PB.build([.int(1, 1), .int(2, 1)]))])
            // Same version bytes as the template's own styles (1.0.5); the stylesheet is object 69271.
            var object = Archive.Object(id: boldItalicStyle)
            object.messages = [([.int(1, 2021), .bytes(2, [1, 0, 5]), .int(3, UInt64(payload.count))], payload)]
            objects.append(object)
        }
        return Archive.build(objects)
    }

    // MARK: Containers

    /// The archives of an `.iwa` file: an ArchiveInfo (protobuf: id, message infos) and the messages' bytes.
    /// Every field of the info that Rondelle doesn't change is kept as it was.
    enum Archive {
        struct Object {
            var id: UInt64
            /// Fields of the ArchiveInfo other than the id and the message infos.
            var extra: [PB.Field] = []
            /// One entry per message: its info (type 1, version 2, length 3, field infos 4, references 5, …) and its bytes.
            var messages: [(info: [PB.Field], payload: [UInt8])] = []

            var payloads: [[UInt8]] {
                get { messages.map(\.payload) }
                set { for (i, p) in newValue.enumerated() { messages[i].payload = p } }
            }

            mutating func addReferences(_ ids: Set<UInt64>) throws {
                guard !messages.isEmpty else { return }
                var info = messages[0].info
                var known: [UInt64] = []
                if let at = info.firstIndex(where: { $0.num == 5 }) {
                    var j = 0
                    while j < info[at].data.count { known.append(try PB.readVarint(info[at].data, &j)) }
                    known += ids.sorted().filter { !known.contains($0) }
                    info[at].data = known.flatMap { PB.varint($0) }
                } else {
                    info.append(.bytes(5, ids.sorted().flatMap { PB.varint($0) }))
                }
                messages[0].info = info
            }
        }

        static func parse(_ data: [UInt8]) throws -> [Object] {
            var objects: [Object] = []
            var i = 0
            while i < data.count {
                let length = Int(try PB.readVarint(data, &i))
                guard length >= 0, i + length <= data.count else { throw bad() }
                let info = try PB.parse(Array(data[i..<(i + length)])); i += length
                var object = Object(id: 0)
                for field in info {
                    if field.num == 1 { object.id = field.value; continue }
                    guard field.num == 2 else { object.extra.append(field); continue }
                    let inner = try PB.parse(field.data)
                    let size = Int(inner.first(where: { $0.num == 3 })?.value ?? 0)
                    guard i + size <= data.count else { throw bad() }
                    object.messages.append((inner, Array(data[i..<(i + size)]))); i += size
                }
                objects.append(object)
            }
            return objects
        }

        static func build(_ objects: [Object]) -> [UInt8] {
            var out: [UInt8] = []
            for object in objects {
                var fields: [PB.Field] = [.int(1, object.id)]
                for message in object.messages {
                    let info = message.info.map { $0.num == 3 ? PB.Field.int(3, UInt64(message.payload.count)) : $0 }
                    fields.append(.bytes(2, PB.build(info)))
                }
                fields += object.extra
                let header = PB.build(fields)
                out += PB.varint(UInt64(header.count)) + header
                for message in object.messages { out += message.payload }
            }
            return out
        }

        private static func bad() -> OpError {
            .unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle"))
        }
    }

    // MARK: Protobuf (just what the archives need)

    enum PB {
        struct Field {
            var num: Int
            var wire: Int
            var value: UInt64 = 0
            var data: [UInt8] = []
            static func int(_ n: Int, _ v: UInt64) -> Field { Field(num: n, wire: 0, value: v) }
            static func bytes(_ n: Int, _ d: [UInt8]) -> Field { Field(num: n, wire: 2, data: d) }
        }

        static func varint(_ value: UInt64) -> [UInt8] {
            var n = value, out: [UInt8] = []
            while true {
                let byte = UInt8(n & 0x7f); n >>= 7
                if n == 0 { out.append(byte); return out }
                out.append(byte | 0x80)
            }
        }

        static func readVarint(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw OpError.unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle")) }
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7f) << shift; shift += 7
                if byte & 0x80 == 0 { return result }
            }
        }

        static func parse(_ b: [UInt8]) throws -> [Field] {
            var i = 0, fields: [Field] = []
            while i < b.count {
                let key = try readVarint(b, &i)
                var field = Field(num: Int(key >> 3), wire: Int(key & 7))
                switch field.wire {
                case 0: field.value = try readVarint(b, &i)
                case 2:
                    let length = Int(try readVarint(b, &i))
                    guard length >= 0, i + length <= b.count else { throw OpError.unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle")) }
                    field.data = Array(b[i..<(i + length)]); i += length
                case 1, 5:
                    let size = field.wire == 1 ? 8 : 4
                    guard i + size <= b.count else { throw OpError.unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle")) }
                    field.data = Array(b[i..<(i + size)]); i += size
                default: throw OpError.unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle"))
                }
                fields.append(field)
            }
            return fields
        }

        static func build(_ fields: [Field]) -> [UInt8] {
            var out: [UInt8] = []
            for field in fields {
                out += varint(UInt64(field.num << 3 | field.wire))
                switch field.wire {
                case 0: out += varint(field.value)
                case 2: out += varint(UInt64(field.data.count)) + field.data
                default: out += field.data
                }
            }
            return out
        }
    }

    // MARK: IWA (blocks of Snappy)

    enum IWA {
        static func decode(_ raw: [UInt8]) throws -> [UInt8] {
            var out: [UInt8] = [], i = 0
            while i < raw.count {
                guard i + 4 <= raw.count, raw[i] == 0 else { throw OpError.unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle")) }
                let length = Int(raw[i + 1]) | Int(raw[i + 2]) << 8 | Int(raw[i + 3]) << 16
                i += 4
                guard i + length <= raw.count else { throw OpError.unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle")) }
                out += try snappyDecode(Array(raw[i..<(i + length)])); i += length
            }
            return out
        }

        /// Blocks of at most 64 KB, Snappy with literals only: valid, and Pages reads it.
        static func encode(_ data: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [], i = 0
            repeat {
                let block = snappyLiteral(Array(data[i..<min(i + 65536, data.count)]))
                out += [0, UInt8(block.count & 0xff), UInt8(block.count >> 8 & 0xff), UInt8(block.count >> 16 & 0xff)] + block
                i += 65536
            } while i < data.count
            return out
        }

        static func snappyDecode(_ d: [UInt8]) throws -> [UInt8] {
            var i = 0
            let expected = Int(try PB.readVarint(d, &i))
            var out: [UInt8] = []
            out.reserveCapacity(expected)
            func bad() -> OpError { .unsupported(L("Il modello di Pages installato non è riconosciuto: aggiorna Rondelle")) }
            while i < d.count {
                let tag = d[i]; i += 1
                if tag & 3 == 0 {
                    var length = Int(tag >> 2)
                    if length >= 60 {
                        let count = length - 59
                        guard i + count <= d.count else { throw bad() }
                        length = 0
                        for k in 0..<count { length |= Int(d[i + k]) << (8 * k) }
                        i += count
                    }
                    length += 1
                    guard i + length <= d.count else { throw bad() }
                    out += d[i..<(i + length)]; i += length
                } else {
                    var length: Int, offset: Int
                    switch tag & 3 {
                    case 1:
                        guard i < d.count else { throw bad() }
                        length = Int(tag >> 2 & 7) + 4; offset = Int(tag >> 5) << 8 | Int(d[i]); i += 1
                    case 2:
                        guard i + 2 <= d.count else { throw bad() }
                        length = Int(tag >> 2) + 1; offset = Int(d[i]) | Int(d[i + 1]) << 8; i += 2
                    default:
                        guard i + 4 <= d.count else { throw bad() }
                        length = Int(tag >> 2) + 1; offset = Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24; i += 4
                    }
                    guard offset > 0, offset <= out.count else { throw bad() }
                    for _ in 0..<length { out.append(out[out.count - offset]) }
                }
            }
            guard out.count == expected else { throw bad() }
            return out
        }

        static func snappyLiteral(_ d: [UInt8]) -> [UInt8] {
            var out = PB.varint(UInt64(d.count)), i = 0
            while i < d.count {
                let chunk = Array(d[i..<min(i + 60000, d.count)])
                let l = chunk.count - 1
                if l < 60 { out.append(UInt8(l << 2)) }
                else if l < 256 { out += [60 << 2, UInt8(l)] }
                else { out += [61 << 2, UInt8(l & 0xff), UInt8(l >> 8)] }
                out += chunk; i += chunk.count
            }
            return out
        }
    }
}
