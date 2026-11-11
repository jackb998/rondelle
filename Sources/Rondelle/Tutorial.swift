import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// How the app works, with small animations built on the real wheel. Opens by itself at the first launch, and
/// from Settings → Aiuto or the menu bar («Come si usa…»). The last page asks for the Home folder permission.
/// The window is round, shaped like the wheel (a washer): no frame, moved by dragging its background.
@MainActor
final class TutorialWindow {
    static let shared = TutorialWindow()
    private var window: NSWindow?

    func show(page: Int = 0, frozenStep: Int? = nil) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: TutorialRing.diameter, height: TutorialRing.diameter)
        let window = RoundWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = L("Come si usa Rondelle")
        window.isOpaque = false
        window.backgroundColor = .clear   // outside the circle
        window.hasShadow = true
        // Only WindowDragArea (the empty disc) moves the window. Movable by its whole background, a click on the photo
        // of a practice scene went to the window server as a window drag on some Macs: the window moved or tiled.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TutorialView(page: page, frozenStep: frozenStep) { [weak window] in window?.close() })
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.center()
        // The shadow follows the drawn circle once the page is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in window?.invalidateShadow() }
        // Closed for good: the scenes and their timer go with the window.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.contentView = nil
                self?.window = nil
            }
        }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A window without frame still takes the keys (Return, arrows, Esc) and closes with ⌘W.
private final class RoundWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }
}

/// The sizes of the round window, shared by the window, the pages and the fit test (`--test-tutorial`).
enum TutorialRing {
    static let diameter: CGFloat = 560
    static let band: CGFloat = 5
    /// Everything on a page stays this close to the centre, inside the ring.
    static let safe: CGFloat = diameter / 2 - band - 4
    /// The scenes: a rectangle in the upper part of the circle.
    static let scene = CGSize(width: 440, height: 276)
    static let sceneCentre = CGPoint(x: 280, y: 198)
    static let space = "tutorialCircle"
}

/// Where each piece of a page sits in the circle, by name: read by the fit test.
private struct TutorialFitKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Capsule buttons, as on macOS welcome sheets (glass buttons are capsules already on macOS 26).
    @ViewBuilder func capsuleButton() -> some View {
        if #available(macOS 14.0, *) { buttonBorderShape(.capsule) } else { self }
    }

    func fits(_ name: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: TutorialFitKey.self, value: [name: g.frame(in: .named(TutorialRing.space))])
        })
    }
}

/// The background, like a Mac window made round: translucent material (Liquid Glass on macOS 26), a thin ring in the
/// accent colour and a hairline edge, as system windows have.
private struct WasherBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = Color(nsColor: Settings.accentColor), dark = scheme == .dark
        let band = TutorialRing.band
        ZStack {
            DiscMaterial()
            // Enough paper over the material for the text to read on any desktop.
            Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(dark ? 0.62 : 0.7))
            Circle().fill(LinearGradient(colors: [accent.opacity(0.10), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: band)
            Circle().inset(by: band).strokeBorder(Color.white.opacity(dark ? 0.08 : 0.45), lineWidth: 1)
            Circle().strokeBorder(dark ? Color.white.opacity(0.22) : Color.black.opacity(0.18), lineWidth: 0.5)
        }
    }
}

/// The disc's material: Liquid Glass on macOS 26, the window material behind the window before.
private struct DiscMaterial: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Circle())
        } else {
            BehindWindow().clipShape(Circle())
        }
    }

    private struct BehindWindow: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }
}

/// What a newcomer already tried in the tutorial. Until then «Avanti» stays off on the two pages to try; from the next
/// opening (or once tried) those pages can be skipped. `store` is swapped by `--test-tutorial`.
@MainActor
enum TutorialProgress {
    static var store = UserDefaults.standard
    private static let convertKey = "tutorialTriedConvert", wheelsKey = "tutorialTriedWheels"

    static var triedConvert: Bool {
        get { store.bool(forKey: convertKey) }
        set { store.set(newValue, forKey: convertKey) }
    }
    static var triedWheels: Bool {
        get { store.bool(forKey: wheelsKey) }
        set { store.set(newValue, forKey: wheelsKey) }
    }

    /// Whether «Avanti» leaves this page: the convert page once a conversion worked, the wheels page once all three opened.
    static func passable(_ page: Int, triedConvert: Bool, triedWheels: Bool) -> Bool {
        guard tutorialPages.indices.contains(page), case .practice(_, let tour) = tutorialPages[page].scene else { return true }
        return tour ? triedWheels : triedConvert
    }

    /// Back always; forward only across pages that can be left (the page dots).
    static func reachable(_ target: Int, from page: Int, triedConvert: Bool, triedWheels: Bool) -> Bool {
        target <= page || (page..<target).allSatisfy { passable($0, triedConvert: triedConvert, triedWheels: triedWheels) }
    }
}

/// The empty parts of the circle move the window.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        // Only the circle: outside it the click goes to what is behind the window.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = convert(point, from: superview)
            return hypot(p.x - bounds.midX, p.y - bounds.midY) <= min(bounds.width, bounds.height) / 2 ? super.hitTest(point) : nil
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private enum TutorialScene {
    /// The app's icon, before anything to learn.
    case welcome
    /// A scene to try, which plays by itself once left alone for a few seconds (`tour`: the demo also switches wheel).
    case practice(WheelMode, tour: Bool)
    case menus
    /// What Settings lets you change, with a button to open them.
    case settings
    case privacy
}

private struct TutorialPage {
    let title: String
    let text: String
    let scene: TutorialScene
}

/// Worked out when read: the texts name the keys chosen in Settings. A welcome, then five pages, one sentence or two each: the
/// scene's hint line teaches the drag step by step. The two practice pages must be tried once (TutorialProgress).
@MainActor
private var tutorialPages: [TutorialPage] {
    func keys(_ mode: WheelMode) -> String { Settings.keys(for: mode).label }
    func switchKeys(_ mode: WheelMode) -> String { Settings.switchKey(for: mode).label }
    return [
        TutorialPage(title: L("Benvenuto in Rondelle"),
                     text: L("Converti, modifica e condividi file trascinandoli. Il risultato compare accanto all'originale."),
                     scene: .welcome),
        TutorialPage(title: L("Prova a convertire"),
                     text: L("Trascina la foto, premi %@ e rilasciala su un formato. Con i file del Finder è lo stesso.", keys(.convert)),
                     scene: .practice(.convert, tour: false)),
        TutorialPage(title: L("Tre ruote"),
                     text: L("Prova tutte e tre: con la ruota aperta, un tasto solo cambia ruota (%@ Converti, %@ Strumenti, %@ Condividi).",
                             switchKeys(.convert), switchKeys(.tools), switchKeys(.share)),
                     scene: .practice(.convert, tour: true)),
        TutorialPage(title: L("Senza trascinare, e se sbagli"),
                     text: L("Nel Finder: clic destro → Servizi → «Rondelle: Converti…».") + "\n"
                        + L("Dal menu di Rondelle, «Annulla ultima conversione» sposta nel Cestino i file creati."),
                     scene: .menus),
        TutorialPage(title: L("Fatta a modo tuo"),
                     text: L("Rondelle si adatta a te: nelle Impostazioni cambi quasi tutto."),
                     scene: .settings),
        TutorialPage(title: L("La tua privacy"),
                     text: L("Per salvare i risultati accanto agli originali, consenti la cartella Inizio. Altrimenti Rondelle chiede cartella per cartella."),
                     scene: .privacy),
    ]
}

