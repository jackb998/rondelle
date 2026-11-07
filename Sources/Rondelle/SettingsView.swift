import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    nonisolated static let smallest = NSSize(width: 720, height: 460)
    nonisolated static let largest = NSSize(width: 1_180, height: 820)
    private var window: NSWindow?
    nonisolated static let sidebarWidth: CGFloat = 240

    /// How long the sidebar takes to go or come back.
    nonisolated static let sidebarAnimation: TimeInterval = 0.25
    let sidebar = SettingsSidebar()
    private var slide: Timer?

    /// Hiding the sidebar takes its width off the window: the panes are forms, wider they would only stretch.
    /// SwiftUI never relayouts for it: the column stays open and the whole view slides under the window's left edge,
    /// which moves right (left, to show it again). Each frame is one window resize, the pane stays still on screen.
    /// Hidden, the sidebar sits outside the window and is disabled, so Tab and VoiceOver don't go there.
    func toggleSidebar() {
        guard slide == nil, let window, let host = (window.contentViewController as? SettingsContainer)?.host.view,
              let container = host.superview else { return }
        let hide = sidebar.shown
        let width = Self.sidebarWidth
        let pane = window.frame.width - (hide ? width : 0)
        let startX = window.frame.minX
        var endX = hide ? startX + width : startX - width
        if !hide, let screen = window.screen?.visibleFrame { endX = max(endX, screen.minX) }
        // Both sizes allowed while it moves; the final limits once it has arrived.
        window.contentMinSize.width = Self.smallest.width - width
        window.contentMaxSize.width = Self.largest.width
        host.autoresizingMask = []
        if !hide { sidebar.outside = false }
        withAnimation(.easeInOut(duration: Self.sidebarAnimation)) { sidebar.shown = !hide }
        let start = CACurrentMediaTime()
        let step = { [weak self] in
            let t = min((CACurrentMediaTime() - start) / Self.sidebarAnimation, 1)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(2 - 2 * t, 2) / 2
            let visible = width * (hide ? 1 - eased : eased)   // how much of the sidebar is still in the window
            var frame = window.frame
            frame.size.width = pane + visible
            frame.origin.x = startX + (endX - startX) * eased
            window.setFrame(frame, display: false)
            host.frame = NSRect(x: visible - width, y: 0, width: pane + width, height: container.bounds.height)
            if t >= 1 { self?.endSlide(hide: hide, host: host) }
        }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { step() } }
        RunLoop.main.add(timer, forMode: .common)
        slide = timer
    }

    private func endSlide(hide: Bool, host: NSView) {
        slide?.invalidate()
        slide = nil
        host.autoresizingMask = [.width, .height]   // keeps the sidebar's 240 points outside on the left when hidden
        if hide { sidebar.outside = true }
        let removed = hide ? Self.sidebarWidth : 0
        window?.contentMinSize = NSSize(width: Self.smallest.width - removed, height: Self.smallest.height)
        window?.contentMaxSize = NSSize(width: Self.largest.width - removed, height: Self.largest.height)
    }

    func show(pane: SettingsPane = .appearance) {
        if window == nil {
            let window = NSWindow(contentViewController: SettingsContainer(SettingsView(pane: pane)))
            window.title = L("Impostazioni di Rondelle")
            // Sidebar up to the top, as in System Settings, under a transparent title bar; the detail column draws
            // its own bar behind the title (see SettingsView), so scrolled text never runs under «Impostazioni di
            // Rondelle» and the bar ends exactly at the sidebar's edge. Full-size content stays: without it the
            // glass buttons lost their labels on macOS 26+.
            // A little room to resize from the edges, between these two sizes; no full screen and no green button.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.contentMinSize = Self.smallest
            window.contentMaxSize = Self.largest
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 940, height: 620))
            window.center()
            // Rondelle lives in the menu bar: it shows in the Dock (and gets a menu bar) only while Settings is open.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
            }
            self.window = window
        }
        applyTheme()
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.menu() }
        NSApp.setActivationPolicy(.regular)
        DockIcon.follow()   // after: the Dock's tile only exists from here, and starts with the bundle's icon
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The menu bar while Settings is open: the app menu and Edit, so ⌘C / ⌘V / ⌘W / ⌘Q work.
    private static func menu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: L("Chiudi finestra"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(.separator())
        app.addItem(withTitle: L("Esci da Rondelle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Rondelle", action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: L("Modifica"))
        edit.addItem(withTitle: L("Annulla (menu Modifica)"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Ripristina"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Taglia (menu Modifica)"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copia"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Incolla"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Seleziona tutto"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: L("Modifica"), action: nil, keyEquivalent: "").submenu = edit
        return main
    }

    /// Settings → Aspetto → Tema delle impostazioni.
    func applyTheme() {
        switch Settings.settingsTheme {
        case .auto: window?.appearance = nil
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        case .light: window?.appearance = NSAppearance(named: .aqua)
        }
    }
}

/// Whether the sidebar is in the window. Read only by small views (the button, the sidebar's availability), so a
/// change doesn't make SwiftUI go through all of Settings again.
@MainActor
final class SettingsSidebar: ObservableObject {
    /// Where the sidebar button sits: it moves out of the way of the window's buttons as the sidebar goes.
    @Published var shown = true
    /// Hidden and parked outside the window: disabled and out of VoiceOver.
    @Published var outside = false
}

/// Holds the SwiftUI view in a plain view, so the window can slide it under its left edge (`toggleSidebar`).
/// The window's limits are its own: SwiftUI's view is not the window's content controller.
private final class SettingsContainer: NSViewController {
    let host: NSHostingController<SettingsView>

    init(_ view: SettingsView) {
        host = NSHostingController(rootView: view)
        host.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.smallest))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.width, .height]
        view.addSubview(host.view)
    }
}

