import Foundation

/// The properties an Office package (DOCX, XLSX, PPTX) or an OpenDocument file (ODT, ODS) carries about itself:
/// author, last editor, dates, company, template… Read for «Metadati → Leggi», removed by «Metadati → Rimuovi».
/// Only small, fixed entries are read, each capped (`maxEntryBytes`), straight to memory through `unzip -p`:
/// nothing of the package is extracted to disk, so no entry name can point outside a folder.
enum OfficeMetadata {
    static let maxEntryBytes: Int64 = 1_000_000
    /// The parts with the properties, by format. «Rimuovi» rewrites only the Office ones.
    static let officeParts = ["docProps/core.xml", "docProps/app.xml", "docProps/custom.xml"]
    static let openDocumentParts = ["meta.xml"]
    static let strippable: Set<String> = ["docx", "xlsx", "pptx"]

    static func parts(for url: URL) -> [String] {
        switch url.pathExtension.lowercased() {
        case "docx", "xlsx", "pptx": return officeParts
        case "odt", "ods", "odp": return openDocumentParts
        default: return []
        }
    }

    static func canStrip(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { strippable.contains($0.pathExtension.lowercased()) }
    }

    /// «Documento · creator» rows, in the order the file writes them. Empty values are left out.
    static func read(_ url: URL) -> [(String, String)] {
        var rows: [(String, String)] = []
        for part in parts(for: url) {
            guard let data = try? ArchiveOps.entryData(in: url, entry: part, maxBytes: maxEntryBytes) else { continue }
            rows += leaves(in: data)
        }
        return rows.map { ("Office · " + $0.0, $0.1) }
    }

    /// The text of every element that holds only text (`<dc:creator>Nome</dc:creator>` → ("creator", "Nome")).
    /// Custom properties (`<property name="Cliente"><vt:lpwstr>…`) are listed by their own name.
    static func leaves(in data: Data) -> [(String, String)] {
        let collector = LeafCollector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        return collector.rows
    }

    private final class LeafCollector: NSObject, XMLParserDelegate {
        var rows: [(String, String)] = []
        private var text = ""
        private var depth = 0
        private var hadChild: [Bool] = []
        private var propertyName: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if !hadChild.isEmpty { hadChild[hadChild.count - 1] = true }
            hadChild.append(false)
            if name == "property", let custom = attributes["name"] { propertyName = custom }
            text = ""
            if rows.count > MetadataReader.maxRows { parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if text.count <= MetadataReader.maxValue { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let leaf = hadChild.popLast() == false
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if leaf, !value.isEmpty, hadChild.count >= 1 {
                // Inside a custom property the value element is <vt:lpwstr>: the row takes the property's name.
                rows.append((propertyName ?? name, value))
            }
            if name == "property" { propertyName = nil }
            text = ""
        }
    }

    // MARK: Removing

    /// Empty parts, valid for Word, Excel and PowerPoint: the package keeps the same entries and content types.
    static let emptyCore = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/>
        """
    static let emptyApp = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"/>
        """
    static let emptyCustom = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"/>
        """

    /// A copy without author, last editor, dates, company, template and custom properties: the parts that hold
    /// them are replaced by empty ones (only those the file has). The text, sheets and pictures are copied as they are.
    static func strip(_ url: URL) throws -> [URL] {
        guard strippable.contains(url.pathExtension.lowercased()) else {
            throw OpError.unsupported(L("«%@»: i metadati si tolgono solo da DOCX, XLSX e PPTX", url.lastPathComponent))
        }
        try SafeFile.openForReading(url).close()
        let present = officeParts.filter { (try? ArchiveOps.entryData(in: url, entry: $0, maxBytes: maxEntryBytes)) != nil }
        guard !present.isEmpty else { throw OpError.failed(L("«%@» non ha metadati da togliere", url.lastPathComponent)) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let contents = ["docProps/core.xml": emptyCore, "docProps/app.xml": emptyApp, "docProps/custom.xml": emptyCustom]
        for part in present {
            let file = work.appendingPathComponent(part)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents[part]!.utf8).write(to: file)
        }
        // The package is updated in the temporary folder, then its bytes are written to the reserved output name:
        // a new file, so it doesn't inherit the original's dates or extended attributes (where it was downloaded
        // from: com.apple.metadata:kMDItemWhereFroms and the other Spotlight attributes).
        let package = work.appendingPathComponent("documento." + url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: package)
        for part in present { try ArchiveOps.update(package, entry: part, in: work) }
        let out = FileNaming.output(for: url, ext: url.pathExtension.lowercased(), suffix: "senza metadati")
        do {
            try Data(contentsOf: package).write(to: out)
            withoutSpotlightAttributes(out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return [out]
    }

    /// Removes the com.apple.metadata:* extended attributes of a file Rondelle has just written.
    static func withoutSpotlightAttributes(_ url: URL) {
        for name in ExtendedAttributes.names(url) where name.hasPrefix("com.apple.metadata:") {
            removexattr(url.path, name, XATTR_NOFOLLOW)
        }
    }
}

/// The extended attributes of a file, read without following links (Finder tags, download origin, quarantine…).
enum ExtendedAttributes {
    static func names(_ url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 1_000_000 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func value(_ url: URL, _ name: String, maxBytes: Int = 1_000_000) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0, size <= maxBytes else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }
}
