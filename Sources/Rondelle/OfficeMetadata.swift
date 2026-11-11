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
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let contents = ["docProps/core.xml": emptyCore, "docProps/app.xml": emptyApp, "docProps/custom.xml": emptyCustom]
        var changed = present
        for part in present {
            let file = work.appendingPathComponent(part)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents[part]!.utf8).write(to: file)
        }
        let (rewritten, removed, remaining) = try cleanedParts(of: url, into: work)
        changed += rewritten
        guard !changed.isEmpty || !removed.isEmpty else { throw OpError.failed(L("«%@» non ha metadati da togliere", url.lastPathComponent)) }
        // The package is updated in the temporary folder, then its bytes are written to the reserved output name:
        // a new file, so it doesn't inherit the original's dates or extended attributes (where it was downloaded
        // from: com.apple.metadata:kMDItemWhereFroms and the other Spotlight attributes).
        let package = work.appendingPathComponent("documento." + url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: package)
        for part in changed { try ArchiveOps.update(package, entry: part, in: work) }
        if !removed.isEmpty { try ArchiveOps.remove(removed, from: package) }
        let out = FileNaming.output(for: url, ext: url.pathExtension.lowercased(), suffix: "senza metadati")
        do {
            try Data(contentsOf: package).write(to: out)
            withoutSpotlightAttributes(out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        let customXML = removed.contains { $0.lowercased().hasPrefix("customxml/") }
        if !remaining.isEmpty || customXML { explainRemaining(remaining, customXML: customXML) }
        return [out]
    }

    // MARK: Beyond the properties

    /// Parts taken out of the package: the thumbnail (a picture of the first page, with its own EXIF), Word's
    /// list of the people who edited it, and the custom XML data (SharePoint properties, sources' authors…) with
    /// its properties and relationships: fields bound to it keep their text and lose the link.
    static func isRemovedPart(_ name: String) -> Bool {
        name.hasPrefix("docProps/thumbnail.") || name == "word/people.xml" || name.lowercased().hasPrefix("customxml/")
    }

    /// The other parts that name people or places, rewritten in `work` at their path: authors and initials of
    /// comments and tracked changes become «Autore» (their text and the changes stay), Excel's and PowerPoint's
    /// lists of people too, Excel's folder of the last save (x15ac:absPath) is removed, links to local files lose
    /// their path, and the embedded photos are written again without EXIF, GPS, IPTC or XMP (as «Rimuovi» does
    /// for an image). Returns the rewritten and the removed entries, and what is left for the user to know.
    private static func cleanedParts(of url: URL, into work: URL) throws -> (rewritten: [String], removed: [String], remaining: Set<String>) {
        let names = IWorkFile.names(url)
        // An entry is written below `work` only with a plain relative name: no «..», no absolute path.
        func plain(_ n: String) -> Bool {
            !n.isEmpty && !n.hasPrefix("/") && !n.hasSuffix("/") && !n.contains("\\") && !n.split(separator: "/").contains("..")
        }
        // ImageOps names a JPEG «.jpg» and a TIFF «.tif»: the same format as «.jpeg» and «.tiff».
        func same(_ a: String, _ b: String) -> Bool {
            let group = ["jpeg": "jpg", "tiff": "tif"]
            return (group[a] ?? a) == (group[b] ?? b)
        }
        let removed = names.filter(isRemovedPart)
        var rewritten: [String] = []
        var remaining: Set<String> = []
        for name in names where plain(name) && !removed.contains(name) {
            try PDFOps.checkCancelled()
            let lower = name.lowercased()
            var escaped = ""
            for c in name { if "[]*?\\".contains(c) { escaped.append("\\") }; escaped.append(c) }
            let target = work.appendingPathComponent(name)
            if let text = textToClean(lower) {
                guard let data = try? ArchiveOps.entryData(in: url, entry: escaped, maxBytes: PptxReader.maxXMLPart) else { continue }
                let original = String(decoding: data, as: UTF8.self)
                if original.contains("<w:ins ") || original.contains("<w:del ") || original.contains("<w:comment ") || original.contains("<comment ") || original.contains("<p:cm ") {
                    remaining.insert(L("il testo e le date di commenti e revisioni"))
                }
                let cleaned = text(original, removed)
                guard cleaned != original else { continue }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(cleaned.utf8).write(to: target)
                rewritten.append(name)
            } else if ["word/media/", "xl/media/", "ppt/media/"].contains(where: lower.hasPrefix),
                      let ext = ["jpg", "jpeg", "png", "tif", "tiff", "heic"].first(where: { lower.hasSuffix("." + $0) }) {
                let folder = work.appendingPathComponent("immagini-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let original = folder.appendingPathComponent("immagine." + ext)
                try ArchiveOps.entryData(in: url, entry: escaped, maxBytes: PptxReader.maxImagePart).write(to: original)
                guard let clean = try ImageOps.process(original, quality: 0.95, stripMetadata: true, suffix: "pulita").first,
                      same(clean.pathExtension.lowercased(), ext) else { continue }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: clean, to: target)
                rewritten.append(name)
            }
        }
        return (rewritten, removed, remaining)
    }

    /// How a part's text is cleaned, or nil when the part is left as it is.
    private static func textToClean(_ lower: String) -> ((String, [String]) -> String)? {
        func replacing(_ text: String, _ pattern: String, _ template: String) -> String {
            text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        if lower == "[content_types].xml" {
            return { text, removed in
                removed.reduce(text) { replacing($0, #"<Override [^>]*PartName="/\#(NSRegularExpression.escapedPattern(for: $1))"[^>]*/>"#, "") }
            }
        }
        if lower.hasSuffix(".rels") {
            return { text, removed in
                var out = text
                // Links to the removed parts, then local paths of external targets (file:, C:\, \\server, /Users/…).
                for name in removed {
                    let last = NSRegularExpression.escapedPattern(for: (name as NSString).lastPathComponent)
                    out = replacing(out, #"<Relationship [^>]*Target="(?:[^"]*/)?\#(last)"[^>]*/>"#, "")
                }
                out = replacing(out, #"(<Relationship [^>]*TargetMode="External"[^>]*Target=")(?:file:[^"]*|[A-Za-z]:[\\/][^"]*|\\\\[^"]*|/[^"]*)""#, #"$1file:///""#)
                out = replacing(out, #"(<Relationship [^>]*Target=")(?:file:[^"]*|[A-Za-z]:[\\/][^"]*|\\\\[^"]*|/[^"]*)("[^>]*TargetMode="External")"#, #"$1file:///$2"#)
                return out
            }
        }
        if lower.hasPrefix("word/") && lower.hasSuffix(".xml") {
            return { text, _ in replacing(replacing(text, #"\bw:author="[^"]*""#, #"w:author="Autore""#), #"\bw:initials="[^"]*""#, #"w:initials="A""#) }
        }
        if lower.hasPrefix("xl/comments") && lower.hasSuffix(".xml") {
            return { text, _ in replacing(text, #"<author>[^<]*</author>"#, "<author>Autore</author>") }
        }
        if lower.hasPrefix("xl/persons/") || lower == "ppt/authors.xml" || lower == "ppt/commentauthors.xml" {
            return { text, _ in
                var out = replacing(text, #"\b(displayName|name)="[^"]*""#, #"$1="Autore""#)
                out = replacing(out, #"\binitials="[^"]*""#, #"initials="A""#)
                out = replacing(out, #"\buserId="[^"]*""#, #"userId="""#)
                return replacing(out, #"\bproviderId="[^"]*""#, #"providerId="None""#)
            }
        }
        if lower == "xl/workbook.xml" {
            return { text, _ in
                let wrapped = #"<mc:AlternateContent[^>]*>\s*<mc:Choice[^>]*>\s*<x15ac:absPath[^>]*/>\s*</mc:Choice>\s*</mc:AlternateContent>"#
                return replacing(replacing(text, wrapped, ""), #"<x15ac:absPath[^>]*/>"#, "")
            }
        }
        return nil
    }

    /// Once per launch, what «Rimuovi» can't take out of an Office file (it is part of the document).
    /// `customXML`: the custom XML data was taken out, and the fields bound to it lost their link.
    private static func explainRemaining(_ remaining: Set<String>, customXML: Bool) {
        guard Prompts.allowed else { return }
        Task { @MainActor in
            guard !explained else { return }
            explained = true
            let unbound = customXML ? L("Ha tolto anche i dati personalizzati (customXml): i campi collegati a dati XML tengono il loro testo ma perdono il collegamento.") : ""
            if remaining.isEmpty {
                Notice.show(title: L("Metadati tolti"), text: unbound)
                return
            }
            let text = L("Rondelle ha tolto autore, azienda, date, miniatura, nomi in commenti e revisioni, percorsi locali e dati delle foto. Restano %@: fanno parte del documento, toglili nell'app prima di condividerlo.",
                         remaining.sorted().joined(separator: L(" e ")))
            Notice.show(title: L("Metadati tolti, ma non tutto"), text: unbound.isEmpty ? text : text + " " + unbound)
        }
    }
    @MainActor private static var explained = false

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
