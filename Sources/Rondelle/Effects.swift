import AppKit
import QuartzCore

// MARK: Real-size preview

/// A blank wheel at its real on-screen size, shown beside the Settings window while choosing the size.
@MainActor
final class SizePreview {
    static let shared = SizePreview()

    private let panel: NSPanel
    private let view = WheelView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
    private var hideWork: DispatchWorkItem?
    var isVisible: Bool { panel.isVisible }

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.contentView = view
        view.unregisterDraggedTypes()
        view.blank = true
        view.actions = (0..<8).map { _ in WheelAction.each("") { _ in [] } }
    }

    /// Shows (or resizes) the preview; with `autoHide`, it disappears a moment after the last call.
    func show(autoHide: Bool = false) {
        hideWork?.cancel()
        let side = WheelController.size(for: 8)
        let frame = placement(side: side)
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        if autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    /// Beside the Settings window (right, else left), else in the middle of the screen.
    private func placement(side: CGFloat) -> NSRect {
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.midX - side / 2, y: screen.midY - side / 2)
        if let settings = NSApp.windows.first(where: { $0.title == L("Impostazioni di Rondelle") && $0.isVisible })?.frame {
            let y = min(max(settings.midY - side / 2, screen.minY), screen.maxY - side)
            if settings.maxX + 24 + side <= screen.maxX {
                origin = NSPoint(x: settings.maxX + 24, y: y)
            } else if settings.minX - 24 - side >= screen.minX {
                origin = NSPoint(x: settings.minX - 24 - side, y: y)
            }
        }
        return NSRect(origin: origin, size: NSSize(width: side, height: side))
    }
}

// MARK: Completion animation

enum CompletionStyle: String, CaseIterable, Identifiable {
    case none, ring, circle
    var id: String { rawValue }
    var label: String { ["none": L("Nessuna"), "ring": L("Anello che si apre"), "circle": L("Cerchio che si completa")][rawValue]! }
}

/// The app's symbol where the job was started, then it fades away. «Anello che si apre»: a closed ring opens and its dot
/// leaves through the gap. «Cerchio che si completa»: the ring draws itself like a progress bar reaching the end, the dot
/// jumps into place and a green wave goes out.
@MainActor
enum CompletionAnimation {
    private static var panels: [NSPanel] = []

