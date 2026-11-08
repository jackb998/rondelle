import AppKit
import AVFoundation
import CoreServices
import ImageIO
import PDFKit
import SwiftUI

/// «Metadati → Leggi»: what a file says about itself, in a small window. Nothing is written.
/// The values come from the file, so they are shortened and cleaned of control characters before being shown.
enum MetadataReader {
    static let maxRows = 400
    static let maxValue = 300
    static let maxFiles = 10

    struct Section {
        let name: String
        var symbol = "doc"
        var rows: [(key: String, value: String)]
    }

    static func read(_ url: URL) async -> Section {
        var rows: [(String, String)] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
                                         .tagNamesKey, .isDirectoryKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            if let type = values.localizedTypeDescription { rows.append((L("Tipo"), type)) }
            if let size = values.fileSize { rows.append((L("Dimensione"), ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
            if values.isDirectory == true, let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                rows.append((L("Elementi"), "\(items.count)"))
            }
            if let date = values.creationDate { rows.append((L("Creato"), date.formatted(date: .abbreviated, time: .shortened))) }
            if let date = values.contentModificationDate { rows.append((L("Modificato"), date.formatted(date: .abbreviated, time: .shortened))) }
            if let tags = values.tagNames, !tags.isEmpty { rows.append((L("Etichette"), tags.joined(separator: ", "))) }
        }
        // "Gruppo · nome": the window shows one card per group; the file's own values are under «File».
        func grouped(_ name: String, _ found: [(String, String)]) -> [(String, String)] {
            found.map { $0.0.contains(" · ") ? $0 : (name + " · " + $0.0, $0.1) }
        }
        let kind = FileKind(url)
        switch kind {
        case .image: rows += grouped(L("Immagine"), image(url))
        case .pdf: rows += grouped("PDF", pdf(url))
        case .video, .audio: rows += grouped(L("Audio e video"), await media(url))
        case .document, .spreadsheet: rows += OfficeMetadata.read(url)
        case .archive: rows += grouped(L("Archivio"), archive(url))
        default: break
        }
        // What the Mac knows about the file, for every kind: where it came from and what Spotlight has noted.
        rows += grouped("Origine", origin(url))
        rows += grouped("Spotlight", spotlight(url))
        let symbol = [FileKind.image: "photo", .pdf: "doc.richtext", .video: "film", .audio: "waveform", .document: "doc.text",
                      .spreadsheet: "tablecells", .subtitle: "captions.bubble", .archive: "archivebox", .folder: "folder"][kind] ?? "doc"
        if rows.count > maxRows { rows = Array(rows.prefix(maxRows)) + [("…", L("altri valori non mostrati"))] }
        return Section(name: url.lastPathComponent, symbol: symbol, rows: rows.map { (clean($0.0, limit: 80), clean($0.1, limit: maxValue)) })
    }

    /// One line, no control characters, at most `limit` characters.
    static func clean(_ text: String, limit: Int) -> String {
        let line = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    private static func image(_ url: URL) -> [(String, String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var rows: [(String, String)] = []
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { rows.append((L("Immagini nel file"), "\(frames)")) }
        flatten(props, prefix: "", depth: 0, into: &rows)
        return rows
    }

    /// {Exif} → "Exif · DateTimeOriginal"; nested dictionaries at most three levels deep, raw data as its size.
    private static func flatten(_ dict: [String: Any], prefix: String, depth: Int, into rows: inout [(String, String)]) {
        for key in dict.keys.sorted() {
            guard rows.count <= maxRows else { return }
            let name = prefix + key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            switch dict[key] {
            case let nested as [String: Any]:
                if depth < 3 { flatten(nested, prefix: name + " · ", depth: depth + 1, into: &rows) }
            case let list as [Any]:
                rows.append((name, list.prefix(20).map(describe).joined(separator: ", ")))
            case let value?:
                rows.append((name, describe(value)))
            case nil:
                break
            }
        }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data: return L("%@ byte", data.count)
        case let date as Date: return date.formatted(date: .abbreviated, time: .standard)
        case let text as String: return String(text.prefix(maxValue + 1))
        case is [String: Any]: return "…"
        default: return String(String(describing: value).prefix(maxValue + 1))
        }
    }

    private static func pdf(_ url: URL) -> [(String, String)] {
        guard let doc = PDFDocument(url: url) else { return [(L("PDF"), L("non leggibile"))] }
        var rows: [(String, String)] = [(L("Pagine"), "\(doc.pageCount)")]
        if doc.isEncrypted { rows.append((L("Protetto da password"), doc.isLocked ? L("sì, bloccato") : L("sì"))) }
        let attributes = doc.documentAttributes ?? [:]
        for key in attributes.keys.compactMap({ $0 as? String }).sorted() {
            if let value = attributes[key] { rows.append((key, describe(value))) }
        }
        return rows
    }

    private static func archive(_ url: URL) -> [(String, String)] {
        guard let (total, entries) = try? ArchiveOps.expandedSize(url, limit: .max) else { return [] }
        return [(L("File nell'archivio"), "\(entries)"),
                (L("Dimensione estratta"), ByteCountFormatter.string(fromByteCount: total, countStyle: .file))]
    }

    /// Download address and page (kMDItemWhereFroms), the app that downloaded it and when (quarantine), the other
    /// extended attributes by name.
    static func origin(_ url: URL) -> [(String, String)] {
        var rows: [(String, String)] = []
        let names = ExtendedAttributes.names(url)
        if let data = ExtendedAttributes.value(url, "com.apple.metadata:kMDItemWhereFroms"),
           let froms = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            for from in froms.prefix(5) where !from.isEmpty { rows.append((L("Scaricato da"), from)) }
        }
        // "0083;6543a1b2;Safari;UUID": flags, time (hex seconds since 1970), the app, an id.
        if let data = ExtendedAttributes.value(url, "com.apple.quarantine", maxBytes: 4096) {
            let fields = String(decoding: data, as: UTF8.self).components(separatedBy: ";")
            if fields.count > 2, !fields[2].isEmpty { rows.append((L("Scaricato con"), fields[2])) }
            if fields.count > 1, let seconds = UInt64(fields[1], radix: 16), seconds > 0 {
                rows.append((L("Data del download"), Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)))
            }
            rows.append((L("Quarantena"), L("sì: macOS chiede conferma alla prima apertura")))
        }
        let others = names.filter { !$0.hasPrefix("com.apple.quarantine") && $0 != "com.apple.metadata:kMDItemWhereFroms" }
        if !others.isEmpty { rows.append((L("Attributi estesi"), others.prefix(20).joined(separator: ", "))) }
        return rows
    }

