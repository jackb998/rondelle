import AppKit

/// Floating card showing progress for one job, styled like a macOS notification
/// (Liquid Glass on macOS 26+, a blurred HUD material before).
@MainActor
final class ProgressPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let titleLabel: NSTextField
    private let icon = ResultIcon(image: NSApp.applicationIconImage ?? NSImage())
    private let bar = NSProgressIndicator()
    private let cancelButton = FirstClickButton(title: L("Annulla"), target: nil, action: nil)
    /// Called when the user presses «Annulla».
    var onCancel: (() -> Void)?

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        let size = NSSize(width: 340, height: 74)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 38).isActive = true

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = true

        let text = NSStackView(views: [titleLabel, label, bar])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.controlSize = .small
        cancelButton.bezelStyle = .rounded
        let row = NSStackView(views: [icon, text, cancelButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: size.width - 14 - 38 - 12 - 16 - 70 - 12).isActive = true

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = row
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 18
            blur.layer?.masksToBounds = true
            blur.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: blur.leadingAnchor), row.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                row.topAnchor.constraint(equalTo: blur.topAnchor), row.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            background = blur
        }
        background.frame = NSRect(origin: .zero, size: size)
        panel.contentView = background
    }

    /// Its place in the column of cards, under the menu bar. A card past the bottom of the screen waits, hidden.
    func show(position: Int) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let top = screen.maxY - 12 - CGFloat(position) * (panel.frame.height + 8)
        guard top - panel.frame.height >= screen.minY else { panel.orderOut(nil); return }
        panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 16, y: top))
        panel.orderFrontRegardless()
        bar.startAnimation(nil)
    }

    func waiting() { label.stringValue = L("In coda…") }

    /// Under the pointer: the moment to keep showing it.
    var isHovered: Bool { panel.frame.contains(NSEvent.mouseLocation) }

    /// The job is done: the card now shows the result, whose icon can be dragged anywhere, and offers to undo it.
    func showResult(title: String, detail: String, files: [URL], undo: (() -> Void)?) {
        titleLabel.stringValue = title
        label.stringValue = detail
        bar.stopAnimation(nil)
        bar.isHidden = true
        if !files.isEmpty { icon.files = files }
        onCancel = undo
        cancelButton.isHidden = undo == nil
        cancelButton.isEnabled = true
        finished = true
    }

    func update(done: Int, total: Int, current: String) {
        label.stringValue = total > 1 ? L("%@ di %@ — %@", done + 1, total, current) : current
        if total > 1 {
            bar.isIndeterminate = false
            bar.maxValue = Double(total)
            bar.doubleValue = Double(done)
        }
    }

    func close() { panel.close() }

    private var finished = false

    @objc private func cancel() {
        cancelButton.isEnabled = false
        if !finished { label.stringValue = L("Annullamento…") }
        onCancel?()
    }
}

/// The progress card never becomes the key window: its button must work on the first click.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The icon of a progress card; once there is a result, it can be dragged into any app or folder.
private final class ResultIcon: NSImageView, NSDraggingSource {
    var files: [URL] = [] {
        didSet { image = files.count == 1 ? NSWorkspace.shared.icon(forFile: files[0].path) : NSWorkspace.shared.icon(for: .folder) }
    }

    convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard !files.isEmpty else { return }
        beginDraggingSession(with: files.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// One job, from the drop to its end: queued or running, reachable from its card and the menu bar.
@MainActor
final class RunningJob {
    let title: String
    let detail: String
    let progress: ProgressPanel
    fileprivate var cancelled = false
    fileprivate var task: Task<[URL], Error>?
    /// It has a place among those running, to give back at its end.
    fileprivate var holdsPlace = false

    fileprivate init(title: String, detail: String) {
        self.title = title
        self.detail = detail
        progress = ProgressPanel(title: title)
    }

    func cancel() {
        cancelled = true
        task?.cancel()   // the page loops check Task.isCancelled; external tools are stopped too
        JobCenter.leaveQueue(self)
    }
}

/// Several jobs at the same time, in a column of cards. A few run at once, the others wait for their turn: each job is
/// bounded on its own (memory above all), so the number of jobs is what bounds them together.
@MainActor
enum JobCenter {
    static let maxRunning = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    /// Queued or running.
    private(set) static var jobs: [RunningJob] = []
    private static var cards: [ProgressPanel] = []
    private static var running = 0
    private static var queue: [(job: RunningJob, resume: CheckedContinuation<Void, Never>)] = []
    #if DEBUG
    private(set) static var mostRunning = 0
    #endif

    fileprivate static func add(title: String, detail: String) -> RunningJob {
        let job = RunningJob(title: title, detail: detail)
        job.progress.onCancel = { [weak job] in job?.cancel() }
        jobs.append(job)
        cards.append(job.progress)
        arrange()
        return job
    }

    private static func arrange() {
        for (position, card) in cards.enumerated() { card.show(position: position) }
    }

    /// Waits until the job may start. Returns at once if it was cancelled while waiting.
    fileprivate static func waitForTurn(_ job: RunningJob) async {
        guard !job.cancelled else { return }
        if running >= maxRunning {
            job.progress.waiting()
            await withCheckedContinuation { queue.append((job, $0)) }
            return
        }
        running += 1
        job.holdsPlace = true
        #if DEBUG
        mostRunning = max(mostRunning, running)
        #endif
    }

    fileprivate static func leaveQueue(_ job: RunningJob) {
        guard let index = queue.firstIndex(where: { $0.job === job }) else { return }
        queue.remove(at: index).resume.resume()
    }

    /// The job is over. Its card stays only if it has a result to show.
    fileprivate static func end(_ job: RunningJob, keepingCard: Bool) {
        jobs.removeAll { $0 === job }
        if job.holdsPlace {
            if queue.isEmpty {
                running -= 1
            } else {
                // The place goes to the first in line: `running` doesn't change.
                let next = queue.removeFirst()
                next.job.holdsPlace = true
                next.resume.resume()
            }
        }
        if !keepingCard { close(job.progress) }
    }

    fileprivate static func close(_ card: ProgressPanel) {
        card.close()
        cards.removeAll { $0 === card }
        arrange()
    }

    fileprivate static func closeLater(_ card: ProgressPanel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                guard cards.contains(where: { $0 === card }) else { return }
                if card.isHovered { closeLater(card) } else { close(card) }
            }
        }
    }

    static func cancelAll() { jobs.forEach { $0.cancel() } }
}

