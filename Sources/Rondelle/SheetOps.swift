import Foundation

/// Spreadsheets: XLSX, ODS, CSV and TSV in, XLSX, ODS, CSV, TSV, HTML and PDF out.
///
/// XLSX and ODS are ZIP packages of XML. `unzip -p` decompresses one known entry at a time into a file of ours
/// in the app's temporary folder (capped per entry and per package, on the bytes that really come out), which is
/// then parsed a piece at a time with external entities off; any DTD is refused (these formats never need one,
/// entity bombs do). Values only: formulas give their last computed result, styles and charts are not kept.
enum SheetOps {
    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    /// Bytes of one XML entry once decompressed, of all the entries read from one package, and cells in the
    /// whole workbook. Extracting needs twice the package cap free on disk.
    static let maxEntryBytes = 1_000_000_000   // an ODS of 1 M rows × 6 columns written by Rondelle is 615 MB (0.8.3-S6)
    static let maxPackageBytes = 1_200_000_000
    static let maxCells = 6_000_000
    /// Characters (UTF-8 bytes) of cell text in the whole workbook, counted each time a shared string or a
    /// repeated cell is used: a small file can't expand into gigabytes (A1).
    static let maxChars = 300_000_000
    /// One cell's text (Excel stops at 32 767 characters): `text:s` spaces can't grow a cell without end.
    static let maxCellChars = 1_000_000
    /// HTML and PDF lay the text out: beyond this they take minutes.
    static let maxCharsForLayout = 5_000_000
    static let maxSheets = 50
    static var tooManySheets: Error { OpError.unsupported(L("più di %@ fogli: dividi il file in più parti", maxSheets)) }
    /// HTML and PDF lay every cell out as text: past this they would take minutes and gigabytes.
    static let maxCellsForLayout = 100_000

    enum Target: String { case xlsx, ods, csv, tsv, html, pdf, numbers }

    // MARK: Convert