    /// What Spotlight has noted about the file that the file itself may not say (last opened, how many times…).
    static func spotlight(_ url: URL) -> [(String, String)] {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return [] }
        let wanted: [(CFString, String)] = [
            (kMDItemLastUsedDate, "Ultima apertura"), ("kMDItemUseCount" as CFString, "Aperto (volte)"),
            (kMDItemDownloadedDate, "Data del download"), (kMDItemAuthors, "Autori"), (kMDItemTitle, "Titolo"),
            (kMDItemCreator, "Creato con"), (kMDItemEncodingApplications, "Codificato con"),
            (kMDItemNumberOfPages, "Pagine"), (kMDItemVersion, "Versione"), (kMDItemComment, "Commenti"),
        ]
        var rows: [(String, String)] = []
        for (attribute, name) in wanted {
            guard let value = MDItemCopyAttribute(item, attribute) else { continue }
            let text: String
            switch value {
            case let list as [Any]: text = list.prefix(10).map(describe).joined(separator: ", ")
            default: text = describe(value)
            }
            if !text.isEmpty { rows.append((L(name), text)) }
        }
        return rows
    }

    private static func media(_ url: URL) async -> [(String, String)] {
        let asset = AVURLAsset(url: url)
        var rows: [(String, String)] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            rows.append((L("Durata"), Duration.seconds(duration.seconds).formatted(.time(pattern: .hourMinuteSecond))))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            rows.append((L("Risoluzione"), "\(Int(abs(size.width))) × \(Int(abs(size.height)))"))
        }
        for item in (try? await asset.load(.metadata)) ?? [] {
            guard rows.count <= maxRows else { break }
            let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "?"
            if let text = try? await item.load(.stringValue) { rows.append((key, text)) }
            else if let number = try? await item.load(.numberValue) { rows.append((key, number.stringValue)) }
            else if let date = try? await item.load(.dateValue) { rows.append((key, describe(date))) }
            else if let data = try? await item.load(.dataValue) { rows.append((key, describe(data))) }
        }
        return rows
    }
}


@MainActor
enum MetadataWindow {
    private static var open: [NSWindow] = []