/// The app's icon as the Mac's appearance wants it: the bundle's (black tile) with a dark Mac, the inverted one
/// (AppIconLight) with a light Mac. It goes in the Dock, which shows while Settings is open, and at the top of
/// Settings and «Informazioni su Rondelle». It goes by the Mac's appearance, not by the theme chosen for Settings.
@MainActor
final class DockIcon: ObservableObject {
    static let shared = DockIcon()
    @Published private(set) var image: NSImage
    private var observer: NSKeyValueObservation?
    private var inDock = false

    private init() {
        image = Self.current()
        observer = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DockIcon.shared.update() } }
        }
    }

    private static func load(_ name: String) -> NSImage? {
        #if DEBUG
        // The development build isn't an app bundle: its icons come from Resources.
        if Bundle.main.bundleURL.pathExtension != "app", let root = ProcessInfo.processInfo.environment["RONDELLE_RESOURCES"] {
            return NSImage(contentsOfFile: "\(root)/\(name).icns")
        }
        #endif
        return Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    private static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private static func current() -> NSImage {
        (dark ? load("AppIcon") : load("AppIconLight") ?? load("AppIcon")) ?? NSApp.applicationIconImage
    }

    static func follow() {
        shared.inDock = true
        shared.update()
        // The Dock takes a moment to add the tile: what is set before that doesn't reach it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { shared.update() } }
    }

    private func update() {
        image = Self.current()
        if inDock { NSApp.applicationIconImage = Self.dark ? nil : image }   // nil: the bundle's own icon
    }
}

/// The app icon in a SwiftUI view, light or dark with the Mac.
struct AppIconImage: View {
    @ObservedObject private var icon = DockIcon.shared

    var body: some View {
        Image(nsImage: icon.image).resizable()
    }
}

/// Sections of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, behaviour, wheel, conversions, formats, privacy, about, support, help
    var id: String { rawValue }

    var title: String {
        ["appearance": L("Aspetto"), "behaviour": L("Comportamento"), "wheel": L("Ruota (la ruota)"),
         "conversions": L("Conversioni"), "formats": L("Formati"), "privacy": L("Privacy"), "about": L("Informazioni"),
         "support": L("Sostieni Rondelle"), "help": L("Aiuto e contatti")][rawValue]!
    }
    var symbol: String {
        ["appearance": "paintpalette.fill", "behaviour": "hand.tap.fill", "wheel": "chart.pie.fill",
         "conversions": "arrow.triangle.2.circlepath", "formats": "tablecells.fill", "privacy": "hand.raised.fill", "about": "info",
         "support": "cup.and.saucer.fill", "help": "questionmark"][rawValue]!
    }
    /// Words that find this pane from the sidebar search: the labels of its settings (already translated).
    var keywords: [String] {
        switch self {
        case .appearance: return ["Dimensione", "Forma degli spicchi", "Tema", "Colori", "Evidenziazione", "Effetto vetro (Liquid Glass)",
                                  "Mostra icone", "Animazione di apertura", "Opacità sfondo"]
        case .behaviour: return ["Tasto da tenere premuto", "Metti in pausa", "Lingua", "Dopo la conversione",
                                 "Suono al termine", "Mostra il risultato nel Finder", "Avvia Rondelle al login"]
        case .wheel: return ["Tipo di file", "Converti", "Strumenti", "Condividi", "App e servizi aggiunti"]
        case .conversions: return ["Qualità JPG/HEIC", "Dimensioni nella ruota (px)", "Dove salvare i file", "Destinazione"]
        case .formats: return ["Immagini", "Documenti", "Video", "Audio", "Sottotitoli", "PDF", "JPEG", "PNG", "MP4", "MP3", "RAW", "DNG"]
        case .privacy: return ["Garanzie", "Condivisione", "Cartelle autorizzate", "Cronologia", "Lavori da ricordare"]
        case .about: return ["Rondelle"]
        case .support: return ["Offrimi un caffè", "Buy Me a Coffee", "Donazione"]
        case .help: return ["Problemi", "Contatti", "Email", "Segnala un problema"]
        }
    }

    func matches(_ search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || ([title] + keywords.map { L($0) }).contains { $0.localizedStandardContains(text) }
    }

    /// The coloured tile behind the icon, as in System Settings.
    var tint: Color {
        switch self {
        case .appearance: return .orange
        case .behaviour: return .blue
        case .wheel: return .purple
        case .conversions: return .green
        case .formats: return .teal
        case .privacy: return .indigo
        case .about: return .gray
        case .support: return .yellow
        case .help: return .pink
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .appearance: AppearancePane()
        case .behaviour: BehaviourPane()
        case .wheel: WheelPane()
        case .conversions: ConversionsPane()
        case .formats: FormatsPane()
        case .privacy: PrivacyPane()
        case .about: AboutPane()
        case .support: SupportPane()
        case .help: HelpPane()
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane?
    @State private var search = ""

    /// Height of a standard title bar on this macOS version.
    private static let titleBarHeight: CGFloat = {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
    }()

    init(pane: SettingsPane = .appearance) {
        _pane = State(initialValue: pane)
    }

    /// Groups as in System Settings: what Rondelle does, privacy and information, then support; help is always last.
    private let groups: [[SettingsPane]] = [[.appearance, .behaviour, .wheel, .conversions, .formats], [.privacy, .about], [.support, .help]]

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    AppHeader { pane = .about }
                }
                ForEach(groups.indices, id: \.self) { index in
                    Section {
                        ForEach(groups[index].filter { $0.matches(search) }) { item in
                            Label {
                                Text(item.title)
                            } icon: {
                                PaneIcon(pane: item)
                            }
                            .padding(.vertical, 2)
                            .tag(item)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: L("Cerca"))
            .onChange(of: search) { _ in
                // The first matching pane opens by itself, like System Settings.
                if let first = SettingsPane.allCases.first(where: { $0.matches(search) }), pane.map({ !$0.matches(search) }) ?? true {
                    pane = first
                }
            }
            .modifier(ParkedSidebar())
            .withoutSidebarToggle()
            .navigationSplitViewColumnWidth(min: SettingsWindow.sidebarWidth, ideal: SettingsWindow.sidebarWidth, max: SettingsWindow.sidebarWidth)
        } detail: {
            (pane ?? .appearance).content
                .navigationTitle((pane ?? .appearance).title)
                // The detail's own title bar: starts at the sidebar's edge, and the content begins below it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.bar)
                            // Our own button, at the start of this bar (after the window's buttons once the sidebar is gone).
                            SidebarButton()
                        }
                        .frame(height: Self.titleBarHeight)
                        Divider()
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
        }
        .hidingSidebarForTests { SettingsWindow.shared.toggleSidebar() }
        .frame(minWidth: SettingsWindow.smallest.width - SettingsWindow.sidebarWidth, maxWidth: SettingsWindow.largest.width,
               minHeight: SettingsWindow.smallest.height, maxHeight: SettingsWindow.largest.height)
    }
}