    static func convert(_ url: URL, to target: Target) async throws -> [URL] {
        let sheets = try read(url).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw OpError.failed(L("il foglio di calcolo è vuoto")) }
        switch target {
        case .xlsx: return [try writePackage(sheets, from: url, ext: "xlsx", build: xlsxFiles)]
        case .ods: return [try writePackage(sheets, from: url, ext: "ods", build: odsFiles)]
        case .numbers:
            let out = FileNaming.output(for: url, ext: "numbers")
            try NumbersWriter.write(sheets, to: out)
            return [out]
        case .csv, .tsv:
            // One file per sheet: in a folder when there are several.
            if sheets.count == 1 { return [try writeText(sheets[0], to: FileNaming.output(for: url, ext: target.rawValue), target)] }
            let folder = try FileNaming.folder(for: url, suffix: "fogli")
            return [folder] + (try sheets.enumerated().map { i, sheet in
                let name = "\(i + 1) - \(safeFileName(sheet.name)).\(target.rawValue)"
                return try writeText(sheet, to: folder.appendingPathComponent(name), target)
            })
        case .html, .pdf:
            let chars = sheets.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } } }
            guard sheets.reduce(0, { $0 + $1.rows.reduce(0) { $0 + $1.count } }) <= maxCellsForLayout, chars <= maxCharsForLayout else {
                throw OpError.unsupported(L("per HTML e PDF al massimo %@ celle e %@ milioni di caratteri: converti prima in CSV o XLSX",
                                            maxCellsForLayout, maxCharsForLayout / 1_000_000))
            }
            let html = htmlDocument(sheets, title: url.deletingPathExtension().lastPathComponent)
            if target == .html {
                let out = FileNaming.output(for: url, ext: "html")
                try Data(html.utf8).write(to: out)
                return [out]
            }
            return [try await DocumentOps.pdf(fromHTML: html, source: url)]
        }
    }

    // MARK: Read

    static func read(_ url: URL) throws -> [Sheet] {
        guard FileNaming.fileSize(url) <= Limits.maxDocumentBytes else {
            throw OpError.unsupported(L("«%@» supera %@ MB, il massimo per i documenti di questo tipo",
                                        url.lastPathComponent, Limits.maxDocumentBytes / 1_000_000))
        }
        switch url.pathExtension.lowercased() {
        case "xlsx": return try readXLSX(url)
        case "ods": return try readODS(url)
        case "numbers": return try NumbersReader.read(url)
        case "tsv": return [Sheet(name: url.deletingPathExtension().lastPathComponent, rows: try readDelimited(url, separator: "\t"))]
        default: return [Sheet(name: url.deletingPathExtension().lastPathComponent, rows: try readDelimited(url, separator: nil))]
        }
    }

    /// CSV (separator guessed between , ; and tab: Excel in Italian writes ;) or TSV. UTF-8, else Windows Latin.
    private static func readDelimited(_ url: URL, separator: Character?) throws -> [[String]] {
        let data = try Data(contentsOf: url)
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let sep = separator ?? guessSeparator(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var cells = 0
        var chars = text.makeIterator()
        var pending: Character?
        func endField() throws {
            row.append(field)
            field = ""
            cells += 1
            if cells > maxCells { throw OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", maxCells)) }
            if cells & 4095 == 0 { try Task.checkCancellation() }
        }
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    let next = chars.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(c)
                }
            } else if c == "\"", field.isEmpty {
                quoted = true
            } else if c == sep {
                try endField()
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                try endField()
                rows.append(row)
                row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { try endField(); rows.append(row) }
        return rows
    }

    private static func guessSeparator(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        for c in firstLine {
            if c == "\"" { quoted.toggle() } else if !quoted, counts[c] != nil { counts[c]! += 1 }
        }
        // The most frequent of the three; a tie or none keeps the comma.
        let best = counts.filter { $0.key != "," }.max { $0.value < $1.value }
        if let best, best.value > counts[","]! { return best.key }
        return ","
    }

    // MARK: Read XLSX

    private static func readXLSX(_ url: URL) throws -> [Sheet] {
        let package = try Package(url)
        let budget = SheetBudget()
        guard let workbook = try package.entry("xl/workbook.xml") else { throw OpError.failed(L("file XLSX non valido")) }
        defer { try? FileManager.default.removeItem(at: workbook) }
        let rels = try package.entry("xl/_rels/workbook.xml.rels")
        defer { if let rels { try? FileManager.default.removeItem(at: rels) } }
        var strings: [String] = []
        if let file = try package.entry("xl/sharedStrings.xml") {
            defer { try? FileManager.default.removeItem(at: file) }
            strings = try XLSXStrings.parse(file)
        }

        var targets: [String: String] = [:]
        if let rels {
            for rel in try XMLAttributes.collect(rels, element: "Relationship") {
                if let id = rel["Id"], let target = rel["Target"] { targets[id] = target }
            }
        }
        var sheets: [Sheet] = []
        let listed = try XMLAttributes.collect(workbook, element: "sheet")
        guard listed.count <= maxSheets else { throw tooManySheets }   // never a part of the workbook (0.8.3-T3)
        for (i, info) in listed.enumerated() {
            let target = info["r:id"].flatMap { targets[$0] } ?? "worksheets/sheet\(i + 1).xml"
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let file = try package.entry(path) else { continue }   // missing, or already read for another sheet
            defer { try? FileManager.default.removeItem(at: file) }
            let rows = try XLSXSheet.parse(file, strings: strings, budget: budget)
            sheets.append(Sheet(name: info["name"] ?? L("Foglio %@", i + 1), rows: rows))
        }
        return sheets
    }

    // MARK: Read ODS

    private static func readODS(_ url: URL) throws -> [Sheet] {
        guard let content = try Package(url).entry("content.xml") else { throw OpError.failed(L("file ODS non valido")) }
        defer { try? FileManager.default.removeItem(at: content) }
        return try ODSContent.parse(content, budget: SheetBudget(), maxSheets: maxSheets)
    }

    // MARK: ZIP entries

    /// The entries being read, in the app's temporary folder; emptied at launch after a crash.
    static var readingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Fogli in lettura", isDirectory: true)
    }

    /// One XLSX/ODS being read: its entries come out one at a time, each at most once, within one byte budget
    /// for the whole package (0.8.2-S3): 50 sheets pointing at one huge entry can't make it decompress 29 GB.
    final class Package {
        private let url: URL
        private var bytesRead = 0
        private var seen: Set<String> = []

        init(_ url: URL) throws {
            self.url = url
            try FileManager.default.createDirectory(at: SheetOps.readingFolder, withIntermediateDirectories: true)
            // Room for what may be extracted, with a margin for the result (0.8.2-S4).
            let free = (try? SheetOps.readingFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard free >= Int64(2 * maxPackageBytes) else {
                throw OpError.failed(L("spazio libero insufficiente per leggere il foglio di calcolo (servono %@ GB)", 2 * maxPackageBytes / 1_000_000_000))
            }
        }

        /// One entry, decompressed by `unzip -p` into a file of ours in the app's temporary folder (nil if missing
        /// or already read): the XML is then read from disk a piece at a time, never whole in memory. Names inside the
        /// archive are never used to write anything; output past either cap stops the tool.
        func entry(_ name: String) throws -> URL? {
            // Our own fixed names, or names from the package's relationships: plain paths only (unzip treats
            // * ? [ as patterns, and nothing here needs them).
            // A leading "-" would be read by unzip as an option ("-x" printed every entry, A3).
            guard !name.isEmpty, !name.contains(".."), !name.hasPrefix("/"), !name.hasPrefix("-"),
                  name.allSatisfy({ $0.isLetter || $0.isNumber || "_-./ ".contains($0) }) else { return nil }
            guard seen.insert(name).inserted else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", "-qq", url.path, name]
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let file = SheetOps.readingFolder.appendingPathComponent("\(UUID().uuidString).xml")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let output = try FileHandle(forWritingTo: file)
            var keep = false
            defer {
                try? output.close()
                if !keep { try? FileManager.default.removeItem(at: file) }
            }
            try process.run()
            var written = 0
            var tooBig: Error?
            let reader = pipe.fileHandleForReading
            while autoreleasepool(invoking: { () -> Bool in
                let chunk = reader.availableData
                if chunk.isEmpty { return false }
                written += chunk.count
                bytesRead += chunk.count
                if written > maxEntryBytes {
                    tooBig = OpError.unsupported(L("foglio troppo grande una volta decompresso (oltre %@ MB)", maxEntryBytes / 1_000_000))
                } else if bytesRead > maxPackageBytes {
                    tooBig = OpError.unsupported(L("foglio troppo grande una volta decompresso (oltre %@ MB in tutto)", maxPackageBytes / 1_000_000))
                }
                if tooBig != nil || Task.isCancelled { process.terminate(); return false }
                output.write(chunk)
                return true
            }) {}
            process.waitUntilExit()
            try Task.checkCancellation()
            if let tooBig { throw tooBig }
            // 11: no such entry. Anything else non-zero: damaged package.
            if process.terminationStatus == 11 || (written == 0 && process.terminationStatus != 0) { return nil }
            guard process.terminationStatus == 0 else { throw OpError.failed(L("archivio danneggiato o non supportato")) }
            // Entity declarations (the way to an expansion bomb) are refused by the readers, in any encoding.
            keep = true
            return file
        }
    }

    // MARK: Write

    /// Written in pieces of about 1 MB: memory stays flat whatever the size, and «Annulla» is checked between them.
    private static func writeText(_ sheet: Sheet, to out: URL, _ target: Target) throws -> URL {
        if !FileManager.default.fileExists(atPath: out.path) { FileManager.default.createFile(atPath: out.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        var text = ""
        func flush(force: Bool = false) throws {
            guard force || text.utf8.count > 1_000_000 else { return }
            try Task.checkCancellation()
            try handle.write(contentsOf: Data(text.utf8))
            text = ""
        }
        if target == .csv {
            let sep = FormatSettings.csvSeparator
            let sepByte = sep.asciiValue ?? 44
            if FormatSettings.csvBOM { text = "\u{FEFF}" }
            for row in sheet.rows {
                text += row.map { cell in
                    // One pass over the bytes (String.contains on long cells cost minutes, A1).
                    cell.utf8.contains { $0 == sepByte || $0 == 34 || $0 == 10 || $0 == 13 }
                        ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
                }.joined(separator: String(sep)) + "\r\n"
                try flush()
            }
        } else {
            for row in sheet.rows {
                text += row.map { cell in
                    cell.utf8.contains { $0 == 9 || $0 == 10 || $0 == 13 }
                        ? cell.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
                            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                        : cell
                }.joined(separator: "\t") + "\n"
                try flush()
            }
        }
        try flush(force: true)
        return out
    }

    /// Builds the package's files in a private temporary folder, zips them next to the output under a
    /// scratch name, then moves the result into place (same pattern as the other writers).
    private static func writePackage(_ sheets: [Sheet], from source: URL, ext: String,
                                     build: ([Sheet], URL) throws -> [String]) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Fogli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let order = try build(sheets, work)

        let out = FileNaming.output(for: source, ext: ext)
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        do {
            if ext == "ods" {
                // ODF: "mimetype" first and stored uncompressed, then the rest.
                try runZip(["-X", "-0", "-q", temp.path, "mimetype"], in: work)
                try runZip(["-X", "-r", "-q", temp.path] + order.filter { $0 != "mimetype" }, in: work)
            } else {
                try runZip(["-X", "-r", "-q", temp.path] + order, in: work)
            }
            try FileNaming.replace(out, with: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return out
    }

    private static func runZip(_ args: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpError.failed(L("%@ è uscito con codice %@", "zip", process.terminationStatus))
        }
    }

    /// A file written in pieces of about 1 MB: a big sheet never sits whole in memory; «Annulla» between pieces.
    private final class PieceWriter {
        private let handle: FileHandle
        private var text = ""

        init(_ path: String, in dir: URL) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }

        func append(_ s: String) throws {
            text += s
            if text.utf8.count > 1_000_000 { try flush() }
        }

        private func flush() throws {
            try Task.checkCancellation()
            try handle.write(contentsOf: Data(text.utf8))
            text = ""
        }

        func finish() throws {
            try flush()
            try handle.close()
        }
    }

    private static func put(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A plain number (no thousands separators, dot as decimal): written as a number, everything else as text.
    private static func isNumber(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,15})?([eE][-+]?[0-9]{1,3})?$"#, options: .regularExpression) != nil
    }

    private static func sheetNames(_ sheets: [Sheet]) -> [String] {
        var used: Set<String> = []
        return sheets.enumerated().map { i, sheet in
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31)).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = L("Foglio %@", i + 1) }
            var unique = name
            var n = 2
            while used.contains(unique.lowercased()) { unique = String(name.prefix(27)) + " (\(n))"; n += 1 }
            used.insert(unique.lowercased())
            return unique
        }
    }

    private static func xlsxFiles(_ sheets: [Sheet], _ dir: URL) throws -> [String] {
        let names = sheetNames(sheets)
        var overrides = ""
        var entries = ""
        var rels = ""
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            entries += #"<sheet name="\#(xml(names[i]))" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(n).xml"/>"#
            let body = try PieceWriter("xl/worksheets/sheet\(n).xml", in: dir)
            try body.append(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#)
            for (r, row) in sheet.rows.enumerated() {
                var line = #"<row r="\#(r + 1)">"#
                for (c, cell) in row.enumerated() where !cell.isEmpty {
                    let ref = column(c) + String(r + 1)
                    line += isNumber(cell) ? #"<c r="\#(ref)"><v>\#(cell)</v></c>"#
                        : cell == "TRUE" || cell == "FALSE" ? #"<c r="\#(ref)" t="b"><v>\#(cell == "TRUE" ? 1 : 0)</v></c>"#
                        : #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(xml(cell))</t></is></c>"#
                }
                try body.append(line + "</row>")
            }
            try body.append("</sheetData></worksheet>")
            try body.finish()
        }
        try put(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\#(overrides)</Types>"#,
                "[Content_Types].xml", in: dir)
        try put(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
                "_rels/.rels", in: dir)
        try put(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(entries)</sheets></workbook>"#,
                "xl/workbook.xml", in: dir)
        try put(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rels)</Relationships>"#,
                "xl/_rels/workbook.xml.rels", in: dir)
        return ["[Content_Types].xml", "_rels", "xl"]
    }

    private static func odsFiles(_ sheets: [Sheet], _ dir: URL) throws -> [String] {
        let names = sheetNames(sheets)
        try put("application/vnd.oasis.opendocument.spreadsheet", "mimetype", in: dir)
        let tables = try PieceWriter("content.xml", in: dir)
        try tables.append(#"<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>"#)
        for (i, sheet) in sheets.enumerated() {
            try tables.append(#"<table:table table:name="\#(xml(names[i]))">"#)
            for row in sheet.rows {
                var line = "<table:table-row>"
                for cell in row {
                    if cell.isEmpty {
                        line += "<table:table-cell/>"
                    } else if isNumber(cell) {
                        line += #"<table:table-cell office:value-type="float" office:value="\#(cell)"><text:p>\#(cell)</text:p></table:table-cell>"#
                    } else {
                        let paragraphs = cell.components(separatedBy: .newlines).map { "<text:p>\(xml($0))</text:p>" }.joined()
                        line += #"<table:table-cell office:value-type="string">\#(paragraphs)</table:table-cell>"#
                    }
                }
                try tables.append(line + "</table:table-row>")
            }
            try tables.append("</table:table>")
        }
        try tables.append("</office:spreadsheet></office:body></office:document-content>")
        try tables.finish()
        try put(#"<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>"#,
                "META-INF/manifest.xml", in: dir)
        return ["mimetype", "META-INF", "content.xml"]
    }

    private static func htmlDocument(_ sheets: [Sheet], title: String) -> String {
        var html = #"<!DOCTYPE html><html><head><meta charset="utf-8"><title>\#(xml(title))</title><style>body{font:11px -apple-system,Helvetica,sans-serif}table{border-collapse:collapse;margin-bottom:18px}td{border:1px solid #bbb;padding:2px 5px;vertical-align:top}h2{font-size:14px}</style></head><body>"#
        for sheet in sheets {
            if sheets.count > 1 { html += "<h2>\(xml(sheet.name))</h2>" }
            html += "<table>"
            for row in sheet.rows {
                html += "<tr>" + row.map { "<td>\(xml($0).replacingOccurrences(of: "\n", with: "<br>"))</td>" }.joined() + "</tr>"
            }
            html += "</table>"
        }
        return html + "</body></html>"
    }

    /// XML/HTML-escaped text, without the control characters XML can't hold.
    static func xml(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default: if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// 0 → "A", 26 → "AA".
    static func column(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func safeFileName(_ s: String) -> String {
        let cleaned = s.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let name = String(String(cleaned).prefix(60)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.hasPrefix(".") ? L("Foglio") + name : name
    }
}

// MARK: XML readers

/// The attributes of every element with this name (workbook sheets, relationships).
private final class XMLAttributes: GuardedXMLReader {
    private let element: String
    private var found: [[String: String]] = []

    private init(_ element: String) { self.element = element }

    static let maxFound = 10_000
    private var failure: Error?

    static func collect(_ data: URL, element: String) throws -> [[String: String]] {
        let reader = XMLAttributes(element)
        try run(data, reader) { reader.failure }
        return reader.found
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        tick(parser)
        // A workbook has at most a few hundred sheets and relationships: 100 M of them took 2 GB and 23 s
        // (0.8.2-S5). Past 10 000 the file is refused: leaving the rest out picked the wrong sheet (0.8.3-T2).
        guard name == element else { return }
        guard found.count < Self.maxFound else {
            failure = OpError.unsupported(L("troppi fogli o relazioni nel file (oltre %@)", Self.maxFound))
            parser.abortParsing()
            return
        }
        found.append(attributes)
    }
}

/// Base of the readers: any entity declaration stops the parse, whatever the file's encoding (the byte search
/// in `entry` only sees ASCII-compatible ones; UTF-16 got past it, A4).
private class GuardedXMLReader: NSObject, XMLParserDelegate {
    fileprivate var declaredEntity = false
    fileprivate var cancelled = false
    private var elements = 0

    /// Called for every element: «Annulla» is noticed even in a stretch of empty cells, which spend nothing
    /// from the budget (0.8.2-S3).
    fileprivate func tick(_ parser: XMLParser) {
        elements += 1
        if elements & 4095 == 0, Task.isCancelled {
            cancelled = true
            parser.abortParsing()
        }
    }

    private func refuse(_ parser: XMLParser) {
        declaredEntity = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        refuse(parser)
    }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                notationName: String?) { refuse(parser) }
}

/// What a workbook may still produce, shared by its sheets: cells and characters (a shared string or a repeated
/// cell counts every time it is used). It is also where the readers notice «Annulla».
final class SheetBudget {
    private var cells = 0
    private var chars = 0
    private var calls = 0

    func spend(cells c: Int, chars n: Int) -> Error? {
        cells += c
        chars += n
        if cells > SheetOps.maxCells { return OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells)) }
        if chars > SheetOps.maxChars {
            return OpError.unsupported(L("foglio troppo grande (oltre %@ milioni di caratteri)", SheetOps.maxChars / 1_000_000))
        }
        calls += 1
        if calls & 1023 == 0, Task.isCancelled { return CancellationError() }
        return nil
    }
}

/// Parses with external entities off. A reader that stopped on purpose (too many cells) reports its own
/// reason; any other failure means a damaged file.
private func run(_ file: URL, _ delegate: GuardedXMLReader, stoppedBy reason: (() -> Error?)? = nil) throws {
    guard let parser = XMLParser(contentsOf: file) else { throw OpError.failed(L("XML del foglio di calcolo danneggiato")) }
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false
    parser.delegate = delegate
    let parsed = parser.parse()
    if delegate.declaredEntity { throw OpError.unsupported(L("il file contiene dichiarazioni XML non ammesse")) }
    if delegate.cancelled { throw CancellationError() }
    if let reason = reason?() { throw reason }
    guard parsed else { throw OpError.failed(L("XML del foglio di calcolo danneggiato")) }
}

/// xl/sharedStrings.xml: the text of every <si>, rich runs joined, phonetic hints (<rPh>) skipped.
/// Within limits of their own (0.8.2-S1): at most as many strings as a workbook may have cells, their text within
/// the workbook's character limit, each one within the cell limit. 120 M empty strings took 2.4 GB, one string of
/// 577 MB 1.2 GB. Cells using them are counted again by the sheets' budget.
private final class XLSXStrings: GuardedXMLReader {
    private var strings: [String] = []
    private var chars = 0
    private var current = ""
    private var inText = false
    private var inPhonetic = false
    private var failure: Error?

    static func parse(_ data: URL) throws -> [String] {
        let reader = XLSXStrings()
        try run(data, reader) { reader.failure }
        return reader.strings
    }

    private func stop(_ error: Error, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        tick(parser)
        switch name {
        case "si": current = ""
        case "t": inText = !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText, failure == nil else { return }
        if current.utf8.count + string.utf8.count > SheetOps.maxCellChars {
            return stop(OpError.unsupported(L("cella troppo lunga (oltre %@ caratteri)", SheetOps.maxCellChars)), parser)
        }
        current += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si":
            chars += current.utf8.count
            if strings.count >= SheetOps.maxCells {
                return stop(OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells)), parser)
            }
            if chars > SheetOps.maxChars {
                return stop(OpError.unsupported(L("foglio troppo grande (oltre %@ milioni di caratteri)", SheetOps.maxChars / 1_000_000)), parser)
            }
            strings.append(current)
        case "t": inText = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

/// One worksheet: cells placed by their reference ("B7"), gaps filled with empty cells, within a budget.
private final class XLSXSheet: GuardedXMLReader {
    private let strings: [String]
    private let budget: SheetBudget
    private var rows: [Int: [Int: String]] = [:]
    private var maxColumn = -1
    private var cellRef = ""
    private var cellType = ""
    private var value = ""
    private var collecting = false
    private var nextRow = 0
    private var nextColumn = 0
    private var seenCells = 0
    private var failure: Error?

    private func refuse(_ message: String, _ parser: XMLParser) {
        if failure == nil { failure = OpError.unsupported(message) }
        parser.abortParsing()
    }

    private init(strings: [String], budget: SheetBudget) {
        self.strings = strings
        self.budget = budget
    }

    static func parse(_ data: URL, strings: [String], budget: SheetBudget) throws -> [[String]] {
        let reader = XLSXSheet(strings: strings, budget: budget)
        try run(data, reader) { reader.failure }
        guard let last = reader.rows.keys.max() else { return [] }
        let width = reader.maxColumn + 1
        // The gaps become empty cells: the whole grid must fit the budget too.
        guard (last + 1).multipliedReportingOverflow(by: width).partialValue <= SheetOps.maxCells, width <= 16_384 else {
            throw OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells))
        }
        return (0...last).map { r in
            let cells = reader.rows[r] ?? [:]
            return (0..<width).map { cells[$0] ?? "" }
        }
    }

    /// "AB12" → (row 11, column 27); nil if malformed or beyond Excel's grid.
    private static func position(_ ref: String) -> (Int, Int)? {
        var column = 0
        var rowDigits = ""
        for c in ref {
            if let a = c.asciiValue, (65...90).contains(a), rowDigits.isEmpty {
                column = column * 26 + Int(a - 64)
                if column > 16_384 { return nil }
            } else if c.isASCII, c.isNumber {
                rowDigits.append(c)
            } else {
                return nil
            }
        }
        guard column > 0, let row = Int(rowDigits), (1...1_048_576).contains(row) else { return nil }
        return (row - 1, column - 1)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        tick(parser)
        switch name {
        case "row":
            if let r = attributes["r"] {
                // Outside the grid the cells used to land on the next row instead (0.8.3-T7).
                guard let n = Int(r), (1...1_048_576).contains(n) else {
                    return refuse(L("riferimento fuori dalla griglia del foglio: %@", "r=\(r.prefix(20))"), parser)
                }
                nextRow = n - 1
            }
            nextColumn = 0
        case "c":
            // Empty cells spend nothing from the budget: 64 M of them took 40 s to reach the end (0.8.2-S3).
            seenCells += 1
            if seenCells > 2 * SheetOps.maxCells, failure == nil {
                failure = OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells))
                parser.abortParsing()
                return
            }
            cellRef = attributes["r"] ?? ""
            cellType = attributes["t"] ?? ""
            value = ""
        case "v", "t":
            collecting = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collecting, failure == nil else { return }
        // The same limit as ODS: a cell of 577 MB took 1.6 GB before the budget saw it (0.8.2-S2).
        if value.utf8.count + string.utf8.count > SheetOps.maxCellChars {
            failure = OpError.unsupported(L("cella troppo lunga (oltre %@ caratteri)", SheetOps.maxCellChars))
            parser.abortParsing()
            return
        }
        value += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t":
            collecting = false
        case "c":
            guard let (row, column) = cellRef.isEmpty ? (nextRow, nextColumn) : Self.position(cellRef) else {
                return refuse(L("riferimento fuori dalla griglia del foglio: %@", String(cellRef.prefix(20))), parser)
            }
            nextColumn = column + 1
            var text = value
            switch cellType {
            case "s": text = Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
            case "b": text = value == "1" ? "TRUE" : "FALSE"
            default: break
            }
            guard !text.isEmpty else { return }
            if let stop = budget.spend(cells: 1, chars: text.utf8.count) {
                failure = stop
                parser.abortParsing()
                return
            }
            rows[row, default: [:]][column] = text
            maxColumn = max(maxColumn, column)
        case "row":
            nextRow += 1
        default: break
        }
    }
}

