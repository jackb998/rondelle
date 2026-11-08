import AppKit
import Compression

/// What Rondelle reads of a PowerPoint file (PPTX): the slides' size, background, text, pictures, tables and
/// plain shapes, as a list of items in points that `PptxRenderer` draws. A PPTX is a ZIP of XML parts: it is read
/// with the system's unzip and XMLParser, nothing else. Not read: charts, SmartArt, animations, transitions,
/// video and audio, effects (shadows, gradients), table styles; a pictures' vector formats (EMF, WMF, SVG).
enum PptxReader {
    // MARK: Limits

    static let maxSlides = 1000
    static let maxXMLPart: Int64 = 20_000_000
    static let maxImagePart: Int64 = 40_000_000

    // MARK: Model

    struct Frame {
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        var rot = 0.0   // degrees, clockwise
        var flipH = false, flipV = false
    }

    struct Run {
        var text: String
        var font: String?
        var size: Double
        var bold: Bool, italic: Bool, underline: Bool
        var color: NSColor
    }

    struct Paragraph {
        var runs: [Run]
        var align: NSTextAlignment
        var marL: Double, indent: Double
        var bullet: String?
        var spaceBefore: Double
        var spaceAfter: Double
        var lineMultiple: Double
        var emptySize: Double
    }

    enum Anchor { case top, middle, bottom }

    struct Text {
        var paragraphs: [Paragraph]
        var anchor = Anchor.top
        var insets = (l: 7.2, t: 3.6, r: 7.2, b: 3.6)
        var fontScale = 1.0
        var isEmpty: Bool { paragraphs.allSatisfy { $0.runs.allSatisfy { $0.text.isEmpty } } }
        var plain: String { paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }
    }

    enum Geometry: Equatable { case rect, ellipse, roundRect, line, custom(Custom) }

    /// A free-form outline, in a square of side 1 (the top left corner is 0,0): it takes the size of the shape.
    struct Custom: Equatable {
        let path: CGPath
        static func == (a: Custom, b: Custom) -> Bool { a.path === b.path }
    }

    struct Crop { var l = 0.0, t = 0.0, r = 0.0, b = 0.0 }

    struct Cell { var text: Text; var fill: NSColor? }
    struct Row { var height: Double; var cells: [Cell] }

    enum Content {
        case shape(Geometry, fill: NSColor?, line: NSColor?, lineWidth: Double, text: Text?)
        case picture(path: String, crop: Crop, clip: Geometry?)
        case table(columns: [Double], rows: [Row])
    }

    struct Item {
        var frame: Frame
        var content: Content
        var layer: Int   // 0 master, 1 layout, 2 the slide itself
    }

    enum Background {
        case color(NSColor)
        case picture(String)
    }

    struct Slide {
        var background: Background?
        var items: [Item]
        var notes: String
    }

    final class Deck {
        let size: CGSize
        let slides: [Slide]
        fileprivate let package: Package
        fileprivate init(size: CGSize, slides: [Slide], package: Package) { self.size = size; self.slides = slides; self.package = package }

        /// The bytes of a picture of the file, read when the slide is drawn and not kept.
        func imageData(_ path: String) -> Data? { package.data(path, max: PptxReader.maxImagePart) }
    }

    // MARK: Reading

    static func read(_ url: URL) throws -> Deck {
        let package = Package(url: url)
        let invalid = OpError.unsupported(L("«%@» non è una presentazione PowerPoint valida", url.lastPathComponent))
        guard let presentation = package.xml("ppt/presentation.xml") else { throw invalid }
        let rels = package.rels(of: "ppt/presentation.xml")
        let ids = (presentation.child("sldIdLst")?.kids("sldId") ?? []).compactMap { $0.rattr("id") }
        let paths = ids.compactMap { id in rels.first { $0.id == id && !$0.external }?.target }
        guard !paths.isEmpty else { throw invalid }
        guard paths.count <= maxSlides else {
            throw OpError.unsupported(L("«%@» ha troppe diapositive (massimo %@)", url.lastPathComponent, maxSlides))
        }
        let sz = presentation.child("sldSz")
        let width = (Double(sz?.attr("cx") ?? "") ?? 9_144_000) / 12700, height = (Double(sz?.attr("cy") ?? "") ?? 6_858_000) / 12700
        guard (10...6000).contains(width), (10...6000).contains(height) else { throw invalid }
        let context = Context(package: package, defaults: presentation.child("defaultTextStyle"))
        var slides: [Slide] = []
        for path in paths {
            try PDFOps.checkCancelled()
            guard let slide = package.xml(path) else { throw invalid }
            if slide.attr("show") == "0" { continue }   // hidden slides are not in the PDF PowerPoint makes
            slides.append(context.slide(slide, at: path))
        }
        guard !slides.isEmpty else { throw invalid }
        return Deck(size: CGSize(width: width, height: height), slides: slides, package: package)
    }

    // MARK: The package

    struct Rel { let id: String, type: String, target: String, external: Bool }