/// A label style chosen at run time.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct TutorialView: View {
    @State var page: Int
    let frozenStep: Int?
    let close: () -> Void
    @State private var step = 0
    @State private var homeGranted = FolderAccess.allowedFolders.contains { FolderAccess.covers($0, FolderAccess.realHome) }
    @State private var triedConvert = TutorialProgress.triedConvert
    @State private var triedWheels = TutorialProgress.triedWheels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = Timer.publish(every: 1.1, on: .main, in: .common).autoconnect()

    /// Without movement (or in a snapshot) each scene stays on the step that explains it best.
    private var shownStep: Int { frozenStep ?? (reduceMotion ? 3 : step) }
    private var isLast: Bool { page == tutorialPages.count - 1 }
    private var canGoOn: Bool { TutorialProgress.passable(page, triedConvert: triedConvert, triedWheels: triedWheels) }
    private var accent: Color { Color(nsColor: Settings.accentColor) }

    var body: some View {
        let current = tutorialPages[page], d = TutorialRing.diameter
        ZStack {
            WasherBackground().overlay(WindowDragArea())
            scene(current.scene)
                .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
                .id(page)
                .transition(.opacity)
                .position(TutorialRing.sceneCentre)
            VStack(spacing: 6) {
                Text(current.title).font(.system(size: 22, weight: .bold)).fits("titolo")
                Text(current.text)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 376)
                    .fits("testo")
            }
            .frame(width: 400, height: 116, alignment: .top)
            .position(x: d / 2, y: 344 + 58)
            controls.fits("navigazione").position(x: d / 2, y: 478)
            dots.fits("puntini").position(x: d / 2, y: 512)
            closeButton.fits("chiudi").position(x: d / 2, y: 30)
        }
        .frame(width: d, height: d)
        .coordinateSpace(name: TutorialRing.space)
        .clipShape(Circle())
        .onPreferenceChange(TutorialFitKey.self) { frames in
            #if DEBUG
            MainActor.assumeIsolated { TutorialFit.frames = frames }
            #endif
        }
        .onReceive(timer) { _ in
            guard frozenStep == nil, !reduceMotion else { return }
            step = (step + 1) % Self.sceneSteps(current.scene)
        }
    }

    static func sceneSteps(_ scene: TutorialScene) -> Int {
        switch scene {
        case .welcome: return 1
        case .practice: return 7
        case .menus: return 7
        case .settings: return 1
        case .privacy: return 4
        }
    }

    /// The steps a snapshot can stop on: a practice scene's demo, half a second each.
    static func snapshotSteps(_ scene: TutorialScene) -> Int {
        if case .practice(let goal, let tour) = scene { return Int(PracticeScript.duration(goal, tour: tour) * 2) + 1 }
        return sceneSteps(scene)
    }

    @ViewBuilder private func scene(_ scene: TutorialScene) -> some View {
        switch scene {
        case .practice(let goal, let tour):
            // `frozenStep` (snapshots) stops the demo at that half second; without movement the demo never starts.
            // The convert page opens only the Convert wheel; the wheels page counts the wheels opened (its checkmarks).
            PracticeScene(goal: goal, idleDemo: !reduceMotion, frozen: frozenStep.map { Double($0) * 0.5 }, tour: tour,
                          allowed: tour ? PracticeModel.allModes : [goal]) { opened, converted in
                if tour, opened.isSuperset(of: PracticeModel.allModes), !triedWheels {
                    triedWheels = true
                    TutorialProgress.triedWheels = true
                } else if !tour, converted, !triedConvert {
                    triedConvert = true
                    TutorialProgress.triedConvert = true
                }
            }
        case .welcome: WelcomeScene()
        case .menus: MenusScene(step: shownStep)
        case .settings: SettingsScene()
        case .privacy: PrivacyScene(granted: homeGranted)
        }
    }

    /// Small and quiet, like the close button of a panel.
    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(L("Chiudi"))
        .accessibilityLabel(L("Chiudi"))
    }

    /// Page dots: small to look at, 22 points to click.
    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(tutorialPages.indices, id: \.self) { i in
                let open = TutorialProgress.reachable(i, from: page, triedConvert: triedConvert, triedWheels: triedWheels)
                Circle().fill(i == page ? accent : Color.secondary.opacity(open ? 0.35 : 0.18))
                    .frame(width: i == page ? 8 : 7, height: i == page ? 8 : 7)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { if open { go(i) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Pagina %@ di %@", page + 1, tutorialPages.count))
    }

    /// One prominent action per page. On the last one it is the Home folder permission until it is granted, then «Inizia».
    private var controls: some View {
        HStack(spacing: 10) {
            if page > 0 {
                // Next to the permission button only the arrow fits in the circle; the X closes without granting it.
                let narrow = isLast && !homeGranted
                Button { go(page - 1) } label: {
                    Label(L("Indietro"), systemImage: "chevron.left").labelStyle(narrow ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .buttonStyle(.bordered)   // a visible fill: plain glass on this background reads as a label
                .capsuleButton()
                .help(L("Indietro"))
            }
            if !isLast {
                // On the two pages to try, off until they were tried (now or at an earlier opening): the → key too.
                Button { go(page + 1) } label: {
                    HStack(spacing: 5) { Text(page == 0 ? L("Comincia") : L("Avanti")); Image(systemName: "chevron.right") }
                        .padding(.horizontal, page == 0 ? 14 : 6)
                }
                .keyboardShortcut(.defaultAction)
                .rondelleProminentButton()
                .capsuleButton()
                .disabled(!canGoOn)
                .help(canGoOn ? "" : lockedHelp)
                .background(Button("") { go(page + 1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!canGoOn)
                    .opacity(0).accessibilityHidden(true))
            } else if homeGranted {
                Button(action: close) { Text(L("Inizia")).padding(.horizontal, 10) }
                    .keyboardShortcut(.defaultAction)
                    .rondelleProminentButton()
                    .capsuleButton()
            } else {
                Button {
                    homeGranted = FolderAccess.request(FolderAccess.realHome, explanation: L("Seleziona la cartella Inizio e premi «Consenti»."))
                } label: {
                    Label(L("Consenti cartella Inizio…"), systemImage: "folder.badge.plus")
                }
                .keyboardShortcut(.defaultAction)
                .rondelleProminentButton()
                .capsuleButton()
            }
        }
        .controlSize(.large)
        .tint(accent)
    }

    private var lockedHelp: String {
        if case .practice(_, true) = tutorialPages[page].scene { return L("Prima apri tutte e tre le ruote.") }
        return L("Prima converti la foto.")
    }

    private func go(_ target: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            page = target
            step = 0
        }
    }
}

// MARK: Scenes

/// What a practice scene shows at one moment: where the sample file is, which keys are down, the wheel if open.
private struct PracticeFrame {
    var file = PracticeModel.home
    var held: NSEvent.ModifierFlags = []
    var wheel: WheelMode?
    var centre = PracticeModel.middle
    var highlight: Int?
    var result: PracticeModel.Result?
    var cancelled = false
    var dragging = false
    var cursor = false   // drawn only when the scene plays by itself
    var panel: String?   // the group whose options panel is open (its key)
}

/// Interactive practice: the sample file is dragged for real, the keys open the wheel, the drop shows the result.
/// Nothing is converted. The same scene plays by itself on the first page, with reduced motion off, and for the
/// README's animation (`PracticeScript`).
@MainActor
private final class PracticeModel: ObservableObject {
    enum Result: Equatable {
        case file(name: String, type: UTType)
        case sent(String)
    }

    /// The scene's size and middle, inside the round window (TutorialRing).
    nonisolated static let size = TutorialRing.scene
    nonisolated static let middle = CGPoint(x: TutorialRing.scene.width / 2, y: TutorialRing.scene.height / 2)
    nonisolated static let home = CGPoint(x: 64, y: 180)
    nonisolated static let radius: CGFloat = 100
    nonisolated static let hole: CGFloat = 28

    nonisolated static let allModes: Set<WheelMode> = [.convert, .tools, .share]

    @Published var frame = PracticeFrame()
    /// The wheels opened so far, and whether a drop (or a variant) gave a result: what unlocks «Avanti».
    @Published private(set) var opened: Set<WheelMode> = []
    @Published private(set) var converted = false
    let goal: WheelMode
    /// The wheels this scene opens: on the convert page only Convert, the other keys do nothing there.
    let allowed: Set<WheelMode>
    /// The last drag, drop, key or choice: the demo waits for the scene to be left alone (`isIdle`).
    var lastActivity = Date()
    private var monitor: Any?
    private var reset: Task<Void, Never>?

    init(goal: WheelMode, allowed: Set<WheelMode> = PracticeModel.allModes) {
        self.goal = goal
        self.allowed = allowed
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.keys(event.modifierFlags) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset?.cancel()
    }

    /// While the file is held: the first keys of a wheel open it where the file is; once open, a key press switches.
    func keys(_ flags: NSEvent.ModifierFlags) {
        let before = frame.held
        frame.held = KeyCombo(flags).flags
        lastActivity = Date()
        guard frame.dragging else { return }
        if let open = frame.wheel {
            if let next = Settings.switchMode(from: before, to: flags), next != open, allowed.contains(next) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { frame.wheel = next; frame.highlight = nil }
                opened.insert(next)
            }
        } else if let mode = Settings.mode(for: flags), allowed.contains(mode) {
            open(mode)
        }
    }

    func drag(to point: CGPoint) {
        guard frame.panel == nil else { return }
        reset?.cancel()
        lastActivity = Date()
        if !frame.dragging {
            frame = PracticeFrame(file: point, held: frame.held, dragging: true)
            if let mode = Settings.mode(for: NSEvent.modifierFlags), allowed.contains(mode) { open(mode) }
        }
        frame.file = point
        if frame.wheel != nil { frame.highlight = Self.segment(at: point, centre: frame.centre, count: actions.count) }
    }

    func drop() {
        guard frame.panel == nil else { return }
        frame.dragging = false
        lastActivity = Date()
        if frame.wheel != nil, let index = frame.highlight {
            // A group opens its options panel, as on the real wheel (unless Settings → Ruota says «Solo anello»).
            if case .group = actions[index].work, Settings.wheelStyle.opensPanel {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    frame.panel = actions[index].key
                    frame.wheel = nil
                    frame.highlight = nil
                }
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                frame.result = Self.result(of: actions[index], mode: frame.wheel ?? goal)
                frame.wheel = nil
            }
            converted = true
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                frame.cancelled = frame.wheel != nil
                frame.wheel = nil
                frame.highlight = nil
                frame.file = Self.home
            }
        }
        scheduleReset()
    }

    /// A variant picked in the options panel, or nil (closed): the result, or the photo back in its place.
    func choose(_ option: WheelAction?) {
        lastActivity = Date()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            frame.panel = nil
            if let option { frame.result = Self.result(of: option, mode: .tools) } else { frame.file = Self.home }
        }
        if option != nil { converted = true }
        scheduleReset()
    }

    private func scheduleReset() {
        reset?.cancel()
        reset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, !self.frame.dragging else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.frame = PracticeFrame(held: self.frame.held) }
        }
    }

    var actions: [WheelAction] { Self.actions(frame.wheel ?? goal) }

    /// Nothing touched for `seconds` and the scene at rest (photo in its place, no wheel, no result, no panel).
    func isIdle(for seconds: TimeInterval, now: Date = Date()) -> Bool {
        !frame.dragging && frame.wheel == nil && frame.result == nil && frame.panel == nil && now.timeIntervalSince(lastActivity) >= seconds
    }

    private func open(_ mode: WheelMode) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            frame.centre = Self.wheelCentre(near: frame.file)
            frame.wheel = mode
            frame.highlight = nil
            frame.cancelled = false
        }
        opened.insert(mode)
    }

    /// Where the wheel opens: around the file, kept inside the scene.
    /// Near the file, but only in the middle of the scene, so a newcomer always finds the wheel in the same area.
    /// How far from the middle the wheel may open, each way: it always stays inside the circle.
    nonisolated static let zone = CGSize(width: 60, height: 25)

    static func wheelCentre(near point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, middle.x - zone.width), middle.x + zone.width), y: min(max(point.y, middle.y - zone.height), middle.y + zone.height))
    }

    /// As in WheelView: segment 0 at the top, then clockwise; the hole in the middle cancels.
    static func segment(at point: CGPoint, centre: CGPoint, count: Int) -> Int? {
        let dx = point.x - centre.x, dy = point.y - centre.y
        let r = hypot(dx, dy)
        guard count > 0, r >= hole, r <= radius + 8 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let step = 2 * .pi / CGFloat(count)
        return Int((angle + step / 2) / step) % count
    }

    /// The middle of a segment, for the scene that plays by itself.
    static func point(of index: Int, count: Int, centre: CGPoint) -> CGPoint {
        let angle = Double(index) / Double(count) * 2 * .pi
        return CGPoint(x: centre.x + sin(angle) * 66, y: centre.y - cos(angle) * 66)
    }

    static func actions(_ mode: WheelMode) -> [WheelAction] {
        switch mode {
        case .convert: return ["PNG", "HEIC", "PDF", "WebP", "TIFF", "GIF"].map { .each($0) { _ in [] } }
        case .tools: return [
            WheelAction(title: "Comprimi", symbol: "arrow.down.circle", work: .group(members(of: "Comprimi")), id: "group.compress"),
            WheelAction(title: "Ridimensiona", symbol: "arrow.up.left.and.arrow.down.right", work: .group(members(of: "Ridimensiona")),
                        id: "group.resize"),
            .each("Modifica", "pencil.tip.crop.circle") { _ in [] },
            .each("Testo e QR", "text.viewfinder") { _ in [] },
            .each("Sfondo", "person.crop.square") { _ in [] },
            .each("ZIP", "archivebox") { _ in [] },
        ]
        case .share: return [
            .each("AirDrop", "airplayaudio") { _ in [] },
            .each("Messaggi", "message") { _ in [] },
            .each("Mail", "envelope") { _ in [] },
            .each("WhatsApp", "phone.bubble") { _ in [] },
            .each("Copia", "doc.on.clipboard") { _ in [] },
        ]
        }
    }

    /// The variants an image really gets in those two groups (the sizes of Settings → Conversioni included), as in WheelGroups.
    static func members(of group: String) -> [WheelAction] {
        let all = ActionCatalog.allActions(for: .image, mode: .tools).flatMap(\.flattened)
        if group == "Comprimi" { return all.filter { ["Comprimi", "Comprimi +", "Peso…"].contains($0.key) } }
        return all.filter { $0.key == "50%" || $0.key == "Misura…" || ($0.key.hasSuffix("px") && $0.symbol != nil) }
    }

    static func result(of action: WheelAction, mode: WheelMode) -> Result {
        switch mode {
        case .convert:
            let ext = action.key.lowercased()
            return .file(name: L("foto") + ".\(ext)", type: UTType(filenameExtension: ext) ?? .image)
        case .tools:
            if action.key == "ZIP" { return .file(name: L("foto") + ".zip", type: .zip) }
            // A variant that asks (Misura…, Peso…) is shown with the value it proposes.
            if case .asking(_, let value, _, _) = action.work {
                return .file(name: L("foto (%@).jpg", action.key == "Misura…" ? "\(value)px" : "\(value) MB"), type: .jpeg)
            }
            return .file(name: L("foto (%@).jpg", action.title.lowercased()), type: .jpeg)
        case .share:
            return .sent(L("Inviato con %@", action.title))
        }
    }
}

