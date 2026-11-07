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
        window.isMovableByWindowBackground = true
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
    static let band: CGFloat = 14
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
    func fits(_ name: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: TutorialFitKey.self, value: [name: g.frame(in: .named(TutorialRing.space))])
        })
    }
}

/// The background, like the wheel: a disc with a ring in the accent colour, cut in six like the wheel's pieces.
private struct WasherBackground: View {
    var body: some View {
        let accent = Color(nsColor: Settings.accentColor), paper = Color(nsColor: .windowBackgroundColor)
        let r = TutorialRing.diameter / 2, band = TutorialRing.band
        ZStack {
            Circle().fill(paper)
            Circle().fill(LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: band)
            ForEach(0..<6, id: \.self) { i in
                Rectangle().fill(paper.opacity(0.85)).frame(width: 2, height: band + 1)
                    .offset(y: -(r - band / 2))
                    .rotationEffect(.degrees(Double(i) * 60 + 30))
            }
            Circle().inset(by: band).strokeBorder(accent.opacity(0.3), lineWidth: 1)
        }
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
    /// The first page plays by itself (`tour`: it also switches wheel); the next three are for trying.
    case practice(WheelMode, tour: Bool)
    case features([TutorialFeature])
    case menus
    case privacy
}

private struct TutorialFeature {
    let symbol: String
    let title: String
    let text: String
}

private struct TutorialPage {
    let title: String
    let text: String
    let scene: TutorialScene
}

/// Worked out when read: the texts name the keys chosen in Settings.
@MainActor
private var tutorialPages: [TutorialPage] {
    func keys(_ mode: WheelMode) -> String { Settings.keys(for: mode).label }
    func switchKeys(_ mode: WheelMode) -> String { Settings.switchKey(for: mode).label }
    var documents = [
        TutorialFeature(symbol: "lock.doc", title: L("Proteggi"),
                        text: L("«ZIP protetto» cifra i file con AES-256. Puoi aggiungere un suggerimento per ricordare la password: si legge anche senza password, quindi non scriverci la password.")),
        TutorialFeature(symbol: "text.viewfinder", title: L("Leggi il testo"),
                        text: L("Estrai il testo da foto e scansioni, o rendi ricercabile un PDF.")),
        TutorialFeature(symbol: "doc.on.doc", title: L("Organizza i PDF"),
                        text: L("Unisci, dividi, riordina e numera le pagine.")),
    ]
    if #available(macOS 15.0, *) {
        documents.insert(TutorialFeature(symbol: "translate", title: L("Traduci"),
                                         text: L("PDF, documenti e sottotitoli fra italiano, inglese e francese. Rondelle riconosce la lingua da solo e usa la traduzione di Apple, che secondo Apple lavora sul dispositivo. Un PDF torna come testo semplice, senza impaginazione né immagini.")), at: 0)
    }
    return [
        TutorialPage(title: L("Benvenuto in Rondelle"),
                     text: L("Trascina un file, scegli cosa farne e trovi il risultato accanto all'originale. Vediamo come in un minuto."),
                     scene: .practice(.convert, tour: true)),
        TutorialPage(title: L("Cambia formato"),
                     text: L("Trascina un file dal Finder e tieni premuto %@: attorno al puntatore compare la ruota dei formati. Rilascia il file sul formato che vuoi; rilasciandolo al centro annulli.", keys(.convert))
                        + " " + L("Poi puoi lasciare i tasti: la ruota resta aperta finché tieni il file. Per cambiare ruota premi %@ (Converti), %@ (Strumenti) o %@ (Condividi).",
                                  switchKeys(.convert), switchKeys(.tools), switchKeys(.share)),
                     scene: .practice(.convert, tour: false)),
        TutorialPage(title: L("Usa gli strumenti"),
                     text: L("Con %@ la ruota mostra gli strumenti per quel tipo di file: comprimi, ridimensiona, unisci, dividi… Le azioni simili sono raccolte in gruppi: passaci sopra per vedere le varianti.", keys(.tools)),
                     scene: .practice(.tools, tour: false)),
        TutorialPage(title: L("Condividi"),
                     text: L("Con %@ la ruota manda i file ad AirDrop, Messaggi, Mail, WhatsApp e altre app.", keys(.share)),
                     scene: .practice(.share, tour: false)),
        TutorialPage(title: L("Traduci, proteggi, leggi"),
                     text: L("Sulla ruota degli strumenti trovi anche questo. Attenzione: il testo nascosto, bianco o coperto di un PDF viene letto e compare nel risultato. Per oscurare davvero, trasforma la pagina in immagine e usa «Copri» in «Modifica»."),
                     scene: .features(documents)),
        TutorialPage(title: L("Senza trascinare, e se sbagli"),
                     text: L("Nel Finder: clic destro sui file → Servizi → «Rondelle: Converti…», «Strumenti…» o «Comprimi». E dal menu di Rondelle «Annulla ultima conversione» sposta nel Cestino i file creati."),
                     scene: .menus),
        TutorialPage(title: L("La tua privacy"),
                     text: L("Rondelle non carica file online: la sandbox di macOS blocca la rete alla parte che legge i file, che legge solo quelli che trascini e salva solo nelle cartelle che autorizzi. In rete vanno solo il controllo degli aggiornamenti e i messaggi che scrivi tu. La traduzione usa il servizio di Apple, che secondo Apple lavora sul dispositivo."),
                     scene: .privacy),
    ]
}