/// content.xml of an ODS: tables, rows and cells with their "repeated" counts. Repeated empty cells and rows
/// (LibreOffice writes a million of them to the end of the grid) only count once something follows them.
private final class ODSContent: GuardedXMLReader {
    private let budget: SheetBudget
    private let maxSheets: Int
    private var sheets: [SheetOps.Sheet] = []
    private var rows: [[String]] = []
    private var row: [String] = []
    private var pendingCells = 0
    private var pendingRows = 0
    private var rowRepeat = 1
    private var cellRepeat = 1
    private var cellValue: String?
    private var text = ""
    private var paragraphs: [String] = []
    private var inParagraph = false
    /// Bytes of the text being collected for one cell: `<text:s text:c="1000"/>` repeated would grow it without end.
    private var cellBytes = 0
    private var rowChars = 0
    private var failure: Error?
    private var seenCells = 0
    private var rowRepeatAsWritten = 1

    private init(budget: SheetBudget, maxSheets: Int) {
        self.budget = budget
        self.maxSheets = maxSheets
    }

    static func parse(_ data: URL, budget: SheetBudget, maxSheets: Int) throws -> [SheetOps.Sheet] {
        let reader = ODSContent(budget: budget, maxSheets: maxSheets)
        try run(data, reader) { reader.failure }
        return reader.sheets
    }

