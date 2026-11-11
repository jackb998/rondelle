import Foundation

/// The container of a Keynote or Numbers file, shared by the readers and the writers: a ZIP (or a folder, the way
/// iCloud sometimes keeps it) with `Index/*.iwa` (Snappy-compressed protobuf archives, see `PagesReader`) and
/// `Data/` (pictures). Everything is done with the system's `unzip` and `zip`, like Pages and PowerPoint.
enum IWorkFile {
    typealias PB = PagesWriter.PB
    typealias Objects = PagesReader.Objects

    /// Uncompressed bytes of `Index` that are read: the text and the cells, not the pictures.
    static let maxIndexBytes = 50_000_000

    static func unreadable(_ app: String) -> OpError {
        .unsupported(L("Rondelle non riesce a leggere questo file di %@: aprilo in %@ ed esportalo in PDF o in un altro formato", app, app))
    }

    static func isFolder(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: Reading

    /// The names inside the file («Index/Document.iwa», «Data/a-12.jpeg»).
    static func names(_ file: URL) -> [String] {
        if isFolder(file) {
            let base = file.standardizedFileURL.path.count + 1
            let items = FileManager.default.enumerator(at: file, includingPropertiesForKeys: nil)
            return (items?.allObjects as? [URL] ?? []).map { String($0.standardizedFileURL.path.dropFirst(base)) }
        }
        let out = (try? run("/usr/bin/unzip", ["-Z1", file.path])) ?? ""
        return out.split(separator: "\n").map(String.init)
    }

    static func tooLarge(_ file: URL, limit: Int = maxIndexBytes) -> OpError {
        .unsupported(L("«%@» supera %@ MB, il massimo per i documenti di questo tipo", file.lastPathComponent, limit / 1_000_000))
    }

    /// The objects of one `.iwa`, within what is left of the file's `budget` (see `IWA.Budget`): past a cap in bytes
    /// the file is refused as too large, past the others (or damaged) as unreadable.
    static func objects(in raw: Data, of file: URL, unreadable: OpError, budget: inout PagesWriter.IWA.Budget) throws -> Objects {
        do {
            return try PagesReader.parse(raw, budget: &budget)
        } catch PagesWriter.IWA.Over.bytes(let limit) {
            throw tooLarge(file, limit: limit)
        } catch is PagesWriter.IWA.Over {
            throw unreadable
        } catch is OpError {
            throw unreadable   // a damaged block or archive: not «update Rondelle», which is for its own templates
        }
    }

    /// The `.iwa` files of `Index` (also of its subfolders) whose path below `Index/` satisfies `wanted`, read into
    /// memory: from a ZIP through `unzip -p`, so nothing is extracted to disk and no link is followed; from a folder
    /// as regular files only (no links, pipes or devices). At most `maxIndexBytes` really read in all, whatever the
    /// ZIP declares, and «Annulla» is checked between the files.
    static func index(_ file: URL, app: String, wanted: (String) -> Bool) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var budget = maxIndexBytes
        if isFolder(file) {
            let index = file.appendingPathComponent("Index", isDirectory: true)
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
            guard let items = FileManager.default.enumerator(at: index, includingPropertiesForKeys: Array(keys)) else { return [:] }
            let base = index.standardizedFileURL.path.count + 1
            for case let url as URL in items where url.pathExtension == "iwa" {
                try PDFOps.checkCancelled()
                let name = String(url.standardizedFileURL.path.dropFirst(base))
                guard wanted(name), (try? url.resourceValues(forKeys: keys).isSymbolicLink) == false,
                      let handle = try? SafeFile.openForReading(url) else { continue }
                defer { try? handle.close() }
                let data = try handle.read(upToCount: budget + 1) ?? Data()
                guard data.count <= budget else { throw tooLarge(file) }
                budget -= data.count
                files[name] = data
            }
            return files
        }
        for entry in names(file) where entry.hasPrefix("Index/") && entry.hasSuffix(".iwa") {
            let name = String(entry.dropFirst("Index/".count))
            guard wanted(name) else { continue }
            try PDFOps.checkCancelled()
            guard let data = try self.entry(entry, in: file, max: budget) else { throw tooLarge(file) }
            budget -= data.count
            files[name] = data
        }
        return files
    }

