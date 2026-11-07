import AppKit

/// The share wheel (by default ⌃ Control + ⇧ Shift): macOS sharing services,
/// apps that accept files, web apps. Rondelle itself never sends anything (it has no network access):
/// it hands the files to macOS, to another app or to the clipboard, and the user sends them there.
@MainActor
enum ShareOps {
    /// An installed app with its own share extension (shown by macOS in the share menu).
    private struct ExtensionApp: Sendable {
        let title: String
        let bundleIDs: [String]
    }

    /// Apps and web apps without a share extension: the files go on the clipboard, the user pastes them.
    private struct PasteTarget: Sendable {
        let title: String
        let bundleIDs: [String]
        /// Web app, offered when the app isn't installed.
        let web: URL?
    }

    nonisolated private static let extensionApps = [
        ExtensionApp(title: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
    ]

    nonisolated private static let pasteTargets = [
        PasteTarget(title: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"],
                    web: URL(string: "https://web.whatsapp.com")),
    ]

    nonisolated static func actions() -> [WheelAction] {
        var actions: [WheelAction] = [
            share("AirDrop", "dot.radiowaves.left.and.right") { perform(.sendViaAirDrop, $0) },
            share("Messaggi", "message") { perform(.composeMessage, $0) },
            share("Mail", "envelope") { email($0) },
        ]
        for app in extensionApps {
            guard let appURL = installed(app.bundleIDs) else { continue }
            actions.append(share(app.title, "paperplane") { performExtension(app.title, appURL: appURL, $0) })
        }
        for target in pasteTargets {
            if let appURL = installed(target.bundleIDs) {
                actions.append(share(target.title, "bubble.left.and.bubble.right") { paste($0, into: target.title, app: appURL) })
            } else if let web = target.web {
                let title = "\(target.title) Web"
                actions.append(share(title, "globe") { paste($0, into: title, web: web) })
            }
        }
        // Settings → Ruota → Condividi: apps and macOS services the user added.
        for added in ShareTargets.all {
            switch added.kind {
            case .service:
                actions.append(share(added.title, "square.and.arrow.up.on.square") { performService(added.title, $0) })
            case .app:
                guard let appURL = installed([added.id]) else { continue }
                actions.append(share(added.title, "app") { performExtension(added.title, appURL: appURL, $0) })
            }
        }
        actions.append(share("Copia", "doc.on.clipboard") { urls in
            copyToClipboard(urls)
            Notice.show(title: urls.count == 1 ? L("File copiato") : L("%@ file copiati", urls.count),
                        text: L("Incollalo con ⌘V in una chat, in un'email o nel Finder."))
        })
        // The originals' paths, not those of the copies without metadata: what is copied is where the file is.
        actions.append(WheelAction(title: "Copia percorso", symbol: "link", work: .share { urls in
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(pathsText(urls), forType: .string)
            NSSound(named: "Pop")?.play()
            CompletionAnimation.play()
        }))
        actions.append(WheelAction(title: "SHA-256", symbol: "number.square", work: .share { urls in
            // Of the originals, as a job of its own: a large file takes time, and can be stopped.
            JobRunner.run(.all("SHA-256") { try await Checksum.copy($0) }, urls: urls)
        }))
        // For the command line: the originals, never the copies without metadata.
        actions.append(WheelAction(title: "Terminale", symbol: "terminal", work: .share { openTerminal($0) }))
        actions.append(share("Altro…", "square.and.arrow.up") { showPicker($0) })
        return actions
    }

    // MARK: Routes

    nonisolated private static func share(_ title: String, _ symbol: String, _ send: @escaping @MainActor ([URL]) -> Void) -> WheelAction {
        WheelAction(title: title, symbol: symbol, work: .share { urls in
            Task { @MainActor in
                guard let ready = await prepared(urls) else { return }
                NSApp.activate(ignoringOtherApps: true)
                send(ready)
            }
        })
    }

    private static func perform(_ name: NSSharingService.Name, _ urls: [URL]) {
        guard let service = NSSharingService(named: name), service.canPerform(withItems: urls) else {
            Notice.show(title: L("Condivisione non disponibile"),
                        text: L("macOS non offre «%@» per questi file.", name.rawValue))
            return
        }
        service.perform(withItems: urls)
    }

    /// A new email in the default mail app (Settings of Mail, or of Spark…): Apple Mail through macOS,
    /// another app through its share extension, else attached by pasting.
    private static func email(_ urls: [URL]) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!),
              Bundle(url: app)?.bundleIdentifier != "com.apple.mail" else {
            perform(.composeEmail, urls)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        // "Spark Desktop" names its extension "Spark": match on the first word.
        let short = name.split(separator: " ").first.map(String.init) ?? name
        performExtension(short, appURL: app, urls,
                         hint: L("I file vengono copiati negli appunti. Quando si apre %@, crea una nuova email e premi ⌘V.", short))
    }

