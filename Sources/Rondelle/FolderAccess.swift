import AppKit

/// Inside the App Sandbox the app can read a dropped file, but may only write next to it in a folder
/// the user has explicitly allowed through an Open panel. Those permissions are remembered as
/// security-scoped bookmarks (readable only by this app) and can be revoked from the menu.
@MainActor
enum FolderAccess {
    private static let key = "allowedFolderBookmarks"

    /// The real home folder (in the sandbox NSHomeDirectory() points inside the app's container).
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var allowedFolders: [URL] {
        bookmarks.compactMap { resolve($0)?.url }
    }

    /// Call at launch: re-opens every folder the user allowed earlier.
    static func restore() {
        var refreshed: [Data] = []
        for data in bookmarks {
            guard let (url, stale) = resolve(data) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            refreshed.append(stale ? (try? bookmark(for: url)) ?? data : data)
        }
        bookmarks = refreshed
    }

    /// Makes sure the app can save into every folder in `dirs`, asking the user where needed.
    static func ensureWritable(_ dirs: [URL]) -> Bool {
        var seen = Set<String>()
        for dir in dirs where seen.insert(dir.standardizedFileURL.path).inserted {
            if canWrite(in: dir) { continue }
            guard request(dir) else { return false }
        }
        return true
    }

    /// The folder chosen in the most recent successful `request`.
    private(set) static var lastGranted: URL?

    /// Shows the Open panel on `suggested`; the user confirms that folder or picks a parent of it.
    /// With `acceptAny`, any chosen folder counts as success (Settings), otherwise it must cover `suggested`.
    @discardableResult
    static func request(_ suggested: URL, explanation: String? = nil, acceptAny: Bool = false) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = suggested
        panel.prompt = L("Consenti")
        panel.message = explanation ?? L("Rondelle salva i file convertiti accanto agli originali: serve il tuo permesso per «%@».\nSuggerimento: scegli la cartella Inizio per non doverlo rifare per ogni cartella.", suggested.lastPathComponent)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // G: a folder that doesn't contain the destination is of no use here: don't keep a permission for it.
        guard acceptAny || covers(url, suggested) else {
            Notice.show(title: L("Cartella non adatta"),
                        text: L("«%@» non contiene «%@»: il permesso non è stato salvato. Scegli quella cartella o una che la contiene.", url.lastPathComponent, suggested.lastPathComponent))
            return false
        }
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? bookmark(for: url) {
            bookmarks = bookmarks.filter { resolve($0)?.url.standardizedFileURL != url.standardizedFileURL } + [data]
        }
        lastGranted = url
        return acceptAny ? canWrite(in: url) : canWrite(in: suggested)
    }

    /// True if `folder` is `target` or one of its parents (after resolving links, e.g. /tmp → /private/tmp).
    static func covers(_ folder: URL, _ target: URL) -> Bool {
        let f = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let t = target.resolvingSymlinksInPath().standardizedFileURL.path
        return t == f || t.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    static func revokeAll() {
        for url in allowedFolders { url.stopAccessingSecurityScopedResource() }
        bookmarks = []
    }

    /// Real write test: the sandbox decides, so asking the file system is the only reliable check.
    static func canWrite(in dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".rondelle-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    // MARK: Storage

    private static var bookmarks: [Data] {
        get { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}