    /// The objects of the `.iwa` files of `Index` whose path below `Index/` satisfies `wanted`.
    static func objects(of file: URL, app: String, wanted: (String) -> Bool) throws -> Objects {
        let files = try index(file, app: app, wanted: wanted)
        guard !files.isEmpty else { throw unreadable(app) }
        var objects: Objects = [:]
        var budget = PagesWriter.IWA.Budget()
        for name in files.keys.sorted() where !(files[name]!.isEmpty) {
            try PDFOps.checkCancelled()
            objects.merge(try self.objects(in: files[name]!, of: file, unreadable: unreadable(app), budget: &budget)) { current, _ in current }
        }
        return objects
    }

    /// One entry of a ZIP, read into memory through `unzip -p` and stopped as soon as it passes `max` bytes
    /// (nil then): what the ZIP declares about its size is not trusted. «Annulla» stops `unzip` too.
    static func entry(_ name: String, in file: URL, max: Int) throws -> Data? {
        var escaped = ""   // unzip reads [ ] * ? as patterns
        for c in name { if "[]*?\\".contains(c) { escaped.append("\\") }; escaped.append(c) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", file.path, escaped]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var data = Data()
        var over = false, cancelled = false
        let reader = pipe.fileHandleForReading
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = reader.availableData
            if chunk.isEmpty { return false }
            if Task.isCancelled { cancelled = true; return false }
            if data.count + chunk.count > max { over = true; return false }
            data.append(chunk)
            return true
        }) {}
        if over || cancelled { process.terminate() }
        process.waitUntilExit()
        if cancelled { throw CancellationError() }
        if over { return nil }
        guard process.terminationStatus == 0 else { throw OpError.failed(L("elaborazione del file")) }
        return data
    }

    /// One file of the package (a picture), at most `max` bytes.
    static func data(_ name: String, in file: URL, max: Int) -> Data? {
        if isFolder(file) {
            let url = file.appendingPathComponent(name)
            guard FileNaming.fileSize(url) <= max else { return nil }
            return FileManager.default.contents(atPath: url.path)
        }
        var escaped = ""
        for c in name { if "[]*?\\".contains(c) { escaped.append("\\") }; escaped.append(c) }
        return try? ArchiveOps.entryData(in: file, entry: escaped, maxBytes: Int64(max))
    }

    // MARK: Protobuf reading

    static func fields(_ bytes: [UInt8]) -> [PB.Field] { (try? PB.parse(bytes)) ?? [] }

    /// The identifier of a `TSP.Reference` held in field `number` of `fields`.
    static func ref(_ fields: [PB.Field], _ number: Int) -> UInt64? {
        guard let field = fields.first(where: { $0.num == number && $0.wire == 2 }) else { return nil }
        return self.fields(field.data).first(where: { $0.num == 1 })?.value
    }

    static func refs(_ fields: [PB.Field], _ number: Int) -> [UInt64] {
        fields.filter { $0.num == number && $0.wire == 2 }.compactMap { self.fields($0.data).first(where: { $0.num == 1 })?.value }
    }

    static func message(_ fields: [PB.Field], _ number: Int) -> [PB.Field]? {
        fields.first(where: { $0.num == number && $0.wire == 2 }).map { self.fields($0.data) }
    }

    static func float(_ field: PB.Field?) -> Double? {
        guard let field, field.wire == 5, field.data.count == 4 else { return nil }
        return Double(Float(bitPattern: field.data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }))
    }

    static func string(_ fields: [PB.Field], _ number: Int) -> String? {
        fields.first(where: { $0.num == number && $0.wire == 2 }).map { String(decoding: $0.data, as: UTF8.self) }
    }

    // MARK: Processes

    @discardableResult
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice   // unzip asks questions about damaged files
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpError.failed(L("elaborazione del file")) }
        return String(decoding: data, as: UTF8.self)
    }
}
