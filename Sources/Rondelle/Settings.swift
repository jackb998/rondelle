import AppKit

enum WheelTheme: String, CaseIterable, Identifiable {
    case auto, dark, light
    var id: String { rawValue }
    var label: String { ["auto": L("Automatico"), "dark": L("Scuro"), "light": L("Chiaro")][rawValue]! }
}

/// The keys held while dragging that open a wheel: one or two of ⌃ ⌥ ⇧ ⌘ (Settings → Comportamento).
struct KeyCombo: Hashable, Identifiable {
    static let keys: [(flag: NSEvent.ModifierFlags, name: String, label: String)] = [
        (.control, "control", "⌃ Control"), (.option, "option", "⌥ Option"),
        (.shift, "shift", "⇧ Shift"), (.command, "command", "⌘ Command"),
    ]
    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let flags: NSEvent.ModifierFlags
    var id: String { rawValue }

    init(_ flags: NSEvent.ModifierFlags) { self.flags = flags.intersection(Self.relevant) }

    /// "shift" or "option+shift", as stored in the preferences.
    init?(rawValue: String) {
        var flags: NSEvent.ModifierFlags = []
        for name in rawValue.split(separator: "+") {
            guard let key = Self.keys.first(where: { $0.name == name }) else { return nil }
            flags.insert(key.flag)
        }
        guard !flags.isEmpty else { return nil }
        self.init(flags)
    }

    var rawValue: String { Self.keys.filter { flags.contains($0.flag) }.map(\.name).joined(separator: "+") }
    var label: String { Self.keys.filter { flags.contains($0.flag) }.map { L($0.label) }.joined(separator: " + ") }

    /// Every choice: the four keys alone, then every pair.
    static let all: [KeyCombo] = {
        var combos = keys.map { KeyCombo($0.flag) }
        for i in keys.indices { for j in keys.indices where j > i { combos.append(KeyCombo(keys[i].flag.union(keys[j].flag))) } }
        return combos
    }()

    func hash(into hasher: inout Hasher) { hasher.combine(flags.rawValue) }
    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.flags == b.flags }
}

/// Settings → Aspetto → Forma degli spicchi: the corners of the wheel's pieces.
enum WheelShape: String, CaseIterable, Identifiable {
    case sharp, round, soft, chamfer, pizza
    var id: String { rawValue }
    var label: String {
        ["sharp": L("Netta"), "round": L("Tonda"), "soft": L("Molto morbida"), "chamfer": L("Smussata"), "pizza": L("Fetta di pizza")][rawValue]!
    }
}

/// macOS offers three kinds of trackpad tap, not a continuous strength: from the softest to the clearest.
enum HapticStrength: String, CaseIterable, Identifiable {
    case light, medium, strong
    var id: String { rawValue }
    var label: String { ["light": L("Leggero"), "medium": L("Medio"), "strong": L("Deciso")][rawValue]! }
    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .light: return .alignment
        case .medium: return .levelChange
        case .strong: return .generic
        }
    }
}

enum SaveLocation: String, CaseIterable, Identifiable {
    case besideOriginal, folder
    var id: String { rawValue }
}

/// Preferences, stored in UserDefaults inside the app's sandbox container.
/// Read live (UserDefaults is thread-safe and cached in memory), so changes apply immediately.
enum Settings {
    enum Key {
        static let wheelScale = "wheelScale"
        static let wheelOpacity = "wheelOpacity"
        static let accentHex = "accentHex"
        static let theme = "wheelTheme"
        static let showIcons = "showIcons"
        static let animate = "animateWheel"
        static let liquidGlass = "liquidGlass"
        static let trigger = "triggerKey"   // before 0.8: shift or control, read once to set the keys below
        static let convertKeys = "keys.convert"
        static let toolsKeys = "keys.tools"
        static let shareKeys = "keys.share"
        static let paused = "paused"
        static let revealInFinder = "revealInFinder"
        static let playSound = "playSound"
        static let showResultCard = "showResultCard"
        static let completionStyle = "completionStyle"
        static let imageQuality = "imageQuality"
        static let imageSizes = "imageSizes"
        static let targetMB = "targetMB"
        static let saveLocation = "saveLocation"
        static let outputFolderPath = "outputFolderPath"
        static let shareWithoutMetadata = "shareWithoutMetadata"
        static let checkUpdates = "checkUpdates"
        static let removeLocation = "removeLocation"
        static let appLanguage = "appLanguage"
        static let wheelStyle = "wheelStyle"
        static let wheelShape = "wheelShape"
        static let hoverHaptic = "hoverHaptic"
        static let hoverSound = "hoverSound"
        static let hoverHapticStrength = "hoverHapticStrength"
        static let hoverVolume = "hoverVolume"
        static let settingsTheme = "settingsTheme"
        static let historyLimit = "historyLimit"
    }

