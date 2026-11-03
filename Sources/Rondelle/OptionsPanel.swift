import AppKit
import SwiftUI

/// The options of a group (Comprimi, Ridimensiona, Unisci e dividi…), in a small panel next to where the files were dropped.
/// Choosing one runs it like a wheel action; Esc or the close button cancels.
@MainActor
enum OptionsPanel {
    private static var panel: NSPanel?

    static func show(title: String, _ actions: [WheelAction], urls: [URL], at point: NSPoint) {
        close()
        let content = OptionsView(title: title, actions: actions, fileCount: urls.count) { choice in
            close()
            guard let choice else { return }
            JobRunner.run(choice, urls: urls, at: point)
        }
        let host = NSHostingController(rootView: content)
        let panel = KeyPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.title = title
        let size = host.view.fittingSize
        var frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        if let screen = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - size.width - 8)
            frame.origin.y = min(max(frame.minY, screen.minY + 8), screen.maxY - size.height - 8)
        }
        panel.setFrame(frame, display: true)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Takes the keyboard (Esc, arrows, Return) although it is a panel.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { OptionsPanel.close() }
    }
}

struct OptionsView: View {
    let title: String
    let actions: [WheelAction]
    let fileCount: Int
    let choose: (WheelAction?) -> Void
    @State private var hovered: Int?

    private let columns = [GridItem(.fixed(150), spacing: 10), GridItem(.fixed(150), spacing: 10)]

    /// One line under the options that look alike, so the choice is clear without trying them.
    static func hint(_ key: String) -> String? {
        if key.hasSuffix("px"), key != "Misura…", let px = Int(key.dropLast(2)) { return L("Lato lungo %@ pixel", px) }
        let hints = [
            "Comprimi": "Più leggero, qualità quasi uguale",
            "Comprimi +": "Il più leggero possibile",
            "Peso…": "Scegli i MB massimi",
            "50%": "Metà larghezza e altezza",
            "Misura…": "Scegli il lato lungo in pixel",
            "1080p": "Full HD",
            "720p": "HD, più leggero",
            "HEVC": "Stessa risoluzione, file più piccolo",
            "2×": "Due volte più veloce",
            "0,5×": "Rallentato a metà",
            "Muto": "Video senza audio",
            "Solo audio": "Solo la traccia audio (M4A)",
            "Password": "Serve per aprire il PDF",
            "Sblocca": "Toglie la password",
            "Filigrana": "Testo su ogni pagina",
            "Numera pagine": "Numero su ogni pagina",
            "Unisci e dividi": "Più PDF in uno, o separa",
            "Organizza e dividi": "Riordina o separa",
            "Unisci": "Più PDF in uno, in ordine",
            "Organizza": "Riordina, ruota, elimina pagine",
            "Copia testo": "Negli appunti, nessun file",
            "Testo": "In un file TXT, e negli appunti",
            "Sottotitoli": "Dal parlato, in un file SRT",
            "SRT italiano": "Se si parla italiano",
            "SRT inglese": "Se si parla inglese",
            "SRT francese": "Se si parla francese",
            "Oscura": "Toglie davvero il testo coperto",
            "Ruota": "Tutte le pagine del PDF",
            "Ruota a destra": "Tutte le pagine, 90°",
            "Ruota a sinistra": "Tutte le pagine, −90°",
            "Capovolgi": "Tutte le pagine, 180°",
            "SHA-256": "L'impronta del file, negli appunti",
            "Copia percorso": "Il percorso del file come testo",
            "Dividi": "Un PDF per pagina",
            "ZIP protetto": "AES-256 con password",
            "Modifica": "Regola, ritaglia, annota",
            "Con formattazione": "Dove è possibile",
            "Senza formattazione": "Solo il testo",
        ]
        return hints[key].map(L)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    Text(fileCount == 1 ? L("1 file") : L("%@ file", fileCount)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { choose(nil) } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help(L("Annulla"))
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(actions.indices, id: \.self) { i in
                    let action = actions[i]
                    Button { choose(action) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: action.symbol ?? "doc").font(.system(size: 22, weight: .medium))
                            Text(action.title).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            if let hint = Self.hint(action.key) {
                                Text(hint).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                    .foregroundStyle(hovered == i ? Color.white.opacity(0.85) : Color.secondary)
                            }
                        }
                        .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 104)
                        .foregroundStyle(hovered == i ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(hovered == i ? Color(nsColor: Settings.accentColor) : Color.primary.opacity(0.06)))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { hovered = i } else if hovered == i { hovered = nil }
                        if inside { HoverFeedback.play() }
                    }
                }
            }
            if actions.contains(where: { if case .asking = $0.work { return true } else { return false } }) {
                Text(L("Le voci con «…» chiedono il valore prima di partire."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 346)
    }
}
