import Foundation

/// Cells → a Numbers file, written by Rondelle itself (nothing is sent to Numbers: no Apple Events, no permission).
///
/// A `.numbers` file is a ZIP of `.iwa` archives (Snappy-compressed protobuf, see `PagesWriter`). Rondelle takes the
/// empty spreadsheet that the installed Numbers ships as a template (`Blank`), and changes the one table in it:
/// its size, the identifiers of its rows and columns, its string table and the tile that holds the cells (version 5
/// of Apple's `TSTCellStorage`, as `NumbersReader` reads it). The template is read from the installed app each time
/// and never copied into Rondelle, so without Numbers there is no conversion (the wheel doesn't offer it then).
///
/// What is written: one sheet with one table; text and numbers (values only: no formulas, formats, styles, charts).
/// A table is at most 65 536 rows by 255 columns (one tile, as tall as the table: the tile size is written into the file);
/// several sheets are written too: the first sheet's objects (and the calculation engine's records for its table) are copied
/// under new identifiers for every other sheet.
enum NumbersWriter {
    typealias PB = PagesWriter.PB
    typealias Archive = PagesWriter.Archive
    typealias IWA = PagesWriter.IWA
    typealias Object = Archive.Object

    static let maxRows = 65_536, maxColumns = 255, maxSheets = 50

    /// Bytes of cells, row infos and texts for all the sheets: what one `.iwa` holds, less 2 MB for the template.
    static let maxCellBytes = IWA.maxEntryBytes - 2_000_000

    private static var tooBig: OpError {
        .unsupported(L("troppi dati per un file Numbers che Rondelle sa rileggere: dividi il foglio in più parti"))
    }

    /// An upper bound of the bytes `fill` writes (row info with its two tables of 255 offsets, 40 bytes per number
    /// cell and 28 per text cell with their legacy copy, each distinct text once), or `Int.max` when a table has
    /// more distinct texts than the reader reads in one message.
    static func estimatedBytes(_ sheets: [SheetOps.Sheet]) -> Int {
        var total = 0
        for sheet in sheets {
            var texts = Set<String>()
            for row in sheet.rows {
                total += 1_100
                for value in row where !value.isEmpty {
                    let first = value.utf8.first { $0 != 0x20 && $0 != 0x09 } ?? 0
                    if first == 0x2D || (0x30...0x39).contains(first), decimal128(value) != nil { total += 52 } else {
                        total += 40
                        if texts.insert(value).inserted { total += value.utf8.count + 16 }
                    }
                }
                if total > maxCellBytes { return total }
            }
            if texts.count >= PB.maxFields - 10 { return .max }
        }
        return total
    }

    /// The `.iwa` written, read back within the reader's caps (`IWorkFile.maxIndexBytes`, `IWA.Budget`): past one, the
    /// file is not written.
    private static func readable(_ index: URL) throws {
        var budget = IWA.Budget(), left = IWorkFile.maxIndexBytes
        for case let url as URL in FileManager.default.enumerator(at: index, includingPropertiesForKeys: nil)?.allObjects ?? [] where url.pathExtension == "iwa" {
            try PDFOps.checkCancelled()
            guard let raw = FileManager.default.contents(atPath: url.path) else { continue }
            left -= raw.count
            guard left >= 0 else { throw tooBig }
            do { _ = try IWorkFile.objects(in: raw, of: url, unreadable: tooBig, budget: &budget) } catch is CancellationError { throw CancellationError() } catch { throw tooBig }
        }
    }

    private static var unknownTemplate: OpError {
        .unsupported(L("Il modello di Numbers installato non è riconosciuto: aggiorna Rondelle"))
    }

    // MARK: Public

