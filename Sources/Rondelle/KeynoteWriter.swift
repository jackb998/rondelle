import AppKit
import CryptoKit
import ImageIO

/// Slides → a Keynote file, written by Rondelle itself (nothing is sent to Keynote: no Apple Events, no permission).
///
/// A `.key` file is a ZIP of `.iwa` archives (Snappy-compressed protobuf, see `PagesWriter`). Rondelle takes the
/// empty presentation that the installed Keynote ships as a template (`Basic White`), and for every slide copies
/// the objects of one of the template's own layouts (a title, a bulleted body) under fresh identifiers, puts the
/// text in them, and adds the slide to the show. The first slide takes the place of the template's empty one. The
/// template is read from the installed app each time and never copied into Rondelle, so without Keynote there is
/// no conversion (the wheel doesn't offer it then).
///
/// What is written: for each slide a title, body paragraphs (bullets of the layout) and speaker notes. Not
/// written: pictures, tables, shapes, colours and fonts of the source (the theme's look is used).
/// The layouts of Apple's `KNArchives`, `TSWPArchives` and `TSPArchiveMessages` are followed field by field.
enum KeynoteWriter {
    typealias PB = PagesWriter.PB
    typealias Archive = PagesWriter.Archive
    typealias IWA = PagesWriter.IWA
    typealias Object = Archive.Object

    /// A picture of a slide: the bytes of the file (JPEG, PNG…), its size in pixels and its frame on the source slide, in points.
    struct Picture: Equatable {
        var data: Data
        var ext: String
        var pixels: CGSize
        var frame: CGRect
        var description = ""
    }

    struct Slide: Equatable {
        var title: String
        var body: [String]
        var notes: String
        var pictures: [Picture] = []
    }

    static let maxSlides = 1000

    private static var unknownTemplate: OpError {
        .unsupported(L("Il modello di Keynote installato non è riconosciuto: aggiorna Rondelle"))
    }

    // MARK: Public