    static let defaultValues: [String: Any] = [
        Key.wheelScale: 1.0,
        Key.wheelOpacity: 0.9,
        Key.accentHex: defaultAccentHex,
        Key.theme: WheelTheme.dark.rawValue,
        Key.showIcons: true,
        Key.animate: true,
        Key.liquidGlass: true,
        Key.convertKeys: "shift",
        Key.toolsKeys: "option+shift",
        Key.shareKeys: "control+shift",
        Key.paused: false,
        Key.revealInFinder: true,
        Key.playSound: false,
        Key.completionStyle: CompletionStyle.ring.rawValue,
        Key.showResultCard: true,
        Key.imageQuality: 0.9,
        Key.imageSizes: "1920, 480",
        Key.targetMB: "1",
        Key.saveLocation: SaveLocation.besideOriginal.rawValue,
        Key.outputFolderPath: "",
        Key.shareWithoutMetadata: true,
        Key.checkUpdates: true,
        Key.removeLocation: true,
        Key.appLanguage: "",
        Key.wheelStyle: WheelStyle.mixed.rawValue,
        Key.wheelShape: WheelShape.sharp.rawValue,
        Key.hoverHaptic: true,
        Key.hoverSound: true,
        Key.hoverHapticStrength: HapticStrength.light.rawValue,
        Key.hoverVolume: 0.25,
        Key.settingsTheme: WheelTheme.auto.rawValue,
        Key.historyLimit: 10,
    ]

    static func register() {
        defaults.register(defaults: defaultValues)
        // 0.7: Control instead of Shift as the trigger → the same wheels with Control.
        if defaults.string(forKey: Key.trigger) == "control" {
            defaults.set("control", forKey: Key.convertKeys)
            defaults.set("control+option", forKey: Key.toolsKeys)
            defaults.set("control+shift", forKey: Key.shareKeys)
            defaults.removeObject(forKey: Key.trigger)
        }
    }

