import Foundation

/// Settings → Ruota: which actions each wheel shows, and in what order.
/// One entry per kind of file and mode, e.g. "image.tools"; unknown or new actions go at the end.
enum WheelConfig {
    struct Entry: Codable, Equatable {
        var order: [String] = []
        var hidden: [String] = []
    }

    /// The wheels you can customise, as shown in Settings.
    static let kinds: [(kind: FileKind, label: String)] = [
        (.image, L("Immagini")), (.pdf, "PDF"), (.video, L("Video")), (.audio, L("Audio")),
        (.document, L("Documenti")), (.spreadsheet, L("Fogli di calcolo")), (.subtitle, L("Sottotitoli")), (.archive, L("Archivi")), (.other, L("Cartelle e altri file")),
    ]

    static func key(_ kind: FileKind, _ mode: WheelMode) -> String {
        let k: String
        switch kind {
        case .image: k = "image"
        case .pdf: k = "pdf"
        case .video: k = "video"
        case .audio: k = "audio"
        case .document: k = "document"
        case .spreadsheet: k = "spreadsheet"
        case .subtitle: k = "subtitle"
        case .archive: k = "archive"
        case .folder, .other: k = "other"
        }
        // The share wheel is the same for every kind of file.
        if mode == .share { return "wheel.share" }
        return "wheel.\(k).\(mode == .convert ? "convert" : "tools")"
    }

    static func entry(_ kind: FileKind, _ mode: WheelMode) -> Entry {
        guard let data = UserDefaults.standard.data(forKey: key(kind, mode)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
        return entry
    }

    static func save(_ entry: Entry, _ kind: FileKind, _ mode: WheelMode) {
        if entry == Entry() {
            UserDefaults.standard.removeObject(forKey: key(kind, mode))
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(entry), forKey: key(kind, mode))
        }
    }

    static func resetAll() {
        for (kind, _) in kinds {
            for mode in [WheelMode.convert, .tools, .share] { UserDefaults.standard.removeObject(forKey: key(kind, mode)) }
        }
    }

    /// Hides and reorders `actions`; never returns an empty wheel.
    static func apply(_ actions: [WheelAction], kind: FileKind, mode: WheelMode) -> [WheelAction] {
        let entry = entry(kind, mode)
        guard entry != Entry() else { return actions }
        let visible = actions.filter { !entry.hidden.contains($0.id) }
        let sorted = visible.enumerated().sorted { a, b in
            let ia = entry.order.firstIndex(of: a.element.id) ?? Int.max
            let ib = entry.order.firstIndex(of: b.element.id) ?? Int.max
            return ia == ib ? a.offset < b.offset : ia < ib
        }.map(\.element)
        return sorted.isEmpty ? actions : sorted
    }
}