@MainActor
enum JobRunner {
    /// - Parameter point: where the files were dropped; the completion animation plays there.
    static func run(_ action: WheelAction, urls: [URL], at point: NSPoint = NSEvent.mouseLocation) {
        // Pipes, sockets and devices stop here, before anything can wait on them.
        do {
            try SafeFile.refuseSpecial(urls)
        } catch {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = L("%@: un file non è stato elaborato", action.title)
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        if case .share(let send) = action.work {
            send(urls)
            return
        }
        // A group dropped on: its options panel, next to the files.
        if case .group(let members) = action.work {
            OptionsPanel.show(title: action.title, members, urls: urls, at: point)
            return
        }
        // Sandbox: the output folders (next to the originals, or the one chosen in Settings) must be allowed first.
        // (Not for what only goes to the clipboard, nor for «Metadati → Leggi», which only shows them.)
        let toClipboard = ["Copia testo", "SHA-256"].contains(action.key)
        guard toClipboard || action.key == "Leggi" || FolderAccess.ensureWritable(urls.map(FileNaming.directory(for:))) else { return }

        // Window actions take over from here: the user finishes the job in the window.
        if case .window(let open) = action.work {
            open(urls)
            return
        }

        // Questions come before the progress window, and cancelling skips the job.
        var work = action.work
        // One file: the hint it carries, if any. Several share one answer, so no single hint belongs to the question.
        let hint = urls.count == 1 ? action.hintReader?(urls[0]) : nil
        if case .asking(let question, let defaultValue, let kind, let ask) = work {
            let answer = kind == .text ? Notice.ask(question, defaultValue: defaultValue)
                : Notice.askPassword(PasswordHint.question(question, hint: hint), twice: kind == .newPassword, withHint: kind == .newPassword)
            guard let answer else { return }
            work = .perFile { try await ask($0, answer) }
        }
        if case .askingAll(let question, let kind, let ask) = work {
            let answer = kind == .text ? Notice.ask(question, defaultValue: "")
                : Notice.askPassword(question, twice: kind == .newPassword, withHint: kind == .newPassword)
            guard let answer else { return }
            work = .batch { try await ask($0, answer) }
        }

        let job = JobCenter.add(title: action.title, detail: urls.count == 1 ? urls[0].lastPathComponent : L("%@ file", urls.count))
        let progress = job.progress
        let control = job

        Task { @MainActor in
            var outputs: [URL] = []
            var errors: [String] = []
            await JobCenter.waitForTurn(job)

            switch work {
            case .asking, .askingAll, .window, .share, .group:
                break
            case .perFile(let work):
                let files = FileNaming.sortedNaturally(urls)
                for (i, url) in files.enumerated() {
                    if control.cancelled { break }
                    progress.update(done: i, total: files.count, current: url.lastPathComponent)
                    let task = Task.detached(priority: .userInitiated) { try await FileNaming.cleaningUpOnFailure { try await work(url) } }
                    control.task = task
                    do {
                        outputs += try await task.value
                    } catch where control.cancelled || error is CancellationError {
                        break
                    } catch {
                        errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            case .batch(let work):
                if control.cancelled { break }
                progress.update(done: 0, total: 1, current: urls.count == 1 ? urls[0].lastPathComponent : L("%@ file", urls.count))
                let task = Task.detached(priority: .userInitiated) { try await FileNaming.cleaningUpOnFailure { try await work(urls) } }
                control.task = task
                do {
                    outputs = try await task.value
                } catch where control.cancelled || error is CancellationError {
                    // cancelled by the user: nothing to report
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            let copied = toClipboard && outputs.isEmpty && errors.isEmpty && !control.cancelled
            let showsResult = (copied || !outputs.isEmpty) && errors.isEmpty && !control.cancelled && Settings.showResultCard
            JobCenter.end(job, keepingCard: showsResult)
            if copied {
                NSSound(named: "Pop")?.play()
                if showsResult {
                    progress.showResult(title: L("Fatto · %@", action.title), detail: action.key == "SHA-256" ? L("Impronta negli appunti") : L("Testo negli appunti"), files: [], undo: nil)
                    JobCenter.closeLater(progress)
                }
            }
            if !outputs.isEmpty {
                JobHistory.record(action.title, outputs: outputs)
                Settings.reveal(outputs)
                if showsResult {
                    let saved = WheelAction.makesSmaller(action.key) ? FileHints.savings(from: urls, to: outputs) : nil
                    let name = outputs.count == 1 ? outputs[0].lastPathComponent : L("%@ file", outputs.count)
                    let paths = outputs.map(\.path)
                    progress.showResult(title: L("Fatto · %@", action.title), detail: saved ?? name, files: outputs) {
                        JobHistory.undo(paths: paths)
                        JobCenter.close(progress)
                    }
                    JobCenter.closeLater(progress)
                }
                if Settings.playSound { NSSound(named: "Glass")?.play() }
                if errors.isEmpty, !control.cancelled { CompletionAnimation.play(at: point) }
            }
            if !errors.isEmpty {
                NSSound.beep()
                let alert = NSAlert()
                alert.messageText = errors.count == 1
                    ? L("%@: un file non è stato elaborato", action.title)
                    : L("%@: %@ file non sono stati elaborati", action.title, errors.count)
                alert.informativeText = errors.prefix(8).joined(separator: "\n")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}
