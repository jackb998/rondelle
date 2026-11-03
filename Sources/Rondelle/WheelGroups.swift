import Foundation

/// How the wheel shows similar actions (Settings → Ruota → Stile).
enum WheelStyle: String, CaseIterable, Identifiable {
    /// Groups: a second ring with the variants while hovering, the options panel when dropped on the group.
    case mixed
    /// Groups with the second ring only: dropping on the group runs its first variant.
    case ring
    /// Groups with the options panel only.
    case panel
    /// Every action on the wheel, no groups (as before 0.8).
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mixed: return L("Anello e pannello")
        case .ring: return L("Solo anello")
        case .panel: return L("Solo pannello")
        case .full: return L("Ruota completa")
        }
    }

    var detail: String {
        switch self {
        case .mixed: return L("Passando su un gruppo compaiono le varianti attorno alla ruota; rilasciando sul gruppo si apre il pannello con tutte le opzioni.")
        case .ring: return L("Passando su un gruppo compaiono le varianti attorno alla ruota; rilasciando sul gruppo parte la prima.")
        case .panel: return L("Rilasciando su un gruppo si apre il pannello con le sue opzioni, vicino al file.")
        case .full: return L("Tutte le azioni sulla ruota, senza gruppi.")
        }
    }

    var showsRing: Bool { self == .mixed || self == .ring }
    var opensPanel: Bool { self == .mixed || self == .panel }
}

/// Puts similar tools under one entry: Comprimi, Ridimensiona, Modifica, Unisci e dividi, Protezione, ZIP…
/// Built on top of the plain action lists, so Shortcuts and the command line keep seeing every action.
enum WheelGroups {
    private struct Spec {
        let id: String
        let title: String
        let symbol: String
        let members: (WheelAction) -> Bool
        /// Members listed here come first, in this order (the first is what «Solo anello» runs on a drop).
        var first: [String] = []
    }

    private static func keys(_ keys: Set<String>) -> (WheelAction) -> Bool { { keys.contains($0.key) || keys.contains($0.id) } }

    private static let specs: [Spec] = [
        Spec(id: "group.compress", title: "Comprimi", symbol: "arrow.down.circle",
             members: keys(["Comprimi", "Comprimi +", "Peso…", "1080p", "720p", "HEVC"])),
        Spec(id: "group.resize", title: "Ridimensiona", symbol: "arrow.up.left.and.arrow.down.right",
             members: { $0.key == "50%" || $0.key == "Misura…" || ($0.key.hasSuffix("px") && $0.symbol != nil) }),
        Spec(id: "group.edit", title: "Modifica", symbol: "pencil.tip.crop.circle", members: keys(["Modifica", "Ruota", "Specchio"]), first: ["Modifica"]),
        Spec(id: "group.text", title: "Testo e QR", symbol: "text.viewfinder", members: keys(["Testo", "Copia testo", "QR"])),
        Spec(id: "group.subtitles", title: "Sottotitoli", symbol: "captions.bubble", members: keys(["SRT italiano", "SRT inglese", "SRT francese"])),
        Spec(id: "group.compose", title: "PDF e layout", symbol: "doc.on.doc", members: { $0.key == "Layout" || ($0.key == "PDF" && $0.symbol != nil) }),
        Spec(id: "group.turn", title: "Ruota", symbol: "rotate.right", members: keys(["Ruota a destra", "Ruota a sinistra", "Capovolgi"])),
        Spec(id: "group.pages", title: "Unisci e dividi", symbol: "doc.on.doc", members: keys(["merge", "Dividi"])),
        Spec(id: "group.protect", title: "Protezione", symbol: "lock", members: keys(["Oscura", "Password", "Sblocca", "Filigrana"])),
        Spec(id: "group.translate", title: "Traduci", symbol: "translate", members: keys(["In italiano", "In inglese", "In francese"])),
        Spec(id: "group.speed", title: "Velocità", symbol: "speedometer", members: keys(["2×", "0,5×"])),
        Spec(id: "group.audio", title: "Audio", symbol: "speaker.wave.2", members: keys(["Muto", "Solo audio"])),
        Spec(id: "group.zip", title: "ZIP", symbol: "archivebox", members: keys(["ZIP", "ZIP protetto", "TAR.GZ"])),
    ]

    static func apply(_ actions: [WheelAction], mode: WheelMode) -> [WheelAction] {
        // Formats and destinations are what those wheels are for: only the tools are grouped.
        guard mode == .tools, Settings.wheelStyle != .full else { return actions }
        var result: [WheelAction] = []
        var used = Set<Int>()
        for (i, action) in actions.enumerated() where !used.contains(i) {
            guard let spec = specs.first(where: { $0.members(action) }) else { result.append(action); continue }
            let members = actions.indices.filter { !used.contains($0) && spec.members(actions[$0]) }
            guard members.count >= 2 else { result.append(action); used.insert(i); continue }
            used.formUnion(members)
            let ordered = members.map { actions[$0] }.enumerated().sorted { a, b in
                let ia = spec.first.firstIndex(of: a.element.key) ?? Int.max, ib = spec.first.firstIndex(of: b.element.key) ?? Int.max
                return ia == ib ? a.offset < b.offset : ia < ib
            }.map(\.element)
            // One PDF has nothing to merge with: there the same window organizes its pages.
            let title = ordered.contains { $0.key == "Organizza" } ? "Organizza e dividi" : spec.title
            result.append(WheelAction(title: title, symbol: spec.symbol, work: .group(ordered), id: spec.id))
        }
        return result
    }
}