/// The scene playing by itself: the file is picked up, the keys open the wheel, then (on the first page and in the
/// README) the other keys switch wheel before the file lands on a segment. `t` in seconds; it loops.
private enum PracticeScript {
    static func duration(_ goal: WheelMode, tour: Bool) -> Double { tour ? 15 : 6 }

    /// Where the first option sits in the panel drawn by PracticeCanvas (scaled, in the middle of the scene).
    static let firstOption = CGPoint(x: 177, y: 117)

    @MainActor static func frame(at t: Double, goal: WheelMode, tour: Bool) -> PracticeFrame {
        let target = 0, count = PracticeModel.actions(goal).count
        let grab = CGPoint(x: 200, y: 150)
        let centre = PracticeModel.wheelCentre(near: grab)
        func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
            let k = max(0, min(1, k)), e = k * k * (3 - 2 * k)
            return CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
        }
        var f = PracticeFrame(cursor: true)
        let keysOf = { (mode: WheelMode) in Settings.keys(for: mode).flags }
        let single = { (mode: WheelMode) in Settings.switchKey(for: mode).flags }
        // 0–1.2 s: to the file and away with it.
        if t < 0.5 { f.file = PracticeModel.home; return f }
        f.dragging = true
        f.file = mix(PracticeModel.home, grab, (t - 0.5) / 0.9)
        if t < 1.5 { return f }
        // 1.5 s: the keys, the wheel.
        f.centre = centre
        f.wheel = goal
        f.held = t < 2.4 ? keysOf(goal) : []
        var wheelEnd = 3.0
        if tour {
            // With the keys let go, one key each switches wheel; then back.
            let stops: [(Double, WheelMode)] = [(3.2, .tools), (4.4, .share), (5.6, goal)]
            for (at, mode) in stops where t >= at {
                f.wheel = mode
                f.held = t < at + 0.5 ? single(mode) : []
            }
            wheelEnd = 6.8
        }
        let dropAt = wheelEnd + 1.0
        if t < wheelEnd { return f }
        f.file = mix(grab, PracticeModel.point(of: target, count: count, centre: centre), (t - wheelEnd) / 0.8)
        f.highlight = t >= wheelEnd + 0.5 ? target : nil
        if t < dropAt { return f }
        f = PracticeFrame(cursor: true)
        f.result = PracticeModel.result(of: PracticeModel.actions(goal)[target], mode: goal)
        guard tour, t >= 9.2 else { return f }
        // Then the tools: dropped on «Ridimensiona», a group, the panel with its variants opens; one is picked.
        let tools = PracticeModel.actions(.tools), group = 1
        let slot = PracticeModel.point(of: group, count: tools.count, centre: centre)
        f = PracticeFrame(dragging: true, cursor: true)
        f.file = mix(PracticeModel.home, grab, (t - 9.2) / 0.8)
        if t < 10.1 { return f }
        f.centre = centre
        f.wheel = .tools
        f.held = t < 10.8 ? keysOf(.tools) : []
        if t < 11.0 { return f }
        f.file = mix(grab, slot, (t - 11.0) / 0.7)
        f.highlight = t >= 11.4 ? group : nil
        if t < 11.9 { return f }
        f = PracticeFrame(cursor: true)
        f.panel = tools[group].key
        f.file = mix(slot, firstOption, (t - 12.2) / 0.7)
        if t < 13.4 { return f }
        f.panel = nil
        if let first = PracticeModel.members(of: tools[group].key).first { f.result = PracticeModel.result(of: first, mode: .tools) }
        return f
    }
}

