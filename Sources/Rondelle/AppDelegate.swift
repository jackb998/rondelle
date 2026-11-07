import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var jobsItem: NSMenuItem!
    private var jobsSeparator: NSMenuItem!
    private let jobsMenu = NSMenu()
    private let monitor = DragMonitor()
    private let wheel = WheelController()
    private var pauseItem: NSMenuItem!
    private var undoItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var recentMenu = NSMenu()
    private lazy var services = FinderServices(wheel: wheel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        FolderAccess.restore()
        // Leftovers of earlier runs in the app's temporary folder (copies of the user's files, plain inner ZIPs,
        // spreadsheet entries being read), in case the app was stopped in the middle.
        ShortcutsWorkspace.removeAll()
        ShareOps.removeAll()
        try? FileManager.default.removeItem(at: ArchiveOps.protectedZipWork)
        try? FileManager.default.removeItem(at: SheetOps.readingFolder)
        CrashJournal.cleanUp()           // what a crash or a forced quit left in the user's folders (A5)
        TextRecognition.warmUp()         // prepare the OCR model now, not when the user is waiting
        setUpStatusItem()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.async { TutorialWindow.shared.show() }
        }

        monitor.onBegin = { [wheel] urls, mode in wheel.show(urls: urls, mode: mode) }
        monitor.onModeChange = { [wheel] mode in wheel.setMode(mode) }
        // The drop is delivered on mouse-up too; give performDragOperation a moment before hiding.
        monitor.onEnd = { [wheel] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { wheel.hide() }
        }
        wheel.view.onDrop = { [wheel] action, urls in
            wheel.hide()
            JobRunner.run(action, urls: urls)
        }
        monitor.start()
        Updates.onChange = { [weak self] in self?.showUpdateState() }
        Updates.startAutomaticChecks()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        // No toolTip: macOS can leave a status item's tooltip on screen after the menu opens or the app
        // loses focus. VoiceOver reads the accessibility label instead.
        statusItem.button?.setAccessibilityLabel(L("Rondelle"))

        let menu = NSMenu()
        menu.delegate = self
        jobsItem = menu.addItem(withTitle: L("Lavori in corso"), action: nil, keyEquivalent: "")
        jobsItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        jobsItem.submenu = jobsMenu
        jobsSeparator = NSMenuItem.separator()
        menu.addItem(jobsSeparator)
        undoItem = menu.addItem(withTitle: L("Annulla ultima conversione"), action: #selector(undoLast), keyEquivalent: "")
        undoItem.target = self
        undoItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        let recent = menu.addItem(withTitle: L("Recenti"), action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        recent.submenu = recentMenu
        menu.addItem(.separator())
        pauseItem = menu.addItem(withTitle: L("Metti in pausa"), action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
        menu.addItem(.separator())
        updateItem = menu.addItem(withTitle: "", action: #selector(downloadUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateItem.isHidden = true
        let help = menu.addItem(withTitle: L("Come si usa…"), action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        let settings = menu.addItem(withTitle: L("Impostazioni…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let check = menu.addItem(withTitle: L("Cerca aggiornamenti…"), action: #selector(checkUpdates), keyEquivalent: "")
        check.target = self
        check.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        let about = menu.addItem(withTitle: L("Informazioni su Rondelle"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Esci da Rondelle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// A newer version: an extra menu item and a dot on the icon, never a window while the user is working.
    private func showUpdateState() {
        let name = Updates.availableName
        updateItem.isHidden = name == nil
        updateItem.title = name.map { L("Scarica la versione %@…", $0) } ?? ""
        statusItem.button?.image = Self.menuBarIcon(updateDot: name != nil)
        statusItem.button?.setAccessibilityLabel(name.map { L("È disponibile Rondelle %@", $0) } ?? L("Rondelle"))
    }

    @objc private func checkUpdates() { Updates.checkAndTell() }

    @objc private func downloadUpdate() { Updates.offerDownload() }

    /// The symbol as a monochrome template, tinted by macOS for light and dark menu bars (brand/symbol: same grid of 100).
    static func menuBarIcon(updateDot: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let unit: CGFloat = 18.0 / 84.0
            let point = { (x: CGFloat, y: CGFloat) in NSPoint(x: (x - 8) * unit, y: (y - 8) * unit) }
            NSColor.black.set()
            let ring = NSBezierPath()
            ring.appendArc(withCenter: point(50, 50), radius: 40 * unit, startAngle: 75, endAngle: 375, clockwise: false)
            ring.appendArc(withCenter: point(50, 50), radius: 20 * unit, startAngle: 375, endAngle: 75, clockwise: true)
            ring.close()
            ring.fill()
            let center = point(78.284, 78.284)
            let r = 10 * unit
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
            if updateDot {   // a badge with a clear edge, so it stands apart from the ring
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 10.5, y: -1.5, width: 9, height: 9)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Rondelle"
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu !== recentMenu, menu !== jobsMenu else { return }
        updateJobsMenu()
        pauseItem.state = Settings.paused ? .on : .off
        statusItem.button?.appearsDisabled = Settings.paused

        let entries = JobHistory.entries
        if let last = entries.first {
            let own = last.ownFiles.count
            undoItem.title = L("Annulla «%@» (%@ file nel Cestino)", last.title, own)
            undoItem.isEnabled = own > 0
        } else {
            undoItem.title = L("Annulla ultima conversione")
            undoItem.isEnabled = false
        }

        recentMenu.removeAllItems()
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        for (i, entry) in entries.enumerated() {
            let names = entry.urls.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
                + (entry.urls.count > 2 ? " +\(entry.urls.count - 2)" : "")
            let item = recentMenu.addItem(withTitle: "\(entry.title): \(names)", action: #selector(revealRecent(_:)),
                                          keyEquivalent: "")
            item.target = self
            item.tag = i
            item.toolTip = formatter.localizedString(for: entry.date, relativeTo: Date())
            item.isEnabled = !entry.existing.isEmpty
        }
        if entries.isEmpty {
            recentMenu.addItem(withTitle: L("Nessun lavoro recente"), action: nil, keyEquivalent: "").isEnabled = false
        } else {
            recentMenu.addItem(.separator())
            recentMenu.addItem(withTitle: L("Svuota elenco"), action: #selector(clearRecent), keyEquivalent: "").target = self
        }
    }

    /// Hidden with no jobs running. Each entry stops that job, and the last one all of them.
    private func updateJobsMenu() {
        let jobs = JobCenter.jobs
        jobsItem.isHidden = jobs.isEmpty
        jobsSeparator.isHidden = jobs.isEmpty
        jobsItem.title = L("Lavori in corso: %@", jobs.count)
        jobsMenu.removeAllItems()
        for (i, job) in jobs.enumerated() {
            let item = jobsMenu.addItem(withTitle: L("Annulla «%@»: %@", job.title, job.detail), action: #selector(cancelJob(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
        }
        guard jobs.count > 1 else { return }
        jobsMenu.addItem(.separator())
        jobsMenu.addItem(withTitle: L("Annulla tutti"), action: #selector(cancelAllJobs), keyEquivalent: "").target = self
    }

    @objc private func cancelJob(_ sender: NSMenuItem) {
        // The list may have changed while the menu was open: the entry may no longer be the job it showed.
        guard JobCenter.jobs.indices.contains(sender.tag),
              sender.title.contains(JobCenter.jobs[sender.tag].detail) else { return }
        JobCenter.jobs[sender.tag].cancel()
    }

    @objc private func cancelAllJobs() { JobCenter.cancelAll() }

    @objc private func undoLast() { JobHistory.undoLast() }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        let entries = JobHistory.entries
        guard entries.indices.contains(sender.tag) else { return }
        JobHistory.reveal(entries[sender.tag])
    }

    @objc private func clearRecent() { JobHistory.clear() }

    @objc private func showSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func togglePause() {
        Settings.paused.toggle()
        statusItem.button?.appearsDisabled = Settings.paused
    }

    @objc private func showAbout() {
        AboutWindow.show()
    }

    @objc private func showHelp() {
        TutorialWindow.shared.show()
    }
}