    static func write(_ sheets: [SheetOps.Sheet], to out: URL) throws {
        guard !sheets.isEmpty, sheets.allSatisfy({ !$0.rows.isEmpty && ($0.rows.map(\.count).max() ?? 0) > 0 }) else {
            throw OpError.failed(L("il foglio di calcolo è vuoto"))
        }
        guard sheets.count <= maxSheets else { throw OpError.unsupported(L("più di %@ fogli: dividi il file in più parti", maxSheets)) }
        for sheet in sheets where sheet.rows.count > maxRows || (sheet.rows.map(\.count).max() ?? 0) > maxColumns {
            throw OpError.unsupported(L("per Numbers al massimo %@ righe e %@ colonne", maxRows, maxColumns))
        }
        // What NumbersReader (and so Rondelle) would refuse is not written: the cells must fit in one `.iwa` of
        // `IWA.maxEntryBytes`, with a margin for the template, and each table in `PB.maxFields` distinct texts.
        try PDFOps.checkCancelled()
        guard estimatedBytes(sheets) <= maxCellBytes else { throw tooBig }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("rondelle-numbers-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try IWorkFile.run("/usr/bin/unzip", ["-q", "-o", try templateURL().path, "-d", work.path])
        try build(sheets, in: work)
        try readable(work.appendingPathComponent("Index", isDirectory: true))
        try? UUID().uuidString.write(to: work.appendingPathComponent("Metadata/DocumentIdentifier"), atomically: true, encoding: .utf8)

        let archive = work.appendingPathComponent("out.numbers")
        let top = ((try? fm.contentsOfDirectory(atPath: work.path)) ?? []).filter { ["Index", "Data", "Metadata"].contains($0) }.sorted()
        try IWorkFile.run("/usr/bin/zip", ["-0", "-X", "-q", "-r", archive.path] + top, in: work)
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.moveItem(at: archive, to: out)
    }

    // MARK: Template

    private static func templateURL() throws -> URL {
        guard let app = IWorkOps.App.numbers.installed else {
            throw OpError.unsupported(L("Per creare un file Numbers serve Numbers installato"))
        }
        let root = app.appendingPathComponent("Contents/SharedSupport/Templates", isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for folder in (folders.filter { $0.hasSuffix("Blank") || $0.hasSuffix("Blank_Black") } + folders) {
            let url = root.appendingPathComponent(folder).appendingPathComponent("Traditional.nmbtemplate")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw unknownTemplate
    }

    // MARK: Cells

    /// A number as Apple stores it: IEEE 754 decimal128 (coefficient up to 19 digits, exponent), 16 bytes little endian.
    /// Text that isn't a plain decimal number, or has more digits than that, is not a number.
    static func decimal128(_ text: String) -> [UInt8]? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]{1,3})?$"#, options: .regularExpression) != nil else { return nil }
        let negative = s.hasPrefix("-")
        var body = negative ? String(s.dropFirst()) : s
        var exponent = 0
        if let e = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(body[body.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
            body = String(body[..<e])
        }
        var digits = body
        if let dot = body.firstIndex(of: ".") {
            let fraction = body[body.index(after: dot)...]
            digits = String(body[..<dot]) + fraction
            exponent -= fraction.count
        }
        while digits.count > 1, digits.hasPrefix("0") { digits.removeFirst() }
        guard digits.count <= 19, let coefficient = UInt64(digits), (-6176...6111).contains(exponent) else { return nil }
        let high = UInt64(exponent + 6176) << 49 | (negative ? 1 << 63 : 0)
        return (0..<8).map { UInt8(truncatingIfNeeded: coefficient >> UInt64(8 * $0)) } + (0..<8).map { UInt8(truncatingIfNeeded: high >> UInt64(8 * $0)) }
    }

    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) } }

    // MARK: Building

    private struct State {
        var files: [String: [Object]] = [:]          // path below Index → objects
        var holder: [UInt64: String] = [:]           // object → path
        var changed = Set<String>()
        var nextID: UInt64 = 0
        var components: [String: UInt64] = [:]       // path → identifier of its component
        var entries: [UInt64: [PB.Field]] = [:]      // component identifier → its metadata entry
        var order: [UInt64] = []                      // the entries, in order
        var uuidKinds: [String: Set<UInt64>] = ["Document.iwa": [2, 3047, 2001], "CalculationEngine.iwa": [6000, 3097, 6001]]

        mutating func allocate() -> UInt64 { defer { nextID += 1 }; return nextID }

        func find(_ id: UInt64) -> (file: String, index: Int)? {
            guard let file = holder[id], let at = files[file]?.firstIndex(where: { $0.id == id }) else { return nil }
            return (file, at)
        }
        func object(_ id: UInt64) -> Object? { find(id).flatMap { files[$0.file]?[$0.index] } }
        func fields(_ id: UInt64) -> [PB.Field]? { object(id).flatMap { $0.messages.first.flatMap { try? PB.parse($0.payload) } } }

        mutating func replace(_ id: UInt64, with fields: [PB.Field]) throws {
            guard let found = find(id) else { throw NumbersWriter.unknownTemplate }
            files[found.file]![found.index].messages[0].payload = PB.build(fields)
            changed.insert(found.file)
        }
        mutating func setReferences(_ id: UInt64, _ ids: [UInt64]) {
            guard let found = find(id), let at = files[found.file]![found.index].messages[0].info.firstIndex(where: { $0.num == 5 }) else { return }
            files[found.file]![found.index].messages[0].info[at].data = ids.flatMap { PB.varint($0) }
            changed.insert(found.file)
        }
        func references(_ id: UInt64) -> [UInt64] {
            guard let info = object(id)?.messages.first?.info.first(where: { $0.num == 5 }) else { return [] }
            var out: [UInt64] = [], i = 0
            while i < info.data.count, let value = try? PB.readVarint(info.data, &i) { out.append(value) }
            return out
        }
    }

    private static func ordered(_ fields: [PB.Field]) -> [PB.Field] {
        fields.enumerated().sorted { ($0.element.num, $0.offset) < ($1.element.num, $1.offset) }.map(\.element)
    }

    private static func refField(_ number: Int, _ id: UInt64) -> PB.Field { .bytes(number, PB.build([.int(1, id)])) }

    private static func build(_ sheets: [SheetOps.Sheet], in work: URL) throws {
        var st = State()
        let index = work.appendingPathComponent("Index", isDirectory: true)
        let base = index.standardizedFileURL.path.count + 1
        for case let url as URL in FileManager.default.enumerator(at: index, includingPropertiesForKeys: nil)?.allObjects ?? [] where url.pathExtension == "iwa" {
            let name = String(url.standardizedFileURL.path.dropFirst(base))
            guard let raw = FileManager.default.contents(atPath: url.path), !raw.isEmpty else { continue }
            let objects = try Archive.parse(try IWA.decode([UInt8](raw)))
            st.files[name] = objects
            for object in objects { st.holder[object.id] = name }
        }
        // The package metadata: the entries of the components, and the counter of identifiers.
        guard let metaObject = st.files["Metadata.iwa"]?.first(where: { KeynoteWriter.kind(of: $0) == 11006 }),
              let package = try? PB.parse(metaObject.messages[0].payload) else { throw unknownTemplate }
        st.nextID = (package.first { $0.num == 1 }?.value ?? 0) + 1
        for field in package where field.num == 3 && field.wire == 2 {
            let entry = IWorkFile.fields(field.data)
            guard let id = entry.first(where: { $0.num == 1 })?.value else { continue }
            let path = (IWorkFile.string(entry, 3) ?? IWorkFile.string(entry, 2) ?? "") + ".iwa"
            st.components[path] = id
            st.entries[id] = entry
            st.order.append(id)
        }

        // The first sheet and its table.
        guard let root = st.files["Document.iwa"]?.first(where: { KeynoteWriter.kind(of: $0) == 1 }),
              let rootFields = st.fields(root.id), let sheet0 = IWorkFile.refs(rootFields, 1).first, let sheetFields = st.fields(sheet0),
              let info0 = IWorkFile.refs(sheetFields, 2).first(where: { st.object($0).map { KeynoteWriter.kind(of: $0) == 6000 } == true }),
              let infoFields = st.fields(info0), let model0 = IWorkFile.ref(infoFields, 2), st.fields(model0) != nil else { throw unknownTemplate }
        var models = [model0], sheetIDs = [sheet0]

        if sheets.count > 1 {
            let copies = try cloneTables(count: sheets.count - 1, sheet: sheet0, info: info0, model: model0, rootID: root.id, &st)
            models += copies.models
            sheetIDs += copies.sheets
        }
        for (k, sheet) in sheets.enumerated() {
            try PDFOps.checkCancelled()
            try fill(model: models[k], sheet: sheetIDs[k], with: sheet, &st)
        }

        // The metadata: the counter, the entries of every component written back.
        var rebuilt: [PB.Field] = []
        for field in package {
            if field.num == 1 { rebuilt.append(.int(1, st.nextID - 1)); continue }
            if field.num == 3 { continue }
            rebuilt.append(field)
        }
        for id in st.order { if let entry = st.entries[id] { rebuilt.append(.bytes(3, PB.build(entry))) } }
        st.files["Metadata.iwa"]![st.files["Metadata.iwa"]!.firstIndex { $0.id == metaObject.id }!].messages[0].payload = PB.build(ordered(rebuilt))
        st.changed.insert("Metadata.iwa")

        for file in st.changed {
            guard let objects = st.files[file] else { continue }
            let url = index.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(IWA.encode(Archive.build(objects))).write(to: url)
        }
    }

    // MARK: Copies of the first table

    /// Copies of the first sheet and of everything its table needs, `count` times, registered in the document.
    private static func cloneTables(count: Int, sheet: UInt64, info: UInt64, model: UInt64, rootID: UInt64, _ st: inout State)
        throws -> (sheets: [UInt64], models: [UInt64]) {
        // The table's owners in the calculation engine: the records whose identifier has the table's second half.
        guard let infoFields = st.fields(info), let tableUID = IWorkFile.message(infoFields, 7),
              let upper = tableUID.first(where: { $0.num == 2 })?.value, let lowerOf = tableUID.first(where: { $0.num == 1 })?.value,
              let engine = st.files["CalculationEngine.iwa"], let engineRoot = engine.first(where: { KeynoteWriter.kind(of: $0) == 4000 }),
              let engineFields = st.fields(engineRoot.id) else { throw unknownTemplate }
        let owners = engine.filter { object in
            guard KeynoteWriter.kind(of: object) == 4008, let f = try? PB.parse(object.messages[0].payload),
                  let uid = IWorkFile.message(f, 1) else { return false }
            return uid.first(where: { $0.num == 2 })?.value == upper
        }
        guard !owners.isEmpty else { throw unknownTemplate }
        // Its identifier is a family of 128-bit values: (high half of the lower, low half + kind, the upper's two halves).
        let lowers = owners.compactMap { o -> UInt64? in IWorkFile.message((try? PB.parse(o.messages[0].payload)) ?? [], 1)?.first { $0.num == 1 }?.value }
        let low32Min = lowers.map { $0 & 0xFFFF_FFFF }.min() ?? 0
        let high32 = lowerOf >> 32, upLow = upper & 0xFFFF_FFFF, upHigh = upper >> 32

        // What is copied: the sheet with what it refers to, the owners with what they refer to (never the stylesheet).
        func closure(_ roots: [UInt64]) -> [UInt64] {
            var seen = Set<UInt64>(), order: [UInt64] = []
            func visit(_ id: UInt64) {
                guard st.object(id) != nil, st.holder[id] != "DocumentStylesheet.iwa", seen.insert(id).inserted else { return }
                order.append(id)
                for ref in st.references(id) { visit(ref) }
            }
            roots.forEach(visit)
            return order
        }
        var unit = closure([sheet])
        for id in closure(owners.map(\.id)) where !unit.contains(id) { unit.append(id) }
        let tileKinds: [UInt64] = unit.compactMap { st.object($0).map { KeynoteWriter.kind(of: $0) } }
        _ = tileKinds

        // The sidebar: the root's children, and the two nodes of the first sheet (its own and its table's).
        guard let sidebarRoot = IWorkFile.ref(st.fields(rootID) ?? [], 5), let sidebarRootFields = st.fields(sidebarRoot),
              let document = st.files["Document.iwa"] else { throw unknownTemplate }
        let sheetNode = document.first { KeynoteWriter.kind(of: $0) == 205 && st.references($0.id).contains(sheet) }
        let tableNode = document.first { KeynoteWriter.kind(of: $0) == 205 && st.references($0.id).contains(info) }
        guard let sheetNode, let tableNode else { throw unknownTemplate }

        var newSheets: [UInt64] = [], newModels: [UInt64] = []
        var rootRefs = st.references(rootID), sidebarRefs = st.references(sidebarRoot), engineRefs = st.references(engineRoot.id)
        var rootFieldsNew = st.fields(rootID) ?? [], sidebarFieldsNew = sidebarRootFields
        var engineTracker = IWorkFile.message(engineFields, 2) ?? []
        var ownerMap = IWorkFile.message(engineTracker, 3) ?? []
        var internalID = ownerMap.filter { $0.num == 1 }.compactMap { IWorkFile.fields($0.data).first { $0.num == 1 }?.value }.max().map { $0 + 1 } ?? 20
        let unitModelIndex = unit.firstIndex(of: model)

        for _ in 0..<count {
            // New identifiers for the objects, new halves for the table's identifier family.
            var map: [UInt64: UInt64] = [:]
            for id in unit { map[id] = st.allocate() }
            map[sheetNode.id] = st.allocate(); map[tableNode.id] = st.allocate()
            let newHigh = UInt64.random(in: 1...0x7FFF_FFFF), newLow = UInt64.random(in: 0x1000_0000...0x7000_0000)
            let newUpLow = UInt64.random(in: 1...0x7FFF_FFFF), newUpHigh = UInt64.random(in: 1...0x7FFF_FFFF)
            for offset in UInt64(0)...64 {
                map[(high32 << 32) | (low32Min + offset)] = (newHigh << 32) | (newLow + offset)
                map[low32Min + offset] = newLow + offset
            }
            map[high32] = newHigh; map[upLow] = newUpLow; map[upHigh] = newUpHigh
            map[upper] = (newUpHigh << 32) | newUpLow

            var copies: [(object: Object, file: String)] = []
            for id in unit {
                guard let source = st.object(id), let file = st.holder[id] else { continue }
                copies.append((cloneObject(source, as: map[id]!, map), file))
            }
            for node in [sheetNode, tableNode] { copies.append((cloneObject(node, as: map[node.id]!, map), "Document.iwa")) }

            // The copies of the owners get internal numbers of their own, and a place in the engine's tables.
            var newOwners: [UInt64] = []
            for at in copies.indices where KeynoteWriter.kind(of: copies[at].object) == 4008 {
                var f = (try? PB.parse(copies[at].object.messages[0].payload)) ?? []
                if let i = f.firstIndex(where: { $0.num == 2 }) { f[i].value = internalID }
                copies[at].object.messages[0].payload = PB.build(f)
                let uid = IWorkFile.message(f, 1) ?? []
                let lo = uid.first { $0.num == 1 }?.value ?? 0, up = uid.first { $0.num == 2 }?.value ?? 0
                let quad: [PB.Field] = [.int(2, lo & 0xFFFF_FFFF), .int(3, lo >> 32), .int(4, up & 0xFFFF_FFFF), .int(5, up >> 32)]
                ownerMap.append(.bytes(1, PB.build([.int(1, internalID), .bytes(2, PB.build(quad))])))
                internalID += 1
                newOwners.append(copies[at].object.id)
            }

            // The table's identifier as text, the names; then every copy goes into a file.
            for at in copies.indices where KeynoteWriter.kind(of: copies[at].object) == 6001 {
                var f = (try? PB.parse(copies[at].object.messages[0].payload)) ?? []
                if let i = f.firstIndex(where: { $0.num == 1 && $0.wire == 2 }) {
                    let bytes = (0..<4).flatMap { k -> [UInt8] in
                        let v = [newLow, newHigh, newUpLow, newUpHigh][k]
                        return (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * $0)) }
                    }
                    let hex = bytes.map { String(format: "%02X", $0) }.joined()
                    let h = Array(hex)
                    f[i].data = Array((String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32])).utf8)
                }
                copies[at].object.messages[0].payload = PB.build(f)
            }
            var newComponents: [UInt64] = []
            for (object, file) in copies {
                let singles = (st.files[file]?.count ?? 0) == 1 && file.hasPrefix("Tables/")
                if singles {
                    let kindName = file.dropLast(4).split(separator: "-", maxSplits: 1).first.map(String.init) ?? file
                    let path = "\(kindName)-\(object.id).iwa"
                    st.files[path] = [object]; st.holder[object.id] = path; st.changed.insert(path)
                    st.components[path] = object.id
                    if let sourceID = st.components[file], var entry = st.entries[sourceID] {
                        entry.removeAll { [1, 3, 6, 11].contains($0.num) }
                        entry.append(.int(1, object.id)); entry.append(.bytes(3, Array(path.dropLast(4).utf8)))
                        st.entries[object.id] = ordered(entry); st.order.append(object.id)
                    }
                    newComponents.append(object.id)
                } else {
                    st.files[file]!.append(object); st.holder[object.id] = file; st.changed.insert(file)
                }
            }

            // The document: the new sheet, its sidebar nodes; the engine: the owners.
            let newSheet = map[sheet]!
            rootFieldsNew.append(refField(1, newSheet)); rootRefs.append(newSheet)
            sidebarFieldsNew.append(refField(2, map[sheetNode.id]!)); sidebarRefs.append(map[sheetNode.id]!)
            engineTracker.removeAll { $0.num == 6 && false }
            for owner in newOwners { engineTracker.append(refField(6, owner)); engineRefs.append(owner) }
            newSheets.append(newSheet)
            if let unitModelIndex { newModels.append(map[unit[unitModelIndex]]!) }
        }
        _ = engineFields
        try st.replace(rootID, with: ordered(rootFieldsNew)); st.setReferences(rootID, rootRefs)
        try st.replace(sidebarRoot, with: ordered(sidebarFieldsNew)); st.setReferences(sidebarRoot, sidebarRefs)
        if let at = engineTracker.firstIndex(where: { $0.num == 3 }) { engineTracker[at].data = PB.build(ownerMap) } else { engineTracker.append(.bytes(3, PB.build(ownerMap))) }
        var newEngine = engineFields
        if let at = newEngine.firstIndex(where: { $0.num == 2 }) { newEngine[at].data = PB.build(ordered(engineTracker)) }
        try st.replace(engineRoot.id, with: newEngine); st.setReferences(engineRoot.id, engineRefs)

        updateEntries(&st)
        return (newSheets, newModels)
    }

    /// The copy of an object under a new identifier: its references (message info and payload) renumbered.
    private static func cloneObject(_ object: Object, as id: UInt64, _ map: [UInt64: UInt64]) -> Object {
        var copy = object
        copy.id = id
        for k in copy.messages.indices {
            var info = copy.messages[k].info
            for i in info.indices where info[i].num == 5 {
                var ids: [UInt64] = [], at = 0
                while at < info[i].data.count, let v = try? PB.readVarint(info[i].data, &at) { ids.append(v) }
                info[i].data = ids.map { map[$0] ?? $0 }.flatMap { PB.varint($0) }
            }
            copy.messages[k].info = info
            copy.messages[k].payload = remap(copy.messages[k].payload, map)
        }
        return copy
    }

    /// `remap` of the Keynote writer, applied to a message: varints that are keys of `map`, also inside nested messages.
    private static func remap(_ bytes: [UInt8], _ map: [UInt64: UInt64], depth: Int = 0) -> [UInt8] {
        guard depth < 16, !bytes.isEmpty, var fields = try? PB.parse(bytes) else { return bytes }
        var changed = false
        for i in fields.indices {
            switch fields[i].wire {
            case 0:
                if let new = map[fields[i].value] { fields[i].value = new; changed = true }
            case 2:
                let data = fields[i].data
                if data.count >= 2, !(data.count >= 4 && data.allSatisfy { ($0 >= 32 && $0 < 127) || $0 >= 0xC2 || $0 == 10 || $0 == 9 }) {
                    let inner = remap(data, map, depth: depth + 1)
                    if inner != data { fields[i].data = inner; changed = true }
                }
            default: break
            }
        }
        return changed ? PB.build(fields) : bytes
    }

    /// The metadata entries of the components that got new objects: the references to other components, the UUIDs.
    private static func updateEntries(_ st: inout State) {
        var owner: [UInt64: UInt64] = [:]
        for (path, objects) in st.files { if let component = st.components[path] { for o in objects { owner[o.id] = component } } }
        for path in st.changed {
            guard let component = st.components[path], var entry = st.entries[component], let objects = st.files[path] else { continue }
            let known = Set(entry.filter { $0.num == 11 && $0.wire == 2 }.compactMap { IWorkFile.fields($0.data).first { $0.num == 1 }?.value })
            var seen = Set(entry.filter { $0.num == 6 && $0.wire == 2 }.map { f -> String in
                let r = IWorkFile.fields(f.data); return "\(r.first { $0.num == 1 }?.value ?? 0)/\(r.first { $0.num == 2 }?.value ?? 0)" })
            let local = Set(objects.map(\.id))
            for object in objects {
                for target in st.references(object.id) where !local.contains(target) {
                    guard let holder = owner[target] else { continue }
                    let key = "\(holder)/\(holder == target ? 0 : target)"
                    if seen.insert(key).inserted {
                        entry.append(.bytes(6, PB.build([.int(1, holder)] + (holder == target ? [] : [PB.Field.int(2, target)]))))
                    }
                }
                if !known.contains(object.id), st.uuidKinds[path]?.contains(KeynoteWriter.kind(of: object)) == true,
                   entry.contains(where: { $0.num == 11 }) || path == "Document.iwa" {
                    entry.append(.bytes(11, PB.build([.int(1, object.id), .bytes(2, PB.build([.int(1, UInt64.random(in: 1...UInt64.max)), .int(2, UInt64.random(in: 1...UInt64.max))]))])))
                }
            }
            st.entries[component] = ordered(entry)
        }
    }

    // MARK: A table's cells

    /// The cells, strings, sizes and names of one table (the first sheet's or a copy's).
    private static func fill(model modelID: UInt64, sheet sheetID: UInt64, with sheet: SheetOps.Sheet, _ st: inout State) throws {
        let rows = sheet.rows
        let width = rows.map(\.count).max() ?? 0
        guard var model = st.fields(modelID), let storeAt = model.firstIndex(where: { $0.num == 4 }) else { throw unknownTemplate }
        let store = IWorkFile.fields(model[storeAt].data)
        guard let stringsID = IWorkFile.ref(store, 4), let columnHeadersID = IWorkFile.ref(store, 2),
              let tileEntry = IWorkFile.message(store, 3).flatMap({ $0.first { $0.num == 1 && $0.wire == 2 } }),
              let tileID = IWorkFile.ref(IWorkFile.fields(tileEntry.data), 2), st.find(tileID) != nil, st.find(stringsID) != nil else { throw unknownTemplate }

        // The strings: key → text, each text once.
        var keys: [String: UInt32] = [:]
        var strings: [String] = []
        var cells: [[(column: Int, bytes: [UInt8])]] = []
        for row in rows {
            var line: [(Int, [UInt8])] = []
            for (column, value) in row.enumerated() where !value.isEmpty {
                if let number = decimal128(value) {
                    line.append((column, [5, 2, 0, 0, 0, 0, 0, 0] + le32(0x1) + number))
                } else {
                    if keys[value] == nil { strings.append(value); keys[value] = UInt32(strings.count) }
                    line.append((column, [5, 3, 0, 0, 0, 0, 0, 0] + le32(0x8) + le32(keys[value]!)))
                }
            }
            cells.append(line)
        }
        var list: [PB.Field] = [.int(1, 1), .int(2, UInt64(strings.count + 1))]
        for (i, text) in strings.enumerated() {
            list.append(.bytes(3, PB.build([.int(1, UInt64(i + 1)), .int(2, 1), .bytes(3, Array(text.utf8))])))
        }
        try st.replace(stringsID, with: list)

        // The tile: a row info for every row up to the last one, 255 slots of offsets each.
        var rowInfos: [PB.Field] = []
        for (r, line) in cells.enumerated() {
            var buffer: [UInt8] = [], legacy: [UInt8] = []
            var offsets = [UInt16](repeating: 0xFFFF, count: 255), legacyOffsets = [UInt16](repeating: 0xFFFF, count: 255)
            for (column, bytes) in line {
                offsets[column] = UInt16(buffer.count)
                legacyOffsets[column] = UInt16(legacy.count)
                buffer += bytes
                legacy += [4] + [UInt8](repeating: 0, count: 11)
            }
            func raw(_ values: [UInt16]) -> [UInt8] { values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
            rowInfos.append(.bytes(5, PB.build([.int(1, UInt64(r)), .int(2, UInt64(line.count)), .bytes(3, legacy), .bytes(4, raw(legacyOffsets)),
                                               .int(5, 5), .bytes(6, buffer), .bytes(7, raw(offsets))])))
        }
        try st.replace(tileID, with: [.int(1, 0), .int(2, 0), .int(3, 0), .int(4, UInt64(rows.count))] + rowInfos + [.int(6, 5), .int(7, 1)])

        // The identifiers of rows and columns (sorted by their second half), the sizes, the widths.
        func uids(_ count: Int) -> (sorted: [[PB.Field]], indexForUID: [UInt64], uidForIndex: [UInt64]) {
            let made = (0..<count).map { _ in (UInt64.random(in: 1...UInt64.max), UInt64.random(in: 1...UInt64.max)) }
            let order = made.indices.sorted { (made[$0].1, made[$0].0) < (made[$1].1, made[$1].0) }
            var rank = [UInt64](repeating: 0, count: count)
            for (position, original) in order.enumerated() { rank[original] = UInt64(position) }
            return (order.map { [PB.Field.int(1, made[$0].0), .int(2, made[$0].1)] }, order.map { UInt64($0) }, rank)
        }
        if let mapID = IWorkFile.ref(model, 46), st.fields(mapID) != nil {
            let columns = uids(width), lines = uids(rows.count)
            var fields: [PB.Field] = columns.sorted.map { .bytes(1, PB.build($0)) }
            fields += columns.indexForUID.map { .int(2, $0) } + columns.uidForIndex.map { .int(3, $0) }
            fields += lines.sorted.map { .bytes(4, PB.build($0)) }
            fields += lines.indexForUID.map { .int(5, $0) } + lines.uidForIndex.map { .int(6, $0) }
            try st.replace(mapID, with: fields)
        }
        if let sizeID = IWorkFile.ref(model, 49), var size = st.fields(sizeID), size.contains(where: { $0.num == 3 }) {
            for i in size.indices { if size[i].num == 2 { size[i].value = UInt64(width) } else if size[i].num == 3 { size[i].value = UInt64(rows.count) } }
            try st.replace(sizeID, with: size)
        }
        try st.replace(columnHeadersID, with: [.int(1, 1)])   // default widths
        for i in model.indices {
            if model[i].num == 6 { model[i].value = UInt64(rows.count) }
            if model[i].num == 7 { model[i].value = UInt64(width) }
        }
        // One tile for the whole table: 256 rows as in the template, or as many as the table has (a power of two).
        var tileSize: UInt64 = 256
        while tileSize < UInt64(rows.count) { tileSize *= 2 }
        var tileStorage = IWorkFile.message(store, 3) ?? []
        tileStorage.removeAll { $0.num == 2 }
        tileStorage.append(.int(2, tileSize))
        var newStore = store
        if let at = newStore.firstIndex(where: { $0.num == 3 }) { newStore[at].data = PB.build(tileStorage.sorted { $0.num < $1.num }) }
        model[storeAt].data = PB.build(newStore)
        // The names: the table's and the sheet's.
        let name = String(sheet.name.prefix(255))
        if !name.isEmpty, let at = model.firstIndex(where: { $0.num == 8 && $0.wire == 2 }) { model[at].data = Array(name.utf8) }
        try st.replace(modelID, with: model)
        if !name.isEmpty, var fields = st.fields(sheetID), let at = fields.firstIndex(where: { $0.num == 1 && $0.wire == 2 }) {
            fields[at].data = Array(name.utf8)
            try st.replace(sheetID, with: fields)
        }
    }
}