/// The button that hides and shows the sidebar; it alone follows `SettingsSidebar.shown`.
private struct SidebarButton: View {
    @ObservedObject private var sidebar = SettingsWindow.shared.sidebar

    var body: some View {
        Button { SettingsWindow.shared.toggleSidebar() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(sidebar.shown ? L("Nascondi la barra laterale") : L("Mostra la barra laterale"))
        .padding(.leading, sidebar.shown ? 14 : 82)
    }
}

/// The sidebar parked outside the window: not reachable with Tab or VoiceOver.
private struct ParkedSidebar: ViewModifier {
    @ObservedObject private var sidebar = SettingsWindow.shared.sidebar

    func body(content: Content) -> some View {
        content
            .disabled(sidebar.outside)
            .accessibilityHidden(sidebar.outside)
    }
}

/// Top of the sidebar: the app, its version and whether it is paused; a click opens «Informazioni».
private struct AppHeader: View {
    let open: () -> Void
    @AppStorage(Settings.Key.paused) private var paused = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AppIconImage()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Rondelle")).font(.headline)
                    if paused {
                        Label(L("In pausa"), systemImage: "pause.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(L("Versione %@", version)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// DEBUG: `--show-window settings-nosidebar` and `--test-sidebar-motion` press the sidebar button.
    @ViewBuilder func hidingSidebarForTests(_ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onReceive(NotificationCenter.default.publisher(for: Notification.Name("RondelleTestHideSidebar"))) { _ in toggle() }
        #else
        self
        #endif
    }

    /// The system's sidebar button is replaced by Rondelle's own, in the detail's title bar (macOS 14+; on 13 both show).
    @ViewBuilder func withoutSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

private struct PaneIcon: View {
    let pane: SettingsPane
    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Every pane stacked vertically (used by `--render-settings` to check the layout).
struct SettingsSnapshot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsPane.allCases) { pane in
                HStack { PaneIcon(pane: pane); Text(pane.title).font(.title3.bold()) }.padding([.top, .leading])
                pane.content.frame(height: pane == .wheel ? 620 : nil)
            }
        }
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @AppStorage(Settings.Key.wheelScale) private var scale = 1.0
    @AppStorage(Settings.Key.wheelOpacity) private var opacity = 0.9
    @AppStorage(Settings.Key.accentHex) private var accentHex = Settings.defaultAccentHex
    @AppStorage(Settings.Key.theme) private var theme = WheelTheme.dark
    @AppStorage(Settings.Key.showIcons) private var showIcons = true
    @AppStorage(Settings.Key.animate) private var animate = true
    @AppStorage(Settings.Key.liquidGlass) private var liquidGlass = true
    @AppStorage(Settings.Key.hoverHaptic) private var hoverHaptic = true
    @AppStorage(Settings.Key.hoverSound) private var hoverSound = true
    @AppStorage(Settings.Key.hoverHapticStrength) private var hapticStrength = HapticStrength.light
    @AppStorage(Settings.Key.hoverVolume) private var hoverVolume = 0.25
    @AppStorage(Settings.Key.settingsTheme) private var settingsTheme = WheelTheme.auto
    @AppStorage(Settings.Key.wheelShape) private var wheelShape = WheelShape.sharp
    /// The real-size preview stays on screen while this is on.
    @State private var realSize = false

    private let swatches = ["#2BB673", "#FF8C1A", "#FF3B30", "#FF2D92", "#AF52DE", "#007AFF", "#30B0C7", "#34C759", "#8E8E93"]

    private var accent: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: accentHex) ?? Settings.accentColor) },
                set: { accentHex = NSColor($0).hexString })
    }

    private var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    WheelPreview(actions: WheelPreview.sample, token: "\(scale)\(opacity)\(accentHex)\(theme)\(showIcons)\(liquidGlass)\(wheelShape)")
                        .frame(width: 200, height: 200)
                    Spacer()
                }
            }
            Section(L("Ruota (la ruota)")) {
                // While dragging the slider, a blank wheel at real size appears beside this window.
                Slider(value: $scale, in: 0.6...1.6, step: 0.05) {
                    Text(L("Dimensione"))
                } minimumValueLabel: { Image(systemName: "circle").font(.caption2) }
                  maximumValueLabel: { Image(systemName: "circle").font(.title3) }
                  onEditingChanged: { editing in
                      if editing || realSize { SizePreview.shared.show(autoHide: !realSize) }
                  }
                  .onChange(of: scale) { _ in
                      if SizePreview.shared.isVisible { SizePreview.shared.show(autoHide: !realSize) }
                  }
                LabeledContent("\(Int(scale * 100))% · \(Int(WheelController.size(for: 8, scale: scale))) pt") {
                    Toggle(L("Grandezza reale"), isOn: $realSize)
                        .toggleStyle(.button)
                        .onChange(of: realSize) { on in on ? SizePreview.shared.show() : SizePreview.shared.hide() }
                }
                .foregroundStyle(.secondary)
                Slider(value: $opacity, in: 0.3...1, step: 0.05) { Text(liquidGlass && glassAvailable ? L("Tinta del vetro") : L("Opacità sfondo")) }
                Toggle(isOn: $liquidGlass) {
                    Text(L("Effetto vetro (Liquid Glass)"))
                    Text(glassAvailable ? L("Lo sfondo della ruota lascia intravedere ciò che c'è dietro.")
                                        : L("Disponibile da macOS 26."))
                }
                .disabled(!glassAvailable)
            }
            Section(L("Forma")) {
                Picker(L("Forma degli spicchi"), selection: $wheelShape) {
                    ForEach(WheelShape.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: wheelShape) { _ in
                    if SizePreview.shared.isVisible { SizePreview.shared.show(autoHide: !realSize) }
                }
            }
            Section(L("Colori")) {
                Picker(L("Tema della ruota"), selection: $theme) {
                    ForEach(WheelTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(L("Evidenziazione")) {
                    HStack(spacing: 7) {
                        ForEach(swatches, id: \.self) { hex in
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: hex)!).gradient)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white, lineWidth: accentHex == hex ? 2 : 0))
                                .shadow(color: .black.opacity(accentHex == hex ? 0.3 : 0), radius: 2)
                                .onTapGesture { accentHex = hex }
                        }
                        ColorPicker("", selection: accent, supportsOpacity: false).labelsHidden()
                    }
                }
            }
            Section(L("Dettagli")) {
                Toggle(L("Mostra icone"), isOn: $showIcons)
                Toggle(L("Animazione di apertura"), isOn: $animate)
                Toggle(L("Tocco sul trackpad passando sulle voci"), isOn: $hoverHaptic)
                if hoverHaptic {
                    Picker(L("Intensità del tocco"), selection: $hapticStrength) {
                        ForEach(HapticStrength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: hapticStrength) { _ in HoverFeedback.play() }   // feel it right away
                }
                Toggle(L("Clic sonoro passando sulle voci"), isOn: $hoverSound)
                if hoverSound {
                    Slider(value: $hoverVolume, in: 0.05...1, onEditingChanged: { editing in
                        if !editing { HoverFeedback.play() }   // hear the new volume
                    }) { Text(L("Volume del clic")) }
                }
            }
            Section(L("Finestra delle impostazioni")) {
                Picker(L("Tema delle impostazioni"), selection: $settingsTheme) {
                    ForEach(WheelTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settingsTheme) { _ in SettingsWindow.shared.applyTheme() }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            realSize = false
            SizePreview.shared.hide()
        }
    }
}