    /// The central directory of a ZIP, read from the file itself, so that the parts are read without a process of
    /// their own. Sizes are only upper bounds for the buffers: what a part really holds is never trusted to be that.
    fileprivate struct ZipDirectory {
        struct Entry { let method: Int, compressed: Int, size: Int, offset: Int, encrypted: Bool }
        let data: Data
        let entries: [String: Entry]

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 22 else { return nil }
            var found: [String: Entry] = [:]
            let ok = data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
                func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
                func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
                var end = b.count - 22
                let lowest = max(0, b.count - 22 - 65_535)
                while end >= lowest, u32(end) != 0x0605_4B50 { end -= 1 }
                guard end >= lowest else { return false }
                let count = u16(end + 10), offset = u32(end + 16)
                guard count != 0xFFFF, offset != 0xFFFF_FFFF, offset < b.count, count <= 100_000 else { return false }   // ZIP64: unzip
                var i = offset
                for _ in 0..<count {
                    guard i + 46 <= b.count, u32(i) == 0x0201_4B50 else { return false }
                    let n = u16(i + 28), e = u16(i + 30), c = u16(i + 32)
                    guard i + 46 + n <= b.count else { return false }
                    let name = String(decoding: UnsafeRawBufferPointer(rebasing: b[(i + 46)..<(i + 46 + n)]), as: UTF8.self)
                    found[name] = Entry(method: u16(i + 10), compressed: u32(i + 20), size: u32(i + 24), offset: u32(i + 42), encrypted: u16(i + 8) & 1 == 1)
                    i += 46 + n + e + c
                }
                return true
            }
            guard ok else { return nil }
            self.data = data
            self.entries = found
        }

        func read(_ name: String, limit: Int) -> Data? {
            guard let e = entries[name], !e.encrypted, e.size <= limit else { return nil }
            if e.size == 0 { return Data() }
            return data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Data? in
                func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
                func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
                let o = e.offset
                guard o >= 0, o + 30 <= b.count, u32(o) == 0x0403_4B50 else { return nil }
                let start = o + 30 + u16(o + 26) + u16(o + 28)
                guard start + e.compressed <= b.count, let base = b.baseAddress else { return nil }
                let source = base.advanced(by: start).assumingMemoryBound(to: UInt8.self)
                switch e.method {
                case 0:
                    return e.compressed == e.size ? Data(bytes: source, count: e.size) : nil
                case 8:
                    var out = Data(count: e.size)
                    let n = out.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
                        compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count, source, e.compressed, nil, COMPRESSION_ZLIB)
                    }
                    return n == e.size ? out : nil
                default:
                    return nil
                }
            }
        }
    }

    fileprivate struct Package {
        let url: URL
        let archive: ZipDirectory?

        init(url: URL) { self.url = url; self.archive = ZipDirectory(url: url) }

        func data(_ path: String, max: Int64) -> Data? {
            if let archive {
                if archive.entries[path] == nil { return nil }
                if let data = archive.read(path, limit: Int(clamping: max)) { return data }
            }
            // unzip reads [ ] * ? as patterns: those characters in a name are escaped.
            var name = ""
            for c in path { if "[]*?\\".contains(c) { name.append("\\") }; name.append(c) }
            return try? ArchiveOps.entryData(in: url, entry: name, maxBytes: max)
        }

        func xml(_ path: String) -> XNode? { data(path, max: PptxReader.maxXMLPart).flatMap(XNode.parse) }

        func rels(of part: String) -> [Rel] {
            let parts = part.split(separator: "/", omittingEmptySubsequences: true)
            guard let name = parts.last else { return [] }
            let path = (parts.dropLast() + ["_rels", "\(name).rels"]).joined(separator: "/")
            guard let root = xml(path) else { return [] }
            return root.kids("Relationship").compactMap { r in
                guard let id = r.attr("Id"), let target = r.attr("Target") else { return nil }
                let type = (r.attr("Type") ?? "").split(separator: "/").last.map(String.init) ?? ""
                let external = r.attr("TargetMode") == "External"
                return Rel(id: id, type: type, target: external ? target : PptxReader.resolve(target, from: part), external: external)
            }
        }
    }

    /// «../media/a.png» next to «ppt/slides/slide1.xml» → «ppt/media/a.png».
    static func resolve(_ target: String, from part: String) -> String {
        var stack = target.hasPrefix("/") ? [] : part.split(separator: "/").dropLast().map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = stack.popLast() } else if piece != "." { stack.append(String(piece)) }
        }
        return stack.joined(separator: "/")
    }

    // MARK: XML

    final class XNode {
        let name: String
        let attrs: [String: String]
        var children: [XNode] = []
        var text = ""
        init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

        func child(_ n: String) -> XNode? { children.first { $0.name == n } }
        func kids(_ n: String) -> [XNode] { children.filter { $0.name == n } }
        func attr(_ n: String) -> String? { attrs[n] }
        /// An attribute with a namespace («r:embed», «r:id»), whatever the prefix.
        func rattr(_ local: String) -> String? { attrs.first { $0.key.hasSuffix(":" + local) }?.value }
        func double(_ n: String) -> Double? { attr(n).flatMap(Double.init) }
        func descendants(_ n: String) -> [XNode] { children.flatMap { ($0.name == n ? [$0] : []) + $0.descendants(n) } }

        static func parse(_ data: Data) -> XNode? {
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = builder
            guard parser.parse(), !builder.failed else { return nil }
            return builder.root
        }

        private final class Builder: NSObject, XMLParserDelegate {
            var root: XNode?
            var stack: [XNode] = []
            var count = 0
            var failed = false

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                count += 1
                if count > 1_500_000 || stack.count > 100 { failed = true; parser.abortParsing(); return }
                let node = XNode(name: name.split(separator: ":").last.map(String.init) ?? name, attrs: attributes)
                if let parent = stack.last { parent.children.append(node) } else { root = node }
                stack.append(node)
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
            func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        }
    }

    // MARK: Theme and styles

    fileprivate struct Theme {
        var colors: [String: NSColor] = [:]
        var clrMap: [String: String] = [:]
        var major: String?, minor: String?

        func color(named name: String) -> NSColor? { colors[clrMap[name] ?? name] }
    }

    fileprivate enum Bullet { case none, char(String), number(String) }

    fileprivate struct Style {
        var size: Double?, bold: Bool?, italic: Bool?, underline: Bool?, color: NSColor?, font: String?
        var align: NSTextAlignment?, marL: Double?, indent: Double?, bullet: Bullet?
        var spaceBeforePoints: Double?, spaceBeforePercent: Double?, linePercent: Double?
        var spaceAfterPoints: Double?, spaceAfterPercent: Double?

        /// `self` wins over `base`.
        func over(_ base: Style) -> Style {
            var s = base
            if let v = size { s.size = v }; if let v = bold { s.bold = v }; if let v = italic { s.italic = v }
            if let v = underline { s.underline = v }; if let v = color { s.color = v }; if let v = font { s.font = v }
            if let v = align { s.align = v }; if let v = marL { s.marL = v }; if let v = indent { s.indent = v }
            if let v = bullet { s.bullet = v }; if let v = spaceBeforePoints { s.spaceBeforePoints = v; s.spaceBeforePercent = nil }
            if let v = spaceBeforePercent { s.spaceBeforePercent = v; s.spaceBeforePoints = nil }
            if let v = linePercent { s.linePercent = v }
            if let v = spaceAfterPoints { s.spaceAfterPoints = v; s.spaceAfterPercent = nil }
            if let v = spaceAfterPercent { s.spaceAfterPercent = v; s.spaceAfterPoints = nil }
            return s
        }
    }

    /// Kinds of placeholder that take their text style from the master.
    fileprivate enum PlaceholderKind { case title, body, other, none }

    fileprivate struct Affine {
        var sx = 1.0, sy = 1.0, ox = 0.0, oy = 0.0   // child EMU → slide EMU
    }

    /// A part being read: its own relationships (pictures), the master's theme and text styles.
    fileprivate final class Context {
        let package: Package
        let defaults: XNode?
        var themes: [String: Theme] = [:]
        var parts: [String: XNode] = [:]
        var relations: [String: [Rel]] = [:]

        /// The relationships of a part, read once.
        func rels(of part: String) -> [Rel] {
            if let cached = relations[part] { return cached }
            let found = package.rels(of: part)
            relations[part] = found
            return found
        }

        init(package: Package, defaults: XNode?) { self.package = package; self.defaults = defaults }

        func part(_ path: String) -> XNode? {
            if let cached = parts[path] { return cached }
            guard let node = package.xml(path) else { return nil }
            parts[path] = node
            return node
        }

        // MARK: Slide

        func slide(_ root: XNode, at path: String) -> Slide {
            let own = rels(of: path)
            let layoutPath = own.first { $0.type == "slideLayout" }?.target
            let layout = layoutPath.flatMap(part)
            let masterPath = layoutPath.flatMap { rels(of: $0).first { $0.type == "slideMaster" }?.target }
            let master = masterPath.flatMap(part)
            let theme = masterPath.map(self.theme(of:)) ?? Theme()

            let slideTree = root.child("cSld")?.child("spTree")
            let layoutTree = layout?.child("cSld")?.child("spTree")
            let masterTree = master?.child("cSld")?.child("spTree")
            let inherit = Inherit(layout: layoutTree.map(placeholders) ?? [], master: masterTree.map(placeholders) ?? [],
                                  masterStyles: master?.child("txStyles"))
            var items: [Item] = []
            let showMaster = root.attr("showMasterSp") != "0" && layout?.attr("showMasterSp") != "0"
            if showMaster, let masterTree, let masterPath {
                items += shapes(masterTree, Affine(), Reader(part: masterPath, theme: theme, inherit: nil, layer: 0))
            }
            if let layoutTree, let layoutPath {
                items += shapes(layoutTree, Affine(), Reader(part: layoutPath, theme: theme, inherit: nil, layer: 1))
            }
            if let slideTree {
                items += shapes(slideTree, Affine(), Reader(part: path, theme: theme, inherit: inherit, layer: 2))
            }
            let background = self.background(root, path, theme)
                ?? layoutPath.flatMap { p in layout.flatMap { self.background($0, p, theme) } }
                ?? masterPath.flatMap { p in master.flatMap { self.background($0, p, theme) } }
            let notes = own.first { $0.type == "notesSlide" }.flatMap { part($0.target) }.map(notesText) ?? ""
            return Slide(background: background ?? theme.color(named: "bg1").map(Background.color), items: items, notes: notes)
        }

        private func notesText(_ root: XNode) -> String {
            let boxes = (root.child("cSld")?.child("spTree")?.children ?? []).filter { sp in
                sp.name == "sp" && sp.child("nvSpPr")?.child("nvPr")?.child("ph")?.attr("type") == "body"
            }
            return boxes.compactMap { $0.child("txBody") }.flatMap { $0.kids("p") }
                .map { $0.descendants("t").map(\.text).joined() }.joined(separator: "\n")
        }

        private func background(_ root: XNode, _ path: String, _ theme: Theme) -> Background? {
            guard let bg = root.child("cSld")?.child("bg") else { return nil }
            if let props = bg.child("bgPr") {
                if let fill = props.child("solidFill"), let c = color(fill, theme) { return .color(c) }
                if let blip = props.child("blipFill")?.child("blip"), let id = blip.rattr("embed"),
                   let target = rels(of: path).first(where: { $0.id == id })?.target { return .picture(target) }
                return nil
            }
            if let ref = bg.child("bgRef"), let c = color(ref, theme) { return .color(c) }
            return nil
        }

        private func theme(of masterPath: String) -> Theme {
            if let cached = themes[masterPath] { return cached }
            var theme = Theme()
            if let master = part(masterPath), let map = master.child("clrMap") { theme.clrMap = map.attrs }
            if let target = rels(of: masterPath).first(where: { $0.type == "theme" })?.target, let root = part(target),
               let elements = root.child("themeElements") {
                for entry in elements.child("clrScheme")?.children ?? [] {
                    guard let value = entry.children.first else { continue }
                    let hex = value.attr("srgbClr") ?? (value.name == "sysClr" ? value.attr("lastClr") : nil) ?? value.attr("val")
                    if let hex, let c = NSColor(hex: hex) { theme.colors[entry.name] = c }
                }
                theme.major = elements.child("fontScheme")?.child("majorFont")?.child("latin")?.attr("typeface")
                theme.minor = elements.child("fontScheme")?.child("minorFont")?.child("latin")?.attr("typeface")
            }
            themes[masterPath] = theme
            return theme
        }

        // MARK: Placeholders

        struct Placeholder { let node: XNode, type: String?, idx: String? }

        struct Inherit {
            let layout: [Placeholder], master: [Placeholder]
            let masterStyles: XNode?
        }

        func placeholders(_ tree: XNode) -> [Placeholder] {
            tree.children.compactMap { sp in
                guard sp.name == "sp", let ph = sp.child("nvSpPr")?.child("nvPr")?.child("ph") else { return nil }
                return Placeholder(node: sp, type: ph.attr("type"), idx: ph.attr("idx"))
            }
        }

        private static func family(_ type: String?) -> String {
            switch type { case "title", "ctrTitle": return "title"; case nil, "body", "subTitle", "obj": return "body"; default: return type! }
        }

        func match(_ ph: XNode, in list: [Placeholder], byIndex: Bool) -> Placeholder? {
            let type = ph.attr("type"), idx = ph.attr("idx")
            if byIndex, let idx, let found = list.first(where: { $0.idx == idx }) { return found }
            return list.first { Self.family($0.type) == Self.family(type) }
        }

        // MARK: Shapes

        struct Reader { let part: String, theme: Theme, inherit: Inherit?, layer: Int }

        func shapes(_ tree: XNode, _ t: Affine, _ r: Reader) -> [Item] {
            var items: [Item] = []
            for node in tree.children {
                if hidden(node) { continue }   // guides, helpers and the like: PowerPoint doesn't draw them either
                switch node.name {
                case "sp", "cxnSp": items += shape(node, t, r)
                case "pic": items += picture(node, t, r)
                case "graphicFrame": items += table(node, t, r)
                case "grpSp":
                    guard let x = node.child("grpSpPr")?.child("xfrm") else { items += shapes(node, t, r); continue }
                    let off = (x.child("off")?.double("x") ?? 0, x.child("off")?.double("y") ?? 0)
                    let ext = (x.child("ext")?.double("cx") ?? 0, x.child("ext")?.double("cy") ?? 0)
                    let choff = (x.child("chOff")?.double("x") ?? 0, x.child("chOff")?.double("y") ?? 0)
                    let chext = (x.child("chExt")?.double("cx") ?? 0, x.child("chExt")?.double("cy") ?? 0)
                    let sx = chext.0 > 0 ? ext.0 / chext.0 : 1, sy = chext.1 > 0 ? ext.1 / chext.1 : 1
                    let inner = Affine(sx: t.sx * sx, sy: t.sy * sy, ox: t.ox + t.sx * (off.0 - choff.0 * sx), oy: t.oy + t.sy * (off.1 - choff.1 * sy))
                    items += shapes(node, inner, r)
                case "AlternateContent":
                    if let pick = node.child("Fallback") ?? node.child("Choice") { items += shapes(pick, t, r) }
                default: break
                }
            }
            return items
        }

        private func frame(_ xfrm: XNode?, _ t: Affine) -> Frame? {
            guard let xfrm, let off = xfrm.child("off"), let ext = xfrm.child("ext"),
                  let x = off.double("x"), let y = off.double("y"), let cx = ext.double("cx"), let cy = ext.double("cy") else { return nil }
            var f = Frame(x: (t.ox + t.sx * x) / 12700, y: (t.oy + t.sy * y) / 12700, w: t.sx * cx / 12700, h: t.sy * cy / 12700)
            f.rot = (xfrm.double("rot") ?? 0) / 60000
            f.flipH = xfrm.attr("flipH") == "1" || xfrm.attr("flipH") == "true"
            f.flipV = xfrm.attr("flipV") == "1" || xfrm.attr("flipV") == "true"
            return f
        }

        private func hidden(_ node: XNode) -> Bool {
            guard let nv = node.children.first(where: { $0.name.hasPrefix("nv") }), let c = nv.child("cNvPr") else { return false }
            return c.attr("hidden") == "1" || c.attr("hidden") == "true"
        }

        /// The first of `chain` (the shape's own properties, then the layout's, then the master's) with one of `names` inside.
        private func firstChild(_ chain: [XNode?], _ names: [String]) -> XNode? {
            for node in chain { if let c = node?.children.first(where: { names.contains($0.name) }) { return c } }
            return nil
        }

        private func shape(_ node: XNode, _ t: Affine, _ r: Reader) -> [Item] {
            let properties = node.child("spPr")
            let ph = node.child("nvSpPr")?.child("nvPr")?.child("ph")
            if ph != nil, r.layer < 2 { return [] }   // prompts of the layout and the master are not on the slide
            let layoutPh = ph.flatMap { match($0, in: r.inherit?.layout ?? [], byIndex: true) }
            let masterPh = ph.flatMap { match($0, in: r.inherit?.master ?? [], byIndex: false) }
            let chain: [XNode?] = [properties, layoutPh?.node.child("spPr"), masterPh?.node.child("spPr")]
            let place = frame(properties?.child("xfrm"), t)
                ?? frame(layoutPh?.node.child("spPr")?.child("xfrm"), Affine()) ?? frame(masterPh?.node.child("spPr")?.child("xfrm"), Affine())
            guard let place else { return [] }

            var geometry = node.name == "cxnSp" ? Geometry.line : Geometry.rect
            if let g = self.geometry(chain, width: place.w * 12700, height: place.h * 12700) { geometry = g }
            // Fill and line: their own, the layout's or the master's, or the theme's colour of the shape's style reference.
            let style = node.child("style")
            func colour(of fill: XNode) -> NSColor? {
                switch fill.name {
                case "solidFill": return color(fill, r.theme)
                case "gradFill": return fill.child("gsLst")?.kids("gs").first.flatMap { color($0, r.theme) }
                default: return nil
                }
            }
            let paints = ["solidFill", "noFill", "gradFill", "pattFill", "blipFill"]
            var fill: NSColor?
            if geometry != .line {
                if let f = firstChild(chain, paints) { fill = colour(of: f) }
                else if let ref = style?.child("fillRef"), ref.attr("idx") != "0" { fill = color(ref, r.theme) }
            }
            let lines = chain.map { $0?.child("ln") }
            let lineNode = lines.compactMap { $0 }.first { ln in ln.children.contains { paints.contains($0.name) } }
            var line: NSColor?
            if let f = lineNode?.children.first(where: { paints.contains($0.name) }) { line = colour(of: f) }
            else if let ref = style?.child("lnRef"), ref.attr("idx") != "0" { line = color(ref, r.theme) }
            if line == nil, geometry == .line, lineNode == nil { line = NSColor.black }
            let lineWidth = max((lines.compactMap { $0?.double("w") }.first ?? 9525) / 12700, 0.25)

            var text: Text?
            if let body = node.child("txBody") {
                let kind: PlaceholderKind = ph == nil ? .other : (Self.family(ph?.attr("type")) == "title" ? .title : Self.family(ph?.attr("type")) == "body" ? .body : .none)
                var textChain: [XNode?] = [defaults]
                let styles = r.inherit?.masterStyles
                switch kind {
                case .title: textChain.append(styles?.child("titleStyle"))
                case .body: textChain.append(styles?.child("bodyStyle"))
                default: break
                }
                textChain += [masterPh?.node.child("txBody")?.child("lstStyle"), layoutPh?.node.child("txBody")?.child("lstStyle"), body.child("lstStyle")]
                let props = [body.child("bodyPr"), layoutPh?.node.child("txBody")?.child("bodyPr"), masterPh?.node.child("txBody")?.child("bodyPr")]
                let parsed = self.text(body, chain: textChain, theme: r.theme, bodyProps: props)
                if !parsed.isEmpty { text = parsed }
            }
            if fill == nil, line == nil, text == nil { return [] }
            return [Item(frame: place, content: .shape(geometry, fill: fill, line: line, lineWidth: lineWidth, text: text), layer: r.layer)]
        }

        private func picture(_ node: XNode, _ t: Affine, _ r: Reader) -> [Item] {
            let ph = node.child("nvPicPr")?.child("nvPr")?.child("ph")
            if ph != nil, r.layer < 2 { return [] }
            let layoutPh = ph.flatMap { match($0, in: r.inherit?.layout ?? [], byIndex: true) }
            let masterPh = ph.flatMap { match($0, in: r.inherit?.master ?? [], byIndex: false) }
            let chain: [XNode?] = [node.child("spPr"), layoutPh?.node.child("spPr"), masterPh?.node.child("spPr")]
            guard let place = frame(node.child("spPr")?.child("xfrm"), t)
                    ?? frame(layoutPh?.node.child("spPr")?.child("xfrm"), Affine()) ?? frame(masterPh?.node.child("spPr")?.child("xfrm"), Affine()),
                  let blipFill = node.child("blipFill"), let id = blipFill.child("blip")?.rattr("embed"),
                  let target = rels(of: r.part).first(where: { $0.id == id && !$0.external })?.target,
                  ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "webp"].contains((target as NSString).pathExtension.lowercased()) else { return [] }
            var crop = Crop()
            if let src = blipFill.child("srcRect") {
                crop = Crop(l: (src.double("l") ?? 0) / 100_000, t: (src.double("t") ?? 0) / 100_000,
                            r: (src.double("r") ?? 0) / 100_000, b: (src.double("b") ?? 0) / 100_000)
            }
            var clip = geometry(chain, width: place.w * 12700, height: place.h * 12700)
            if clip == .rect || clip == .line { clip = nil }
            return [Item(frame: place, content: .picture(path: target, crop: crop, clip: clip), layer: r.layer)]
        }

        // MARK: Outlines

        /// The outline of a shape: a preset (only the few the renderer draws) or a free-form path.
        private func geometry(_ chain: [XNode?], width: Double, height: Double) -> Geometry? {
            guard let g = firstChild(chain, ["prstGeom", "custGeom"]) else { return nil }
            if g.name == "custGeom" { return custom(g, width: width, height: height) }
            let kind = g.attr("prst") ?? "rect"
            var adjust: [String: Double] = [:]
            for gd in g.child("avLst")?.kids("gd") ?? [] {
                if let name = gd.attr("name"), let value = gd.attr("fmla")?.split(separator: " ").last.flatMap({ Double($0) }) { adjust[name] = value }
            }
            return preset(kind, adjust, width: width, height: height)
        }

        /// The presets the renderer draws as such: arrows, a few polygons and rounded rectangles; any other is a rectangle.
        private func preset(_ kind: String, _ adj: [String: Double], width w: Double, height h: Double) -> Geometry? {
            guard w > 0, h > 0 else { return .rect }
            let ss = min(w, h)
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), max(lo, hi)) }
            func polygon(_ points: [(Double, Double)]) -> Geometry {
                let path = CGMutablePath()
                for (i, point) in points.enumerated() {
                    let q = CGPoint(x: point.0 / w, y: point.1 / h)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                path.closeSubpath()
                return .custom(Custom(path: path))
            }
            switch kind {
            case "ellipse": return .ellipse
            case "line", "straightConnector1": return .line
            case "roundRect":
                let r = ss * clamp(adj["adj"] ?? 16667, 0, 50000) / 100_000
                return .custom(Custom(path: CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1, height: 1), cornerWidth: r / w, cornerHeight: r / h, transform: nil)))
            case "rightArrow", "leftArrow":
                let head = ss * clamp(adj["adj2"] ?? 50000, 0, 100_000 * w / ss) / 100_000
                let half = h * clamp(adj["adj1"] ?? 50000, 0, 100_000) / 200_000
                let y1 = h / 2 - half, y2 = h / 2 + half
                let pts: [(Double, Double)] = kind == "rightArrow"
                    ? [(0, y1), (w - head, y1), (w - head, 0), (w, h / 2), (w - head, h), (w - head, y2), (0, y2)]
                    : [(w, y1), (head, y1), (head, 0), (0, h / 2), (head, h), (head, y2), (w, y2)]
                return polygon(pts)
            case "upArrow", "downArrow":
                let head = ss * clamp(adj["adj2"] ?? 50000, 0, 100_000 * h / ss) / 100_000
                let half = w * clamp(adj["adj1"] ?? 50000, 0, 100_000) / 200_000
                let x1 = w / 2 - half, x2 = w / 2 + half
                let pts: [(Double, Double)] = kind == "upArrow"
                    ? [(x1, h), (x1, head), (0, head), (w / 2, 0), (w, head), (x2, head), (x2, h)]
                    : [(x1, 0), (x1, h - head), (0, h - head), (w / 2, h), (w, h - head), (x2, h - head), (x2, 0)]
                return polygon(pts)
            case "triangle": return polygon([(0, h), (w * clamp(adj["adj"] ?? 50000, 0, 100_000) / 100_000, 0), (w, h)])
            case "diamond": return polygon([(0, h / 2), (w / 2, 0), (w, h / 2), (w / 2, h)])
            case "homePlate":
                let x1 = w - ss * clamp(adj["adj"] ?? 50000, 0, 100_000 * w / ss) / 100_000
                return polygon([(0, 0), (x1, 0), (w, h / 2), (x1, h), (0, h)])
            case "chevron":
                let x1 = ss * clamp(adj["adj"] ?? 50000, 0, 100_000 * w / ss) / 100_000
                return polygon([(0, 0), (w - x1, 0), (w, h / 2), (w - x1, h), (0, h), (x1, h / 2)])
            default: return .rect
            }
        }

        /// The values a free-form shape's formulas can use: the shape's size, its guides, and numbers.
        private final class Guides {
            var formulas: [String: String] = [:]
            private var cache: [String: Double] = [:]
            let w: Double, h: Double
            init(w: Double, h: Double) { self.w = w; self.h = h }

            func value(_ token: String, _ depth: Int = 0) -> Double {
                if let v = Double(token) { return v }
                if let c = cache[token] { return c }
                switch token {
                case "w", "r": return w
                case "h", "b": return h
                case "l", "t": return 0
                case "hc", "wd2": return w / 2
                case "vc", "hd2": return h / 2
                case "wd4": return w / 4
                case "hd4": return h / 4
                case "ss": return min(w, h)
                case "ls": return max(w, h)
                default: break
                }
                guard depth < 40, let formula = formulas[token] else { return 0 }
                let p = formula.split(separator: " ").map(String.init)
                func arg(_ i: Int) -> Double { p.count > i ? value(p[i], depth + 1) : 0 }
                let a = arg(1), b = arg(2), c = arg(3)
                let result: Double
                switch p.first ?? "" {
                case "val": result = a
                case "*/": result = c != 0 ? a * b / c : 0
                case "+-": result = a + b - c
                case "+/": result = c != 0 ? (a + b) / c : 0
                case "abs": result = abs(a)
                case "min": result = min(a, b)
                case "max": result = max(a, b)
                case "sqrt": result = sqrt(max(a, 0))
                case "?:": result = a > 0 ? b : c
                case "mod": result = (a * a + b * b + c * c).squareRoot()
                default: result = 0
                }
                cache[token] = result
                return result
            }
        }

        private func custom(_ g: XNode, width: Double, height: Double) -> Geometry? {
            guard width > 0, height > 0 else { return nil }
            let guides = Guides(w: width, h: height)
            for gd in g.child("gdLst")?.kids("gd") ?? [] {
                if let name = gd.attr("name"), let formula = gd.attr("fmla") { guides.formulas[name] = formula }
            }
            let path = CGMutablePath()
            var commands = 0
            for p in (g.child("pathLst")?.kids("path") ?? []).prefix(20) where p.attr("fill") != "none" {
                // Coordinates are in the path's own units when it declares them, in the shape's otherwise.
                let pw = p.double("w") ?? 0, ph = p.double("h") ?? 0
                let sx = 1 / (pw > 0 ? pw : width), sy = 1 / (ph > 0 ? ph : height)
                func point(_ n: XNode?) -> CGPoint {
                    CGPoint(x: guides.value(n?.attr("x") ?? "0") * sx, y: guides.value(n?.attr("y") ?? "0") * sy)
                }
                var current = CGPoint.zero
                for cmd in p.children.prefix(20_000) {
                    commands += 1
                    switch cmd.name {
                    case "moveTo": current = point(cmd.child("pt")); path.move(to: current)
                    case "lnTo": current = point(cmd.child("pt")); path.addLine(to: current)
                    case "cubicBezTo":
                        let pts = cmd.kids("pt").map(point)
                        guard pts.count == 3 else { continue }
                        path.addCurve(to: pts[2], control1: pts[0], control2: pts[1]); current = pts[2]
                    case "quadBezTo":
                        let pts = cmd.kids("pt").map(point)
                        guard pts.count == 2 else { continue }
                        path.addQuadCurve(to: pts[1], control: pts[0]); current = pts[1]
                    case "arcTo":
                        let rx = guides.value(cmd.attr("wR") ?? "0") * sx, ry = guides.value(cmd.attr("hR") ?? "0") * sy
                        let start = guides.value(cmd.attr("stAng") ?? "0") / 60000 * .pi / 180
                        let sweep = guides.value(cmd.attr("swAng") ?? "0") / 60000 * .pi / 180
                        let centre = CGPoint(x: current.x - rx * cos(start), y: current.y - ry * sin(start))
                        let steps = max(Int((abs(sweep) / (.pi / 36)).rounded(.up)), 1)
                        for k in 1...steps {
                            let a = start + sweep * Double(k) / Double(steps)
                            current = CGPoint(x: centre.x + rx * cos(a), y: centre.y + ry * sin(a))
                            path.addLine(to: current)
                        }
                    case "close": path.closeSubpath()
                    default: break
                    }
                }
            }
            return commands > 0 && !path.isEmpty ? .custom(Custom(path: path.copy() ?? path)) : nil
        }

        private func table(_ node: XNode, _ t: Affine, _ r: Reader) -> [Item] {
            guard let place = frame(node.child("xfrm"), t),
                  let tbl = node.child("graphic")?.child("graphicData")?.child("tbl") else { return [] }
            let columns = (tbl.child("tblGrid")?.kids("gridCol") ?? []).map { ($0.double("w") ?? 0) * t.sx / 12700 }
            guard !columns.isEmpty, columns.count <= 100 else { return [] }
            var rows: [Row] = []
            for tr in tbl.kids("tr").prefix(1000) {
                var cells: [Cell] = []
                for tc in tr.kids("tc") {
                    let text = tc.child("txBody").map { self.text($0, chain: [defaults], theme: r.theme, bodyProps: [$0.child("bodyPr")]) }
                        ?? Text(paragraphs: [])
                    var cell = Cell(text: text, fill: tc.child("tcPr")?.child("solidFill").flatMap { color($0, r.theme) })
                    cell.text.insets = (l: 7.2, t: 3.6, r: 7.2, b: 3.6)
                    cells.append(cell)
                }
                rows.append(Row(height: (tr.double("h") ?? 0) * t.sy / 12700, cells: cells))
            }
            return [Item(frame: place, content: .table(columns: columns, rows: rows), layer: r.layer)]
        }

        // MARK: Text

        private func level(_ list: XNode?, _ n: Int, _ theme: Theme) -> Style {
            style(list?.child("lvl\(n + 1)pPr"), theme)
        }

        /// A paragraph's properties (`pPr`, or `lvlNpPr` of a list style), and its default run properties.
        private func style(_ pPr: XNode?, _ theme: Theme) -> Style {
            var s = runStyle(pPr?.child("defRPr"), theme)
            guard let pPr else { return s }
            switch pPr.attr("algn") {
            case "ctr": s.align = .center
            case "r": s.align = .right
            case "just": s.align = .justified
            case "l": s.align = .left
            default: break
            }
            s.marL = pPr.double("marL").map { $0 / 12700 }
            s.indent = pPr.double("indent").map { $0 / 12700 }
            if pPr.child("buNone") != nil { s.bullet = Bullet.none }
            if let c = pPr.child("buChar")?.attr("char") {
                let font = pPr.child("buFont")?.attr("typeface") ?? ""
                s.bullet = .char(font.contains("Wingdings") || font.contains("Symbol") ? (c == "ü" ? "✓" : c == "§" ? "▪" : "•") : c)
            }
            if let n = pPr.child("buAutoNum") { s.bullet = .number(n.attr("type") ?? "arabicPeriod") }
            if let p = pPr.child("spcBef")?.child("spcPts")?.double("val") { s.spaceBeforePoints = p / 100 }
            if let p = pPr.child("spcBef")?.child("spcPct")?.double("val") { s.spaceBeforePercent = p / 100_000 }
            if let p = pPr.child("spcAft")?.child("spcPts")?.double("val") { s.spaceAfterPoints = p / 100 }
            if let p = pPr.child("spcAft")?.child("spcPct")?.double("val") { s.spaceAfterPercent = p / 100_000 }
            if let p = pPr.child("lnSpc")?.child("spcPct")?.double("val") { s.linePercent = p / 100_000 }
            return s
        }

        private func runStyle(_ rPr: XNode?, _ theme: Theme) -> Style {
            var s = Style()
            guard let rPr else { return s }
            s.size = rPr.double("sz").map { $0 / 100 }
            s.bold = rPr.attr("b").map { $0 == "1" || $0 == "true" }
            s.italic = rPr.attr("i").map { $0 == "1" || $0 == "true" }
            s.underline = rPr.attr("u").map { $0 != "none" }
            if let fill = rPr.child("solidFill") { s.color = color(fill, theme) }
            if let face = rPr.child("latin")?.attr("typeface") {
                s.font = face == "+mj-lt" ? theme.major : face == "+mn-lt" ? theme.minor : face.hasPrefix("+") ? nil : face
            }
            return s
        }

        private func text(_ body: XNode, chain: [XNode?], theme: Theme, bodyProps: [XNode?]) -> Text {
            var text = Text(paragraphs: [])
            // Anchor, margins and autofit: the shape's own, else the layout's, else the master's.
            func prop(_ name: String) -> String? { bodyProps.lazy.compactMap { $0?.attr(name) }.first }
            switch prop("anchor") { case "ctr": text.anchor = .middle; case "b": text.anchor = .bottom; default: break }
            text.insets = (l: (prop("lIns").flatMap(Double.init) ?? 91440) / 12700, t: (prop("tIns").flatMap(Double.init) ?? 45720) / 12700,
                           r: (prop("rIns").flatMap(Double.init) ?? 91440) / 12700, b: (prop("bIns").flatMap(Double.init) ?? 45720) / 12700)
            if let scale = bodyProps.lazy.compactMap({ $0?.child("normAutofit")?.double("fontScale") }).first { text.fontScale = max(scale / 100_000, 0.1) }
            let black = theme.color(named: "tx1") ?? .black
            var counters = [Int](repeating: 0, count: 10)
            for p in body.kids("p").prefix(5000) {
                let pPr = p.child("pPr")
                let n = min(max(Int(pPr?.attr("lvl") ?? "") ?? 0, 0), 8)
                var s = style(pPr, theme)
                s = s.over(chain.reduce(Style()) { acc, list in level(list, n, theme).over(acc) })
                var runs: [Run] = []
                func add(_ value: String, _ rPr: XNode?) {
                    let own = runStyle(rPr, theme).over(s)
                    runs.append(Run(text: value, font: own.font, size: (own.size ?? 18) * text.fontScale,
                                    bold: own.bold ?? false, italic: own.italic ?? false, underline: own.underline ?? false,
                                    color: own.color ?? black))
                }
                for piece in p.children {
                    switch piece.name {
                    case "r", "fld": add(piece.child("t")?.text ?? "", piece.child("rPr"))
                    case "br": add("\u{2028}", piece.child("rPr"))
                    default: break
                    }
                }
                // Numbering: counts the paragraphs of a level in a row; any other paragraph ends the count.
                var label: String?
                switch s.bullet {
                case .char(let c)?: label = c; counters[n] = 0
                case .number(let kind)?:
                    counters[n] += 1
                    label = PptxReader.numberLabel(counters[n], kind)
                    for deeper in (n + 1)..<counters.count { counters[deeper] = 0 }
                default: counters[n] = 0
                }
                if runs.allSatisfy({ $0.text.isEmpty }) { label = nil }
                let size = (s.size ?? 18) * text.fontScale
                let before = s.spaceBeforePoints ?? (s.spaceBeforePercent.map { $0 * size } ?? 0)
                let after = s.spaceAfterPoints ?? (s.spaceAfterPercent.map { $0 * size } ?? 0)
                let hanging = label == nil ? 0 : 18.0
                text.paragraphs.append(Paragraph(runs: runs, align: s.align ?? .left, marL: s.marL ?? (label == nil ? 0 : hanging * Double(n + 1)),
                                                 indent: s.indent ?? (label == nil ? 0 : -hanging), bullet: label,
                                                 spaceBefore: before * text.fontScale, spaceAfter: after * text.fontScale, lineMultiple: s.linePercent ?? 1, emptySize: size))
            }
            return text
        }

        // MARK: Colours

        /// The colour inside `holder` (a solidFill, a bgRef…): an RGB value or a theme colour, with the usual changes.
        func color(_ holder: XNode, _ theme: Theme) -> NSColor? {
            guard let node = holder.children.first(where: { ["srgbClr", "schemeClr", "sysClr", "prstClr"].contains($0.name) }) else { return nil }
            var base: NSColor?
            switch node.name {
            case "srgbClr": base = node.attr("val").flatMap { NSColor(hex: $0) }
            case "schemeClr": base = node.attr("val").flatMap { theme.color(named: $0) }
            case "sysClr": base = node.attr("lastClr").flatMap { NSColor(hex: $0) }
            default: base = node.attr("val") == "white" ? .white : .black
            }
            guard var c = base?.usingColorSpace(.sRGB) else { return nil }
            for change in node.children {
                guard let v = change.double("val").map({ $0 / 100_000 }) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                switch change.name {
                case "lumMod": c = NSColor(hue: h, saturation: s, brightness: min(b * v, 1), alpha: a)
                case "lumOff": c = NSColor(hue: h, saturation: s, brightness: min(max(b + v, 0), 1), alpha: a)
                case "tint": c = c.blended(withFraction: 1 - v, of: .white) ?? c
                case "shade": c = c.blended(withFraction: 1 - v, of: .black) ?? c
                default: break
                }
            }
            return c
        }
    }

    fileprivate static func numberLabel(_ n: Int, _ kind: String) -> String {
        func letters(_ n: Int) -> String { String(UnicodeScalar(UInt8(96 + (n - 1) % 26 + 1))) }
        switch kind {
        case "arabicParenR": return "\(n))"
        case "alphaLcPeriod": return letters(n) + "."
        case "alphaUcPeriod": return letters(n).uppercased() + "."
        case "alphaLcParenR": return letters(n) + ")"
        default: return "\(n)."
        }
    }
}