    static func open(_ urls: [URL]) {
        let shown = Array(urls.prefix(MetadataReader.maxFiles))
        let model = MetadataModel(more: urls.count - shown.count)
        let host = NSHostingController(rootView: MetadataView(model: model))
        host.sizingOptions = []   // the window is sized to the values once they are read (`fit`)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.rondelleStyle()
        window.title = shown.count == 1 ? L("Metadati — %@", shown[0].lastPathComponent) : L("Metadati — %@ file", urls.count)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 220))
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { open.removeAll { $0 === window } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            var sections: [MetadataReader.Section] = []
            for url in shown {
                sections.append(await Task.detached(priority: .userInitiated) { await MetadataReader.read(url) }.value)
            }
            model.sections = sections
            fit(window, to: sections)
        }
    }

    /// As tall as the values need, up to most of the screen (the rest scrolls); the top edge stays put.
    private static func fit(_ window: NSWindow, to sections: [MetadataReader.Section]) {
        let rows = sections.reduce(0) { $0 + $1.rows.count }
        let groups = sections.reduce(0) { $0 + MetadataView.groups($1.rows).count }
        let wanted = CGFloat(110 + sections.count * 78 + groups * 46 + rows * 31)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = window.frame
        let height = min(max(wanted, 240), screen.height * 0.85)
        frame.origin.y = max(frame.maxY - height, screen.minY)
        frame.size.height = height
        window.setFrame(frame, display: true, animate: true)
    }
}

@MainActor
final class MetadataModel: ObservableObject {
    @Published var sections: [MetadataReader.Section]?
    /// What the search field filters by (names and values, in every file shown).
    @Published var query = ""
    let more: Int
    weak var searchField: NSSearchField?
    init(more: Int) { self.more = more }

    /// ⌘F: the cursor goes to the search field, its text selected.
    func focusSearch() {
        guard let field = searchField, let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
}

/// The system's search field (magnifier, clear button, Esc clears), bound to `MetadataModel.query`.
struct MetadataSearchField: NSViewRepresentable {
    @ObservedObject var model: MetadataModel

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = L("Cerca per nome o valore")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("metadata-search")
        model.searchField = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: MetadataModel
        init(_ model: MetadataModel) { self.model = model }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            MainActor.assumeIsolated { model.query = field.stringValue }
        }
    }
}

struct MetadataView: View {
    @ObservedObject var model: MetadataModel

    struct Group: Identifiable {
        let name: String
        var rows: [(key: String, value: String)]
        var id: String { name }
    }

    /// Plain names for the most common values; any other key is shown as the file writes it.
    static let names: [String: String] = [
        "PixelWidth": "Larghezza (px)",
        "PixelHeight": "Altezza (px)",
        "DPIWidth": "Risoluzione orizzontale (dpi)",
        "DPIHeight": "Risoluzione verticale (dpi)",
        "ColorModel": "Modello di colore",
        "Depth": "Bit per canale",
        "Orientation": "Orientamento",
        "ProfileName": "Profilo colore",
        "HasAlpha": "Trasparenza",
        "Make": "Marca",
        "Model": "Modello",
        "Software": "Software",
        "DateTime": "Data",
        "DateTimeOriginal": "Data dello scatto",
        "DateTimeDigitized": "Data di digitalizzazione",
        "LensModel": "Obiettivo",
        "FNumber": "Diaframma (f)",
        "ExposureTime": "Tempo di esposizione (s)",
        "ISOSpeedRatings": "ISO",
        "FocalLength": "Lunghezza focale (mm)",
        "Flash": "Flash",
        "Latitude": "Latitudine",
        "Longitude": "Longitudine",
        "Altitude": "Altitudine (m)",
        "Artist": "Autore",
        "Copyright": "Copyright",
        "Author": "Autore",
        "Title": "Titolo",
        "Subject": "Oggetto",
        "Creator": "Creato con",
        "Producer": "Prodotto da",
        "CreationDate": "Data di creazione",
        "ModDate": "Data di modifica",
        "Keywords": "Parole chiave",
        // Office (docProps) and OpenDocument (meta.xml)
        "creator": "Creato da",
        "initial-creator": "Creato da",
        "lastModifiedBy": "Ultima modifica di",
        "created": "Creato",
        "modified": "Modificato",
        "creation-date": "Creato",
        "date": "Modificato",
        "lastPrinted": "Ultima stampa",
        "print-date": "Ultima stampa",
        "revision": "Revisione",
        "editing-cycles": "Revisione",
        "title": "Titolo",
        "subject": "Oggetto",
        "keywords": "Parole chiave",
        "keyword": "Parole chiave",
        "description": "Descrizione",
        "category": "Categoria",
        "Company": "Azienda",
        "Manager": "Responsabile",
        "Application": "Applicazione",
        "AppVersion": "Versione dell'applicazione",
        "generator": "Applicazione",
        "Template": "Modello di documento",
        "TotalTime": "Minuti di modifica",
        "editing-duration": "Tempo di modifica",
        "Pages": "Pagine",
        "Words": "Parole",
        "Characters": "Caratteri",
        "Lines": "Righe",
        "Paragraphs": "Paragrafi",
    ]
    static let groupNames: [String: String] = [
        "Exif": "Scatto (Exif)",
        "TIFF": "Fotocamera (TIFF)",
        "GPS": "Posizione (GPS)",
        "ContentLightLevelInfo": "HDR",
        "ExifAux": "Obiettivo (Exif)",
        "MakerApple": "Dati Apple",
        "IPTC": "Didascalie (IPTC)",
        "Office": "Documento",
        "Origine": "Provenienza",
        "Spotlight": "Spotlight",
    ]

