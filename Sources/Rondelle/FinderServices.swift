import AppKit

/// Finder → right-click → Servizi → "Rondelle: …" (declared under NSServices in Info.plist).
/// macOS hands the selected files over with sandbox access to them.
@MainActor
final class FinderServices: NSObject {
    private let wheel: WheelController

    init(wheel: WheelController) {
        self.wheel = wheel
    }

    @objc func runService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = L("Nessun file selezionato.") as NSString
            return
        }
        switch userData {
        case "tools":
            wheel.show(urls: urls, mode: .tools, clickMode: true)
        case "share":
            wheel.show(urls: urls, mode: .share, clickMode: true)
        case "compress":
            compress(urls)
        default:
            wheel.show(urls: urls, mode: .convert, clickMode: true)
        }
    }

    /// The "Comprimi" tool for that kind of file (HEVC for videos), without opening the wheel.
    /// Any app can call a service, and the app in front is no proof of who did (it can bring the Finder
    /// forward first), so the user always confirms. The app that was in front is shown as a hint.
    private func compress(_ urls: [URL]) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? L("sconosciuta")
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? L("Comprimere questo file?") : L("Comprimere questi %@ file?", urls.count)
        alert.informativeText = urls.prefix(6).map { "• " + $0.lastPathComponent }.joined(separator: "\n")
            + (urls.count > 6 ? "\n…" : "")
            + "\n\n" + L("Richiesta arrivata dal servizio «Rondelle: Comprimi» mentre era in primo piano «%@». Se non l'hai chiesta tu, premi Annulla.", front)
        alert.addButton(withTitle: L("Comprimi"))
        alert.addButton(withTitle: L("Annulla"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let tools = ActionCatalog.actions(for: urls, mode: .tools)
        guard let action = tools.first(where: { $0.id == "Comprimi" }) ?? tools.first(where: { $0.id == "HEVC" }) else {
            Notice.show(title: L("Niente da comprimere"), text: L("Rondelle comprime immagini, PDF, video e audio (uno stesso tipo alla volta)."))
            return
        }
        JobRunner.run(action, urls: urls)
    }
}