    static let black = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.078, alpha: 0.94).cgColor
    static let paper = NSColor(srgbRed: 0.961, green: 0.949, blue: 0.918, alpha: 1).cgColor
    static let green = NSColor(srgbRed: 0.169, green: 0.714, blue: 0.451, alpha: 1).cgColor

    static func play(at point: NSPoint = NSEvent.mouseLocation, style: CompletionStyle = Settings.completionStyle) {
        guard style != .none else { return }
        let side: CGFloat = 180
        let panel = NSPanel(contentRect: NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        panel.contentView = view
        panel.orderFrontRegardless()
        panels.append(panel)

        let root = view.layer!
        let center = CGPoint(x: side / 2, y: side / 2)
        // "Reduce motion" in Accessibility: the open symbol and the check mark, nothing moves.
        let duration = draw(style, on: root, center: center,
                            moving: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, start: CACurrentMediaTime())

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panels.removeAll { $0 === panel }
                }
            }
        }
    }

    /// Adds the animation's layers to `root`, timed from `start` (the layers' clock); returns how long it lasts.
    static func draw(_ style: CompletionStyle, on root: CALayer, center: CGPoint, moving: Bool, start: CFTimeInterval) -> CFTimeInterval {
        switch style {
        case .none: 0
        case .ring: playRing(on: root, center: center, moving: moving, start: start)
        case .circle: playCircle(on: root, center: center, moving: moving, start: start)
        }
    }

    // MARK: Ring

    /// Geometry of the symbol (brand/symbol), at 0.95 of its grid: ring from radius 19 to 38, a gap of 60° centred on 45°.
    private static func playRing(on root: CALayer, center: CGPoint, moving: Bool, start: CFTimeInterval) -> CFTimeInterval {
        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: CGRect(x: center.x - 54, y: center.y - 54, width: 108, height: 108), transform: nil)
        disc.fillColor = black
        root.addSublayer(disc)

        let open: CGFloat = 300.0 / 360.0
        let ring = CAShapeLayer()
        let path = CGMutablePath()
        path.addArc(center: center, radius: 28.5, startAngle: .pi * 75 / 180, endAngle: .pi * 435 / 180, clockwise: false)
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = paper
        ring.lineWidth = 19
        ring.strokeEnd = open
        root.addSublayer(ring)

        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -9.5, y: -9.5, width: 19, height: 19), transform: nil)
        dot.fillColor = green
        let diagonal = cos(CGFloat.pi / 4)
        dot.position = CGPoint(x: center.x + 38 * diagonal, y: center.y + 38 * diagonal)
        root.addSublayer(dot)

        guard moving else {
            addCheck(to: root, center: center, delay: 0, start: start)
            return 1.0
        }
        let opening = CABasicAnimation(keyPath: "strokeEnd")
        opening.fromValue = 1
        opening.toValue = open
        opening.beginTime = start + 0.1
        opening.duration = 0.35
        opening.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        opening.fillMode = .backwards
        ring.add(opening, forKey: "open")

        let leaving = CAKeyframeAnimation(keyPath: "position")
        leaving.values = [28.5, 42, 38].map { NSValue(point: NSPoint(x: center.x + $0 * diagonal, y: center.y + $0 * diagonal)) }
        leaving.keyTimes = [0, 0.7, 1]
        let growing = CABasicAnimation(keyPath: "transform.scale")
        growing.fromValue = 0.2
        growing.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [leaving, growing]
        group.beginTime = start + 0.3
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .backwards
        dot.add(group, forKey: "leave")
        // Hidden until it starts to leave: the gap isn't open yet.
        let hidden = CABasicAnimation(keyPath: "opacity")
        hidden.fromValue = 0
        hidden.toValue = 0
        hidden.beginTime = start
        hidden.duration = 0.3
        dot.add(hidden, forKey: "wait")

        addCheck(to: root, center: center, delay: 0.7, start: start)
        return 1.4
    }

    // MARK: Circle

    /// The same symbol; the ring is drawn from the top of the gap all the way round, as a progress bar that finishes.
    /// Shapes change through their paths, not by scaling: so `--animation-frames` draws them as they move.
    private static func playCircle(on root: CALayer, center: CGPoint, moving: Bool, start: CFTimeInterval) -> CFTimeInterval {
        let circle = { (r: CGFloat, c: CGPoint) in CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil) }
        let disc = CAShapeLayer()
        disc.path = circle(54, center)
        disc.fillColor = black
        root.addSublayer(disc)

        let wave = CAShapeLayer()
        wave.path = circle(54, center)
        wave.fillColor = nil
        wave.strokeColor = green
        wave.lineWidth = 3
        wave.opacity = 0
        root.insertSublayer(wave, below: disc)

        let ring = CAShapeLayer()
        let path = CGMutablePath()
        path.addArc(center: center, radius: 28.5, startAngle: .pi * 75 / 180, endAngle: .pi * 375 / 180, clockwise: false)
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = paper
        ring.lineWidth = 19
        root.addSublayer(ring)

        let diagonal = cos(CGFloat.pi / 4)
        let spot = CGPoint(x: center.x + 38 * diagonal, y: center.y + 38 * diagonal)
        let dot = CAShapeLayer()
        dot.path = circle(9.5, spot)
        dot.fillColor = green
        root.addSublayer(dot)

        guard moving else {
            addCheck(to: root, center: center, delay: 0, start: start)
            return 1.0
        }
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = circle(46, center)
        grow.toValue = circle(54, center)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        let appear = CAAnimationGroup()
        appear.animations = [grow, fadeIn]
        appear.beginTime = start
        appear.duration = 0.2
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        appear.fillMode = .backwards
        disc.add(appear, forKey: "appear")

        let drawing = CABasicAnimation(keyPath: "strokeEnd")
        drawing.fromValue = 0
        drawing.toValue = 1
        drawing.beginTime = start + 0.1
        drawing.duration = 0.5
        drawing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drawing.fillMode = .backwards
        ring.add(drawing, forKey: "draw")

        // The dot jumps into place just as the ring reaches the gap.
        let jump = CAKeyframeAnimation(keyPath: "path")
        jump.values = [0.01, 13, 8.5, 9.5].map { circle($0, spot) }
        jump.keyTimes = [0, 0.5, 0.8, 1]
        jump.beginTime = start + 0.55
        jump.duration = 0.35
        jump.fillMode = .backwards
        dot.add(jump, forKey: "jump")

        let out = CABasicAnimation(keyPath: "path")
        out.fromValue = circle(54, center)
        out.toValue = circle(84, center)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let waveGroup = CAAnimationGroup()
        waveGroup.animations = [out, fade]
        waveGroup.beginTime = start + 0.6
        waveGroup.duration = 0.6
        waveGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wave.add(waveGroup, forKey: "wave")

        addCheck(to: root, center: center, delay: 0.8, start: start)
        return 1.5
    }

    // MARK: Pieces

    /// A white check mark that draws itself on a green badge.
    private static func addCheck(to root: CALayer, center: CGPoint, delay: CFTimeInterval, start: CFTimeInterval) {
        let badge = CAShapeLayer()
        let r: CGFloat = 15
        badge.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        badge.position = CGPoint(x: center.x + 30, y: center.y - 30)
        badge.path = CGPath(ellipseIn: badge.bounds, transform: nil)
        badge.fillColor = NSColor.systemGreen.cgColor
        badge.strokeColor = NSColor.white.cgColor
        badge.lineWidth = 2
        badge.opacity = 0

        let check = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r * 0.55, y: r * 1.0))
        path.addLine(to: CGPoint(x: r * 0.88, y: r * 0.68))
        path.addLine(to: CGPoint(x: r * 1.45, y: r * 1.3))
        check.path = path
        check.strokeColor = NSColor.white.cgColor
        check.fillColor = nil
        check.lineWidth = 3
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeEnd = 0
        badge.addSublayer(check)
        root.addSublayer(badge)

        let appear = CAKeyframeAnimation(keyPath: "transform.scale")
        appear.values = [0.3, 1.15, 1]
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [appear, show]
        group.beginTime = start + delay
        group.duration = 0.3
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        badge.add(group, forKey: "appear")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = start + delay + 0.2
        draw.duration = 0.3
        draw.fillMode = .forwards
        draw.isRemovedOnCompletion = false
        check.add(draw, forKey: "draw")
    }
}