/// One scene to try. Left alone for `idleDelay` seconds it plays the demo once (PracticeScript), then waits again;
/// a drag stops the demo at once. `frozen` stops the demo at that second (snapshots, the README).
private struct PracticeScene: View {
    let goal: WheelMode
    let idleDemo: Bool
    let frozen: Double?
    var tour = false
    /// Told each time a wheel opens or a drop gives a result (the demo doesn't count): wheels opened, a result yet.
    var progress: (Set<WheelMode>, Bool) -> Void = { _, _ in }
    @StateObject private var model: PracticeModel
    @State private var demoFrom: Date?
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    nonisolated static let idleDelay: TimeInterval = 5

    init(goal: WheelMode, idleDemo: Bool, frozen: Double?, tour: Bool = false, allowed: Set<WheelMode> = PracticeModel.allModes,
         progress: @escaping (Set<WheelMode>, Bool) -> Void = { _, _ in }) {
        self.goal = goal
        self.idleDemo = idleDemo
        self.frozen = frozen
        self.tour = tour
        self.progress = progress
        _model = StateObject(wrappedValue: PracticeModel(goal: goal, allowed: allowed))
    }

    /// The wheels page shows a checkmark by each wheel opened.
    private var checks: Set<WheelMode>? { tour ? model.opened : nil }

    private var demoLength: Double { PracticeScript.duration(goal, tour: tour) + 1.6 }

    var body: some View {
        Group {
            if let frozen {
                PracticeCanvas(frame: PracticeScript.frame(at: frozen, goal: goal, tour: tour), goal: goal, interactive: false,
                               switching: tour, checks: checks)
            } else if let demoFrom {
                TimelineView(.animation) { context in
                    let t = min(context.date.timeIntervalSince(demoFrom), demoLength)
                    PracticeCanvas(frame: PracticeScript.frame(at: t, goal: goal, tour: tour), goal: goal, interactive: false,
                                   switching: tour, checks: checks)
                }
            } else {
                PracticeCanvas(frame: model.frame, goal: goal, interactive: true, switching: tour, checks: checks,
                               choose: { model.choose($0) })
            }
        }
        .onChange(of: model.opened) { progress($0, model.converted) }
        .onChange(of: model.converted) { progress(model.opened, $0) }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("practice"))
            .onChanged {
                if demoFrom != nil { demoFrom = nil }
                model.drag(to: $0.location)
            }
            .onEnded { _ in model.drop() })
        .onAppear { if frozen == nil { model.start() } }
        .onDisappear { model.stop() }
        .onReceive(tick) { now in
            guard frozen == nil, idleDemo else { return }
            if let from = demoFrom {
                if now.timeIntervalSince(from) > demoLength { demoFrom = nil; model.lastActivity = now }
            } else if model.isIdle(for: Self.idleDelay, now: now) {
                demoFrom = now
            }
        }
        .coordinateSpace(name: "practice")
        .frame(width: PracticeModel.size.width, height: PracticeModel.size.height)
    }
}

/// Draws one PracticeFrame: the keys at the top, the wheel, the file, the result, and a line saying what to do.
private struct PracticeCanvas: View {
    let frame: PracticeFrame
    let goal: WheelMode
    let interactive: Bool
    /// Whether a single key switches wheel here (not on the convert page, where only Convert opens).
    var switching = true
    /// The wheels opened so far, each with a checkmark under its keys; nil: no checkmarks.
    var checks: Set<WheelMode>?
    var choose: (WheelAction?) -> Void = { _ in }