    /// A macOS sharing service chosen in Settings (Notes, Dropbox…), found by its title.
    private static func performService(_ title: String, _ urls: [URL]) {
        if let service = services(for: urls).first(where: { $0.title == title }), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            Notice.show(title: L("Condivisione non disponibile"), text: L("macOS non offre «%@» per questi file.", title))
        }
    }

    /// Every sharing service macOS offers for these files, extensions of other apps included.
    static func services(for urls: [URL]) -> [NSSharingService] {
        // Deprecated, but the only way to reach one app's extension without showing the whole menu.
        NSSharingService.sharingServices(forItems: urls)
    }

    /// The app's own share extension; if it is turned off, falls back to the clipboard.
    private static func performExtension(_ title: String, appURL: URL, _ urls: [URL], hint: String? = nil) {
        let service = services(for: urls).first { $0.title.localizedCaseInsensitiveContains(title) }
        if let service, service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            paste(urls, into: title, app: appURL, hint: hint)
        }
    }

    /// Semi-automatic: the files go on the clipboard, then the app or web page opens and the user pastes.
    private static func paste(_ urls: [URL], into title: String, app: URL? = nil, web: URL? = nil, hint: String? = nil) {
        guard Notice.confirm(title: L("Condividi con %@", title),
                             text: hint ?? L("I file vengono copiati negli appunti. Quando si apre %@, scegli la chat e premi ⌘V.", title),
                             button: L("Apri %@", title)) else { return }
        copyToClipboard(urls)
        if let app {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let web, web.scheme == "https" {
            NSWorkspace.shared.open(web)
        }
    }

    /// Files that make the shell or git run commands set by whoever made the folder (0.8-E2): `.git` (git status,
    /// e.g. from a prompt, runs `core.fsmonitor` and `filter` commands of its config, also from subfolders),
    /// `.envrc` (direnv), `.mise.toml` and `.tool-versions` (mise, asdf).
    nonisolated static let autoRunFiles = [".git", ".envrc", ".mise.toml", ".tool-versions"]

    /// What in `folder` (or, for `.git`, in any folder above it: git looks upwards too) could run commands by itself.
    /// Folders the sandbox can't see count as clean.
    nonisolated static func autoRunFindings(in folder: URL) -> [String] {
        let fm = FileManager.default
        var found = autoRunFiles.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        var parent = folder.standardizedFileURL.deletingLastPathComponent()
        while !found.contains(".git"), parent.path != "/", !parent.path.isEmpty {
            if fm.fileExists(atPath: parent.appendingPathComponent(".git").path) {
                found.append(".git (\(parent.lastPathComponent))")
                break
            }
            parent = parent.deletingLastPathComponent()
        }
        return found
    }

    /// A Terminal window in the files' folder, with their paths (quoted for the shell) on the clipboard.
    private static func openTerminal(_ urls: [URL]) {
        guard let first = urls.first,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let folder = FileKind(first) == .folder ? first : first.deletingLastPathComponent()
        let findings = autoRunFindings(in: folder)
        if !findings.isEmpty {
            guard Notice.confirm(title: L("Aprire il Terminale in «%@»?", folder.lastPathComponent),
                                 text: L("La cartella contiene %@. Se viene da un archivio o da un'altra persona, git (anche il prompt della shell) o strumenti come direnv possono eseguire comandi scelti da chi l'ha creata. Aprila solo se ti fidi.", findings.joined(separator: ", ")),
                                 button: L("Apri il Terminale")) else { return }
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " "),
                        forType: .string)
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// One path per line, as they are: no quotes, ready to paste into a field or a message.
    nonisolated static func pathsText(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    private static func copyToClipboard(_ urls: [URL]) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(urls as [NSURL])
    }

    /// The full macOS share menu, opened where the files were dropped.
    static func showPicker(_ urls: [URL]) {
        PickerSession.shared.open(urls, at: NSEvent.mouseLocation)
    }

    /// Invisible panel the share menu hangs from. Before 1.0.2 it was a borderless NSWindow, which can't become key,
    /// and the app is often not active after a drop (macOS may refuse the activation): no window of the app had the
    /// keyboard, so Esc reached no one, and a click in another app never reached the menu (a popover) either. A
    /// non-activating panel takes the keyboard without bringing the app forward.
    final class PickerAnchor: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { PickerSession.shared.finish() }
    }

    /// One open share menu: its anchor window, and what closes it (a choice, Esc, a click outside, the app losing focus).
    @MainActor final class PickerSession: NSObject, @preconcurrency NSSharingServicePickerDelegate {
        static let shared = PickerSession()
        private(set) var anchor: PickerAnchor?
        private var picker: NSSharingServicePicker?
        private var monitors: [Any] = []
        private var observer: NSObjectProtocol?

        func open(_ urls: [URL], at point: NSPoint) {
            finish()
            let anchor = PickerAnchor(contentRect: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            anchor.isOpaque = false
            anchor.backgroundColor = .clear
            anchor.level = .popUpMenu
            anchor.isReleasedWhenClosed = false
            anchor.hidesOnDeactivate = false
            self.anchor = anchor
            anchor.makeKeyAndOrderFront(nil)
            let picker = NSSharingServicePicker(items: urls)
            picker.delegate = self
            self.picker = picker
            picker.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            // A click in another app (global monitors of the mouse need no permission), Esc in this one.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                              handler: { _ in MainActor.assumeIsolated { PickerSession.shared.finish() } }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { PickerSession.shared.finish() }
                return nil
            }) {
                monitors.append(local)
            }
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                              queue: .main) { _ in MainActor.assumeIsolated { PickerSession.shared.finish() } }
        }

        /// Closes the menu (with its anchor) and stops listening. Safe to call more than once.
        func finish(closingMenu: Bool = true) {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            // Closing the anchor alone leaves the menu on screen: it must be closed itself (macOS 13).
            let open = picker
            picker = nil
            open?.delegate = nil
            if closingMenu { open?.close() }
            anchor?.close()
            anchor = nil
        }

        /// Also with `service == nil`: the menu was dismissed without a choice. The menu is already going away by
        /// itself: closing it again could stop the chosen service.
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            finish(closingMenu: false)
        }
    }

    nonisolated private static func installed(_ bundleIDs: [String]) -> URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    // MARK: Copies without location and metadata

    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Condividi", isDirectory: true)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Copies older than an hour: the receiving app has long read them.
    private static func removeOld() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        for run in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? run.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: run) }
        }
    }

    /// The files to share: the originals, or (Settings → Privacy) copies of photos, videos, audio and PDFs
    /// without location, device, dates and other metadata, with the original names. Nil: an error was shown.
    static func prepared(_ urls: [URL]) async -> [URL]? {
        guard Settings.shareWithoutMetadata,
              urls.contains(where: { [.image, .video, .audio, .pdf].contains(FileKind($0)) }) else { return urls }
        removeOld()
        let run = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            var ready: [URL] = []
            for url in urls {
                let kind = FileKind(url)
                guard [.image, .video, .audio, .pdf].contains(kind) else { ready.append(url); continue }
                // One folder per file, so the copy keeps the original name.
                let folder = run.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let outputs = try await FileNaming.$outputOverride.withValue(folder) {
                    try await clean(url, kind: kind)
                }
                guard let out = outputs.first else { throw OpError.failed(L("copia senza metadati")) }
                let named = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension(out.pathExtension)
                try FileManager.default.moveItem(at: out, to: named)
                ready.append(named)
            }
            return ready
        } catch {
            try? FileManager.default.removeItem(at: run)
            Notice.show(title: L("Condivisione annullata"),
                        text: L("%@\n\nNon è stato condiviso nulla. Per inviare i file così come sono, disattiva «Condividi senza posizione e metadati» in Impostazioni → Privacy.",
                                error.localizedDescription))
            return nil
        }
    }

    private static func clean(_ url: URL, kind: FileKind) async throws -> [URL] {
        switch kind {
        case .image:
            let folder = FileNaming.outputOverride   // task-local values don't reach a detached task
            return try await Task.detached {
                try FileNaming.$outputOverride.withValue(folder) {
                    try ImageOps.process(url, quality: 0.95, stripMetadata: true)
                }
            }.value
        case .video: return try await MediaOps.stripMetadata(url)
        case .audio: return try await MediaOps.stripAudioMetadata(url)
        default: return try PDFOps.stripMetadata(url)
        }
    }
}

