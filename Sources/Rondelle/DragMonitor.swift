import AppKit

/// Detects "the user is dragging files while holding Shift" (or the key chosen in Settings) anywhere on screen.
///
/// Polls instead of using global event monitors, so it needs no Accessibility or Input Monitoring
/// permission: the mouse button and modifier state are public, and every drag in macOS writes
/// to the shared drag pasteboard, whose change count tells us a new drag has started.
@MainActor
final class DragMonitor {
    var onBegin: (([URL], WheelMode) -> Void)?
    var onModeChange: ((WheelMode) -> Void)?
    var onEnd: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var baseline = 0
    private var wasPressed = false
    private var active = false
    private var mode = WheelMode.convert
    private var heldFlags: NSEvent.ModifierFlags = []

    func start() {
        baseline = dragPasteboard.changeCount
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        defer { wasPressed = pressed }

        guard pressed else {
            if wasPressed {
                baseline = dragPasteboard.changeCount
                if active {
                    active = false
                    onEnd?()
                }
            }
            return
        }

        let flags = NSEvent.modifierFlags
        let held = Settings.mode(for: flags)

        if active {
            // Only a key press switches (Settings.switchMode): the keys can be let go and the wheel stays.
            defer { heldFlags = flags }
            if let next = Settings.switchMode(from: heldFlags, to: flags), next != mode {
                mode = next
                onModeChange?(next)
            }
            return
        }

        // Only touch the pasteboard (an IPC call) while a wheel's keys are held during a press.
        guard !Settings.paused, let current = held, dragPasteboard.changeCount != baseline else { return }
        let urls = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        active = true
        mode = current
        heldFlags = flags
        onBegin?(urls, current)
    }
}