    private var accent: Color { Color(nsColor: Settings.accentColor) }

    /// The keys shown at the top: on the convert page only Convert's, so the other wheels don't distract; else all three.
    static func keyRow(goal: WheelMode, switching: Bool) -> [WheelMode] {
        switching ? [.convert, .tools, .share] : [goal]
    }

    private var hint: String {
        if let result = frame.result {
            switch result {
            case .file(let name, _): return L("Fatto: nel Finder «%@» comparirebbe accanto all'originale.", name)
            case .sent(let text): return text
            }
        }
        if frame.panel != nil { return L("Una voce con più varianti: scegline una. Nell'app il pannello si apre accanto al file.") }
        if frame.cancelled { return L("Rilasciata al centro: annullato. Riprova!") }
        if frame.wheel != nil {
            if !frame.held.isEmpty { return L("Puoi già lasciare i tasti: la ruota resta aperta.") }
            return switching ? L("Rilascia la foto su una voce. Al centro annulli; un tasto solo cambia ruota.")
                             : L("Rilascia la foto su un formato. Al centro annulli.")
        }
        if frame.dragging { return L("Ora premi %@ senza lasciare la foto.", Settings.keys(for: goal).label) }
        if let checks, interactive {
            return checks.isSuperset(of: PracticeModel.allModes) ? L("Tutte e tre provate!") : L("Prova tu: apri tutte e tre le ruote.")
        }
        return interactive ? L("Prova tu: trascina la foto.") : ""
    }

    var body: some View {
        ZStack {
            // The three wheels and their keys: the one in use lights up.
            // The name under each key, so the row is narrow enough for the top of the circle.
            HStack(alignment: .top, spacing: 14) {
                ForEach(Self.keyRow(goal: goal, switching: switching), id: \.self) { mode in
                    let on = frame.wheel == mode || (frame.wheel == nil && !frame.held.isEmpty && Settings.keys(for: mode).flags == frame.held)
                    VStack(spacing: 2) {
                        // Alone (convert page), the keys that open it; in the row of three, the single key that switches to it.
                        KeyCaps(label: switching ? Settings.switchKey(for: mode).label : Settings.keys(for: mode).label,
                                held: switching ? Settings.switchMode(from: [], to: frame.held) == mode : frame.held == Settings.keys(for: mode).flags)
                        HStack(spacing: 3) {
                            if let checks {
                                Image(systemName: checks.contains(mode) ? "checkmark.circle.fill" : "circle")
                                    .font(.caption)
                                    .foregroundStyle(checks.contains(mode) ? Color.green : Color.secondary.opacity(0.6))
                                    .accessibilityLabel(checks.contains(mode) ? L("provata") : L("da provare"))
                            }
                            Text(mode.wheelName).font(.caption.weight(.medium)).foregroundStyle(on ? accent : .secondary).fixedSize()
                        }
                    }
                }
            }
            .fits("tasti")
            .position(x: PracticeModel.middle.x, y: 24)

            // Always there, shown by its opacity: an AppKit view inserted with a transition gets an opaque backdrop.
            let mode = frame.wheel ?? goal
            WheelPreview(actions: PracticeModel.actions(mode), token: "practice", highlight: frame.highlight, mode: mode)
                .frame(width: PracticeModel.radius * 2, height: PracticeModel.radius * 2)
                .scaleEffect(frame.wheel == nil ? 0.7 : 1)
                .opacity(frame.wheel == nil ? 0 : 1)
                .fits("ruota")
                .position(frame.centre)
                .allowsHitTesting(false)

            if let result = frame.result {
                VStack(spacing: 4) {
                    ZStack(alignment: .bottomTrailing) {
                        switch result {
                        case .file(_, let type):
                            Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: 64, height: 64)
                        case .sent:
                            Image(systemName: "paperplane.fill").font(.system(size: 40)).foregroundStyle(accent).frame(width: 64, height: 64)
                        }
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .green)
                    }
                    if case .file(let name, _) = result { Text(name).font(.callout.weight(.medium)) }
                }
                .fits("risultato")
                .position(PracticeModel.middle)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                VStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(for: .jpeg)).resizable().frame(width: 52, height: 52)
                    Text(L("foto") + ".jpg").font(.caption).opacity(frame.dragging ? 0 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if frame.cursor {
                        Image(systemName: "cursorarrow").font(.title3).foregroundStyle(.primary).offset(x: 10, y: -6)
                    }
                }
                .scaleEffect(frame.highlight != nil ? 0.7 : 1)
                .opacity(frame.panel == nil ? 1 : 0)
                .fits(frame.dragging ? "foto trascinata" : "foto")
                .position(frame.file)
                .onHover { inside in
                    guard interactive else { return }
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
            }

            // At rest, an arrow points at the photo: what to pick up first.
            if frame.wheel == nil && !frame.dragging && frame.result == nil && frame.panel == nil && !frame.cancelled {
                HStack(alignment: .bottom, spacing: 4) {
                    Image(systemName: "arrow.turn.left.down").font(.title3.weight(.semibold))
                    Text(L("Trascinami")).font(.callout.weight(.semibold)).offset(y: -12)
                }
                .foregroundStyle(accent)
                .fits("richiamo")
                .position(x: PracticeModel.home.x + 86, y: PracticeModel.home.y - 52)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // The real options panel, smaller: the variants of the group the photo was dropped on.
            if let group = frame.panel {
                OptionsView(title: L(group), actions: PracticeModel.members(of: group), fileCount: 1, choose: choose)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 6))
                    .fits("pannello")
                    .scaleEffect(0.58)
                    .position(x: PracticeModel.middle.x, y: PracticeModel.middle.y - 4)
                    .allowsHitTesting(interactive)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                if frame.cursor {
                    Image(systemName: "cursorarrow").font(.title3).foregroundStyle(.primary).position(frame.file)
                }
            }

            Text(hint)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420)
                .fits("suggerimento")
                .position(x: PracticeModel.middle.x, y: PracticeModel.size.height - 16)
                .animation(.none, value: hint)
        }
        .frame(width: PracticeModel.size.width, height: PracticeModel.size.height)
        .contentShape(Rectangle())
    }
}

private extension WheelMode {
    var wheelName: String {
        switch self {
        case .convert: return L("Converti")
        case .tools: return L("Strumenti")
        case .share: return L("Condividi")
        }
    }
}

private struct KeyCaps: View {
    let label: String
    let held: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(label.components(separatedBy: " + "), id: \.self) { key in
                Text(key)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(held ? Color.white : Color.primary)
                    .background(held ? Color(nsColor: Settings.accentColor) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .scaleEffect(held ? 0.96 : 1)
            }
        }
    }
}

/// The first page: the app's icon (the one Settings → Aspetto picks for the Dock) on a soft halo in the accent colour.
private struct WelcomeScene: View {
    var body: some View {
        let accent = Color(nsColor: Settings.accentColor)
        ZStack {
            Circle().fill(RadialGradient(colors: [accent.opacity(0.35), accent.opacity(0)], center: .center, startRadius: 40, endRadius: 130))
                .frame(width: 260, height: 260)
            Circle().strokeBorder(accent.opacity(0.35), lineWidth: 1.5).frame(width: 196, height: 196)
            Image(nsImage: DockIcon.shared.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 150, height: 150)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        }
        .fits("benvenuto")
        .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
        .accessibilityHidden(true)
    }
}

/// A Finder menu reaching the Rondelle services, then the menu bar's undo.
private struct MenusScene: View {
    let step: Int

