import AppKit

/// Colours of the wheel for the current theme and opacity setting.
struct WheelPalette {
    let background: NSColor
    let border: NSColor
    let segment: NSColor
    let hub: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let accent: NSColor
    /// Solid pieces of the wheel when no glass sits behind, with their brand colours (black or paper).
    let tile: NSColor
    let hubFill: NSColor
    let crust: NSColor
    let glassEdge: NSColor

    /// How much the glass is tinted, from «Tinta del vetro»: light enough to see what's behind it.
    static var glassTint: CGFloat { Settings.wheelOpacity * 0.28 }

    /// Text on the accent colour: black or white, whichever reads better on it.
    var onAccent: NSColor {
        guard let c = accent.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.36 ? NSColor(hex: "#111214") ?? .black : .white
    }

    static var isDark: Bool {
        switch Settings.theme {
        case .dark: return true
        case .light: return false
        case .auto: return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        }
    }

    static var current: WheelPalette {
        let dark = isDark
        let opacity = Settings.wheelOpacity
        return dark
            ? WheelPalette(background: NSColor(white: 0.08, alpha: opacity), border: NSColor(white: 1, alpha: 0.12),
                           segment: NSColor(white: 1, alpha: 0.07), hub: NSColor(white: 1, alpha: 0.06),
                           text: NSColor(white: 1, alpha: 0.9), secondaryText: NSColor(white: 1, alpha: 0.55),
                           accent: Settings.accentColor,
                           tile: (NSColor(hex: "#111214") ?? .black).withAlphaComponent(opacity),
                           hubFill: (NSColor(hex: "#1B1C20") ?? .black).withAlphaComponent(opacity),
                           crust: NSColor(white: 1, alpha: 0.13), glassEdge: NSColor(white: 1, alpha: 0.28))
            : WheelPalette(background: NSColor(white: 0.97, alpha: opacity), border: NSColor(white: 0, alpha: 0.12),
                           segment: NSColor(white: 0, alpha: 0.05), hub: NSColor(white: 0, alpha: 0.04),
                           text: NSColor(white: 0, alpha: 0.82), secondaryText: NSColor(white: 0, alpha: 0.5),
                           accent: Settings.accentColor,
                           tile: (NSColor(hex: "#F5F2EA") ?? .white).withAlphaComponent(opacity),
                           hubFill: (NSColor(hex: "#EAE6DA") ?? .white).withAlphaComponent(opacity),
                           crust: NSColor(white: 0, alpha: 0.1), glassEdge: NSColor(white: 0, alpha: 0.22))
    }
}

/// The radial menu: a ring of segments around the pointer that accepts the dragged files.
/// Everything is proportional to the view's size, so the "wheel size" setting simply resizes the view.
final class WheelView: NSView {
    var actions: [WheelAction] = [] {
        didSet { highlighted = nil; highlightedChild = nil; openGroup = nil; lifts = [:]; needsDisplay = true }
    }
    var mode = WheelMode.convert { didSet { needsDisplay = true } }
    var fileCount = 0
    var onDrop: ((WheelAction, [URL]) -> Void)?
    /// The dragged files' format, in a few words, under «1 file» while nothing is under the pointer.
    var filesHint: String? { didSet { needsDisplay = true } }
    /// Scrolling over the wheel: the next wheel (true) or the previous one.
    var onScrollMode: ((Bool) -> Void)?
    private var scrolled: CGFloat = 0
    private var lastModeSwitch = Date.distantPast
    /// Draws one segment as selected (used by the settings preview).
    var previewHighlight: Int? { didSet { highlighted = previewHighlight } }
    /// Segments only, no text or icons (the real-size preview in Settings).
    var blank = false { didSet { needsDisplay = true } }
    /// A Liquid Glass view sits behind: don't paint the disc, just the segments on top of the glass.
    var glassBackground = false { didSet { needsDisplay = true } }
    /// Settings → Ruota → Stile: whether groups open a second ring. Previews keep `.full` behaviour (no ring).
    var style = WheelStyle.full
    /// Points kept free around the disc for the second ring (0 when there is none).
    var ringSpace: CGFloat = 0 { didSet { needsDisplay = true } }

    override func scrollWheel(with event: NSEvent) {
        scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
        guard abs(scrolled) > 24, Date().timeIntervalSince(lastModeSwitch) > 0.3 else { return }
        onScrollMode?(scrolled > 0)
        scrolled = 0
        lastModeSwitch = Date()
    }

    /// The round background, inside a wheel view of the given bounds (minus the space of the second ring).
    static func discRect(in bounds: NSRect, ring: CGFloat = 0) -> NSRect {
        let radius = min(bounds.width, bounds.height) / 2 - 4 - ring
        return NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
    }

    /// The Liquid Glass disc: just around the pieces, so that the chosen one comes out of it.
    static func glassRect(in bounds: NSRect, ring: CGFloat = 0) -> NSRect {
        let radius = (min(bounds.width, bounds.height) / 2 - 10 - ring) * 165 / 179 + 3
        return NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
    }