    /// `sourceSize`: the size of the slides the pictures' frames are in (they are scaled to the template's slide size).
    static func write(_ slides: [Slide], sourceSize: CGSize? = nil, to out: URL) throws {
        guard !slides.isEmpty else { throw OpError.failed(L("nessuna diapositiva")) }
        guard slides.count <= maxSlides else { throw OpError.unsupported(L("troppe diapositive (massimo %@)", maxSlides)) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("rondelle-key-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let wide = sourceSize.map { $0.width / max($0.height, 1) >= 1.5 } ?? false
        try IWorkFile.run("/usr/bin/unzip", ["-q", "-o", try templateURL(wide: wide).path, "-d", work.path])
        try build(slides, sourceSize: sourceSize, in: work)
        try? UUID().uuidString.write(to: work.appendingPathComponent("Metadata/DocumentIdentifier"), atomically: true, encoding: .utf8)

        let archive = work.appendingPathComponent("out.key")
        let top = ((try? fm.contentsOfDirectory(atPath: work.path)) ?? []).filter { ["Index", "Data", "Metadata"].contains($0) }.sorted()
        try IWorkFile.run("/usr/bin/zip", ["-0", "-X", "-q", "-r", archive.path] + top, in: work)
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.moveItem(at: archive, to: out)
    }

    /// The slides of a Keynote file written by `write`, read back from the archives themselves (for the tests):
    /// per slide the title, the body and the notes.
    static func summary(of file: URL) throws -> [Slide] {
        let index = try IWorkFile.index(file, app: "Keynote") { $0 == "Document.iwa" || $0.hasPrefix("Slide-") }
        func load(_ name: String) throws -> [Object] {
            guard let raw = index[name] else { throw unknownTemplate }
            return try Archive.parse(try IWA.decode([UInt8](raw)))
        }
        do {
            let document = try load("Document.iwa")
            guard let show = document.first(where: { kind(of: $0) == 2 }),
                  let tree = IWorkFile.message(IWorkFile.fields(show.messages[0].payload), 3) else { throw unknownTemplate }
            var result: [Slide] = []
            for nodeID in IWorkFile.refs(tree, 2) {
                guard let node = document.first(where: { $0.id == nodeID }),
                      let slideID = IWorkFile.ref(IWorkFile.fields(node.messages[0].payload), 2) else { continue }
                let byID = Dictionary(try load("Slide-\(slideID).iwa").map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                func lines(_ ref: UInt64?) -> [String] {
                    guard let ref, let object = byID[ref] else { return [] }
                    let fields = IWorkFile.fields(object.messages[0].payload)
                    let shape = kind(of: object) == 7 ? (IWorkFile.message(fields, 1) ?? []) : fields
                    guard let storageID = kind(of: object) == 15 ? IWorkFile.ref(fields, 1) : IWorkFile.ref(shape, 4),
                          let storage = byID[storageID] else { return [] }
                    let joined = IWorkFile.fields(storage.messages[0].payload).filter { $0.num == 3 && $0.wire == 2 }
                        .map { String(decoding: $0.data, as: UTF8.self) }.joined()
                    return joined.isEmpty ? [] : joined.components(separatedBy: "\n")
                }
                guard let slide = byID[slideID] else { continue }
                let fields = IWorkFile.fields(slide.messages[0].payload)
                result.append(Slide(title: lines(IWorkFile.ref(fields, 5)).joined(separator: " "), body: lines(IWorkFile.ref(fields, 6)),
                                    notes: lines(IWorkFile.ref(fields, 27)).joined(separator: "\n")))
            }
            return result
        }
    }

    // MARK: Template

    private static func templateURL(wide: Bool) throws -> URL {
        guard let app = IWorkOps.App.keynote.installed else {
            throw OpError.unsupported(L("Per creare un file Keynote serve Keynote installato"))
        }
        let root = app.appendingPathComponent("Contents/SharedSupport/Templates", isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for folder in (folders.filter { $0.hasSuffix("BasicWhite") } + folders) {
            let url = root.appendingPathComponent(folder).appendingPathComponent(wide ? "Wide.kth" : "Standard.kth")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw unknownTemplate
    }

    // MARK: Files

    private static func load(_ folder: URL, _ name: String) throws -> [Object] {
        guard let raw = FileManager.default.contents(atPath: folder.appendingPathComponent("Index/\(name)").path) else { throw unknownTemplate }
        return try Archive.parse(try IWA.decode([UInt8](raw)))
    }

    private static func save(_ objects: [Object], _ folder: URL, _ name: String) throws {
        try Data(IWA.encode(Archive.build(objects))).write(to: folder.appendingPathComponent("Index/\(name)"))
    }

    static func kind(of object: Object) -> UInt64 {
        object.messages.first?.info.first(where: { $0.num == 1 })?.value ?? 0
    }

    // MARK: Small helpers

    private static func unpack(_ bytes: [UInt8]) -> [UInt64] {
        var ids: [UInt64] = [], i = 0
        while i < bytes.count, let value = try? PB.readVarint(bytes, &i) { ids.append(value) }
        return ids
    }

    private static func pack(_ ids: [UInt64]) -> [UInt8] { ids.flatMap { PB.varint($0) } }

    /// The identifiers an object says it refers to (field 5 of its message info).
    private static func references(_ object: Object) -> [UInt64] {
        object.messages.first?.info.first(where: { $0.num == 5 }).map { unpack($0.data) } ?? []
    }

    /// Fields in ascending order of number; fields of the same number stay in their order.
    private static func ordered(_ fields: [PB.Field]) -> [PB.Field] {
        fields.enumerated().sorted { ($0.element.num, $0.offset) < ($1.element.num, $1.offset) }.map(\.element)
    }

    private static func refField(_ number: Int, _ id: UInt64) -> PB.Field { .bytes(number, PB.build([.int(1, id)])) }

    private static func randomUUID() -> [PB.Field] { [.int(1, UInt64.random(in: 1...UInt64.max)), .int(2, UInt64.random(in: 1...UInt64.max))] }

    // MARK: Cloning

    /// The bytes of a message with every varint that is one of `map`'s keys replaced (references are varints, and
    /// the identifiers are seven digits long, so no other number is taken by mistake). Nested messages are entered
    /// when they parse completely and don't look like text; only a message in which something changed is rebuilt.
    private static func remap(_ bytes: [UInt8], _ map: [UInt64: UInt64], depth: Int = 0) -> [UInt8] {
        guard depth < 16, !bytes.isEmpty, var fields = try? PB.parse(bytes) else { return bytes }
        var changed = false
        for i in fields.indices {
            switch fields[i].wire {
            case 0:
                if let new = map[fields[i].value] { fields[i].value = new; changed = true }
            case 2:
                let data = fields[i].data
                if data.count >= 2, !looksLikeText(data) {
                    let inner = remap(data, map, depth: depth + 1)
                    if inner != data { fields[i].data = inner; changed = true }
                }
            default: break
            }
        }
        return changed ? PB.build(fields) : bytes
    }

    private static func looksLikeText(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data.allSatisfy { ($0 >= 32 && $0 < 127) || $0 >= 0xC2 || $0 == 10 || $0 == 9 }
    }

    private static func clone(_ object: Object, as id: UInt64, _ map: [UInt64: UInt64]) -> Object {
        var copy = object
        copy.id = id
        for k in copy.messages.indices {
            var info = copy.messages[k].info
            for i in info.indices {
                if info[i].num == 5 { info[i].data = pack(unpack(info[i].data).map { map[$0] ?? $0 }) }
                if info[i].num == 4 {   // a field info: a path, a type and the references inside that field (its field 4)
                    var inner = (try? PB.parse(info[i].data)) ?? []
                    for j in inner.indices where inner[j].num == 4 && inner[j].wire == 2 {
                        inner[j].data = pack(unpack(inner[j].data).map { map[$0] ?? $0 })
                    }
                    info[i].data = PB.build(inner)
                }
            }
            copy.messages[k].info = info
            copy.messages[k].payload = remap(copy.messages[k].payload, map)
        }
        return copy
    }

    /// `object` and what it refers to, in `objects` (the order in which they are found).
    private static func closure(_ roots: [UInt64], in objects: [UInt64: Object]) -> [Object] {
        var seen = Set<UInt64>(), order: [Object] = []
        func visit(_ id: UInt64) {
            guard let object = objects[id], seen.insert(id).inserted else { return }
            order.append(object)
            for ref in references(object) { visit(ref) }
        }
        roots.forEach(visit)
        return order
    }

    // MARK: Text in a storage

    /// A storage's payload with `paragraphs` as its text: one entry per paragraph in the tables of paragraph styles
    /// and of paragraph data (the first keeps the style of the template's first paragraph), the other tables as they are.
    private static func settingText(_ payload: [UInt8], _ paragraphs: [String]) -> [UInt8] {
        guard var fields = try? PB.parse(payload) else { return payload }
        let clean = paragraphs.map { $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\u{2028}") }
        let text = clean.joined(separator: "\n")
        var starts: [UInt64] = [0]
        var at: UInt64 = 0
        for paragraph in clean.dropLast() { at += UInt64(paragraph.utf16.count) + 1; starts.append(at) }

        fields.removeAll { $0.num == 3 }
        if !text.isEmpty { fields.append(.bytes(3, Array(text.utf8))) }
        for i in fields.indices {
            switch fields[i].num {
            case 5:   // paragraph styles
                let entries = ((try? PB.parse(fields[i].data)) ?? []).filter { $0.num == 1 }
                guard let first = entries.first else { continue }
                fields[i].data = PB.build([first] + starts.dropFirst().map { PB.Field.bytes(1, PB.build([.int(1, $0)])) })
            case 6:   // paragraph data: (start, level 0, 0)
                fields[i].data = PB.build(starts.map { PB.Field.bytes(1, PB.build([.int(1, $0), .int(2, 0), .int(3, 0)])) })
            default: break
            }
        }
        return PB.build(ordered(fields))
    }

    // MARK: Layout

    private struct Layout {
        var slide: Object
        var objects: [Object]
    }

    /// The template slide with a title, a body and one more text box and no picture, whose body is the biggest.
    private static func chooseLayout(in work: URL, components: [(id: UInt64, locator: String)]) throws -> Layout {
        var best: (layout: Layout, height: Double)?
        for component in components where component.locator.hasPrefix("TemplateSlide-") {
            guard let objects = try? load(work, "\(component.locator).iwa"),
                  let slide = objects.first(where: { $0.id == component.id && kind(of: $0) == 5 }) else { continue }
            let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let fields = IWorkFile.fields(slide.messages[0].payload)
            let kinds = IWorkFile.refs(fields, 7).compactMap { byID[$0].map { kind(of: $0) } }.sorted()
            guard kinds == [7, 7, 2011], let body = IWorkFile.ref(fields, 6).flatMap({ byID[$0] }), IWorkFile.ref(fields, 5) != nil,
                  IWorkFile.ref(fields, 36) != nil else { continue }
            let shape = IWorkFile.message(IWorkFile.fields(body.messages[0].payload), 1) ?? []
            guard let geometry = IWorkFile.message(IWorkFile.message(IWorkFile.message(shape, 1) ?? [], 1) ?? [], 1),
                  let size = IWorkFile.message(geometry, 2), let height = IWorkFile.float(size.first { $0.num == 2 }) else { continue }
            if best == nil || height > best!.height { best = (Layout(slide: slide, objects: objects), height) }
        }
        guard let best else { throw unknownTemplate }
        return best.layout
    }

    // MARK: Pictures

    private struct ImageTemplate {
        var slideID: UInt64
        var imageID: UInt64
        var objects: [UInt64: Object]
    }

    /// A template slide's picture (type 3005 with data of its own): copied for every picture.
    private static func chooseImageTemplate(in work: URL, components: [(id: UInt64, locator: String)]) throws -> ImageTemplate {
        for component in components where component.locator.hasPrefix("TemplateSlide-") {
            guard let loaded = try? load(work, "\(component.locator).iwa"),
                  loaded.contains(where: { $0.id == component.id && kind(of: $0) == 5 }),
                  let image = loaded.first(where: { kind(of: $0) == 3005 && IWorkFile.ref(IWorkFile.fields($0.messages[0].payload), 11) != nil }) else { continue }
            return ImageTemplate(slideID: component.id, imageID: image.id, objects: Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        throw unknownTemplate
    }

    private static func fixed32(_ number: Int, _ value: Double) -> PB.Field {
        let bits = Float(value).bitPattern
        return PB.Field(num: number, wire: 5, value: 0, data: (0..<4).map { UInt8(truncatingIfNeeded: bits >> UInt32(8 * $0)) })
    }

    private static func size(_ width: Double, _ height: Double) -> [UInt8] { PB.build([fixed32(1, width), fixed32(2, height)]) }

    /// The copied picture with the frame, the data and the sizes of `picture`; its mask, its traced outline and its thumbnail go.
    private static func settingPicture(_ object: Object, dataID: UInt64, picture: Picture, frame: CGRect) -> Object {
        var copy = object
        var fields = IWorkFile.fields(object.messages[0].payload)
        let maskID = IWorkFile.ref(fields, 5)
        fields.removeAll { [5, 12, 13, 15, 16, 17, 19, 23, 2, 6, 8].contains($0.num) }
        for i in fields.indices {
            switch fields[i].num {
            case 1:   // the drawable: the geometry (position, size; the template's flags stay), no description
                var drawable = IWorkFile.fields(fields[i].data)
                var geometry = IWorkFile.message(drawable, 1) ?? []
                geometry.removeAll { $0.num == 1 || $0.num == 2 || $0.num == 4 }
                geometry.append(.bytes(1, PB.build([fixed32(1, frame.minX), fixed32(2, frame.minY)])))
                geometry.append(.bytes(2, size(frame.width, frame.height)))
                drawable.removeAll { $0.num == 1 || $0.num == 8 }
                drawable.append(.bytes(1, PB.build(ordered(geometry))))
                fields[i].data = PB.build(ordered(drawable))
            case 4, 9: fields[i].data = size(picture.pixels.width, picture.pixels.height)
            case 11: fields[i].data = PB.build([.int(1, dataID)])
            default: break
            }
        }
        copy.messages[0].payload = PB.build(ordered(fields))
        var info = copy.messages[0].info
        for i in info.indices {
            if info[i].num == 5, let maskID { info[i].data = pack(unpack(info[i].data).filter { $0 != maskID }) }
            if info[i].num == 6 { info[i].data = pack([dataID]) }
        }
        copy.messages[0].info = info
        return copy
    }

    // MARK: Building

    private static func build(_ slides: [Slide], sourceSize: CGSize?, in work: URL) throws {
        // The package's metadata.
        let metaURL = work.appendingPathComponent("Index/Metadata.iwa")
        guard let metaRaw = FileManager.default.contents(atPath: metaURL.path) else { throw unknownTemplate }
        var metaObjects = try Archive.parse(try IWA.decode([UInt8](metaRaw)))
        guard let metaIndex = metaObjects.firstIndex(where: { kind(of: $0) == 11006 }) else { throw unknownTemplate }
        let package = try PB.parse(metaObjects[metaIndex].messages[0].payload)
        var nextID = (package.first { $0.num == 1 }?.value ?? 0) + 1
        func allocate() -> UInt64 { defer { nextID += 1 }; return nextID }

        // The show, its tree and the node of the template's empty slide (the shell).
        var document = try load(work, "Document.iwa")
        guard let showIndex = document.firstIndex(where: { kind(of: $0) == 2 }),
              let treeField = IWorkFile.message(IWorkFile.fields(document[showIndex].messages[0].payload), 3),
              let shellNodeID = IWorkFile.refs(treeField, 2).first,
              let nodeIndex = document.firstIndex(where: { $0.id == shellNodeID && kind(of: $0) == 4 }),
              let shellID = IWorkFile.ref(IWorkFile.fields(document[nodeIndex].messages[0].payload), 2) else { throw unknownTemplate }
        let pristineNode = document[nodeIndex]

        // The components: identifier and locator; which component holds which object.
        var components: [(id: UInt64, locator: String)] = []
        for field in package where field.num == 3 && field.wire == 2 {
            let entry = IWorkFile.fields(field.data)
            components.append((entry.first { $0.num == 1 }?.value ?? 0, IWorkFile.string(entry, 3) ?? IWorkFile.string(entry, 2) ?? ""))
        }
        var owner: [UInt64: UInt64] = [:]
        for component in components where FileManager.default.fileExists(atPath: work.appendingPathComponent("Index/\(component.locator).iwa").path) {
            for object in (try? load(work, "\(component.locator).iwa")) ?? [] { owner[object.id] = component.id }
        }
        func entry(of id: UInt64) -> [PB.Field]? {
            package.lazy.filter { $0.num == 3 && $0.wire == 2 }.map { IWorkFile.fields($0.data) }
                .first { $0.first(where: { $0.num == 1 })?.value == id }
        }

        let layout = try chooseLayout(in: work, components: components)
        let imageTemplate = slides.contains { !$0.pictures.isEmpty } ? try chooseImageTemplate(in: work, components: components) : nil
        var nextDataID = package.filter { $0.num == 4 && $0.wire == 2 }.compactMap { IWorkFile.fields($0.data).first { $0.num == 1 }?.value }.max().map { $0 + 1 } ?? 1
        var newDataInfos: [[PB.Field]] = []
        var dataByDigest: [[UInt8]: UInt64] = [:]
        // The template's slide size, and how the source slides' points map onto it (centred, fitted).
        let showSize = IWorkFile.message(IWorkFile.fields(document[showIndex].messages[0].payload), 4)
        let targetSize = CGSize(width: IWorkFile.float(showSize?.first { $0.num == 1 }) ?? 1024, height: IWorkFile.float(showSize?.first { $0.num == 2 }) ?? 768)
        let source = sourceSize ?? targetSize
        let scale = min(targetSize.width / max(source.width, 1), targetSize.height / max(source.height, 1))
        let offset = CGPoint(x: (targetSize.width - source.width * scale) / 2, y: (targetSize.height - source.height * scale) / 2)
        let layoutByID = Dictionary(layout.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let layoutFields = IWorkFile.fields(layout.slide.messages[0].payload)
        let shell = try load(work, "Slide-\(shellID).iwa")
        let shellByID = Dictionary(shell.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let shellSlide = shellByID[shellID], let noteID = IWorkFile.ref(IWorkFile.fields(shellSlide.messages[0].payload), 27),
              let titleRef = IWorkFile.ref(layoutFields, 5), let bodyRef = IWorkFile.ref(layoutFields, 6),
              let guideRef = IWorkFile.ref(IWorkFile.fields(shellSlide.messages[0].payload), 36),
              let shellEntry = entry(of: shellID) else { throw unknownTemplate }
        func storage(of placeholder: UInt64) -> UInt64? {
            layoutByID[placeholder].flatMap { IWorkFile.ref(IWorkFile.message(IWorkFile.fields($0.messages[0].payload), 1) ?? [], 4) }
        }
        guard let titleStorage = storage(of: titleRef), let bodyStorage = storage(of: bodyRef) else { throw unknownTemplate }
        let layoutUUID = entry(of: layout.slide.id).flatMap { entry in
            entry.filter { $0.num == 11 && $0.wire == 2 }.map { IWorkFile.fields($0.data) }
                .first { $0.first(where: { $0.num == 1 })?.value == layout.slide.id }
        }.flatMap { IWorkFile.message($0, 2) }

        var entries: [[PB.Field]] = []
        var newNodes: [Object] = []
        var newSlideIDs: [UInt64] = []

        for (index, slide) in slides.enumerated() {
            try PDFOps.checkCancelled()
            let rootID = index == 0 ? shellID : allocate()
            if index > 0 { newSlideIDs.append(rootID) }

            // The layout's title, body and guides, and the shell's note, with what they own, under new identifiers.
            let fromLayout = closure([titleRef, bodyRef], in: layoutByID)
            var map: [UInt64: UInt64] = [layout.slide.id: rootID]
            for object in fromLayout { map[object.id] = allocate() }
            let fromShell = closure([noteID, guideRef], in: shellByID)   // the shell's note and its empty guides (the layout's draw lines)
            var noteMap: [UInt64: UInt64] = [shellID: rootID]
            for object in fromShell { noteMap[object.id] = allocate() }

            let texts: [UInt64: [String]] = [titleStorage: [slide.title.replacingOccurrences(of: "\n", with: " ")], bodyStorage: slide.body]
            var objects: [Object] = []
            for object in fromLayout {
                var copy = clone(object, as: map[object.id]!, map)
                if kind(of: copy) == 2001, let paragraphs = texts[object.id] {
                    copy.messages[0].payload = settingText(copy.messages[0].payload, paragraphs)
                }
                objects.append(copy)
            }
            for object in fromShell {
                var copy = clone(object, as: noteMap[object.id]!, noteMap)
                if kind(of: copy) == 2001 {   // the note's storage
                    copy.messages[0].payload = settingText(copy.messages[0].payload, slide.notes.isEmpty ? [] : slide.notes.components(separatedBy: "\n"))
                }
                objects.append(copy)
            }

            // The pictures: the template's picture (without its mask) under new identifiers, the file in Data/, its entry in the metadata.
            var pictureIDs: [UInt64] = []
            var dataUsers: [(data: UInt64, objects: [UInt64])] = []   // per data: the pictures of this slide that use it
            if let imageTemplate {
                for picture in slide.pictures {
                    let parts = closure([imageTemplate.imageID], in: imageTemplate.objects).filter { kind(of: $0) != 3006 }
                    var imageMap: [UInt64: UInt64] = [imageTemplate.slideID: rootID]
                    for object in parts { imageMap[object.id] = allocate() }
                    // The same file is stored once: a digest names one data.
                    let digest = Array(Insecure.SHA1.hash(data: picture.data))
                    let dataID: UInt64
                    if let known = dataByDigest[digest] {
                        dataID = known
                    } else {
                        dataID = nextDataID
                        nextDataID += 1
                        dataByDigest[digest] = dataID
                        let fileName = "image-\(dataID).\(picture.ext)"
                        try picture.data.write(to: work.appendingPathComponent("Data/\(fileName)"))
                        newDataInfos.append([.int(1, dataID), .bytes(2, digest), .bytes(3, Array("image.\(picture.ext)".utf8)),
                                             .bytes(4, Array(fileName.utf8)), .int(18, UInt64(picture.data.count))])
                    }
                    let frame = CGRect(x: offset.x + picture.frame.minX * scale, y: offset.y + picture.frame.minY * scale,
                                       width: picture.frame.width * scale, height: picture.frame.height * scale)
                    for object in parts {
                        var copy = clone(object, as: imageMap[object.id]!, imageMap)
                        if object.id == imageTemplate.imageID {
                            copy = settingPicture(copy, dataID: dataID, picture: picture, frame: frame)
                            pictureIDs.append(copy.id)
                            if let at = dataUsers.firstIndex(where: { $0.data == dataID }) { dataUsers[at].objects.append(copy.id) } else { dataUsers.append((dataID, [copy.id])) }
                        }
                        objects.append(copy)
                    }
                }
            }
            let dataReferences = dataUsers.map { user in
                PB.build([.int(1, user.data)] + user.objects.map { PB.Field.bytes(2, PB.build([.int(1, $0), .int(2, 1)])) })
            }

            // The slide: the layout's style and transition, the new title and body, the template, the note, the guides.
            let newTitle = map[titleRef]!, newBody = map[bodyRef]!, newGuide = noteMap[guideRef]!, newNote = noteMap[noteID]!
            var fields: [PB.Field] = []
            var slideRefs: [UInt64] = []
            if let style = layoutFields.first(where: { $0.num == 1 }), let id = IWorkFile.ref(layoutFields, 1) { fields.append(style); slideRefs.append(id) }
            if let transition = layoutFields.first(where: { $0.num == 4 }) { fields.append(transition) }
            fields += [refField(5, newTitle), refField(6, newBody), refField(7, newTitle), refField(7, newBody)]
            fields += pictureIDs.map { refField(7, $0) }
            fields += [refField(17, layout.slide.id), .int(19, 1), refField(27, newNote), refField(36, newGuide),
                       refField(42, newTitle), refField(42, newBody)]
            fields += pictureIDs.map { refField(42, $0) }
            fields += [.bytes(25, PB.build([.int(1, 1)])), .bytes(45, [])]   // 25: the body's layout properties: shrink text to fit
            slideRefs += [newTitle, newBody, layout.slide.id, newNote, newGuide] + pictureIDs
            var slideObject = shellSlide
            slideObject.id = rootID
            slideObject.messages[0].payload = PB.build(ordered(fields))
            if let at = slideObject.messages[0].info.firstIndex(where: { $0.num == 5 }) { slideObject.messages[0].info[at].data = pack(slideRefs) }
            objects.insert(slideObject, at: 0)

            // The metadata entry of the slide's component: the shell's, with its identifier, locator, objects and references.
            var component = shellEntry.filter { ![1, 3, 6, 11].contains($0.num) }
            component.append(.int(1, rootID))
            component.append(.bytes(3, Array("Slide-\(rootID)".utf8)))
            var externals: [[UInt8]] = [], seenExternal = Set<String>()
            func addExternal(_ target: UInt64, _ object: UInt64?) {
                guard seenExternal.insert("\(target)/\(object ?? 0)").inserted else { return }
                externals.append(PB.build([.int(1, target)] + (object.map { [PB.Field.int(2, $0)] } ?? [])))
            }
            for field in shellEntry where field.num == 6 && field.wire == 2 {   // the stylesheet's objects the shell used
                let reference = IWorkFile.fields(field.data)
                if let target = reference.first(where: { $0.num == 1 })?.value, let object = reference.first(where: { $0.num == 2 })?.value {
                    addExternal(target, object)
                }
            }
            let local = Set(objects.map(\.id))
            for object in objects {
                for target in references(object) where !local.contains(target) {
                    guard let holder = owner[target] else { continue }
                    addExternal(holder, holder == target ? nil : target)
                }
            }
            for external in externals { component.append(.bytes(6, external)) }
            for object in objects where kind(of: object) != 2043 {
                component.append(.bytes(11, PB.build([.int(1, object.id), .bytes(2, PB.build(randomUUID()))])))
            }
            for reference in dataReferences { component.append(.bytes(7, reference)) }
            entries.append(ordered(component))

            try save(objects, work, "Slide-\(rootID).iwa")

            // The slide's node in the show's tree: the template's, with the new slide and no thumbnail (Keynote draws it again).
            var node = pristineNode
            if index > 0 { node.id = allocate() }
            var nodeFields = IWorkFile.fields(pristineNode.messages[0].payload)
            nodeFields.removeAll { [2, 14, 16, 29].contains($0.num) }
            nodeFields.append(refField(2, rootID))
            nodeFields.append(.int(14, 1))
            if let uuid = layoutUUID { nodeFields.append(.bytes(29, PB.build(uuid))) }
            node.messages[0].payload = PB.build(ordered(nodeFields))
            node.messages[0].info.removeAll { $0.num == 6 }   // the thumbnail's data
            if let at = node.messages[0].info.firstIndex(where: { $0.num == 5 }) { node.messages[0].info[at].data = pack([rootID]) }
            if index == 0 { document[nodeIndex] = node } else { newNodes.append(node) }
        }

        // The show: the tree lists every node, and the show refers to them.
        var show = document[showIndex]
        var showFields = IWorkFile.fields(show.messages[0].payload)
        if let at = showFields.firstIndex(where: { $0.num == 3 }) {
            var tree = IWorkFile.fields(showFields[at].data)
            for node in newNodes { tree.append(refField(2, node.id)) }
            showFields[at].data = PB.build(ordered(tree))
        }
        show.messages[0].payload = PB.build(showFields)
        if let at = show.messages[0].info.firstIndex(where: { $0.num == 5 }) {
            show.messages[0].info[at].data = pack(unpack(show.messages[0].info[at].data) + newNodes.map(\.id))
        }
        document[showIndex] = show
        document.insert(contentsOf: newNodes, at: nodeIndex + 1)
        try save(document, work, "Document.iwa")

        // The metadata: the shell's entry gives way to the slides', the Document's entry gets the nodes' UUIDs, the counter moves on.
        var rebuilt: [PB.Field] = []
        for field in package {
            if field.num == 1 { rebuilt.append(.int(1, nextID - 1)); continue }
            if field.num == 4 { rebuilt.append(field); continue }
            guard field.num == 3, field.wire == 2 else { rebuilt.append(field); continue }
            var entry = IWorkFile.fields(field.data)
            let id = entry.first { $0.num == 1 }?.value
            if id == shellID {
                for slideEntry in entries { rebuilt.append(.bytes(3, PB.build(slideEntry))) }
                continue
            }
            if id == 1 {
                for node in newNodes { entry.append(.bytes(11, PB.build([.int(1, node.id), .bytes(2, PB.build(randomUUID()))]))) }
                // The nodes refer to the new slides' components: the Document's entry must name them.
                for slideID in newSlideIDs { entry.append(.bytes(6, PB.build([.int(1, slideID)]))) }
                entry = ordered(entry)
            }
            rebuilt.append(.bytes(3, PB.build(entry)))
        }
        rebuilt += newDataInfos.map { PB.Field.bytes(4, PB.build($0)) }
        metaObjects[metaIndex].messages[0].payload = PB.build(ordered(rebuilt))
        try save(metaObjects, work, "Metadata.iwa")
    }
}