    /// "Exif · DateTimeOriginal" → card «Exif», row «DateTimeOriginal»; values without a group go under «File».
    static func groups(_ rows: [(key: String, value: String)]) -> [Group] {
        var out: [Group] = []
        for row in rows {
            let parts = row.key.components(separatedBy: " · ")
            let name = parts.count > 1 ? groupNames[parts[0]].map(L) ?? parts[0] : L("File")
            let raw = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : row.key
            let key = names[raw].map(L) ?? raw
            if let i = out.firstIndex(where: { $0.name == name }) { out[i].rows.append((key, row.value)) }
            else { out.append(Group(name: name, rows: [(key, row.value)])) }
        }
        return out
    }

    /// The rows whose name or value contains `query` (ignoring case and accents); a group whose own name matches
    /// keeps all its rows. An empty query keeps everything.
    static func filter(_ groups: [Group], _ query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            if contains(group.name, query) { return group }
            let rows = group.rows.filter { contains($0.key, query) || contains($0.value, query) }
            return rows.isEmpty ? nil : Group(name: group.name, rows: rows)
        }
    }

    static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// `text` with every occurrence of `query` on a tinted background.
    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var result = AttributedString(text)
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex,
              let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            if let lower = AttributedString.Index(found.lowerBound, within: result),
               let upper = AttributedString.Index(found.upperBound, within: result) {
                result[lower..<upper].backgroundColor = Color(nsColor: Settings.accentColor).opacity(0.3)
            }
            start = found.upperBound
        }
        return result
    }

    var body: some View {
        SwiftUI.Group {
            if let sections = model.sections {
                let shown = sections.map { Self.filter(Self.groups($0.rows), model.query) }
                let matches = shown.reduce(0) { $0 + $1.reduce(0) { $0 + $1.rows.count } }
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        MetadataSearchField(model: model).frame(maxWidth: .infinity)
                        // ⌘F, as in every Mac window with a search field.
                        Button("") { model.focusSearch() }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 34)
                    .padding(.bottom, 6)
                    if matches == 0, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text(L("Nessun valore corrisponde a «%@».", model.query)).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(22)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                ForEach(sections.indices, id: \.self) { file(sections[$0], groups: shown[$0]) }
                                if model.more > 0 {
                                    Text(L("e altri %@ file", model.more)).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                            .padding(.bottom, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                ProgressView(L("Lettura…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 400, minHeight: 200)
    }

    private func file(_ section: MetadataReader.Section, groups: [Group]) -> some View {
        let filtering = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let count = groups.reduce(0) { $0 + $1.rows.count }
        return VStack(alignment: .leading, spacing: 16) {
            RondelleHeader(symbol: section.symbol, title: section.name,
                           subtitle: filtering ? L("%@ di %@ valori", count, section.rows.count) : L("%@ valori", section.rows.count)) {
                Button { copy(section, groups: filtering ? groups : nil) } label: { Label(L("Copia"), systemImage: "doc.on.doc") }
                    .rondelleButton()
                    .help(filtering ? L("Copia negli appunti i valori trovati") : L("Copia tutti i valori negli appunti"))
            }
            if section.rows.isEmpty {
                Text(L("Nessun metadato trovato.")).font(.callout).foregroundStyle(.secondary)
            } else if groups.isEmpty {
                Text(L("Nessuna corrispondenza in questo file.")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    RondelleSectionTitle(text: group.name)
                    VStack(spacing: 0) {
                        ForEach(group.rows.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(Self.highlighted(group.rows[i].key, model.query)).font(.callout).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(Self.highlighted(group.rows[i].value, model.query))
                                    .font(.callout.weight(.medium))
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                                    .layoutPriority(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            if i < group.rows.count - 1 { Divider().padding(.leading, 14) }
                        }
                    }
                    .rondelleCard()
                }
            }
        }
    }

    private func copy(_ section: MetadataReader.Section, groups: [Group]? = nil) {
        let rows = groups.map { $0.flatMap { group in group.rows.map { (key: group.name + " · " + $0.key, value: $0.value) } } } ?? section.rows
        let text = ([section.name] + rows.map { "\($0.key): \($0.value)" }).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
