import AppKit
import AVFoundation
import AVKit

/// Trim a video or audio file with the system trimming bar (the same one as QuickTime Player).
@MainActor
enum TrimWindow {
    private static var open: [NSWindow] = []

    static func open(_ urls: [URL]) {
        for url in urls.prefix(4) { show(url) }
    }

    private static func show(_ url: URL) {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = false

        let isAudio = FileKind(url) == .audio
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: isAudio ? 200 : 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("Taglia — %@", url.lastPathComponent)
        window.titlebarAppearsTransparent = true
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.center()
        open.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The trimming bar needs the item to be ready.
        Task { @MainActor in
            for _ in 0..<50 where !playerView.canBeginTrimming {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard playerView.canBeginTrimming else {
                Notice.show(title: L("Impossibile tagliare"), text: L("«%@» non può essere tagliato.", url.lastPathComponent))
                close(window)
                return
            }
            playerView.beginTrimming { result in
                MainActor.assumeIsolated {
                    guard result == .okButton, let item = player.currentItem else { close(window); return }
                    let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                    let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                    player.pause()
                    close(window)
                    export(url, range: CMTimeRange(start: start, end: end))
                }
            }
        }
    }

    private static func close(_ window: NSWindow) {
        (window.contentView as? AVPlayerView)?.player?.pause()
        window.close()
        open.removeAll { $0 === window }
    }

    private static func export(_ url: URL, range: CMTimeRange) {
        let point = NSEvent.mouseLocation
        Task { @MainActor in
            do {
                let outputs = try await MediaOps.trim(url, range: range)
                JobHistory.record("Taglia", outputs: outputs)
                Settings.reveal(outputs)
                if Settings.playSound { NSSound(named: "Glass")?.play() }
                CompletionAnimation.play(at: point)
            } catch {
                Notice.show(title: L("Taglio non riuscito"), text: error.localizedDescription)
            }
        }
    }
}
