import AppIntents
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Shortcuts → "Converti con Rondelle": runs one wheel action on the files it receives and returns the results.
/// The files are copied into the app's sandbox temp folder and the results are written there too,
/// so nothing appears next to the originals; Shortcuts decides where they go next.
struct ConvertWithRondelle: AppIntent {
    static let title: LocalizedStringResource = "Converti con Rondelle"
    static let description = IntentDescription(
        "Converte i file nel formato scelto o li elabora con uno strumento di Rondelle (come sulla ruota) e restituisce i risultati."
    )

    @Parameter(title: "File")
    var files: [IntentFile]

    @Parameter(title: "Azione", optionsProvider: ActionOptions())
    var action: String

    static var parameterSummary: some ParameterSummary {
        Summary("Converti \(\.$files) con \(\.$action)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await ShortcutsWorkspace.run(files, action: action))
    }
}

extension ShortcutsWorkspace {
    /// The body of the Shortcuts action (also called by the development command line for testing).
    static func run(_ files: [IntentFile], action: String) async throws -> [IntentFile] {
        guard !files.isEmpty else { throw IntentError.message(L("Nessun file da elaborare.")) }
        guard files.count <= Limits.maxShortcutFiles else {
            throw IntentError.message(L("Troppi file: al massimo %@ per volta.", Limits.maxShortcutFiles))
        }
        ShortcutsWorkspace.removeOld()
        let job = try ShortcutsWorkspace.newJob()
        // The copies of the user's files are needed only during the run; the results stay for Shortcuts.
        defer { try? FileManager.default.removeItem(at: job.inputs) }
        let inputs = try files.map { try ShortcutsWorkspace.copy($0, into: job.inputs) }
        try inputs.forEach(ShortcutsWorkspace.checkLimits)

        guard let match = ActionCatalog.actionsForShortcuts(inputs).first(where: { $0.matches(action) }) else {
            throw IntentError.message(L("«%@» non è disponibile per questi file.", action))
        }

        var work = match.work
        if case .asking(_, let defaultValue, let kind, let ask) = work {
            // A default can't stand in for a password: those actions need the wheel.
            guard kind == .text else { throw IntentError.message(L("«%@» chiede una password: usalo dalla ruota di Rondelle.", action)) }
            work = .perFile { try await ask($0, defaultValue) }
        }
        if case .askingAll(_, let kind, let ask) = work {
            guard kind == .text else { throw IntentError.message(L("«%@» chiede una password: usalo dalla ruota di Rondelle.", action)) }
            work = .batch { try await ask($0, "") }
        }

        var outputs: [URL] = []
        var errors: [String] = []
        // No dialogs from a shortcut: any question (e.g. a very compressed archive) is answered "no".
        try await Prompts.$allowed.withValue(false) { try await FileNaming.$outputOverride.withValue(job.outputs) {
            switch work {
            case .asking, .askingAll:
                break
            case .window, .share, .group:
                throw IntentError.message(L("«%@» apre una finestra: usalo dalla ruota di Rondelle.", action))
            case .perFile(let run):
                for url in FileNaming.sortedNaturally(inputs) {
                    do { outputs += try await FileNaming.cleaningUpOnFailure { try await run(url) } }
                    catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            case .batch(let run):
                do { outputs = try await FileNaming.cleaningUpOnFailure { try await run(inputs) } }
                catch { errors.append(error.localizedDescription) }
            }
        } }

        // Partial success still returns what was made; with nothing made, the first error stops the shortcut.
        guard !outputs.isEmpty else {
            throw IntentError.message(errors.first ?? L("%@: nessun file prodotto.", action))
        }
        return ShortcutsWorkspace.files(for: outputs)
    }
}

/// Every action that can run without a window, across all kinds of files: formats first, then tools.
struct ActionOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        var titles: [String] = []
        for mode in [WheelMode.convert, .tools] {
            for kind in [FileKind.image, .pdf, .video, .audio, .document, .subtitle, .archive, .other] {
                for action in ActionCatalog.allActions(for: kind, mode: mode) {
                    if case .window = action.work { continue }
                    if case .share = action.work { continue }   // hands files to another app: not in a shortcut
                    if !titles.contains(action.title) { titles.append(action.title) }
                }
            }
        }
        return titles
    }
}

enum IntentError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Per-run folders under the sandbox temp directory: "Comandi/<id>/originali" and "Comandi/<id>/risultati".
enum ShortcutsWorkspace {
    struct Job {
        let inputs: URL
        let outputs: URL
    }

    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Comandi", isDirectory: true)
    }

    static func newJob() throws -> Job {
        let base = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let job = Job(inputs: base.appendingPathComponent("originali", isDirectory: true),
                      outputs: base.appendingPathComponent("risultati", isDirectory: true))
        try FileManager.default.createDirectory(at: job.inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: job.outputs, withIntermediateDirectories: true)
        return job
    }

    /// The same limits as the wheel's documents and PDFs (B1/B2); without anyone to ask, over the limit is refused.
    static func checkLimits(_ url: URL) throws {
        try SafeFile.refuseSpecial([url])
        switch FileKind(url) {
        case .document:
            let limit = DocumentOps.sizeLimit(for: url)
            guard FileNaming.fileSize(url) <= limit else {
                throw IntentError.message(L("«%@» è troppo grande (massimo %@ MB).", url.lastPathComponent, limit / 1_000_000))
            }
        case .pdf:
            let pages = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
            guard pages <= Limits.maxPagesWithoutAsking else {
                throw IntentError.message(L("«%@» ha %@ pagine (massimo %@ da Comandi rapidi).", url.lastPathComponent, pages, Limits.maxPagesWithoutAsking))
            }
        default:
            break
        }
    }

    /// At launch no shortcut is running: everything in tmp/Comandi is left over from earlier runs.
    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Results must outlive perform() (Shortcuts reads them afterwards), so earlier runs are cleared on the next one.
    static func removeOld() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let runs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for run in runs {
            let created = (try? run.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: run) }
        }
    }

    static func copy(_ file: IntentFile, into folder: URL) throws -> URL {
        let name = file.filename.isEmpty ? "file" : (file.filename as NSString).lastPathComponent
        let destination = FileNaming.unique(folder.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: destination)   // copyItem won't overwrite; private folder of this run
        if let source = file.fileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil { return destination }
        }
        try file.data.write(to: destination)
        return destination
    }

    /// Folders of results (PDF pages, extracted archives) are handed over as the files inside them.
    static func files(for outputs: [URL]) -> [IntentFile] {
        let fm = FileManager.default
        var urls: [URL] = []
        for url in outputs {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
               let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                urls += FileNaming.sortedNaturally(contents)
            } else {
                urls.append(url)
            }
        }
        return urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: UTType(filenameExtension: $0.pathExtension)) }
    }
}