/// Settings → Ruota → Condividi: apps and macOS sharing services added to the share wheel.
enum ShareTargets {
    struct Target: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case app, service }
        let kind: Kind
        let title: String
        /// Bundle identifier for an app; the title for a service.
        let id: String
    }

    private static let key = "shareTargets"

    static var all: [Target] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let targets = try? JSONDecoder().decode([Target].self, from: data) else { return [] }
            return targets
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func add(_ target: Target) {
        guard !all.contains(where: { $0.kind == target.kind && $0.id == target.id }) else { return }
        all.append(target)
    }

    static func remove(_ target: Target) {
        all.removeAll { $0 == target }
    }

    /// An app chosen in /Applications: only its name and identifier are kept, never a file permission.
    @MainActor static func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = L("Aggiungi")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(Target(kind: .app, title: name, id: id))
    }

    /// The macOS sharing services worth offering in Settings (beyond those already on the wheel).
    @MainActor static func availableServices() -> [String] {
        let tmp = FileManager.default.temporaryDirectory
        // macOS only lists services for files that exist: two empty samples, removed right after.
        let samples = ["esempio.jpg", "esempio.pdf"].map { tmp.appendingPathComponent($0) }
        for sample in samples { FileManager.default.createFile(atPath: sample.path, contents: nil) }
        defer { for sample in samples { try? FileManager.default.removeItem(at: sample) } }
        let builtIn: Set<String> = ["AirDrop", "Messages", "Messaggi", "Mail", "Telegram"]
        var titles: [String] = []
        for service in ShareOps.services(for: samples) where !builtIn.contains(service.title) && !titles.contains(service.title) {
            titles.append(service.title)
        }
        return titles
    }
}