/// The real WheelView (with Liquid Glass when enabled); `token` changes whenever a setting does.
struct WheelPreview: NSViewRepresentable {
    var actions: [WheelAction]
    let token: String
    /// The segment drawn as if the pointer were over it, and which wheel it is (the tutorial changes both).
    var highlight: Int? = 0
    var mode: WheelMode = .tools

    static let sample: [WheelAction] = [
        .each("Comprimi", "arrow.down.circle") { _ in [] },
        .each("Ruota", "rotate.right") { _ in [] },
        .each("PDF", "doc.on.doc") { _ in [] },
        .each("ZIP", "archivebox") { _ in [] },
        .each("Sfondo", "person.crop.square") { _ in [] },
        .each("50%", "arrow.down.right.and.arrow.up.left") { _ in [] },
    ]

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = WheelView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.unregisterDraggedTypes()
        view.fileCount = 1
        view.mode = .tools
        view.previewHighlight = 0
        container.addSubview(view)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let view = container.subviews.compactMap({ $0 as? WheelView }).first else { return }
        view.mode = mode
        view.actions = actions
        view.previewHighlight = actions.isEmpty ? nil : highlight
        container.subviews.filter { !($0 is WheelView) }.forEach { $0.removeFromSuperview() }
        view.glassBackground = false
        if #available(macOS 26.0, *), Settings.liquidGlass {
            let glass = NSGlassEffectView(frame: WheelView.glassRect(in: container.bounds))
            glass.cornerRadius = glass.frame.width / 2
            // The container may still be getting its final size: measure again once SwiftUI has laid it out.
            DispatchQueue.main.async { [weak glass, weak container] in
                guard let glass, let container else { return }
                glass.frame = WheelView.glassRect(in: container.bounds)
                glass.cornerRadius = glass.frame.width / 2
            }
            let dark = WheelPalette.isDark
            glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            glass.tintColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(WheelPalette.glassTint)
            container.addSubview(glass, positioned: .below, relativeTo: view)
            view.glassBackground = true
        }
        view.needsDisplay = true
    }
}

// MARK: Behaviour