    private var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            needsDisplay = true
            if !animates { lifts = highlighted.map { [$0: 1] } ?? [:] }
            startMotion()
            // Only the real wheel on screen: not Settings' preview or the snapshots.
            if highlighted != nil, window is WheelPanel { HoverFeedback.play() }
        }
    }
    /// The group whose variants are shown on the second ring, and the variant under the pointer.
    private var openGroup: Int?
    private var highlightedChild: Int? {
        didSet {
            guard oldValue != highlightedChild else { return }
            needsDisplay = true
            if highlightedChild != nil, window is WheelPanel { HoverFeedback.play() }
        }
    }

    private func members(of index: Int?) -> [WheelAction]? {
        guard let index, actions.indices.contains(index), case .group(let members) = actions[index].work else { return nil }
        return members
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    /// The chosen piece moves out by `lift`, so the pieces stop that much before the edge of the view.
    private var edge: CGFloat { min(bounds.width, bounds.height) / 2 - 10 - ringSpace }
    private var outer: CGFloat { edge * 165 / 179 }
    private var lift: CGFloat { edge - outer }
    private var inner: CGFloat { outer * (shape == .pizza ? 0.31 : 0.38) }
    private var shape: WheelShape {
        #if DEBUG
        if let debugShape { return debugShape }
        if let env = ProcessInfo.processInfo.environment["RONDELLE_SHAPE"], let shape = WheelShape(rawValue: env) { return shape }
        #endif
        return Settings.wheelShape
    }
    #if DEBUG
    var debugShape: WheelShape?
    #endif
    /// 1 at the original 165 pt radius; fonts and icons scale with it.
    private var unit: CGFloat { outer / 165 }
    private var segment: CGFloat { 2 * .pi / CGFloat(max(actions.count, 1)) }

    /// Segment under `point`; segment 0 is centred at 12 o'clock, then clockwise.
    private func index(at point: NSPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy)
        guard !actions.isEmpty, r >= inner, r <= edge + (ringSpace > 0 ? 3 : 10) else { return nil }
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + segment / 2) / segment) % actions.count
    }

    // MARK: Second ring

    private var ringInner: CGFloat { edge + 6 * unit }
    private var ringOuter: CGFloat { edge + ringSpace - 2 }
    /// Angle of one variant: about the same arc length as a main segment's label, whatever the radius.
    private var childAngle: CGFloat { min(74 * unit / ((ringInner + ringOuter) / 2), 0.9) }

    /// Centre angle of variant `c` of the group at main segment `g`: the variants fan out around the group.
    private func childMid(_ c: Int, of count: Int, group g: Int) -> CGFloat {
        CGFloat(g) * segment + (CGFloat(c) - CGFloat(count - 1) / 2) * childAngle
    }

    private func childIndex(at point: NSPoint) -> Int? {
        guard let g = openGroup, let members = members(of: g) else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy)
        guard r > edge + 1, r <= ringOuter + 12 else { return nil }
        let angle = atan2(dx, dy)
        for c in members.indices {
            var d = angle - childMid(c, of: members.count, group: g)
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            if abs(d) <= childAngle / 2 { return c }
        }
        return nil
    }

    /// Hover logic shared by drags and click mode: main segment, then the ring of an open group.
    private func track(at point: NSPoint) {
        if openGroup != nil, let c = childIndex(at: point) {
            highlightedChild = c
            return
        }
        highlightedChild = nil
        let i = index(at: point)
        if i == nil, openGroup != nil, hypot(point.x - center.x, point.y - center.y) > edge {
            return   // between the wheel and the ring: keep the group open
        }
        highlighted = i
        let open = style.showsRing && members(of: i) != nil ? i : nil
        if open != openGroup { openGroup = open; needsDisplay = true }
    }

    // MARK: Motion

    /// A CADisplayLink on macOS 14+ (in step with the screen, 120 Hz on ProMotion), a timer before.
    private var motion: AnyObject?
    private var lastTick: CFTimeInterval = 0
    private var openingStart: CFTimeInterval?
    /// How far each piece has moved out, from 0 to 1: the chosen one goes out, the one left behind glides back.
    private var lifts: [Int: CGFloat] = [:]
    private var dotPosition: NSPoint?
    /// Switching wheel with the scroll: the pieces turn into place, from the side of the scroll.
    private var switchStart: CFTimeInterval?
    private var switchDirection: CGFloat = 1

    /// Only the wheel on screen moves: not the previews, not with «Animazione di apertura» off or «Riduci movimento» on.
    private var animates: Bool {
        window is WheelPanel && Settings.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The pieces come out of the hub one after the other, then the dot appears. Called before the panel is placed,
    /// so that its first frame is already the empty one.
    func playOpening() {
        guard animates else { return }
        let start = CACurrentMediaTime()
        openingStart = start
        switchStart = nil
        dotPosition = nil
        startMotion()
        // With the screen asleep, or before it gives frames, the display link may not tick: the wheel must not stay empty.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openingDuration + 0.15) { [weak self] in
            guard let self, self.openingStart == start else { return }
            self.openingStart = nil
            self.needsDisplay = true
        }
    }

    /// The scroll changed the wheel: the new pieces turn in from the side the scroll went.
    func playSwitch(forward: Bool) {
        guard animates, openingStart == nil else { return }
        switchStart = CACurrentMediaTime()
        switchDirection = forward ? 1 : -1
        startMotion()
    }

    private func startMotion() {
        guard animates, motion == nil else { return }
        lastTick = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            motion = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            motion = timer
        }
    }

    @objc private func tick() { step() }

    #if DEBUG
    /// Tests: frames drawn by the motion, and whether it is still running.
    private(set) var debugFrames = 0
    var debugMoving: Bool { motion != nil }
    var debugOpening: Bool { openingStart != nil }
    var debugLift: CGFloat { highlighted.flatMap { lifts[$0] } ?? 0 }
    var debugHighlighted: Int? { highlighted }
    var debugChild: Int? { highlightedChild }
    #endif

    /// The wheel closed: nothing goes on moving behind it, and the next opening starts from scratch.
    func stopAll() {
        stopMotion()
        openingStart = nil
        switchStart = nil
        lifts = [:]
    }

    private func stopMotion() {
        if #available(macOS 14.0, *), let link = motion as? CADisplayLink { link.invalidate() }
        (motion as? Timer)?.invalidate()
        motion = nil
    }

    /// Time based, so the speed is the same at 60 and 120 Hz.
    private func step() {
        #if DEBUG
        debugFrames += 1
        #endif
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 1.0 / 30)
        lastTick = now
        var moving = false
        if let start = openingStart {
            if now - start > Self.openingDuration { openingStart = nil } else { moving = true }
        }
        if let start = switchStart {
            if now - start > Self.switchDuration { switchStart = nil } else { moving = true }
        }
        // Eases towards the target: about 95% of the way in 0.15 s.
        let follow = CGFloat(1 - exp(-dt / 0.05))
        var next: [Int: CGFloat] = [:]
        for i in Set(lifts.keys).union(highlighted.map { [$0] } ?? []) {
            let target: CGFloat = i == highlighted ? 1 : 0
            var value = lifts[i] ?? 0
            value += (target - value) * follow
            if abs(target - value) < 0.004 { value = target } else { moving = true }
            if value > 0 { next[i] = value }
        }
        lifts = next
        let target = dotTarget
        if let dot = dotPosition, hypot(dot.x - target.x, dot.y - target.y) > 0.3 {
            let k = CGFloat(1 - exp(-dt / 0.058))
            dotPosition = NSPoint(x: dot.x + (target.x - dot.x) * k, y: dot.y + (target.y - dot.y) * k)
            moving = true
        } else {
            dotPosition = target
        }
        needsDisplay = true
        // The shadow of a borderless panel follows its content only when asked.
        window?.invalidateShadow()
        if !moving || window?.isVisible != true {
            stopMotion()
            openingStart = nil
            switchStart = nil
        }
    }

    private static let openingDuration: CFTimeInterval = 0.42
    private static let switchDuration: CFTimeInterval = 0.24

    /// How far piece `i` has come out while the wheel opens, from 0 to 1.
    private func openingAmount(_ i: Int) -> CGFloat {
        guard let start = openingStart else { return 1 }
        let elapsed = CGFloat(CACurrentMediaTime() - start)
        let x = min(1, max(0, (elapsed - CGFloat(i) * 0.2 / CGFloat(max(actions.count, 1))) / 0.2))
        return 1 - pow(1 - x, 3)
    }

    /// 0 when the scroll has just changed the wheel, 1 once the pieces are in place.
    private var switchAmount: CGFloat {
        guard let start = switchStart else { return 1 }
        let x = min(1, max(0, CGFloat(CACurrentMediaTime() - start) / CGFloat(Self.switchDuration)))
        return 1 - pow(1 - x, 3)
    }

    /// The dot comes in once the pieces are almost out.
    private var dotAlpha: CGFloat {
        guard let start = openingStart else { return 1 }
        return min(1, max(0, (CGFloat(CACurrentMediaTime() - start) - 0.22) / 0.14))
    }

    /// Unit vector towards the middle of a piece (radians clockwise from 12 o'clock).
    private func direction(_ mid: CGFloat) -> NSPoint { NSPoint(x: sin(mid), y: cos(mid)) }

    /// In the hub above the title; with a piece chosen, in the gap at the middle of its arc.
    private var dotTarget: NSPoint {
        if let i = highlighted, actions.indices.contains(i) {
            let d = direction(CGFloat(i) * segment)
            let r = inner + lift / 2
            return NSPoint(x: center.x + d.x * r, y: center.y + d.y * r)
        }
        return NSPoint(x: center.x, y: center.y + (shape == .pizza ? 25 : 30) * unit)
    }

    #if DEBUG
    /// Tests/functional: the area of each piece is its whole sector, whatever the shape and however it is drawn.
    func hitProblems() -> [String] {
        var problems: [String] = []
        for shape in WheelShape.allCases {
            debugShape = shape
            for count in [2, 6, 8, 10, 14] {
                actions = (0..<count).map { n in WheelAction.each("\(n)", nil) { _ in [] } }
                for i in 0..<count {
                    let mid = CGFloat(i) * segment
                    for r in [inner + 1, labelRadius, outer - 1, edge - 1] {
                        let p = NSPoint(x: center.x + sin(mid) * r, y: center.y + cos(mid) * r)
                        if index(at: p) != i { problems.append("\(shape.rawValue) \(count) voce \(i) r \(Int(r))") }
                    }
                }
                let hub = NSPoint(x: center.x + inner - 2, y: center.y)
                if index(at: center) != nil || index(at: hub) != nil { problems.append("\(shape.rawValue) \(count) centro") }
                let far = NSPoint(x: center.x, y: center.y + edge + 20)
                if index(at: far) != nil { problems.append("\(shape.rawValue) \(count) fuori") }
            }
        }
        debugShape = nil
        return problems
    }

    /// Snapshots: as if the pointer were over group `group` and its variant `child`.
    func previewOpen(group: Int, child: Int?) {
        highlighted = group
        openGroup = members(of: group) != nil ? group : nil
        highlightedChild = child
    }
    #endif

    /// What a drop or a click picks: a variant, a group (its panel, or its first variant with «Solo anello») or an action.
    private func picked() -> WheelAction? {
        if let g = openGroup, let c = highlightedChild, let members = members(of: g) { return members[c] }
        guard let i = highlighted, actions.indices.contains(i) else { return nil }
        if let members = members(of: i), !style.opensPanel, style != .full { return members.first }
        return actions[i]
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let palette = WheelPalette.current
        if !glassBackground {
            // Nearly invisible, but it keeps the gaps between the pieces inside the window: a drop there isn't lost.
            NSColor(white: 0.5, alpha: 0.02).setFill()
            NSBezierPath(ovalIn: Self.discRect(in: bounds, ring: ringSpace)).fill()
        }

        // Pieces still out (the chosen one, and the one gliding back) are drawn last, on top.
        let order = actions.indices.sorted { (lifts[$0] ?? 0, $0 == highlighted ? 1 : 0) < (lifts[$1] ?? 0, $1 == highlighted ? 1 : 0) }
        let turn = (1 - switchAmount) * switchDirection * 0.35, fade = 0.3 + 0.7 * switchAmount
        let base = glassBackground ? palette.tile.withAlphaComponent(0.2) : palette.tile
        for i in order {
            let action = actions[i], mid = CGFloat(i) * segment + turn, chosen = highlighted == i
            let amount = openingAmount(i)
            guard amount > 0 else { continue }
            // Without motion the chosen piece is simply out; with it, each piece is as far out as it has come.
            let out = animates ? (lifts[i] ?? 0) : (chosen ? 1 : 0)
            let lit = out > 0.5
            let d = direction(mid), moved = lift * out
            let origin = NSPoint(x: center.x + d.x * moved, y: center.y + d.y * moved)
            let reach = outer * (0.82 + 0.18 * amount)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(amount * fade)
            // On glass the pieces are a light veil, so that what's behind shows through; a thin edge keeps their shape.
            // The accent comes in as the piece moves out, and goes as it moves back.
            (out >= 1 ? palette.accent : out <= 0 ? base : base.blended(withFraction: out, of: palette.accent) ?? base).setFill()
            let shapePath = piece(around: mid, origin: origin, outer: reach)
            shapePath.fill()
            if glassBackground, !lit {
                palette.glassEdge.withAlphaComponent(palette.glassEdge.alphaComponent * (1 - out)).setStroke()
                shapePath.lineWidth = 1
                shapePath.stroke()
            }
            if shape == .pizza { drawCrust(around: mid, origin: origin, outer: reach, palette: palette, chosen: lit) }
            if !blank {
                let labelOrigin = NSPoint(x: origin.x + d.x * labelRadius, y: origin.y + d.y * labelRadius)
                if !chosen || labelFits(action) {
                    drawLabel(action, at: labelOrigin, color: lit ? palette.onAccent : palette.text)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if let g = openGroup, let members = members(of: g), !blank { drawRing(members, group: g, palette: palette) }

        (glassBackground ? palette.hubFill.withAlphaComponent(0.35) : palette.hubFill).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - inner + 2, y: center.y - inner + 2,
                                    width: (inner - 2) * 2, height: (inner - 2) * 2)).fill()
        guard !blank else { return }

        if let g = openGroup, let c = highlightedChild, let members = members(of: g) {
            drawHub(title: members[c].title, hint: FileHints.line(for: members[c]), palette: palette)
        } else if let i = highlighted, actions.indices.contains(i) {
            // Hovering: the hub spells out the full name; a label too long for its piece is redrawn on top, unclipped.
            drawHub(title: actions[i].title, hint: FileHints.line(for: actions[i]), palette: palette)
            if !labelFits(actions[i]) {
                let d = direction(CGFloat(i) * segment), r = labelRadius + lift * (animates ? lifts[i] ?? 0 : 1)
                drawPill(for: actions[i], at: NSPoint(x: center.x + d.x * r, y: center.y + d.y * r), accent: palette.accent)
            }
        } else {
            let hubTitle = mode == .convert ? L("Converti") : mode == .tools ? L("Strumenti") : L("Condividi")
            let hubSub = fileCount == 1 ? L("1 file") : L("%@ file", fileCount)
            let small = shape == .pizza
            drawCentered(hubTitle, font: .systemFont(ofSize: (small ? 11.5 : 13) * unit, weight: .semibold), color: palette.text,
                         at: NSPoint(x: center.x, y: center.y + 4 * unit))
            drawCentered(hubSub, font: .systemFont(ofSize: 10 * unit), color: palette.secondaryText,
                         at: NSPoint(x: center.x, y: center.y - 11 * unit))
            if let filesHint, !small {
                drawWrapped(filesHint, font: .systemFont(ofSize: 8.5 * unit), color: palette.secondaryText,
                            width: (inner - 16) * 2, y: center.y - 28 * unit, weight: .regular)
            }
        }

        if dotAlpha > 0 {
            let dot = animates ? (dotPosition ?? dotTarget) : dotTarget
            let r = 6 * unit * (0.6 + 0.4 * dotAlpha)
            palette.accent.withAlphaComponent(palette.accent.alphaComponent * dotAlpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)).fill()
        }
    }

    /// The group's variants on an arc outside the wheel, on a disc of their own so they read on any background.
    private func drawRing(_ members: [WheelAction], group g: Int, palette: WheelPalette) {
        let half = CGFloat(members.count) * childAngle / 2 + 0.04
        let mid = CGFloat(g) * segment
        let band = NSBezierPath()
        band.appendArc(withCenter: center, radius: ringOuter + 3, startAngle: 90 - (mid - half) * 180 / .pi,
                       endAngle: 90 - (mid + half) * 180 / .pi, clockwise: true)
        band.appendArc(withCenter: center, radius: ringInner - 3, startAngle: 90 - (mid + half) * 180 / .pi,
                       endAngle: 90 - (mid - half) * 180 / .pi, clockwise: false)
        band.close()
        palette.background.withAlphaComponent(max(palette.background.alphaComponent, 0.92)).setFill()
        band.fill()
        palette.border.setStroke()
        band.lineWidth = 1
        band.stroke()
        for (c, member) in members.enumerated() {
            let m = childMid(c, of: members.count, group: g)
            let halfDeg = childAngle * 90 / .pi - 1
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: ringOuter, startAngle: 90 - m * 180 / .pi + halfDeg,
                           endAngle: 90 - m * 180 / .pi - halfDeg, clockwise: true)
            path.appendArc(withCenter: center, radius: ringInner, startAngle: 90 - m * 180 / .pi - halfDeg,
                           endAngle: 90 - m * 180 / .pi + halfDeg, clockwise: false)
            path.close()
            (highlightedChild == c ? palette.accent : palette.segment).setFill()
            path.fill()
            let color = highlightedChild == c ? palette.onAccent : palette.text
            let radius = (ringInner + ringOuter) / 2
            let p = NSPoint(x: center.x + sin(m) * radius, y: center.y + cos(m) * radius)
            if let symbol = member.symbol, Settings.showIcons,
               let image = symbolImage(symbol, size: 14 * unit, color: color, title: member.title) {
                image.draw(in: NSRect(x: p.x - image.size.width / 2, y: p.y + 1 * unit, width: image.size.width, height: image.size.height))
                drawFitted(member.title, font: .systemFont(ofSize: 9 * unit, weight: .semibold), color: color,
                           at: NSPoint(x: p.x, y: p.y - 8 * unit), width: childAngle * radius - 6 * unit)
            } else {
                drawFitted(member.title, font: .systemFont(ofSize: 10 * unit, weight: .semibold), color: color,
                           at: p, width: childAngle * radius - 6 * unit)
            }
        }
    }

    /// Radius of the labels: in the middle of the piece, inside the crust of a pizza slice.
    private var labelRadius: CGFloat {
        shape == .pizza ? (inner + outer - 16 * unit) / 2 + 3 * unit : (inner + outer) / 2 + 3 * unit
    }

    /// Space for a label at its radius: the chord of the segment, minus a margin.
    private func labelWidth() -> CGFloat {
        let chord = actions.count > 1 ? 2 * labelRadius * sin(segment / 2) : outer
        return max(chord - 10 * unit, 20)
    }

    private func labelFont(_ action: WheelAction) -> NSFont {
        if action.symbol == nil { return .systemFont(ofSize: 15 * unit, weight: .bold) }
        return .systemFont(ofSize: (Settings.showIcons ? 10 : 10.5) * unit, weight: .semibold)
    }

    /// The name fits its piece as it is: no pill needed.
    private func labelFits(_ action: WheelAction) -> Bool {
        Self.width(of: action.title, font: labelFont(action)) <= labelWidth()
    }

    /// A label too long for its piece, at full size on an accent-coloured pill with a shadow (never cut).
    private func drawPill(for action: WheelAction, at p: NSPoint, accent: NSColor) {
        // Never smaller than the label it replaces: format names (no icon) are drawn big already.
        let font = NSFont.systemFont(ofSize: (action.symbol == nil ? 16 : 12) * unit, weight: .bold)
        let text = NSAttributedString(string: action.title, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let showsIcon = action.symbol != nil && Settings.showIcons
        let y = showsIcon ? p.y - 10 * unit : p.y
        let pill = NSRect(x: p.x - size.width / 2 - 8 * unit, y: y - size.height / 2 - 3 * unit,
                          width: size.width + 16 * unit, height: size.height + 6 * unit)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        accent.blended(withFraction: 0.35, of: .black)?.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        text.draw(at: NSPoint(x: p.x - size.width / 2, y: y - size.height / 2))
    }

    /// The hub while something is under the pointer: its name and, smaller, what it is for, one above the other however
    /// many lines each takes. A hint that wouldn't fit in the circle stays out.
    private func drawHub(title: String, hint: String?, palette: WheelPalette) {
        let titleFont = NSFont.systemFont(ofSize: 11 * unit, weight: .bold), hintFont = NSFont.systemFont(ofSize: 8.5 * unit)
        let titleWidth = (inner - 10) * 2, hintWidth = (inner - 14) * 2
        let titleHeight = Self.wrappedHeight(title, font: titleFont, width: titleWidth)
        let gap = 3 * unit
        guard let hint, Self.hubFits(title: title, hint: hint, inner: inner, unit: unit),
              case let hintHeight = Self.wrappedHeight(hint, font: hintFont, width: hintWidth) else {
            drawWrapped(title, font: titleFont, color: palette.text, width: titleWidth)
            return
        }
        let top = center.y + (titleHeight + gap + hintHeight) / 2
        drawWrapped(title, font: titleFont, color: palette.text, width: titleWidth, y: top - titleHeight / 2)
        drawWrapped(hint, font: hintFont, color: palette.secondaryText, width: hintWidth, y: top - titleHeight - gap - hintHeight / 2, weight: .regular)
    }

    /// Whether the hint fits under the title in the hub. Fonts and widths scale with the wheel, so the answer is the
    /// same at every size; the pizza shape has the smaller hub.
    static func hubFits(title: String, hint: String, inner: CGFloat, unit: CGFloat) -> Bool {
        let titleFont = NSFont.systemFont(ofSize: 11 * unit, weight: .bold), hintFont = NSFont.systemFont(ofSize: 8.5 * unit)
        let titleHeight = wrappedHeight(title, font: titleFont, width: (inner - 10) * 2)
        let hintHeight = wrappedHeight(hint, font: hintFont, width: (inner - 14) * 2)
        return titleHeight + 3 * unit + hintHeight <= (inner - 12) * 2
    }

    private static func wrappedHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]).height
    }

    /// Centred text that wraps only between words: the font shrinks until the longest word fits.
    private func drawWrapped(_ text: String, font: NSFont, color: NSColor, width: CGFloat, y: CGFloat? = nil, weight: NSFont.Weight = .bold) {
        let longest = text.split(separator: " ").map {
            Self.width(of: String($0), font: font)
        }.max() ?? 0
        let font = longest > width
            ? NSFont.systemFont(ofSize: font.pointSize * width / longest * 0.97, weight: weight) : font
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                                                                   .paragraphStyle: style])
        let box = string.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin])
        string.draw(with: NSRect(x: center.x - width / 2, y: (y ?? center.y) - box.height / 2, width: width, height: box.height),
                    options: [.usesLineFragmentOrigin])
    }

    /// One piece of the wheel, centred on `mid` (radians clockwise from 12 o'clock). The sides stay parallel to the gap,
    /// and the corners follow Settings → Aspetto → Forma degli spicchi.
    private func piece(around mid: CGFloat, origin: NSPoint, outer r2: CGFloat) -> NSBezierPath {
        let r1 = inner
        let path = NSBezierPath()
        let degrees = { (t: CGFloat) in 90 - t * 180 / .pi }   // AppKit angles: counter-clockwise from 3 o'clock
        guard actions.count > 1 else {
            path.appendOval(in: NSRect(x: origin.x - r2, y: origin.y - r2, width: r2 * 2, height: r2 * 2))
            path.appendOval(in: NSRect(x: origin.x - r1, y: origin.y - r1, width: r1 * 2, height: r1 * 2))
            path.windingRule = .evenOdd
            return path
        }
        let gap = 2.6 * unit
        let side = { (r: CGFloat) in asin(min(0.95, gap / r)) }
        let a = mid - segment / 2, b = mid + segment / 2
        let point = { (r: CGFloat, t: CGFloat) in NSPoint(x: origin.x + sin(t) * r, y: origin.y + cos(t) * r) }
        let c1 = point(r1, a + side(r1)), c2 = point(r2, a + side(r2)), c3 = point(r2, b - side(r2)), c4 = point(r1, b - side(r1))
        let room = min((r2 - r1) / 2, (r1 * segment - 2 * gap) / 2 * 0.9)
        let qOuter: CGFloat, qInner: CGFloat
        switch shape {
        case .sharp: (qOuter, qInner) = (0, 0)
        case .round: (qOuter, qInner) = (min(12 * unit, room), min(12 * unit, room))
        case .soft: (qOuter, qInner) = (min(25 * unit, room), min(25 * unit, room))
        case .chamfer: (qOuter, qInner) = (min(15 * unit, room), min(15 * unit, room))
        case .pizza: (qOuter, qInner) = (min(10 * unit, room), 0)
        }
        let along = { (from: NSPoint, to: NSPoint, d: CGFloat) -> NSPoint in
            let len = max(hypot(to.x - from.x, to.y - from.y), 1)
            return NSPoint(x: from.x + (to.x - from.x) * d / len, y: from.y + (to.y - from.y) * d / len)
        }
        let turn = { (to: NSPoint, corner: NSPoint) in
            if self.shape == .chamfer {
                path.line(to: to)
            } else {
                let now = path.currentPoint
                let k: CGFloat = 0.55
                path.curve(to: to, controlPoint1: NSPoint(x: now.x + (corner.x - now.x) * k, y: now.y + (corner.y - now.y) * k),
                           controlPoint2: NSPoint(x: to.x + (corner.x - to.x) * k, y: to.y + (corner.y - to.y) * k))
            }
        }
        let ao = a + side(r2) + qOuter / r2, bo = b - side(r2) - qOuter / r2
        let ai = a + side(r1) + qInner / r1, bi = b - side(r1) - qInner / r1
        path.move(to: along(c1, c2, qInner))
        path.line(to: along(c2, c1, qOuter))
        if qOuter > 0 { turn(point(r2, ao), c2) }
        path.appendArc(withCenter: origin, radius: r2, startAngle: degrees(ao), endAngle: degrees(bo), clockwise: true)
        if qOuter > 0 { turn(along(c3, c4, qOuter), c3) }
        path.line(to: along(c4, c3, qInner))
        if qInner > 0 { turn(point(r1, bi), c4) }
        path.appendArc(withCenter: origin, radius: r1, startAngle: degrees(bi), endAngle: degrees(ai), clockwise: false)
        if qInner > 0 { turn(along(c1, c2, qInner), c1) }
        path.close()
        return path
    }

    /// The raised edge of a pizza slice.
    private func drawCrust(around mid: CGFloat, origin: NSPoint, outer r2: CGFloat, palette: WheelPalette, chosen: Bool) {
        let width = 12 * unit, radius = r2 - width / 2
        let half = segment / 2 - (2.6 * unit + width / 2 + 4 * unit) / radius
        guard half > 0 else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: origin, radius: radius, startAngle: 90 - (mid - half) * 180 / .pi,
                       endAngle: 90 - (mid + half) * 180 / .pi, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .round
        (chosen ? palette.onAccent.withAlphaComponent(0.3) : palette.crust).setStroke()
        path.stroke()
    }

    private func drawLabel(_ action: WheelAction, at p: NSPoint, color: NSColor) {
        guard let symbol = action.symbol, Settings.showIcons else {
            // Format names (no symbol) are short and drawn big; tool names are longer, so smaller.
            drawFitted(action.title, font: labelFont(action), color: color, at: p)
            return
        }
        if let image = symbolImage(symbol, size: 18 * unit, color: color, title: action.title) {
            let size = image.size
            image.draw(in: NSRect(x: p.x - size.width / 2, y: p.y + 2 * unit, width: size.width, height: size.height))
        }
        drawFitted(action.title, font: .systemFont(ofSize: 10 * unit, weight: .medium), color: color,
                   at: NSPoint(x: p.x, y: p.y - 10 * unit))
    }

    /// Widths of the labels, measured once: every frame asks for the same ones many times.
    private static var widths: [String: CGFloat] = [:]

    private static func width(of text: String, font: NSFont) -> CGFloat {
        let key = "\(text)|\(font.fontName)|\(font.pointSize)"
        if let width = widths[key] { return width }
        let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
        if widths.count > 2000 { widths.removeAll() }
        widths[key] = width
        return width
    }

    /// Symbols, made once for each name, size and colour: making them again was most of the time of a frame.
    private static var symbols: [String: NSImage] = [:]

    private func symbolImage(_ name: String, size: CGFloat, color: NSColor, title: String) -> NSImage? {
        let key = "\(name)|\(size)|\(color)"
        if let image = Self.symbols[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: title)?.withSymbolConfiguration(config) else { return nil }
        if Self.symbols.count > 400 { Self.symbols.removeAll() }
        Self.symbols[key] = image
        return image
    }

    /// Shrinks the text (down to 75%) to fit its segment, then goes on two lines, and only then shortens it with "…".
    private func drawFitted(_ text: String, font: NSFont, color: NSColor, at point: NSPoint, width: CGFloat? = nil) {
        let width = width ?? labelWidth()
        var font = font
        func measure(_ s: String) -> CGFloat { Self.width(of: s, font: font) }
        let natural = measure(text)
        if natural > width {
            font = NSFont.systemFont(ofSize: max(font.pointSize * width / natural, font.pointSize * 0.75),
                                     weight: font.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .medium)
        }
        if measure(text) > width {
            let words = text.split(separator: " ").map(String.init)
            let splits = (1..<max(words.count, 1)).map { (words[..<$0].joined(separator: " "), words[$0...].joined(separator: " ")) }
            if let best = splits.min(by: { max(measure($0.0), measure($0.1)) < max(measure($1.0), measure($1.1)) }),
               max(measure(best.0), measure(best.1)) <= width {
                drawCentered(best.0, font: font, color: color, at: point)
                drawCentered(best.1, font: font, color: color, at: NSPoint(x: point.x, y: point.y - font.pointSize * 1.15))
                return
            }
        }
        var shown = text
        while measure(shown) > width, shown.count > 2 {
            shown = String(shown.dropLast(shown.hasSuffix("…") ? 2 : 1)) + "…"
        }
        drawCentered(shown, font: font, color: color, at: point)
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { resetHover() }

    private func resetHover() {
        highlighted = nil
        highlightedChild = nil
        openGroup = nil
        needsDisplay = true
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(at: convert(sender.draggingLocation, from: nil))
        return picked() == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let action = picked() else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDrop?(action, urls) }
        return true
    }

    // MARK: Click mode (opened from the Finder's right-click menu)

    /// When set, the wheel works with the mouse: hover highlights, click picks, Esc or a click in the centre cancels.
    var clickURLs: [URL]? {
        didSet { highlighted = nil; window?.acceptsMouseMovedEvents = clickURLs != nil }
    }
    var onCancel: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickURLs != nil else { return }
        track(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if clickURLs != nil { resetHover() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let urls = clickURLs else { return }
        track(at: convert(event.locationInWindow, from: nil))
        if let action = picked() {
            DispatchQueue.main.async { self.onDrop?(action, urls) }
        } else {
            onCancel?()
        }
    }

    override var acceptsFirstResponder: Bool { clickURLs != nil }

    /// Esc cancels; ← → go round the wheel clockwise and back, ↓ ↑ through the variants of an open group,
    /// Return or Space pick, Tab switches wheel as the scroll wheel does.
    override func keyDown(with event: NSEvent) {
        guard let urls = clickURLs, !actions.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: onCancel?()
        case 123, 124: step(event.keyCode == 124 ? 1 : -1)
        case 125, 126: stepChild(event.keyCode == 125 ? 1 : -1)
        case 36, 76, 49:
            if let action = picked() { DispatchQueue.main.async { self.onDrop?(action, urls) } }
        case 48: onScrollMode?(!event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    /// The modifier keys down at the last check: pressing a wheel's key switches to it, letting go does nothing.
    var heldFlags: NSEvent.ModifierFlags = []
    var onSetMode: ((WheelMode) -> Void)?

    override func flagsChanged(with event: NSEvent) {
        guard clickURLs != nil else { return super.flagsChanged(with: event) }
        defer { heldFlags = event.modifierFlags }
        if let next = Settings.switchMode(from: heldFlags, to: event.modifierFlags), next != mode { onSetMode?(next) }
    }

    /// The next piece round the wheel; the first press starts from the top (or the last piece, going back).
    private func step(_ by: Int) {
        let count = actions.count
        let i = highlighted.map { (($0 + by) % count + count) % count } ?? (by > 0 ? 0 : count - 1)
        highlightedChild = nil
        highlighted = i
        let open = style.showsRing && members(of: i) != nil ? i : nil
        if open != openGroup { openGroup = open; needsDisplay = true }
    }

    /// The next variant of the open group; going up past the first one comes back to the group itself.
    private func stepChild(_ by: Int) {
        guard let g = openGroup, let members = members(of: g) else { return }
        let c = (highlightedChild ?? -1) + by
        highlightedChild = c < 0 ? nil : min(c, members.count - 1)
    }
}

/// A borderless panel that can take keyboard focus in click mode (for Esc).
final class WheelPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// Borderless floating panel that hosts the wheel, centred on the pointer.
@MainActor
final class WheelController {
    /// Side of the wheel in points: grows with the number of actions so labels fit, times the size setting.
    static func size(for actionCount: Int, scale: CGFloat = Settings.wheelScale) -> CGFloat {
        let base: CGFloat = actionCount > 10 ? 410 : actionCount > 8 ? 386 : 360
        return (base * scale).rounded()
    }

    let view = WheelView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
    private let panel: WheelPanel
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
    /// One line under the wheel about the files: name, size, and pixels, pages or length.
    private let cardPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 24),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let cardLabel = NSTextField(labelWithString: "")
    private var cardTask: Task<Void, Never>?
    /// Liquid Glass disc behind the wheel (macOS 26+), when enabled in Settings.
    private var glass: NSView?

    init() {
        panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // .auxiliary: Stage Manager leaves the wheel out of Rondelle's stage, so opening or switching it never brings
        // back the stage's other windows (Settings, even minimised to the Dock).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .auxiliary]
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        panel.contentView = container
        view.onCancel = { [weak self] in self?.hide() }
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.ignoresMouseEvents = true
        cardPanel.level = .popUpMenu
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .auxiliary]
        let cardBackground = NSVisualEffectView(frame: cardPanel.contentRect(forFrameRect: cardPanel.frame))
        cardBackground.material = .hudWindow
        cardBackground.state = .active
        cardBackground.wantsLayer = true
        cardBackground.layer?.cornerRadius = 12
        cardBackground.layer?.masksToBounds = true
        cardBackground.autoresizingMask = [.width, .height]
        cardLabel.font = .systemFont(ofSize: 11, weight: .medium)
        cardLabel.lineBreakMode = .byTruncatingMiddle
        cardLabel.alignment = .center
        cardLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cardBackground.addSubview(cardLabel)
        cardPanel.contentView = cardBackground
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Click mode: clicking anywhere else closes the wheel.
            MainActor.assumeIsolated { if self?.view.clickURLs != nil { self?.hide() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.giveBackFocus() }
        }
    }

    /// Opened by a drag while another app was in front: that app, and the windows that were in the Dock.
    private var dragOwner: NSRunningApplication?
    private var minimised: [NSWindow] = []
    #if DEBUG
    var debugGaveBack = 0
    #endif

    /// macOS activates the app under a drag after a few seconds; with Stage Manager that brought back Rondelle's
    /// stage, Settings included. While a drag's wheel is open, the app in front stays in front.
    private func giveBackFocus() {
        guard panel.isVisible, view.clickURLs == nil, let owner = dragOwner, !owner.isTerminated else { return }
        owner.activate(options: [])
        for window in minimised where !window.isMiniaturized { window.miniaturize(nil) }
        #if DEBUG
        debugGaveBack += 1
        #endif
    }

    var isVisible: Bool { panel.isVisible }
    #if DEBUG
    /// The wheel and the line under it, as Stage Manager sees them (--test-wheel-behind).
    var debugBehaviors: [NSWindow.CollectionBehavior] { [panel.collectionBehavior, cardPanel.collectionBehavior] }
    #endif

    /// - Parameter clickMode: true when opened from the Finder menu: used with clicks instead of a drop.
    func show(urls: [URL], mode: WheelMode, clickMode: Bool = false) {
        view.fileCount = urls.count
        view.filesHint = FileHints.line(forFiles: urls)
        currentMode = mode
        view.onScrollMode = { [weak self] forward in self?.scrollMode(forward: forward) }
        view.onSetMode = { [weak self] next in self?.setMode(next) }
        view.heldFlags = NSEvent.modifierFlags
        view.mode = mode
        view.actions = ActionCatalog.actions(for: urls, mode: mode)
        lastURLs = urls
        view.clickURLs = clickMode ? urls : nil
        dragOwner = clickMode || NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication
        minimised = dragOwner == nil ? [] : NSApp.windows.filter(\.isMiniaturized)
        panel.allowsKey = clickMode
        if Settings.animate { view.playOpening() }   // before place(): the first frame drawn is the empty wheel
        place()
        showCard(for: urls)

        panel.alphaValue = Settings.animate ? 0 : 1
        if clickMode {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
        if Settings.animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private var currentMode = WheelMode.convert

    private func scrollMode(forward: Bool) {
        let all: [WheelMode] = [.convert, .tools, .share]
        let here = all.firstIndex(of: currentMode) ?? 0
        setMode(all[(here + (forward ? 1 : all.count - 1)) % all.count], forward: forward)
    }

    /// `forward`: the side the pieces turn in from; by default, the order Converti, Strumenti, Condividi.
    func setMode(_ mode: WheelMode, forward: Bool? = nil) {
        guard panel.isVisible, mode != currentMode else { return }
        let all: [WheelMode] = [.convert, .tools, .share]
        let forward = forward ?? ((all.firstIndex(of: mode) ?? 0) > (all.firstIndex(of: currentMode) ?? 0))
        currentMode = mode
        view.mode = mode
        view.actions = ActionCatalog.actions(for: lastURLs, mode: mode)
        view.playSwitch(forward: forward)
        place()
    }

    /// Under the wheel, or over it at the bottom of the screen.
    private func placeCard() {
        guard panel.isVisible || cardLabel.stringValue.isEmpty == false else { return }
        let width = min(max(cardLabel.intrinsicContentSize.width + 24, 120), 420)
        let height: CGFloat = 24
        let frame = panel.frame
        var y = frame.minY + (frame.height - WheelController.size(for: view.actions.count)) / 2 - height - 2
        if let screen = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame, y < screen.minY {
            y = frame.maxY - (frame.height - WheelController.size(for: view.actions.count)) / 2 + 2
        }
        cardPanel.setFrame(NSRect(x: frame.midX - width / 2, y: y, width: width, height: height), display: true)
        cardLabel.frame = NSRect(x: 12, y: 4, width: width - 24, height: 16)
    }

    private func showCard(for urls: [URL]) {
        cardTask?.cancel()
        cardLabel.stringValue = urls.count == 1 ? urls[0].lastPathComponent : L("%@ file", urls.count)
        placeCard()
        cardPanel.orderFrontRegardless()
        cardTask = Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .utility) { await FileHints.card(for: urls) }.value
            guard let self, !Task.isCancelled, let text else { return }
            self.cardLabel.stringValue = text
            self.placeCard()
        }
    }

    func hide() {
        dragOwner = nil
        minimised = []
        cardTask?.cancel()
        cardPanel.orderOut(nil)
        view.clickURLs = nil
        view.stopAll()
        panel.allowsKey = false
        panel.orderOut(nil)
    }

    /// Centres the panel on the pointer at the size the current actions need, moved inside the screen
    /// when the pointer is near an edge (the wheel is never cut in half).
    private func place() {
        // Room for the second ring around the disc, when a group can open one.
        let hasGroups = view.actions.contains { if case .group = $0.work { return true } else { return false } }
        view.style = Settings.wheelStyle
        let disc = Self.size(for: view.actions.count)
        let ring = view.style.showsRing && hasGroups ? (disc * 0.17).rounded() : 0
        view.ringSpace = ring
        let side = disc + 2 * ring
        let mouse = NSEvent.mouseLocation
        var frame = NSRect(x: mouse.x - side / 2, y: mouse.y - side / 2, width: side, height: side)
        if let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - side)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - side)
        }
        panel.setFrame(frame, display: false)
        placeCard()
        container.frame = NSRect(x: 0, y: 0, width: side, height: side)
        view.frame = container.bounds
        updateGlass(side: side)
        view.needsDisplay = true
        panel.display()
    }

    /// The disc as real Liquid Glass (macOS 26+): it refracts what's behind; the theme and opacity tint it.
    private func updateGlass(side: CGFloat) {
        guard #available(macOS 26.0, *), Settings.liquidGlass else {
            glass?.removeFromSuperview()
            glass = nil
            view.glassBackground = false
            return
        }
        let disc = WheelView.glassRect(in: NSRect(x: 0, y: 0, width: side, height: side), ring: view.ringSpace)
        let effect = (glass as? NSGlassEffectView) ?? NSGlassEffectView()
        effect.frame = disc
        effect.cornerRadius = disc.width / 2
        effect.style = .regular
        let dark = WheelPalette.isDark
        effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        effect.tintColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(WheelPalette.glassTint)
        if glass == nil {
            container.addSubview(effect, positioned: .below, relativeTo: view)
            glass = effect
        }
        view.glassBackground = true
    }

    private var lastURLs: [URL] = []
}

/// A light tap on the trackpad and a soft click when the pointer moves onto another action.
@MainActor
enum HoverFeedback {
    private static let click = NSSound(named: "Tink")

    static func play() {
        if Settings.hoverHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(Settings.hoverHapticStrength.pattern, performanceTime: .now)
        }
        if Settings.hoverSound, let click {
            click.stop()
            click.volume = Settings.hoverVolume
            click.play()
        }
    }
}
