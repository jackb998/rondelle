import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Interface text in the Mac's language. The Italian text is both the source and the key; the translations live in
/// Resources/<lingua>.lproj/Localizable.strings. A missing translation shows the Italian text, never a blank.
enum Loc {
    static let languages = ["it", "en", "fr"]

    static let bundle: Bundle = {
        #if DEBUG
        // Tests: the development build isn't an app bundle, so it is pointed at Resources/<lang>.lproj.
        let env = ProcessInfo.processInfo.environment
        if let root = env["RONDELLE_RESOURCES"], let lang = env["RONDELLE_LANG"],
           let bundle = Bundle(path: "\(root)/\(lang).lproj") { return bundle }
        #endif
        return .main
    }()

    /// The same text in every language the app has, so that a shortcut made in one language still finds its action.
    static func everyTranslation(of key: String) -> Set<String> {
        var all: Set<String> = [key, L(key)]
        for language in languages {
            if let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
                all.insert(bundle.localizedString(forKey: key, value: key, table: nil))
            }
        }
        return all
    }
}

extension Loc {
    /// The language the interface is in, for names macOS translates (a language's name in a message).
    static var languageCode: String {
        #if DEBUG
        if let lang = ProcessInfo.processInfo.environment["RONDELLE_LANG"] { return lang }
        if Bundle.main.bundleURL.pathExtension != "app" { return "it" }
        #endif
        return Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "it"
    }
}

/// The interface text whose Italian original is `key`, in the Mac's language.
func L(_ key: String) -> String {
    Loc.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// The same with values: each `%@` in the text (or `%1$@`, `%2$@`… in a translation) is replaced by `values`.
func L(_ key: String, _ values: CustomStringConvertible...) -> String {
    String(format: L(key), arguments: values.map { $0.description as NSString })
}

enum OpError: LocalizedError {
    case unreadable(URL)
    case unsupported(String)
    case failed(String)
    case notSmaller
    case alreadySmall

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): return L("Impossibile leggere «%@».", url.lastPathComponent)
        case .unsupported(let what): return L("Operazione non supportata: %@.", L(what))
        case .failed(let why): return L("Operazione non riuscita: %@.", L(why))
        case .notSmaller: return L("Il file è già ottimizzato: la versione compressa non sarebbe più piccola.")
        case .alreadySmall: return L("Il file è già più piccolo della dimensione richiesta.")
        }
    }
}

enum FileKind: Hashable {
    case image, pdf, video, audio, document, spreadsheet, presentation, subtitle, archive, folder, other

    static let documentExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "md", "webarchive", "pages"]
    static let spreadsheetExtensions: Set<String> = ["xlsx", "ods", "csv", "tsv", "numbers"]
    static let presentationExtensions: Set<String> = ["pptx", "key"]
    static let subtitleExtensions: Set<String> = ["srt", "vtt"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"]

    init(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // Before the drop the sandbox may hide resource values, so also trust the URL's trailing slash.
        let isDirectory = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory, ext.isEmpty || ext == "app" {
            self = .folder
            return
        }
        if Self.documentExtensions.contains(ext) { self = .document; return }
        if Self.spreadsheetExtensions.contains(ext) { self = .spreadsheet; return }
        if Self.presentationExtensions.contains(ext) { self = .presentation; return }
        if Self.subtitleExtensions.contains(ext) { self = .subtitle; return }
        if Self.archiveExtensions.contains(ext) { self = .archive; return }
        guard let type = UTType(filenameExtension: ext) else {
            self = .other
            return
        }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else { self = .other }
    }
}

