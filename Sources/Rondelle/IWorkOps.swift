import AppKit

/// «Apri in Pages» / «Apri in Numbers»: their formats are Apple's own and undocumented, so Rondelle doesn't
/// convert to or from them; it opens the file in the app through macOS, as a double click would, and the user
/// saves or exports it there. No Apple Events: with both apps sandboxed, Pages couldn't read a file passed
/// that way (0.8-E3, tried with the user's consent), and Rondelle needs no permission to control other apps.
enum IWorkOps {
    enum App: Sendable {
        case pages, numbers

        /// Bundle identifiers of the current apps and of the older iWork ones.
        var bundleIDs: [String] {
            self == .pages ? ["com.apple.Pages", "com.apple.iWork.Pages"] : ["com.apple.Numbers", "com.apple.iWork.Numbers"]
        }

        var title: String { self == .pages ? "Apri in Pages" : "Apri in Numbers" }

        var installed: URL? {
            bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        }
    }

    /// Files each app opens (Pages: Word, RTF, text and its own; Numbers: Excel, delimited text and its own).
    static let pagesInputs: Set<String> = ["docx", "doc", "rtf", "txt", "pages"]
    static let numbersInputs: Set<String> = ["xlsx", "csv", "tsv", "numbers"]

    /// The wheel's entry, only when the app is installed. Nothing is written next to the originals.
    static func action(_ app: App) -> WheelAction? {
        guard let appURL = app.installed else { return nil }
        return WheelAction(title: app.title, symbol: "arrow.up.forward.app", work: .share { urls in
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        })
    }
}