private struct BehaviourPane: View {
    @AppStorage(Settings.Key.convertKeys) private var convertKeys = "shift"
    @AppStorage(Settings.Key.toolsKeys) private var toolsKeys = "option+shift"
    @AppStorage(Settings.Key.shareKeys) private var shareKeys = "control+shift"
    @AppStorage(Settings.Key.paused) private var paused = false
    @State private var shortcutHelp = false
    @AppStorage(Settings.Key.revealInFinder) private var reveal = true
    @AppStorage(Settings.Key.playSound) private var sound = false
    @AppStorage(Settings.Key.completionStyle) private var completion = CompletionStyle.ring
    @AppStorage(Settings.Key.showResultCard) private var resultCard = true
    @AppStorage(Settings.Key.appLanguage) private var language = ""
    @State private var languageChanged = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private func keysPicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(KeyCombo.all) { Text($0.label).tag($0.rawValue) }
        }
    }

    var body: some View {
        Form {
            Section {
                keysPicker(L("Ruota «Converti»"), $convertKeys)
                keysPicker(L("Ruota «Strumenti»"), $toolsKeys)
                keysPicker(L("Ruota «Condividi»"), $shareKeys)
                if Set([convertKeys, toolsKeys, shareKeys]).count < 3 {
                    Label(L("Due ruote hanno gli stessi tasti: si apre solo la prima."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Toggle(L("Metti in pausa Rondelle"), isOn: $paused)
            } header: {
                Text(L("Tasti da tenere premuti mentre trascini"))
            } footer: {
                Text(L("Al massimo due tasti per ruota. ⌘ Command e ⌥ Option cambiano anche ciò che fa il Finder se rilasci fuori dalla ruota (sposta / copia). Senza trascinare: clic destro sui file nel Finder → Servizi → Rondelle."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent(L("Ruota «Converti»"), value: "⌘ ⇧ V")
                LabeledContent(L("Ruota «Strumenti»"), value: "⌘ ⇧ M")
                LabeledContent(L("Ruota «Condividi»"), value: "⌘ ⇧ X")
                HStack {
                    Button(L("Cambia le scorciatoie…")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .rondelleButton()
                    Button { shortcutHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.borderless)
                        .help(L("Dove si cambiano le scorciatoie"))
                        .popover(isPresented: $shortcutHelp, arrowEdge: .bottom) { ShortcutHelp() }
                }
            } header: {
                Text(L("Senza trascinare: file selezionati nel Finder"))
            } footer: {
                Text(L("Poi ← → per scegliere, ↓ ↑ per le varianti, Invio per confermare, Tab per cambiare ruota, Esc per chiudere. Le scorciatoie si cambiano in Impostazioni di Sistema → Tastiera → Abbreviazioni → Servizi → File e cartelle."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker(L("Lingua di Rondelle"), selection: $language) {
                    Text(L("Come macOS")).tag("")
                    Text("Italiano").tag("it")
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                }
                .onChange(of: language) { code in
                    Settings.setLanguage(code)
                    languageChanged = true
                }
                if languageChanged {
                    LabeledContent(L("La nuova lingua vale dal prossimo avvio.")) {
                        Button(L("Riavvia Rondelle")) { Settings.relaunch() }.rondelleButton()
                    }
                }
            } header: {
                Text(L("Lingua"))
            }
            Section(L("Dopo la conversione")) {
                Toggle(L("Mostra il risultato nel Finder"), isOn: $reveal)
                Toggle(L("Scheda con il risultato, trascinabile e annullabile"), isOn: $resultCard)
                Toggle(L("Suono al termine"), isOn: $sound)
                LabeledContent(L("Animazione al termine")) {
                    HStack {
                        Picker("", selection: $completion) {
                            ForEach(CompletionStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button(L("Prova")) { CompletionAnimation.play(style: completion) }
                            .rondelleButton()
                            .disabled(completion == .none)
                    }
                }
            }
            Section(L("Avvio")) {
                Toggle(L("Avvia Rondelle al login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Step by step to the Services shortcuts: a sandboxed app cannot change them itself, macOS keeps them.
private struct ShortcutHelp: View {
    private let steps = [
        L("Premi «Cambia le scorciatoie…»: si apre Impostazioni di Sistema → Tastiera."),
        L("Premi il pulsante «Abbreviazioni da tastiera…»."),
        L("Nella colonna a sinistra scegli «Servizi»."),
        L("Apri il gruppo «File e cartelle»."),
        L("Trova «Rondelle: Converti…», «Strumenti…» o «Condividi…», fai doppio clic sui tasti a destra e premi quelli nuovi."),
        L("Lascia la casella accanto accesa, poi premi «Fine»."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Cambiare le scorciatoie")).font(.headline)
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(steps[i]).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L("Se una scorciatoia non fa nulla, l'app in primo piano la usa già: scegline un'altra."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: Wheel (customise actions)

private struct WheelPane: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String?
        var visible: Bool
    }

    @State private var kindIndex = 0
    @State private var mode = WheelMode.tools
    @AppStorage(Settings.Key.wheelStyle) private var style = WheelStyle.mixed
    @State private var rows: [Row] = []
    @State private var added = ShareTargets.all
    @State private var services: [String] = []

    private var kind: FileKind { WheelConfig.kinds[kindIndex].kind }

    var body: some View {
        Form {
            Section {
                if mode != .share {   // the share wheel is the same for every kind of file
                    Picker(L("Tipo di file"), selection: $kindIndex) {
                        ForEach(WheelConfig.kinds.indices, id: \.self) { Text(WheelConfig.kinds[$0].label).tag($0) }
                    }
                }
                Picker(L("Ruota (la ruota)"), selection: $mode) {
                    Text(L("Converti (%@)", Settings.keys(for: .convert).label)).tag(WheelMode.convert)
                    Text(L("Strumenti (%@)", Settings.keys(for: .tools).label)).tag(WheelMode.tools)
                    Text(L("Condividi (%@)", Settings.keys(for: .share).label)).tag(WheelMode.share)
                }
                .pickerStyle(.segmented)
                if mode == .tools {
                    Picker(L("Stile della ruota Strumenti"), selection: $style) {
                        ForEach(WheelStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: style) { _ in load() }
                    Text(style.detail).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text(L("Spunta le azioni da mostrare e trascinale per cambiare l'ordine: la prima è in alto, le altre seguono in senso orario. Una ruota con meno voci è più facile da centrare."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if mode == .share {
                Section {
                    ForEach(added) { target in
                        LabeledContent {
                            Button(L("Rimuovi")) { ShareTargets.remove(target); added = ShareTargets.all; load() }
                                .rondelleButton()
                        } label: {
                            Label(target.title, systemImage: target.kind == .app ? "app" : "square.and.arrow.up.on.square")
                        }
                    }
                    HStack {
                        Button(L("Aggiungi un'app…")) { ShareTargets.chooseApp(); added = ShareTargets.all; load() }
                            .rondelleButton()
                        Menu(L("Aggiungi un servizio di macOS")) {
                            ForEach(services, id: \.self) { title in
                                Button(title) {
                                    ShareTargets.add(.init(kind: .service, title: title, id: title))
                                    added = ShareTargets.all
                                    load()
                                }
                            }
                        }
                        .fixedSize()
                        .onAppear { services = ShareTargets.availableServices() }
                    }
                } header: {
                    Text(L("App e servizi aggiunti"))
                } footer: {
                    Text(L("Un'app con la sua estensione di condivisione (come Telegram) apre la scelta del contatto; le altre si aprono con i file negli appunti, da incollare con ⌘V."))
                        .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                HStack(alignment: .top, spacing: 16) {
                    List {
                        ForEach($rows) { $row in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $row.visible).labelsHidden()
                                Image(systemName: row.symbol ?? "textformat")
                                    .frame(width: 20)
                                    .foregroundStyle(row.visible ? Color.accentColor : .secondary)
                                Text(row.title).foregroundStyle(row.visible ? .primary : .secondary)
                                Spacer()
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            }
                        }
                        .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(minHeight: 300)
                    VStack(spacing: 8) {
                        WheelPreview(actions: previewActions, token: rows.map { "\($0.id)\($0.visible)" }.joined())
                            .frame(width: 180, height: 180)
                        Text(L("%@ azioni visibili", rows.filter(\.visible).count))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("Ripristina questa ruota")) {
                            WheelConfig.save(.init(), kind, mode)
                            load()
                        }
                        .rondelleButton()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: kindIndex) { _ in load() }
        .onChange(of: mode) { _ in load() }
        .onChange(of: rows) { _ in save() }
    }

    private var previewActions: [WheelAction] {
        rows.filter(\.visible).map { row in .each(row.title, row.symbol) { _ in [] } }
    }

    private func load() {
        let all = ActionCatalog.allActions(for: kind, mode: mode)
        let entry = WheelConfig.entry(kind, mode)
        let ordered = all.enumerated().sorted { a, b in
            let ia = entry.order.firstIndex(of: a.element.id) ?? Int.max
            let ib = entry.order.firstIndex(of: b.element.id) ?? Int.max
            return ia == ib ? a.offset < b.offset : ia < ib
        }.map(\.element)
        rows = ordered.map { Row(id: $0.id, title: $0.title, symbol: $0.symbol, visible: !entry.hidden.contains($0.id)) }
    }

    private func save() {
        guard !rows.isEmpty else { return }
        // At least one action must stay visible.
        if !rows.contains(where: \.visible) { rows[0].visible = true; return }
        let defaultOrder = ActionCatalog.allActions(for: kind, mode: mode).map(\.id)
        let order = rows.map(\.id)
        WheelConfig.save(.init(order: order == defaultOrder ? [] : order,
                               hidden: rows.filter { !$0.visible }.map(\.id)), kind, mode)
    }
}

// MARK: Conversions

/// General options, then one page per output format (FormatSettings), with a list on the left as in the main sidebar.
private struct ConversionsPane: View {
    @State private var page = "general"

    init() {
        #if DEBUG
        // Snapshots: RONDELLE_CONVERSIONS_PAGE=JPEG opens that page.
        if let page = ProcessInfo.processInfo.environment["RONDELLE_CONVERSIONS_PAGE"] { _page = State(initialValue: page) }
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                Label(L("Generale"), systemImage: "gearshape").tag("general")
                ForEach(FormatSettings.groups, id: \.title) { group in
                    Section(L(group.title)) {
                        ForEach(group.formats, id: \.self) { Text(L($0)).tag($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            if page == "general" {
                GeneralConversions()
            } else {
                FormatOptions(format: page).id(page)
            }
        }
    }
}

/// Settings → Conversioni → one output format.
private struct FormatOptions: View {
    let format: String
    @AppStorage private var keepMetadata: Bool
    @AppStorage private var maxSide: Int
    @AppStorage private var quality: Double
    @AppStorage private var videoQuality: String
    @AppStorage private var dpi: Int
    @AppStorage private var gifWidth: Int
    @AppStorage private var gifFPS: Int
    @AppStorage private var mp3: String
    @AppStorage private var bits: Int
    @AppStorage private var csvSeparator: String
    @AppStorage private var csvBOM: Bool

    init(format: String) {
        self.format = format
        let k = { FormatSettings.key(format, $0) }
        _keepMetadata = AppStorage(wrappedValue: true, k("keepMetadata"))
        _maxSide = AppStorage(wrappedValue: 0, k("maxSide"))
        _quality = AppStorage(wrappedValue: Double(Settings.imageQuality), k("quality"))
        _videoQuality = AppStorage(wrappedValue: FormatSettings.VideoQuality.original.rawValue, k("quality"))
        _dpi = AppStorage(wrappedValue: 150, k("dpi"))
        _gifWidth = AppStorage(wrappedValue: 480, k("width"))
        _gifFPS = AppStorage(wrappedValue: 10, k("fps"))
        _mp3 = AppStorage(wrappedValue: FormatSettings.MP3Quality.vbr2.rawValue, k("quality"))
        _bits = AppStorage(wrappedValue: 16, k("bits"))
        _csvSeparator = AppStorage(wrappedValue: ",", k("separator"))
        _csvBOM = AppStorage(wrappedValue: true, k("bom"))
    }

    private var isImage: Bool { FormatSettings.groups[0].formats.contains(format) }

    var body: some View {
        Form {
            Section {
                if isImage {
                    Toggle(L("Mantieni i metadati (data, fotocamera, posizione)"), isOn: $keepMetadata)
                    Picker(L("Dimensioni"), selection: $maxSide) {
                        ForEach(FormatSettings.sideChoices, id: \.self) { side in
                            Text(side == 0 ? L("Originali") : L("Lato lungo fino a %@ px", side)).tag(side)
                        }
                    }
                    if FormatSettings.imageQualityFormats.contains(format) {
                        Slider(value: $quality, in: 0.3...1, step: 0.05) {
                            Text(L("Qualità %@%%", Int(quality * 100)))
                        }
                    }
                } else if format == "PDF → immagini" {
                    Picker(L("Risoluzione delle pagine"), selection: $dpi) {
                        ForEach(FormatSettings.dpiChoices, id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                } else if FormatSettings.videoFormats.contains(format) {
                    Picker(L("Qualità"), selection: $videoQuality) {
                        ForEach(FormatSettings.VideoQuality.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle(L("Mantieni i metadati (data, dispositivo, posizione)"), isOn: $keepMetadata)
                } else if format == "GIF animata" {
                    Picker(L("Larghezza massima"), selection: $gifWidth) {
                        ForEach(FormatSettings.gifWidths, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker(L("Fotogrammi al secondo"), selection: $gifFPS) {
                        ForEach(FormatSettings.gifRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                } else if format == "M4A" {
                    Toggle(L("Mantieni i metadati (titolo, artista, copertina)"), isOn: $keepMetadata)
                } else if format == "MP3" {
                    Picker(L("Qualità"), selection: $mp3) {
                        ForEach(FormatSettings.MP3Quality.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                } else if format == "CSV" {
                    Picker(L("Separatore"), selection: $csvSeparator) {
                        Text(L("Virgola ( , )")).tag(",")
                        Text(L("Punto e virgola ( ; )")).tag(";")
                    }
                    .pickerStyle(.segmented)
                    Toggle(L("Segno UTF-8 all'inizio (accenti corretti in Excel)"), isOn: $csvBOM)
                } else if format == "WAV" || format == "AIFF" {
                    Picker(L("Profondità"), selection: $bits) {
                        Text(L("16 bit (CD)")).tag(16)
                        Text(L("24 bit (studio)")).tag(24)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text(L("Impostazioni %@", L(format)))
            } footer: {
                Text(note).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Button(L("Ripristina i valori predefiniti")) {
                    FormatSettings.reset(format)
                    keepMetadata = true; maxSide = 0; quality = Double(Settings.imageQuality)
                    videoQuality = FormatSettings.VideoQuality.original.rawValue; dpi = 150; gifWidth = 480; gifFPS = 10
                    mp3 = FormatSettings.MP3Quality.vbr2.rawValue; bits = 16; csvSeparator = ","; csvBOM = true
                    FormatSettings.reset(format)
                }
                .rondelleButton()
            }
        }
        .formStyle(.grouped)
    }

    private var note: String {
        if isImage { return L("Vale per la conversione verso %@ dalla ruota «Converti».", L(format)) }
        switch format {
        case "PDF → immagini": return L("Ogni pagina del PDF diventa un'immagine PNG o JPG: più dpi, più nitidezza e file più grandi.")
        case "GIF animata": return L("GIF dai video: al massimo i primi 20 secondi.")
        case "M4A": return L("Vale per audio e video convertiti in M4A e per «Solo audio».")
        case "CSV": return L("Excel in italiano, francese e tedesco apre meglio i CSV con il punto e virgola. In lettura Rondelle riconosce da solo virgola, punto e virgola e tabulazione.")
        default: return L("Vale per la conversione verso %@ dalla ruota «Converti».", L(format))
        }
    }
}

private struct GeneralConversions: View {
    @AppStorage(Settings.Key.imageQuality) private var quality = 0.9
    @AppStorage(Settings.Key.imageSizes) private var sizes = "1920, 480"
    @AppStorage(Settings.Key.targetMB) private var targetMB = "1"
    @AppStorage(Settings.Key.saveLocation) private var location = SaveLocation.besideOriginal
    @AppStorage(Settings.Key.outputFolderPath) private var folderPath = ""

    var body: some View {
        Form {
            Section {
                Slider(value: $quality, in: 0.3...1, step: 0.05) { Text(L("Qualità JPG/HEIC")) }
                LabeledContent(L("Dimensioni nella ruota (px)")) {
                    TextField("", text: $sizes).labelsHidden().multilineTextAlignment(.trailing).frame(width: 180)
                }
                LabeledContent(L("«Peso…» propone (MB)")) {
                    TextField("", text: $targetMB).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                }
            } header: {
                Text(L("Immagini"))
            } footer: {
                Text(L("Qualità %@%% (più alta = file più grandi). Dimensioni: fino a 4 valori separati da virgola, es. 2560, 1920, 1080, 480 — attuali: %@.", Int(quality * 100),
                       Settings.imageSizes.isEmpty ? L("nessuna") : Settings.imageSizes.map { "\($0)px" }.joined(separator: ", ")))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section(L("Dove salvare i file")) {
                Picker(L("Destinazione"), selection: $location) {
                    Text(L("Accanto all'originale")).tag(SaveLocation.besideOriginal)
                    Text(L("In una cartella fissa")).tag(SaveLocation.folder)
                }
                .pickerStyle(.radioGroup)
                if location == .folder {
                    LabeledContent(folderPath.isEmpty ? L("Nessuna cartella scelta") : displayPath(folderPath)) {
                        Button(L("Scegli…")) { chooseFolder() }.rondelleButton()
                    }
                    .foregroundStyle(folderPath.isEmpty ? .red : .primary)
                }
            }
            Section {
                Button(L("Ripristina tutte le impostazioni predefinite"), role: .destructive) {
                    Settings.resetAll()
                    WheelConfig.resetAll()
                    FormatSettings.resetAll()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let start = folderPath.isEmpty ? FolderAccess.realHome : URL(fileURLWithPath: folderPath)
        if FolderAccess.request(start, explanation: L("Scegli la cartella dove Rondelle salverà tutti i file convertiti."),
                                acceptAny: true) {
            folderPath = FolderAccess.lastGranted?.path ?? folderPath
        }
    }
}

// MARK: Privacy

private struct PrivacyPane: View {
    @State private var folders = FolderAccess.allowedFolders
    @AppStorage(Settings.Key.shareWithoutMetadata) private var shareWithoutMetadata = true
    @AppStorage(Settings.Key.removeLocation) private var removeLocation = true
    @AppStorage(Settings.Key.checkUpdates) private var checkUpdates = true
    @AppStorage(Settings.Key.historyLimit) private var historyLimit = 10
    /// The stored jobs themselves: the count below follows «Svuota cronologia», here or in the menu bar.
    @AppStorage(JobHistory.key) private var history = Data()

    var body: some View {
        Form {
            Section(L("Garanzie")) {
                Label(L("Nessun dato raccolto in automatico, nessun tracciamento"), systemImage: "checkmark.shield")
                Label(L("Le conversioni non accedono a Internet (bloccato dalla sandbox di macOS)"), systemImage: "wifi.slash")
                Label(L("Un messaggio parte solo se lo invii tu da Aiuto e contatti, mai con file"), systemImage: "paperplane")
                Label(L("Tutto avviene su questo Mac, anche OCR e rimozione sfondo"), systemImage: "laptopcomputer")
                Label(L("Nessun accesso a fotocamera, microfono, posizione, contatti, Foto"), systemImage: "eye.slash")
            }
            Section {
                Toggle(L("Cerca aggiornamenti automaticamente"), isOn: $checkUpdates)
            } header: {
                Text(L("Aggiornamenti"))
            } footer: {
                Text(L("Una volta al giorno un piccolo processo separato chiede a GitHub qual è l'ultima versione. Non invia file né dati personali, ma GitHub vede l'indirizzo IP del Mac. L'aggiornamento non si installa da solo: lo scarichi dalla pagina che si apre."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(L("Togli la posizione GPS da foto e video convertiti"), isOn: $removeLocation)
            } header: {
                Text(L("Posizione"))
            } footer: {
                Text(L("Vale per ogni conversione e strumento (anche con «Mantieni i metadati»): data e fotocamera restano, il punto in cui è stata scattata la foto o girato il video no."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(L("Condividi senza posizione e metadati"), isOn: $shareWithoutMetadata)
            } header: {
                Text(L("Condivisione"))
            } footer: {
                Text(L("Dalla ruota «Condividi» foto, video, audio e PDF partono come copie senza posizione GPS, dispositivo, date e autore; gli originali non cambiano. Rondelle non invia nulla: passa i file a macOS o all'app che scegli."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section(L("Cartelle autorizzate")) {
                if folders.isEmpty {
                    Text(L("Nessuna")).foregroundStyle(.secondary)
                } else {
                    ForEach(folders, id: \.path) {
                        Label(displayPath($0.path), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Button(L("Autorizza una cartella…")) {
                        FolderAccess.request(FolderAccess.realHome,
                                             explanation: L("Scegli una cartella in cui Rondelle può salvare i file convertiti."),
                                             acceptAny: true)
                        folders = FolderAccess.allowedFolders
                    }
                    .rondelleButton()
                    Button(L("Revoca tutte"), role: .destructive) {
                        FolderAccess.revokeAll()
                        folders = FolderAccess.allowedFolders
                    }
                    .rondelleButton()
                    .disabled(folders.isEmpty)
                }
            }
            Section(L("Cronologia")) {
                Picker(L("Lavori da ricordare"), selection: $historyLimit) {
                    ForEach(Settings.historyLimits, id: \.self) { Text("\($0)").tag($0) }
                }
                .onChange(of: historyLimit) { _ in JobHistory.trim() }
                LabeledContent(L("Lavori recenti memorizzati"), value: L("%@ di %@", JobHistory.count(in: history), historyLimit))
                Button(L("Svuota cronologia")) { JobHistory.clear() }.rondelleButton()
            }
        }
        .formStyle(.grouped)
    }
}

/// The project site. Opened in the default browser: Rondelle itself sends nothing there.
enum Website {
    static let url = URL(string: "https://jackb998.github.io/rondelle/")!
}

// MARK: About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 14) {
            AppIconImage()
                .frame(width: 112, height: 112)
            Text(L("Rondelle")).font(.largeTitle.bold())
            Text(L("Versione %@", version)).foregroundStyle(.secondary)
            Text(L("Convertitore di file con la ruota ⇧ + trascina.\nNessun dato raccolto in automatico; Internet solo per cercare aggiornamenti e inviare i messaggi che scrivi tu."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(L("Open source con licenza MIT. Contiene [LAME](https://lame.sourceforge.io) (LGPL) e [libwebp](https://chromium.googlesource.com/webm/libwebp) (BSD).")))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button {
                NSWorkspace.shared.open(Website.url)
            } label: {
                Label(L("Sito web di Rondelle"), systemImage: "safari")
            }
            .rondelleButton()
            Text(L("Il link si apre nel browser: Rondelle non invia nulla a quel sito."))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(L("© 2026 jackb998")).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: Support

/// «Buy me a coffee» page, opened in the default browser: Rondelle itself still has no network access.
enum SupportLink {
    static let coffee = URL(string: "https://buymeacoffee.com/jackb998")!
}

private struct SupportPane: View {

    var body: some View {
        Form {
            Section {
                Text(L("Rondelle è gratuito, senza pubblicità e senza raccolta di dati. Se ti è utile, puoi offrire un caffè a chi lo sviluppa."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSWorkspace.shared.open(SupportLink.coffee)
                } label: {
                    Label(L("Offrimi un caffè"), systemImage: "cup.and.saucer.fill")
                }
                .rondelleButton()
            } header: {
                Text(L("Sostieni Rondelle"))
            } footer: {
                Text(L("Il link si apre nel browser (buymeacoffee.com): Rondelle non invia nulla a quel sito."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Help

private struct HelpPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent(L("Come funziona Rondelle, con piccole animazioni.")) {
                    Button(L("Rivedi il tutorial")) { TutorialWindow.shared.show() }.rondelleButton()
                }
            } header: {
                Text(L("Tutorial"))
            }
            Section {
                Text(L("Hai trovato un problema o hai un'idea per Rondelle? Scrivici da qui: parte solo ciò che scrivi, quando premi Invia."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Segnala un problema")) { FeedbackWindow.show() }
                    .rondelleButton()
            } header: {
                Text(L("Aiuto e contatti"))
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
func displayPath(_ path: String) -> String {
    path.replacingOccurrences(of: FolderAccess.realHome.path, with: "~")
}

// MARK: macOS 26+ styling

extension View {
    /// Liquid Glass button on macOS 26 and later, regular bordered button before.
    @ViewBuilder func rondelleButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    /// The main action of a window (Salva, Unisci…): tinted glass on macOS 26+.
    @ViewBuilder func rondelleProminentButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// A floating glass panel on macOS 26+, a regular material before.
    @ViewBuilder func rondellePanel(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