    var body: some View {
        ZStack {
            MockMenu(rows: [(L("Apri"), false), (L("Copia"), false), (L("Servizi"), step == 1 || step == 2)])
                .frame(width: 150)
                .fits("menu Finder")
                .position(x: 125, y: 84)
            MockMenu(rows: [(L("Rondelle: Converti…"), step == 2), (L("Rondelle: Strumenti…"), false), (L("Rondelle: Comprimi"), false)])
                .fixedSize()
                .fits("menu Servizi")
                .position(x: 290, y: 122)
                .opacity(step >= 1 && step <= 2 ? 1 : 0.15)
            HStack(alignment: .top, spacing: 8) {
                Image(nsImage: AppDelegate.menuBarIcon())
                MockMenu(rows: [(L("Annulla ultima conversione"), step >= 4 && step <= 5), (L("Recenti"), false)]).fixedSize()
            }
            .fits("menu Rondelle")
            .position(x: 230, y: 214)
            .opacity(step >= 3 ? 1 : 0.25)
        }
        .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
        .animation(step == 0 ? .none : .easeInOut(duration: 0.35), value: step)
    }
}

private struct MockMenu: View {
    let rows: [(String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows.indices, id: \.self) { i in
                Text(rows[i].0)
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(rows[i].1 ? Color.white : Color.primary)
                    .background(rows[i].1 ? Color(nsColor: Settings.accentColor) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
    }
}

/// What Settings lets you change, one line per pane (only what is really there), and a button to open them.
private struct SettingsScene: View {
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                line("chart.pie.fill", L("Ruota (la ruota)"), L("scegli e riordina le voci per ogni tipo di file, aggiungi app a Condividi."))
                line("paintpalette.fill", L("Aspetto"), L("colore, forma e dimensione della ruota, effetto vetro."))
                line("keyboard", L("Comportamento"), L("i tasti di ogni ruota e la lingua."))
                line("slider.horizontal.3", L("Conversioni"), L("qualità, dimensioni e dove salvare i risultati."))
            }
            .frame(width: 340)
            Button { SettingsWindow.shared.show(pane: .wheel) } label: {
                Label(L("Apri Impostazioni"), systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .capsuleButton()
            .controlSize(.large)
        }
        .fits("impostazioni")
        .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
    }

    private func line(_ symbol: String, _ pane: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(Color(nsColor: Settings.accentColor))
            (Text(pane).fontWeight(.semibold).foregroundColor(.primary) + Text(": ") + Text(text))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What Rondelle does with files, in three lines. The Home folder permission is the page's main button (TutorialView).
private struct PrivacyScene: View {
    let granted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(granted ? Color.green : Color(nsColor: Settings.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                line("icloud.slash", L("Nessun file va online: la parte che legge i file non ha accesso alla rete."))
                line("arrow.triangle.2.circlepath", L("In rete vanno solo il controllo degli aggiornamenti e i messaggi che scrivi tu."))
                line("translate", L("La traduzione usa il servizio di Apple, che secondo Apple lavora sul dispositivo."))
            }
            .frame(width: 360)
        }
        .fits("privacy")
        .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
/// `--test-tutorial`: the practice scene driven by synthetic drags and keys, as a person would.
@MainActor
enum TutorialPracticeTest {
    static func run() -> [String] {
        var problems: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
        let model = PracticeModel(goal: .convert)
        model.drag(to: CGPoint(x: 200, y: 150))
        expect(model.frame.dragging && model.frame.wheel == nil, "trascino senza tasti: nessuna ruota")
        model.keys(Settings.keys(for: .convert).flags)
        expect(model.frame.wheel == .convert, "i tasti di Converti aprono la ruota")
        model.keys([])
        expect(model.frame.wheel == .convert, "lasciati i tasti la ruota resta")
        for mode in [WheelMode.tools, .share, .convert] {
            model.keys(Settings.switchKey(for: mode).flags)
            expect(model.frame.wheel == mode, "un tasto solo passa a \(mode)")
            model.keys([])
            expect(model.frame.wheel == mode, "lasciato il tasto resta \(mode)")
        }
        let centre = model.frame.centre
        let mid = PracticeModel.middle, zone = PracticeModel.zone
        func central(_ c: CGPoint) -> Bool { abs(c.x - mid.x) <= zone.width && abs(c.y - mid.y) <= zone.height }
        expect(central(centre), "ruota nella zona centrale: \(centre)")
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: PracticeModel.size.width, y: PracticeModel.size.height), CGPoint(x: 5, y: PracticeModel.size.height - 5)] {
            let c = PracticeModel.wheelCentre(near: corner)
            expect(central(c), "foto nell'angolo \(corner): ruota al centro \(c)")
        }
        model.drag(to: PracticeModel.point(of: 2, count: model.actions.count, centre: centre))
        expect(model.frame.highlight == 2, "sopra la terza voce: evidenziata (\(String(describing: model.frame.highlight)))")
        model.drop()
        if case .file(let name, _)? = model.frame.result {
            expect(name.hasSuffix(".pdf"), "rilasciata su PDF: \(name)")
        } else {
            problems.append("rilasciata su una voce: nessun risultato")
        }
        model.drag(to: CGPoint(x: 200, y: 150))
        expect(model.frame.result == nil && model.frame.dragging, "si ricomincia trascinando di nuovo")
        model.keys(Settings.keys(for: .convert).flags)
        model.drag(to: model.frame.centre)
        expect(model.frame.highlight == nil, "al centro nessuna voce")
        model.drop()
        expect(model.frame.cancelled && model.frame.wheel == nil && model.frame.result == nil, "al centro: annullato")
        model.keys([])
        model.drag(to: CGPoint(x: 330, y: 80))
        model.drop()
        expect(!model.frame.cancelled && model.frame.file == PracticeModel.home, "senza ruota la foto torna al suo posto")
        // A group (Ridimensiona) opens the options panel with the real variants; one of them gives the result.
        if Settings.wheelStyle.opensPanel {
            model.drag(to: CGPoint(x: 200, y: 150))
            model.keys(Settings.keys(for: .tools).flags)
            model.keys([])
            let tools = PracticeModel.actions(.tools)
            model.drag(to: PracticeModel.point(of: 1, count: tools.count, centre: model.frame.centre))
            model.drop()
            expect(model.frame.panel == "Ridimensiona" && model.frame.wheel == nil, "rilasciata su Ridimensiona: pannello delle varianti")
            let variants = PracticeModel.members(of: "Ridimensiona")
            expect(variants.contains { $0.key == "50%" } && variants.contains { $0.key == "Misura…" }, "varianti vere: \(variants.map(\.key))")
            model.drag(to: CGPoint(x: 10, y: 10))
            expect(model.frame.panel != nil && !model.frame.dragging, "col pannello aperto la foto non si trascina")
            model.choose(variants.first { $0.key == "Misura…" })
            if case .file(let name, _)? = model.frame.result {
                expect(model.frame.panel == nil && name.contains("px"), "scelta Misura…: \(name)")
            } else {
                problems.append("scelta una variante: nessun risultato")
            }
            expect(PracticeModel.members(of: "Comprimi").count >= 2, "Comprimi ha le sue varianti")
        }
        model.stop()
        // The demo waits until the scene is left alone, at rest; any drag counts as activity.
        let idle = PracticeModel(goal: .convert)
        let later = Date().addingTimeInterval(PracticeScene.idleDelay + 0.1)
        expect(!idle.isIdle(for: PracticeScene.idleDelay), "la demo non parte subito")
        expect(idle.isIdle(for: PracticeScene.idleDelay, now: later), "la demo parte se la scena resta ferma")
        idle.drag(to: CGPoint(x: 200, y: 150))
        expect(!idle.isIdle(for: PracticeScene.idleDelay, now: Date().addingTimeInterval(60)), "mentre trascini la demo non parte")
        idle.drop()
        expect(!idle.isIdle(for: PracticeScene.idleDelay), "appena rilasciata la demo non parte")
        idle.stop()
        problems += lockProblems()
        // A welcome and five pages, short: the promise is «in un minuto».
        let pages = tutorialPages
        expect(pages.count == 6, "pagine del tutorial: \(pages.count), attese 6")
        if case .welcome = pages.first?.scene {} else { problems.append("la prima pagina non è il benvenuto") }
        let words = pages.reduce(0) { $0 + "\($1.title) \($1.text)".split(whereSeparator: \.isWhitespace).count }
        expect(words <= 140, "testo delle pagine troppo lungo: \(words) parole")
        if case .privacy = pages.last?.scene {} else { problems.append("l'ultima pagina non è quella del permesso") }
        if case .settings = pages[pages.count - 2].scene {} else { problems.append("la penultima pagina non è quella delle Impostazioni") }
        let demo = PracticeScript.frame(at: 2.0, goal: .convert, tour: true)
        expect(demo.wheel == .convert && demo.cursor, "la scena da sola apre la ruota")
        let end = PracticeScript.frame(at: PracticeScript.duration(.convert, tour: true) - 0.1, goal: .convert, tour: true)
        expect(end.result != nil, "la scena da sola finisce con un risultato")
        expect(PracticeScript.frame(at: 12.8, goal: .convert, tour: true).panel != nil, "la scena da sola mostra il pannello delle varianti")
        // The wheel stays inside the circle wherever it opens.
        let scene = TutorialRing.sceneCentre, circle = TutorialRing.diameter / 2
        for dx in [-zone.width, zone.width] {
            for dy in [-zone.height, zone.height] {
                let x = scene.x + dx - circle, y = scene.y + dy - circle
                expect(hypot(x, y) + PracticeModel.radius <= TutorialRing.safe, "ruota aperta a (\(dx), \(dy)) fuori dal cerchio")
            }
        }
        return problems + fitProblems()
    }

    /// The two pages to try can't be skipped the first time: on «Prova a convertire» only the Convert wheel opens and
    /// «Avanti» waits for a conversion; on «Tre ruote» it waits for all three wheels. Remembered for the next opening.
    /// Runs on a store of its own, so the real flags don't matter (and aren't touched).
    static func lockProblems() -> [String] {
        var problems: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
        let suite = "rondelle.test.tutorial"
        guard let store = UserDefaults(suiteName: suite) else { return ["nessun archivio di prova per il tutorial"] }
        store.removePersistentDomain(forName: suite)
        TutorialProgress.store = store
        let pages = tutorialPages
        guard let convertPage = pages.firstIndex(where: { if case .practice(_, false) = $0.scene { return true }; return false }),
              let wheelsPage = pages.firstIndex(where: { if case .practice(_, true) = $0.scene { return true }; return false }) else {
            return ["mancano le pagine di prova"]
        }
        func passable(_ page: Int) -> Bool {
            TutorialProgress.passable(page, triedConvert: TutorialProgress.triedConvert, triedWheels: TutorialProgress.triedWheels)
        }
        func reachable(_ target: Int, from page: Int) -> Bool {
            TutorialProgress.reachable(target, from: page, triedConvert: TutorialProgress.triedConvert, triedWheels: TutorialProgress.triedWheels)
        }
        expect(passable(0), "dal benvenuto si va avanti")
        expect(!passable(convertPage), "prima volta: «Avanti» spento prima di convertire")
        expect(!reachable(pages.count - 1, from: 0), "prima volta: i puntini saltano la prova")
        expect(reachable(convertPage, from: 0), "i puntini portano fino alla prima prova")
        expect(reachable(0, from: wheelsPage), "indietro si va sempre")

        // On the convert page only the Convert wheel opens; a drop on a format unlocks.
        let only = PracticeModel(goal: .convert, allowed: [.convert])
        only.drag(to: CGPoint(x: 200, y: 150))
        for mode in [WheelMode.tools, .share] where Settings.keys(for: mode).flags != Settings.keys(for: .convert).flags {
            only.keys(Settings.keys(for: mode).flags)
            expect(only.frame.wheel == nil, "pagina di prova: i tasti di \(mode) non aprono la ruota")
            only.keys([])
        }
        only.keys(Settings.keys(for: .convert).flags)
        expect(only.frame.wheel == .convert, "pagina di prova: i tasti di Converti aprono la ruota")
        only.keys([])
        for mode in [WheelMode.tools, .share] {
            only.keys(Settings.switchKey(for: mode).flags)
            only.keys([])
            expect(only.frame.wheel == .convert, "pagina di prova: un tasto solo non passa a \(mode)")
        }
        expect(PracticeCanvas.keyRow(goal: .convert, switching: false) == [.convert], "pagina di prova: in alto solo i tasti di Converti")
        expect(PracticeCanvas.keyRow(goal: .convert, switching: true).count == 3, "tre ruote: in alto i tasti di tutte e tre")
        expect(!only.converted, "nessun risultato prima del rilascio")
        only.drag(to: PracticeModel.point(of: 0, count: only.actions.count, centre: only.frame.centre))
        only.drop()
        expect(only.converted && only.opened == [.convert], "rilasciata su un formato: conversione riuscita (\(only.opened))")
        only.stop()
        TutorialProgress.triedConvert = only.converted
        expect(passable(convertPage), "dopo la conversione «Avanti» si accende")
        expect(!passable(wheelsPage), "«Avanti» spento sulle tre ruote finché non le provi")

        // On the wheels page each wheel opened gets its checkmark; all three unlock.
        let tour = PracticeModel(goal: .convert)
        tour.drag(to: CGPoint(x: 200, y: 150))
        tour.keys(Settings.keys(for: .convert).flags)
        tour.keys([])
        expect(tour.opened == [.convert], "una ruota aperta, una spunta")
        for mode in [WheelMode.tools, .share] {
            tour.keys(Settings.switchKey(for: mode).flags)
            tour.keys([])
        }
        expect(tour.opened == PracticeModel.allModes, "tutte e tre le ruote aperte: \(tour.opened)")
        tour.stop()
        TutorialProgress.triedWheels = tour.opened.isSuperset(of: PracticeModel.allModes)
        expect(passable(wheelsPage), "provate le tre ruote «Avanti» si accende")

        // Next opening: the store remembers, every page can be skipped.
        expect(store.bool(forKey: "tutorialTriedConvert") && store.bool(forKey: "tutorialTriedWheels"), "prove ricordate per la volta dopo")
        expect(reachable(pages.count - 1, from: 0), "dalla seconda volta si salta tutto")
        // The rest of the run (fit test, real window) keeps this store, emptied: the real flags are never written.
        store.removePersistentDomain(forName: suite)
        return problems
    }

    /// Every page, at every step of its scene, drawn in the round window: each named piece (`fits`) inside the circle,
    /// the text above the buttons. The wheel counts as round.
    static func fitProblems() -> [String] {
        var problems: [String] = []
        let d = TutorialRing.diameter, centre = CGPoint(x: d / 2, y: d / 2)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: [.borderless], backing: .buffered, defer: false)
        var worst: (CGFloat, String) = (0, "")
        for (index, page) in tutorialPages.enumerated() {
            let steps = TutorialView.snapshotSteps(page.scene)
            for step in 0..<steps {
                TutorialFit.frames = [:]
                let host = NSHostingView(rootView: TutorialView(page: index, frozenStep: step) {})
                host.frame = NSRect(x: 0, y: 0, width: d, height: d)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                let frames = TutorialFit.frames, place = "pagina \(index + 1) passo \(step)"
                for name in ["titolo", "testo", "navigazione", "puntini", "chiudi"] where frames[name] == nil {
                    problems.append("\(place): manca «\(name)»")
                }
                for (name, rect) in frames {
                    let far: CGFloat
                    if name == "ruota" {
                        far = hypot(rect.midX - centre.x, rect.midY - centre.y) + rect.width / 2
                    } else {
                        far = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                            .map { hypot($0.x - centre.x, $0.y - centre.y) }.max() ?? 0
                    }
                    if far > worst.0 { worst = (far, "\(name), \(place)") }
                    // The dragged photo follows the pointer: the circle cuts it like the window's edge.
                    if far > TutorialRing.safe, name != "foto trascinata" {
                        problems.append("\(place): «\(name)» esce dal cerchio (\(Int(far)) > \(Int(TutorialRing.safe)) punti)")
                    }
                }
                if let text = frames["testo"], let buttons = frames["navigazione"], text.maxY > buttons.minY - 4 {
                    problems.append("\(place): il testo tocca i pulsanti (\(Int(text.maxY)) > \(Int(buttons.minY - 4)))")
                }
                if let text = frames["titolo"], text.minY < TutorialRing.sceneCentre.y + TutorialRing.scene.height / 2 {
                    problems.append("\(place): il titolo entra nella scena")
                }
            }
        }
        print("pezzo più lontano dal centro: \(worst.1), \(Int(worst.0)) punti su \(Int(TutorialRing.safe))")
        // The real window: round, without frame, takes the keys; the empty background moves it.
        _ = NSApplication.shared
        TutorialWindow.shared.show(page: 3, frozenStep: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        if let round = NSApp.windows.first(where: { $0 is RoundWindow && $0.isVisible }) {
            if !(round.styleMask == [.borderless] && !round.isOpaque && round.backgroundColor == .clear && round.canBecomeKey
                 && round.frame.size == NSSize(width: d, height: d)) {
                problems.append("finestra del tutorial non tonda o senza tasti: \(round.styleMask) \(round.frame.size)")
            }
            // Below the page dots, near the bottom of the disc: nothing there but the background.
            let hit = round.contentView?.hitTest(NSPoint(x: d / 2, y: 30))
            if !(hit is WindowDragArea.DragView) { problems.append("lo sfondo non sposta la finestra: \(String(describing: hit))") }
            if round.contentView?.hitTest(NSPoint(x: 6, y: 6)) is WindowDragArea.DragView { problems.append("fuori dal cerchio un clic sposta la finestra") }
            round.close()
        } else {
            problems.append("la finestra tonda del tutorial non si apre")
        }
        problems += practiceDragProblems()
        return Array(Set(problems)).sorted()
    }

    /// Dragging the photo in the practice scene must not move the window or tile it at a screen edge (seen on a
    /// smaller MacBook): the window, placed against the left edge of the screen, keeps its frame after a drag of the
    /// photo towards that edge, and only the empty background can move it.
    static func practiceDragProblems() -> [String] {
        var problems: [String] = []
        TutorialWindow.shared.show(page: 1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let round = NSApp.windows.first(where: { $0 is RoundWindow && $0.isVisible }) else { return ["la scena di prova non si apre"] }
        defer { round.close() }
        if round.isMovableByWindowBackground { problems.append("la finestra si sposta da ogni punto dello sfondo, anche dalla scena") }
        if let screen = round.screen ?? NSScreen.main {
            round.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.midY - TutorialRing.diameter / 2))
        }
        let before = round.frame
        // The photo, in window coordinates (bottom left origin).
        let scene = CGPoint(x: TutorialRing.sceneCentre.x - TutorialRing.scene.width / 2, y: TutorialRing.sceneCentre.y - TutorialRing.scene.height / 2)
        let photo = NSPoint(x: scene.x + PracticeModel.home.x, y: TutorialRing.diameter - (scene.y + PracticeModel.home.y))
        if let hit = round.contentView?.hitTest(photo) {
            var view: NSView? = hit
            while let v = view, v !== round.contentView?.superview {
                if v is WindowDragArea.DragView { problems.append("sotto la foto c'è lo sfondo che sposta la finestra") }
                view = v.superview
            }
            // With the whole background movable, AppKit hands a click to the window server as a window drag when the
            // view under it says it can move the window (a SwiftUI host does): then the photo never moves, the window does.
            if round.isMovableByWindowBackground && hit.mouseDownCanMoveWindow {
                problems.append("un clic sulla foto può spostare la finestra (\(type(of: hit)))")
            }
        } else {
            problems.append("la foto non riceve il clic")
        }
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: round.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        // Towards the left edge of the screen, past it: where macOS would tile the window.
        for step in 1...12 {
            if let e = event(.leftMouseDragged, NSPoint(x: photo.x - CGFloat(step) * 20, y: photo.y)) { NSApp.postEvent(e, atStart: false) }
        }
        if let up = event(.leftMouseUp, NSPoint(x: photo.x - 240, y: photo.y)) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, photo) { NSApp.sendEvent(down) }
        while let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        // RONDELLE_TUTORIAL_HOLD=seconds: the scene stays open for a drag by hand (or by a real pointer) before the check.
        if let hold = ProcessInfo.processInfo.environment["RONDELLE_TUTORIAL_HOLD"].flatMap(Double.init) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            print("scena aperta per \(Int(hold)) s, finestra \(before)")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: hold))
        }
        if round.frame != before { problems.append("trascinando la foto la finestra si sposta: \(before) → \(round.frame)") }
        print("finestra prima \(before), dopo \(round.frame)")
        return problems
    }
}