    /// Settings → Comportamento → Lingua: "" follows macOS, else "it", "en" or "fr".
    /// macOS picks the app's language at launch from AppleLanguages, so a change needs a restart.
    static func setLanguage(_ code: String) {
        if code.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
        }
    }

    /// Quits and reopens Rondelle, so the new language applies everywhere (menus, wheel, Services).
    @MainActor static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func resetAll() {
        for key in defaultValues.keys { defaults.removeObject(forKey: key) }
        setLanguage("")
        ShareTargets.all = []
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: Appearance

    static var wheelScale: CGFloat { CGFloat(min(max(defaults.double(forKey: Key.wheelScale), 0.6), 1.6)) }
    static var wheelOpacity: CGFloat { CGFloat(min(max(defaults.double(forKey: Key.wheelOpacity), 0.3), 1)) }
    /// The brand green; on a light wheel the default takes the darker tone made for light backgrounds.
    static let defaultAccentHex = "#2BB673"
    static var accentColor: NSColor {
        let hex = defaults.string(forKey: Key.accentHex) ?? defaultAccentHex
        let tone = hex == defaultAccentHex && !WheelPalette.isDark ? "#1F9D63" : hex
        return NSColor(hex: tone) ?? NSColor(hex: defaultAccentHex)!
    }
    static var theme: WheelTheme { WheelTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .dark }
    static var showIcons: Bool { defaults.bool(forKey: Key.showIcons) }
    static var animate: Bool { defaults.bool(forKey: Key.animate) }
    /// Liquid Glass wheel background (macOS 26 and later).
    static var liquidGlass: Bool { defaults.bool(forKey: Key.liquidGlass) }

    // MARK: Behaviour

    static func keysKey(_ mode: WheelMode) -> String {
        switch mode {
        case .convert: return Key.convertKeys
        case .tools: return Key.toolsKeys
        case .share: return Key.shareKeys
        }
    }

    static func keys(for mode: WheelMode) -> KeyCombo {
        KeyCombo(rawValue: defaults.string(forKey: keysKey(mode)) ?? "")
            ?? KeyCombo(rawValue: defaultValues[keysKey(mode)] as! String)!
    }

    /// The wheel whose keys are exactly the ones held (extra keys outside ⌃ ⌥ ⇧ ⌘ don't count).
    static func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        let held = KeyCombo(flags)
        return [WheelMode.convert, .tools, .share].first { keys(for: $0) == held }
    }

    /// With a wheel already open, the wheel a key press switches to: the exact keys of a wheel, or keys that
    /// only one wheel uses (⌥ → Strumenti, ⌃ → Condividi with the default keys). Letting keys go never
    /// switches, so the wheel stays as it is once the keys are released.
    static func switchMode(from previous: NSEvent.ModifierFlags, to now: NSEvent.ModifierFlags) -> WheelMode? {
        let before = KeyCombo(previous).flags, held = KeyCombo(now).flags
        guard !held.isEmpty, !held.isSubset(of: before) else { return nil }
        if let exact = mode(for: held) { return exact }
        let modes = [WheelMode.convert, .tools, .share].filter { keys(for: $0).flags.isSuperset(of: held) }
        return modes.count == 1 ? modes[0] : nil
    }

    /// The single key that switches to this wheel once it is open, or else its full keys.
    static func switchKey(for mode: WheelMode) -> KeyCombo {
        KeyCombo.keys.map { KeyCombo($0.flag) }.first { switchMode(from: [], to: $0.flags) == mode } ?? keys(for: mode)
    }
    static var paused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused) }
    }
    static var revealInFinder: Bool { defaults.bool(forKey: Key.revealInFinder) }
    /// Shows the outputs in the Finder when the setting is on, except when they all sit directly on
    /// the Desktop: the user is already looking at it.
    @MainActor static func reveal(_ outputs: [URL]) {
        guard revealInFinder, !outputs.isEmpty else { return }
        let desktop = FolderAccess.realHome.appendingPathComponent("Desktop").resolvingSymlinksInPath().path
        if outputs.allSatisfy({ $0.deletingLastPathComponent().resolvingSymlinksInPath().path == desktop }) { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
    static var shareWithoutMetadata: Bool { defaults.bool(forKey: Key.shareWithoutMetadata) }
    static var checkUpdates: Bool { defaults.bool(forKey: Key.checkUpdates) }
    /// Settings → Privacy: GPS position left out of every converted photo and video (0.8-C2), even when
    /// a format keeps its other metadata.
    static var removeLocation: Bool { defaults.bool(forKey: Key.removeLocation) }
    static var hoverHaptic: Bool { defaults.bool(forKey: Key.hoverHaptic) }
    static var wheelShape: WheelShape { WheelShape(rawValue: defaults.string(forKey: Key.wheelShape) ?? "") ?? .sharp }
    static var wheelStyle: WheelStyle { WheelStyle(rawValue: defaults.string(forKey: Key.wheelStyle) ?? "") ?? .mixed }
    static var hoverSound: Bool { defaults.bool(forKey: Key.hoverSound) }
    static var hoverHapticStrength: HapticStrength {
        HapticStrength(rawValue: defaults.string(forKey: Key.hoverHapticStrength) ?? "") ?? .light
    }
    static var hoverVolume: Float { Float(min(max(defaults.double(forKey: Key.hoverVolume), 0.05), 1)) }
    /// Settings → Aspetto: the Settings window's own look (the wheel has its theme).
    static var settingsTheme: WheelTheme { WheelTheme(rawValue: defaults.string(forKey: Key.settingsTheme) ?? "") ?? .auto }
    static var playSound: Bool { defaults.bool(forKey: Key.playSound) }
    static var showResultCard: Bool { defaults.bool(forKey: Key.showResultCard) }
    /// Settings → Privacy → Cronologia: how many recent jobs are remembered.
    static let historyLimits = [5, 10, 15, 20]
    static var historyLimit: Int {
        let value = defaults.integer(forKey: Key.historyLimit)
        return historyLimits.contains(value) ? value : 10
    }
    static var completionStyle: CompletionStyle {
        CompletionStyle(rawValue: defaults.string(forKey: Key.completionStyle) ?? "") ?? .ring
    }

    // MARK: Conversions

    static var imageQuality: CGFloat { CGFloat(min(max(defaults.double(forKey: Key.imageQuality), 0.3), 1)) }

    /// "1920, 480" → [1920, 480]; at most four sizes between 16 and 16 000 px.
    static var imageSizes: [Int] {
        let text = defaults.string(forKey: Key.imageSizes) ?? ""
        let sizes = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (16...16_000).contains($0) }
        var seen = Set<Int>()
        return Array(sizes.filter { seen.insert($0).inserted }.prefix(4))
    }

    static var targetMB: String { defaults.string(forKey: Key.targetMB) ?? "1" }

    /// nil = save next to the original.
    static var outputFolder: URL? {
        guard defaults.string(forKey: Key.saveLocation) == SaveLocation.folder.rawValue,
              let path = defaults.string(forKey: Key.outputFolderPath), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return Settings.defaultAccentHex }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