/// Opening a FIFO waits for a writer and a device never ends, so a file the user chose is opened without waiting and
/// looked at through the open descriptor: a check before opening could be answered by a different file (B1).
enum SafeFile {
    private static func describe(_ url: URL) -> (fd: Int32, mode: mode_t)? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)   // links are followed: a link to a file is fine
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); return nil }
        return (fd, info.st_mode & S_IFMT)
    }

    private static func refusal(_ url: URL) -> OpError {
        .unsupported(L("«%@» non è un file normale (è una pipe, un socket o un dispositivo): Rondelle non lo apre", url.lastPathComponent))
    }

    /// For reading: regular files only.
    static func openForReading(_ url: URL) throws -> FileHandle {
        guard let (fd, mode) = describe(url) else { throw errno == ENXIO || errno == EOPNOTSUPP ? refusal(url) : OpError.unreadable(url) }
        guard mode == S_IFREG else {
            close(fd)
            throw refusal(url)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Before any work on the files: regular files and folders pass. What can't be opened for another reason
    /// (a missing file, no permission yet) goes on, and each action reports it as before.
    static func refuseSpecial(_ urls: [URL]) throws {
        for url in urls {
            guard let (fd, mode) = describe(url) else {
                if errno == ENXIO || errno == EOPNOTSUPP { throw refusal(url) }
                continue
            }
            close(fd)
            guard mode == S_IFREG || mode == S_IFDIR else { throw refusal(url) }
        }
    }

    /// Inside a folder that is about to be archived: `ditto` and `zip` would wait on a FIFO. Links aren't followed,
    /// because they are stored as links.
    static func refuseSpecial(inside folder: URL) throws {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        let keys: [URLResourceKey] = [.fileResourceTypeKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        for case let item as URL in items {
            try Task.checkCancellation()
            let type = try? item.resourceValues(forKeys: Set(keys)).fileResourceType
            if type == .namedPipe || type == .socket || type == .characterSpecial || type == .blockSpecial {
                throw OpError.unsupported(L("«%@» contiene «%@», che non è un file normale: toglilo e riprova", folder.lastPathComponent, item.lastPathComponent))
            }
        }
    }
}

/// "2", "2,5", "0.8" → bytes (the value is in MB).
func parseMegabytes(_ text: String) -> Int? {
    guard let mb = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
          mb.isFinite, mb >= 0.001, mb <= 1_000_000 else { return nil }  // 1 KB … 1 TB
    return Int(mb * 1_000_000)
}

/// Whether a job may stop and ask the user (false from Shortcuts and the command line: nobody to answer,
/// so every question is answered "no").
enum Prompts {
    @TaskLocal static var allowed = true
}

/// Limits that keep hostile files ("decompression bombs") from exhausting memory.
enum Limits {
    /// Images above this are refused: 150 MP is ~600 MB decoded, and rotating doubles it (B4).
    /// Phone and camera photos are 12–100 MP.
    static let maxImagePixels = 150_000_000
    /// Longest side of any rendered PDF page.
    static let maxRenderSide: CGFloat = 12_000
    /// Documents (Word, RTF, TXT…) above this are refused; HTML has a stricter limit (B1).
    static let maxDocumentBytes = 50_000_000
    /// HTML is imported by WebKit on the main thread: ≈ 0.8 s of frozen interface at 2 MB.
    static let maxHTMLBytes = 2_000_000
    /// DOCX and ODT are zip files: 10 MB already hold ≈ 40 MB of text (≈ 0.7 GB of memory to import).
    static let maxPackedDocumentBytes = 10_000_000
    /// PDFs with more pages than this need a confirmation (B2), or are refused where nobody can answer.
    static let maxPagesWithoutAsking = 300
    /// The photo editor draws the whole photo in memory: 48 MP phone photos take ≈ 0.6 GB, 100 MP took 1.2 GB (A3).
    static let maxEditorPixels = 50_000_000
    /// Files one Shortcuts run may receive.
    static let maxShortcutFiles = 50
}

/// C2: the output names a job has taken, so that a failed or cancelled job leaves nothing half-made behind.
final class OutputReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock(); urls.append(url); lock.unlock()
        CrashJournal.add(url)
    }

    func removeAll() {
        lock.lock(); let taken = urls; urls = []; lock.unlock()
        for url in taken.reversed() { try? FileManager.default.removeItem(at: url) }
        CrashJournal.remove(taken)
    }

    /// The job succeeded: its outputs are the user's now.
    func keep() {
        lock.lock(); let taken = urls; urls = []; lock.unlock()
        CrashJournal.remove(taken)
    }
}

/// A5: the outputs of jobs still running, also kept on disk, so that what a crash or a forced quit leaves behind
/// (an empty reserved name, a half-written file, an AVFoundation temporary) is removed at the next launch.
enum CrashJournal {
    private static let key = "pendingOutputs"
    private static let lock = NSLock()
    private static let prefix = ".rondelle-"

    private struct Entry: Codable {
        let path: String
        /// The file Rondelle created; a visible name is removed only if it still is that very file.
        let inode: UInt64?
    }

    static func add(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        write(read() + [Entry(path: url.path, inode: inode(of: url))])
    }

    static func remove(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        lock.lock(); defer { lock.unlock() }
        write(read().filter { !paths.contains($0.path) })
    }