/// What the pages reported, for the fit test.
@MainActor
enum TutorialFit {
    static var frames: [String: CGRect] = [:]
}

/// The README's animation: the first scene playing by itself, drawn frame by frame in the app (no screen capture),
/// with the wheel's own background instead of Liquid Glass, which a drawing of the view can't reproduce.
@MainActor
enum TutorialGIF {
    static func write(to url: URL, fps: Double = 15) -> Int32 {
        let size = NSSize(width: 640, height: 300), scale = 2
        let total = PracticeScript.duration(.convert, tour: true) + 1.6
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, Int(total * fps) + 1, nil) else {
            print("impossibile creare \(url.path)")
            return 1
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let accent = Color(nsColor: Settings.accentColor)
        var t = 0.0
        while t < total {
            let host = NSHostingView(rootView: ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                PracticeScene(goal: .convert, idleDemo: false, frozen: t, tour: true)
            }.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            // Two pixels per point, whatever the screen: the README shows it 640 wide, so it stays sharp on Retina.
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { print("nessuna immagine a \(t) s"); return 1 }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let source = rep.cgImage,
                  let context = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                print("fotogramma non disegnabile a \(t) s")
                return 1
            }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: size.width * CGFloat(scale), height: size.height * CGFloat(scale)))
            guard let frame = context.makeImage() else { print("fotogramma non creato a \(t) s"); return 1 }
            CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            t += 1 / fps
        }
        guard CGImageDestinationFinalize(gif) else { print("GIF non scritta"); return 1 }
        return 0
    }
}
#endif
