import AppKit

/// A Pages file → the text of its body with the look its styles give it: size, bold, italic, bullets and
/// numbers (one level). It is the reverse of `PagesWriter`, and uses the same containers.
///
/// A `.pages` file (Pages 10 and later) is a ZIP, or a folder, with `Index/Document.iwa` (the content) and
/// `Index/DocumentStylesheet.iwa` (the styles): Snappy-compressed protobuf archives. The body is the text
/// storage with the most text; its tables say, from which character on, which paragraph style, list style and
/// character style apply. Styles inherit from a parent style.
/// Not read: tables, pictures, text boxes, headers and footers (the body is what a conversion needs first).
/// Files of Pages '09 and earlier (`Index.zip`) are not read either: the message says to open them in Pages.
enum PagesReader {
    typealias PB = PagesWriter.PB
    typealias Archive = PagesWriter.Archive
    typealias IWA = PagesWriter.IWA
    typealias Objects = [UInt64: (type: UInt64, payload: [UInt8])]

    static func read(_ file: URL) throws -> NSAttributedString {
        var budget = IWA.Budget()
        var objects = try load("Index/Document.iwa", in: file, required: true, budget: &budget)
        if let sheet = try? load("Index/DocumentStylesheet.iwa", in: file, required: false, budget: &budget) {
            objects.merge(sheet) { current, _ in current }
        }
        // The body: the text storage (type 2001) that holds the most text.
        var body: (text: String, fields: [PB.Field])?
        for (_, object) in objects where object.type == 2001 {
            guard let fields = try? PB.parse(object.payload),
                  let text = fields.first(where: { $0.num == 3 }).map({ String(decoding: $0.data, as: UTF8.self) }) else { continue }
            if body == nil || text.utf16.count > body!.text.utf16.count { body = (text, fields) }
        }
        guard let body, !body.text.isEmpty else { throw unreadable }
        let result = try render(text: body.text, fields: body.fields, objects: objects)
        guard result.length > 0 else { throw unreadable }
        return result
    }