    /// At launch: removes what jobs that never finished left behind; returns how many items were removed.
    @discardableResult
    static func cleanUp() -> Int {
        lock.lock()
        let entries = read()
        write([])
        lock.unlock()
        let fm = FileManager.default
        var removed = 0
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)
            let name = url.lastPathComponent, dir = url.deletingLastPathComponent()
            if name.hasPrefix(prefix) {
                // Ours by name; AVFoundation also writes "<name>.sb-…" next to it.
                for sibling in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where sibling == name || sibling.hasPrefix(name + ".") {
                    if (try? fm.removeItem(at: dir.appendingPathComponent(sibling))) != nil { removed += 1 }
                }
                continue
            }
            guard let recorded = entry.inode, inode(of: url) == recorded else { continue }   // replaced since: not ours
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            // A folder only if empty: something put in it after the crash isn't ours to delete.
            if isDirectory.boolValue, !((try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false) { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private static func inode(of url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func read() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func write(_ entries: [Entry]) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key)
        }
    }
}

enum FileNaming {
    @TaskLocal static var reservations: OutputReservations?

    /// Runs one job; if it throws (an error or «Annulla»), deletes every output it had started.
    /// macOS sometimes refuses for a moment to open a file marked as downloaded (kMDItemWhereFroms), even to `cat`,
    /// with EPERM: that alone is tried again, a few times, from the start. A real lack of permission is EACCES.
    static func cleaningUpOnFailure<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            let taken = OutputReservations()
            do {
                let result = try await $reservations.withValue(taken) { try await work() }
                taken.keep()
                return result
            } catch {
                taken.removeAll()
                attempt += 1
                guard attempt < 5, isMomentaryRefusal(error) else { throw error }
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private static func isMomentaryRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError else { return false }
        let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return cause == nil || (cause?.domain == NSPOSIXErrorDomain && cause?.code == Int(EPERM))
    }

    /// Returns `url` if free, otherwise "name 2.ext", "name 3.ext", … — and claims it at once (F):
    /// the file is created empty with O_CREAT|O_EXCL|O_NOFOLLOW, so between choosing the name and writing
    /// nobody can put a link there for the writer to follow. Writers then overwrite this empty file.
    static func unique(_ url: URL) -> URL {
        claim(url) { path in
            let fd = open(path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o644)
            if fd >= 0 { close(fd) }
            return fd >= 0
        }
    }

    /// The same for a new folder: mkdir is exclusive by nature (and never follows a link).
    static func uniqueDirectory(_ url: URL) -> URL {
        claim(url) { mkdir($0, 0o755) == 0 }
    }

    private static func claim(_ url: URL, create: (String) -> Bool) -> URL {
        var i = 2
        var candidate = url
        while true {
            if create(candidate.path) {
                reservations?.add(candidate)
                return candidate
            }
            // Not "already exists" (e.g. the folder isn't writable yet): pick a free name and let the
            // writer report the real error.
            if errno != EEXIST, !isTaken(candidate) { return candidate }
            candidate = numbered(url, i)
            i += 1
        }
    }

    private static func numbered(_ url: URL, _ i: Int) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
    }

    /// An unpredictable name next to `url`, for tools that refuse to overwrite: they write here and the
    /// result is renamed onto the claimed name (rename replaces a link instead of following it).
    static func scratchName(next url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".rondelle-\(UUID().uuidString).\(url.pathExtension)")
    }

    /// Moves `temp` onto the claimed `final` name, atomically.
    static func replace(_ final: URL, with temp: URL) throws {
        guard rename(temp.path, final.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw OpError.failed(L("salvataggio di %@", final.lastPathComponent))
        }
    }

    /// Like fileExists, but a symbolic link counts as taken even when it points nowhere:
    /// otherwise a planted "foto.zip → /somewhere/else" would make tools write through it.
    private static func isTaken(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil   // lstat: doesn't follow links
            || FileManager.default.fileExists(atPath: url.path)
    }

    /// Shortcuts: results go to the run's own folder in the sandbox (see ShortcutsWorkspace).
    @TaskLocal static var outputOverride: URL?

    /// Where results of `source` go: next to it, or the folder chosen in Settings.
    static func directory(for source: URL) -> URL {
        outputOverride ?? Settings.outputFolder ?? source.deletingLastPathComponent()
    }

    /// Output file for `source`, e.g. "foto (480px).jpg".
    static func output(for source: URL, ext: String, suffix: String? = nil) -> URL {
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix { base += " (\(L(suffix)))" }
        let url = directory(for: source).appendingPathComponent(base)
        return unique(ext.isEmpty ? url : url.appendingPathExtension(ext))
    }

    /// New empty output folder, e.g. "documento (pagine)".
    static func folder(for source: URL, suffix: String) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent + " (\(L(suffix)))"
        let url = uniqueDirectory(directory(for: source).appendingPathComponent(base))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)   // already there unless unwritable
        return url
    }

    static func sortedNaturally(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Reads from disk every time (URL.resourceValues caches, which breaks retry loops).
    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
