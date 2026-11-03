import AppKit

/// The last jobs, for the menu bar's "Recenti" list and "Annulla ultima conversione".
/// Only file paths, kept in the app's own sandbox container; never sent anywhere.
@MainActor
enum JobHistory {
    struct Entry: Codable {
        let title: String
        let date: Date
        let paths: [String]
        /// Fingerprint of each output when it was made (file number + creation date), see `fingerprint`.
        var fingerprints: [String]?
        var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
        /// Outputs that are still on disk.
        var existing: [URL] { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }

        /// Outputs still on disk *and* still the very files Rondelle made: a path in the history
        /// that now holds another file (or was edited in the preferences) is never trashed.
        var ownFiles: [URL] {
            guard let fingerprints, fingerprints.count == paths.count else { return [] }
            return zip(urls, fingerprints).compactMap { url, print in JobHistory.fingerprint(url) == print ? url : nil }
        }
    }

    /// "file number-creation time"; changes if the file is replaced, even under the same name.
    nonisolated static func fingerprint(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        return "\(number)-\(created.timeIntervalSinceReferenceDate)"
    }

    static var limit: Int { Settings.historyLimit }
    static let key = "jobHistory"

    /// Entries stored in `data` (the value under `key`): Settings shows it live, cleared from the menu too.
    nonisolated static func count(in data: Data) -> Int {
        (try? JSONDecoder().decode([Entry].self, from: data))?.count ?? 0
    }

    /// After a smaller limit is chosen: the oldest jobs beyond it are forgotten at once.
    static func trim() { entries = entries }

    static var entries: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.prefix(limit))), forKey: key)
        }
    }

    static func record(_ title: String, outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        let entry = Entry(title: title, date: Date(), paths: outputs.map(\.path),
                          fingerprints: outputs.map { fingerprint($0) ?? "" })
        entries = [entry] + entries
    }

    static func clear() { entries = [] }

    /// Moves the most recent job's outputs to the Trash (recoverable from there).
    static func undoLast() {
        if let last = entries.first { undo(last) }
    }

    /// The same for the job that made exactly these files (from its result card): another may have ended since.
    static func undo(paths: [String]) {
        if let entry = entries.first(where: { $0.paths == paths }) { undo(entry) }
    }

    private static func undo(_ last: Entry) {
        let files = last.ownFiles
        var failed = last.existing.count - files.count   // replaced or tampered with: left alone
        for url in files {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed += 1 }
        }
        entries = entries.filter { $0.paths != last.paths || $0.date != last.date }
        if failed > 0 {
            Notice.show(title: L("Annullamento incompleto"),
                        text: L("%@ file non sono stati spostati nel Cestino: sono stati modificati, sostituiti o spostati dopo la conversione.", failed))
        } else if !files.isEmpty {
            NSSound(named: "Pop")?.play()
        }
    }

    static func reveal(_ entry: Entry) {
        let files = entry.existing
        if files.isEmpty {
            Notice.show(title: L("File non trovati"), text: L("I file di «%@» sono stati spostati o eliminati.", entry.title))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }
}