    /// One text storage → its text with the look its paragraph, list and character tables give it. Shared with the
    /// Keynote reader (text boxes of a slide use the same storage). «Annulla» is checked at every paragraph.
    static func render(text: String, fields: [PB.Field], objects: Objects) throws -> NSAttributedString {
        let body = (text: text, fields: fields)
        func table(_ number: Int) -> [(index: Int, ref: UInt64?)] {
            var entries: [(Int, UInt64?)] = []
            for field in body.fields where field.num == number {
                for entry in (try? PB.parse(field.data)) ?? [] {
                    let parts = (try? PB.parse(entry.data)) ?? []
                    guard let index = parts.first(where: { $0.num == 1 })?.value else { continue }
                    let ref = parts.first(where: { $0.num == 2 }).flatMap { (try? PB.parse($0.data))?.first(where: { $0.num == 1 })?.value }
                    entries.append((Int(clamping: index), ref))
                }
            }
            return entries.sorted { $0.0 < $1.0 }.map { (index: $0.0, ref: $0.1) }
        }
        /// Each entry with the style in force from it on: a paragraph or list entry without a reference changes nothing,
        /// a character entry without one goes back to no style.
        func inForce(_ entries: [(index: Int, ref: UInt64?)], reset: Bool) -> [(index: Int, ref: UInt64?)] {
            var found: UInt64?
            return entries.map { entry in
                if let ref = entry.ref { found = ref } else if reset { found = nil }
                return (entry.index, found)
            }
        }
        let paragraphTable = inForce(table(5), reset: false), listTable = inForce(table(7), reset: false)
        let characterTable = inForce(table(8), reset: true)
        /// The first entry after `location` (the tables are sorted): a binary search, not a pass over the whole table
        /// at every paragraph and run.
        func after(_ entries: [(index: Int, ref: UInt64?)], _ location: Int) -> Int {
            var low = 0, high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle].index <= location { low = middle + 1 } else { high = middle }
            }
            return low
        }
        /// The style in force at `location`.
        func style(_ entries: [(index: Int, ref: UInt64?)], at location: Int, reset: Bool) -> UInt64? {
            let next = after(entries, location)
            return next > 0 ? entries[next - 1].ref : nil
        }

        var cache: [UInt64: Style] = [:]
        func resolved(_ id: UInt64?) -> Style {
            guard let id else { return Style() }
            if let known = cache[id] { return known }
            let value = Self.style(id, in: objects, depth: 0)
            cache[id] = value
            return value
        }
        func listKind(_ id: UInt64?) -> Int {
            guard let id, let object = objects[id], let fields = try? PB.parse(object.payload),
                  let kind = fields.first(where: { $0.num == 11 })?.value else { return 0 }
            return kind == 3 ? 2 : (kind == 0 ? 0 : 1)   // 0 none, 1 bullet, 2 numbered
        }

        let whole = body.text as NSString
        let result = NSMutableAttributedString()
        var number = 0
        var location = 0
        while location < whole.length {
            try PDFOps.checkCancelled()
            let range = whole.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var content = range
            while content.length > 0, [10, 13, 0x2029, 4].contains(whole.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }

            let paragraph = resolved(style(paragraphTable, at: range.location, reset: false))
            let kind = listKind(style(listTable, at: range.location, reset: false))
            number = kind == 2 ? number + 1 : 0

            // The runs: from each change of character style to the next.
            var cuts = Set([content.location, NSMaxRange(content)])
            var cut = after(characterTable, content.location)
            while cut < characterTable.count, characterTable[cut].index < NSMaxRange(content) { cuts.insert(characterTable[cut].index); cut += 1 }
            let points = cuts.sorted()

            let layout = NSMutableParagraphStyle()
            layout.paragraphSpacing = 6
            if kind != 0 {
                layout.headIndent = 18
                layout.firstLineHeadIndent = 0
                layout.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
            }
            func attributes(at index: Int) -> [NSAttributedString.Key: Any] {
                let character = resolved(style(characterTable, at: index, reset: true))
                let size = CGFloat(character.size ?? paragraph.size ?? 12)
                let bold = character.bold ?? paragraph.bold ?? false
                let italic = character.italic ?? paragraph.italic ?? false
                var font = NSFont(name: "Helvetica Neue", size: size) ?? NSFont.systemFont(ofSize: size)
                if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                return [.font: font, .paragraphStyle: layout]
            }

            if kind != 0 {
                result.append(NSAttributedString(string: kind == 1 ? "•\t" : "\(number).\t", attributes: attributes(at: content.location)))
            }
            for pair in zip(points, points.dropFirst()) where pair.1 > pair.0 {
                let piece = whole.substring(with: NSRange(location: pair.0, length: pair.1 - pair.0))
                let clean = String(piece.unicodeScalars.compactMap { scalar -> Character? in
                    if scalar == "\u{2028}" || scalar == "\u{B}" { return "\u{2028}" }
                    if scalar == "\t" { return "\t" }
                    if scalar.value < 0x20 || scalar == "\u{FFFC}" || scalar == "\u{2029}" { return nil }
                    return Character(scalar)
                })
                if !clean.isEmpty { result.append(NSAttributedString(string: clean, attributes: attributes(at: pair.0))) }
            }
            result.append(NSAttributedString(string: "\n", attributes: attributes(at: content.location)))
        }
        return result
    }

    // MARK: Styles

    private struct Style { var bold: Bool?; var italic: Bool?; var size: Double? }

    /// A paragraph or character style: its own properties (field 11) over those of its parent (field 3 of its header).
    private static func style(_ id: UInt64, in objects: Objects, depth: Int) -> Style {
        guard depth < 8, let object = objects[id], let fields = try? PB.parse(object.payload) else { return Style() }
        var result = Style()
        if let header = fields.first(where: { $0.num == 1 }).flatMap({ try? PB.parse($0.data) }),
           let parent = header.first(where: { $0.num == 3 }).flatMap({ (try? PB.parse($0.data))?.first(where: { $0.num == 1 })?.value }),
           parent != id {
            result = style(parent, in: objects, depth: depth + 1)
        }
        guard let properties = fields.first(where: { $0.num == 11 }).flatMap({ try? PB.parse($0.data) }) else { return result }
        for property in properties {
            switch (property.num, property.wire) {
            case (1, 0): result.bold = property.value != 0
            case (2, 0): result.italic = property.value != 0
            case (3, 5) where property.data.count == 4:
                let bits = property.data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }
                let size = Double(Float(bitPattern: bits))
                if size > 1, size < 500 { result.size = size }
            default: break
            }
        }
        return result
    }

    /// The size of the file's `Index` (text and styles), uncompressed: what reading it costs. The pictures aren't counted.
    static func indexBytes(_ file: URL) -> Int {
        let fm = FileManager.default
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let items = fm.enumerator(at: file.appendingPathComponent("Index"), includingPropertiesForKeys: [.fileSizeKey])
            return (items?.allObjects as? [URL] ?? []).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", file.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return FileNaming.fileSize(file) }
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var total = 0
        for line in listing.split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            if columns.count == 4, columns[3].hasPrefix("Index/"), let size = Int(columns[0]) { total += size }
        }
        return total
    }

    // MARK: Containers

    static var unreadable: OpError {
        .unsupported(L("Rondelle non riesce a leggere questo file di Pages: aprilo in Pages ed esportalo in Word o PDF"))
    }

    /// The objects of one `.iwa` of the file (a ZIP, or a folder the way iCloud sometimes keeps it).
    static func load(_ name: String, in file: URL, required: Bool, budget: inout IWA.Budget) throws -> Objects {
        // Into memory and capped on the bytes really read (a ZIP can declare 1 KB and hold gigabytes); in a folder,
        // regular files only.
        var raw: Data?
        if IWorkFile.isFolder(file) {
            let url = file.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false, let handle = try? SafeFile.openForReading(url) {
                defer { try? handle.close() }
                raw = try handle.read(upToCount: IWorkFile.maxIndexBytes + 1)
            }
        } else {
            switch Result(catching: { try IWorkFile.entry(name, in: file, max: IWorkFile.maxIndexBytes) }) {
            case .success(let data?): raw = data
            case .success(nil): throw IWorkFile.tooLarge(file)
            case .failure(let error as CancellationError): throw error
            case .failure: raw = nil   // a missing entry: the stylesheet is optional
            }
        }
        if let raw, raw.count > IWorkFile.maxIndexBytes { throw IWorkFile.tooLarge(file) }
        guard let raw, !raw.isEmpty else {
            if required { throw unreadable }
            return [:]
        }
        return try IWorkFile.objects(in: raw, of: file, unreadable: unreadable, budget: &budget)
    }

    /// The objects of one `.iwa`: its Snappy blocks, then its archives, by identifier.
    static func parse(_ raw: Data, budget: inout IWA.Budget) throws -> Objects {
        var objects: Objects = [:]
        for object in try Archive.parse(try IWA.decode([UInt8](raw), budget: &budget), budget: &budget) {
            guard let message = object.messages.first,
                  let type = message.info.first(where: { $0.num == 1 })?.value else { continue }
            objects[object.id] = (type, message.payload)
        }
        return objects
    }
}