private struct TutorialView: View {
    @State var page: Int
    let frozenStep: Int?
    let close: () -> Void
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = Timer.publish(every: 1.1, on: .main, in: .common).autoconnect()

    /// Without movement (or in a snapshot) each scene stays on the step that explains it best.
    private var shownStep: Int { frozenStep ?? (reduceMotion ? 3 : step) }

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
                Text(current.title).font(.title3.weight(.semibold)).fits("titolo")
                Text(current.text)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 376)
                    .fits("testo")
            }
            .frame(width: 400, height: 118, alignment: .top)
            .position(x: d / 2, y: 346 + 59)
            controls.fits("navigazione").position(x: d / 2, y: 480)
            dots.fits("puntini").position(x: d / 2, y: 510)
            closeButton.fits("chiudi").position(x: d / 2, y: 38)
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
        case .practice: return 7
        case .features(let list): return list.count * 3
        case .menus: return 7
        case .privacy: return 4
        }
    }

    @ViewBuilder private func scene(_ scene: TutorialScene) -> some View {
        switch scene {
        case .practice(let goal, let tour):
            // `frozenStep` (snapshots) stops the scene at that half second.
            PracticeScene(goal: goal, auto: tour && !reduceMotion, frozen: frozenStep.map { Double($0) * 0.5 } ?? (tour && reduceMotion ? 2 : nil), tour: tour)
        case .features(let list):
            // One feature at a time, about three seconds each; without movement the first, until one is clicked.
            FeaturesScene(features: list, shown: frozenStep.map { min($0, list.count - 1) } ?? (reduceMotion ? 0 : step / 3 % list.count))
        case .menus: MenusScene(step: shownStep)
        case .privacy: PrivacyScene()
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(L("Chiudi"))
        .accessibilityLabel(L("Chiudi"))
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(tutorialPages.indices, id: \.self) { i in
                Circle().fill(i == page ? Color(nsColor: Settings.accentColor) : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    .padding(2)
                    .contentShape(Circle())
                    .onTapGesture { go(i) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Pagina %@ di %@", page + 1, tutorialPages.count))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(L("Indietro")) { go(page - 1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .rondelleButton()
                .disabled(page == 0)
            if page == tutorialPages.count - 1 {
                Button(L("Inizia"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .rondelleProminentButton()
            } else {
                Button(L("Avanti")) { go(page + 1) }
                    .keyboardShortcut(.defaultAction)
                    .rondelleProminentButton()
            }
        }
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

    @Published var frame = PracticeFrame()
    let goal: WheelMode
    private var monitor: Any?
    private var reset: Task<Void, Never>?

    init(goal: WheelMode) { self.goal = goal }

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
        guard frame.dragging else { return }
        if let open = frame.wheel {
            if let next = Settings.switchMode(from: before, to: flags), next != open {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { frame.wheel = next; frame.highlight = nil }
            }
        } else if let mode = Settings.mode(for: flags) {
            open(mode)
        }
    }

    func drag(to point: CGPoint) {
        guard frame.panel == nil else { return }
        reset?.cancel()
        if !frame.dragging {
            frame = PracticeFrame(file: point, held: frame.held, dragging: true)
            if let mode = Settings.mode(for: NSEvent.modifierFlags) { open(mode) }
        }
        frame.file = point
        if frame.wheel != nil { frame.highlight = Self.segment(at: point, centre: frame.centre, count: actions.count) }
    }

    func drop() {
        guard frame.panel == nil else { return }
        frame.dragging = false
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
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            frame.panel = nil
            if let option { frame.result = Self.result(of: option, mode: .tools) } else { frame.file = Self.home }
        }
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

    private func open(_ mode: WheelMode) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            frame.centre = Self.wheelCentre(near: frame.file)
            frame.wheel = mode
            frame.highlight = nil
            frame.cancelled = false
        }
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

private struct PracticeScene: View {
    let goal: WheelMode
    /// Plays by itself (first page, reduced motion off); `frozen` stops it at that second (snapshots, the README).
    let auto: Bool
    let frozen: Double?
    var tour = false
    @StateObject private var model: PracticeModel
    @State private var started = Date()

    init(goal: WheelMode, auto: Bool, frozen: Double?, tour: Bool = false) {
        self.goal = goal
        self.auto = auto
        self.frozen = frozen
        self.tour = tour
        _model = StateObject(wrappedValue: PracticeModel(goal: goal))
    }

    var body: some View {
        Group {
            if let frozen {
                PracticeCanvas(frame: PracticeScript.frame(at: frozen, goal: goal, tour: tour), goal: goal, interactive: false)
            } else if auto {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: PracticeScript.duration(goal, tour: tour) + 1.6)
                    PracticeCanvas(frame: PracticeScript.frame(at: t, goal: goal, tour: tour), goal: goal, interactive: false)
                }
            } else {
                PracticeCanvas(frame: model.frame, goal: goal, interactive: true, choose: { model.choose($0) })
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("practice"))
                        .onChanged { model.drag(to: $0.location) }
                        .onEnded { _ in model.drop() })
                    .onAppear { model.start() }
                    .onDisappear { model.stop() }
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
    var choose: (WheelAction?) -> Void = { _ in }

    private var accent: Color { Color(nsColor: Settings.accentColor) }

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
            return frame.held.isEmpty
                ? L("Rilascia la foto su una voce. Al centro annulli; un tasto solo cambia ruota.")
                : L("Puoi già lasciare i tasti: la ruota resta aperta.")
        }
        if frame.dragging { return L("Ora premi %@ senza lasciare la foto.", Settings.keys(for: goal).label) }
        return interactive ? L("Prova tu: trascina la foto.") : ""
    }

    var body: some View {
        ZStack {
            // The three wheels and their keys: the one in use lights up.
            // The name under each key, so the row is narrow enough for the top of the circle.
            HStack(alignment: .top, spacing: 14) {
                ForEach([WheelMode.convert, .tools, .share], id: \.self) { mode in
                    let on = frame.wheel == mode || (frame.wheel == nil && !frame.held.isEmpty && Settings.keys(for: mode).flags == frame.held)
                    VStack(spacing: 2) {
                        KeyCaps(label: Settings.switchKey(for: mode).label, held: Settings.switchMode(from: [], to: frame.held) == mode)
                        Text(mode.wheelName).font(.caption.weight(.medium)).foregroundStyle(on ? accent : .secondary).fixedSize()
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

/// The features of the tools wheel: a tile each, and the text of the one shown (it changes by itself; a click picks one).
private struct FeaturesScene: View {
    let features: [TutorialFeature]
    let shown: Int
    @State private var picked: Int?

    var body: some View {
        let current = picked ?? shown, accent = Color(nsColor: Settings.accentColor)
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ForEach(features.indices, id: \.self) { i in
                    Button { picked = i } label: {
                        VStack(spacing: 6) {
                            Image(systemName: features[i].symbol).font(.title2).frame(height: 26)
                            Text(features[i].title).font(.caption.weight(.medium)).multilineTextAlignment(.center).lineLimit(2)
                        }
                        .foregroundStyle(i == current ? accent : Color.secondary)
                        .frame(width: 86, height: 70)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(i == current ? accent.opacity(0.2) : Color.secondary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .fits("funzioni")
            Text(features[current].text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 380)
                .fits("funzione")
                .id(current)
                .transition(.opacity)
        }
        .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
        .animation(.easeOut(duration: 0.3), value: current)
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

/// The Home folder permission, so that results can be saved next to the originals without asking folder by folder.
private struct PrivacyScene: View {
    @State private var granted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(L("Per salvare i risultati accanto agli originali, consenti l'accesso alla cartella Inizio. Puoi revocarlo quando vuoi da Impostazioni → Privacy; se preferisci, Rondelle chiederà cartella per cartella."))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360)
            Button(granted ? L("Cartella Inizio consentita") : L("Consenti cartella Inizio…")) {
                granted = FolderAccess.request(FolderAccess.realHome, explanation: L("Seleziona la cartella Inizio e premi «Consenti»."))
            }
            .rondelleButton()
            .disabled(granted)
        }
        .fits("privacy")
        .frame(width: TutorialRing.scene.width, height: TutorialRing.scene.height)
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

    /// Every page, at every step of its scene, drawn in the round window: each named piece (`fits`) inside the circle,
    /// the text above the buttons. The wheel counts as round.
    static func fitProblems() -> [String] {
        var problems: [String] = []
        let d = TutorialRing.diameter, centre = CGPoint(x: d / 2, y: d / 2)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: [.borderless], backing: .buffered, defer: false)
        var worst: (CGFloat, String) = (0, "")
        for (index, page) in tutorialPages.enumerated() {
            let steps = index == 0 ? Int(PracticeScript.duration(.convert, tour: true) * 2) + 1 : TutorialView.sceneSteps(page.scene)
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
        TutorialWindow.shared.show(page: 4, frozenStep: 0)
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
        return Array(Set(problems)).sorted()
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
                PracticeScene(goal: .convert, auto: false, frozen: t, tour: true)
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