    private func spend(_ cells: Int, chars: Int, _ parser: XMLParser) -> Bool {
        if let stop = budget.spend(cells: cells, chars: chars) {
            failure = stop
            parser.abortParsing()
            return false
        }
        return true
    }

    /// Text added to the current cell; past the character budget the parse stops.
    private func append(_ s: String, _ parser: XMLParser) {
        cellBytes += s.utf8.count
        if cellBytes > SheetOps.maxCellChars {
            if failure == nil {
                failure = OpError.unsupported(L("cella troppo lunga (oltre %@ caratteri)", SheetOps.maxCellChars))
                parser.abortParsing()
            }
            return
        }
        text += s
    }

    private func repeatCount(_ attributes: [String: String], _ key: String) -> Int {
        min(rawRepeat(attributes, key), 1_048_576)
    }

    /// The count as written (digits only; too many digits for an Int count as huge), at least 1.
    private func rawRepeat(_ attributes: [String: String], _ key: String) -> Int {
        guard let text = attributes[key], !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return 1 }
        return max(Int(text) ?? Int.max, 1)
    }

    private func stop(_ error: Error, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        tick(parser)
        switch name {
        case "table:table":
            if sheets.count >= maxSheets { return stop(SheetOps.tooManySheets, parser) }   // never a part of it (0.8.3-T3)
            sheets.append(SheetOps.Sheet(name: attributes["table:name"] ?? "", rows: []))
            rows = []
            pendingRows = 0
        case "table:table-row":
            row = []
            rowChars = 0
            pendingCells = 0
            rowRepeat = repeatCount(attributes, "table:number-rows-repeated")
            rowRepeatAsWritten = rawRepeat(attributes, "table:number-rows-repeated")
        case "table:table-cell", "table:covered-table-cell":
            seenCells += 1   // as in XLSX: empty cells, one element at a time, still have an end (0.8.2-S3)
            if seenCells > 2 * SheetOps.maxCells, failure == nil {
                failure = OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells))
                parser.abortParsing()
                return
            }
            cellRepeat = repeatCount(attributes, "table:number-columns-repeated")
            paragraphs = []
            cellBytes = 0
            switch attributes["office:value-type"] {
            case "float", "percentage", "currency": cellValue = attributes["office:value"]
            case "date": cellValue = attributes["office:date-value"]
            case "time": cellValue = attributes["office:time-value"]
            case "boolean": cellValue = attributes["office:boolean-value"] == "true" ? "TRUE" : "FALSE"
            default: cellValue = nil
            }
        case "text:p", "text:h":
            inParagraph = true
            text = ""
        case "text:s":
            // As many spaces as written, up to the cell limit, which then refuses the cell (0.8.3-T6: cut at 1000).
            if inParagraph { append(String(repeating: " ", count: min(rawRepeat(attributes, "text:c"), SheetOps.maxCellChars + 1)), parser) }
        case "text:tab":
            if inParagraph { append("\t", parser) }
        case "text:line-break":
            if inParagraph { append("\n", parser) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inParagraph { append(string, parser) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "text:p", "text:h":
            inParagraph = false
            paragraphs.append(text)
        case "table:table-cell", "table:covered-table-cell":
            let value = cellValue ?? paragraphs.joined(separator: "\n")
            if value.isEmpty { pendingCells += cellRepeat; return }
            // Empty cells before this one become real, then the value as many times as repeated.
            let cells = pendingCells + cellRepeat
            let chars = value.utf8.count * cellRepeat
            guard spend(cells, chars: chars, parser), row.count + cells <= 16_384 else {
                if failure == nil { failure = OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells)); parser.abortParsing() }
                return
            }
            row += Array(repeating: "", count: pendingCells) + Array(repeating: value, count: cellRepeat)
            rowChars += chars
            pendingCells = 0
        case "table:table-row":
            if row.isEmpty { pendingRows += rowRepeat; return }
            // Empty rows past the grid are LibreOffice's padding; rows with content are refused, not cut (0.8.3-T5).
            if rowRepeatAsWritten > 1_048_576 {
                return stop(OpError.unsupported(L("righe ripetute oltre il limite del foglio (%@)", 1_048_576)), parser)
            }
            guard spend(pendingRows + row.count * (rowRepeat - 1), chars: rowChars * (rowRepeat - 1), parser) else { return }
            rows += Array(repeating: [], count: pendingRows) + Array(repeating: row, count: rowRepeat)
            pendingRows = 0
        case "table:table":
            if !sheets.isEmpty {
                let width = rows.map(\.count).max() ?? 0
                guard width.multipliedReportingOverflow(by: rows.count).partialValue <= SheetOps.maxCells else {
                    failure = OpError.unsupported(L("foglio troppo grande (oltre %@ celle)", SheetOps.maxCells))
                    parser.abortParsing()
                    return
                }
                sheets[sheets.count - 1].rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
            }
        default: break
        }
    }
}
