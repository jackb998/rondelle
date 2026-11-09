// Development command line (tests and screenshots). Compiled only in DEBUG test builds:
// the release app contains none of this code, its test hooks or the RONDELLE_* variables.
#if DEBUG
import AppIntents
import AppKit
import AVFoundation
import PDFKit
import SwiftUI

@MainActor
enum CLI {
    static func run(_ command: String, mode: WheelMode, _ args: [String]) -> Int32 {
        switch command {
        case "--list":
            let urls = args.map { URL(fileURLWithPath: $0) }
            for action in ActionCatalog.actions(for: urls, mode: mode) {
                if case .group(let members) = action.work {
                    print("\(action.title) [\(members.map(\.title).joined(separator: ", "))]")
                } else {
                    print(action.title)
                }
            }
            return 0

        case "--run":
            guard args.count >= 2 else { return usage() }
            let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
            guard let action = ActionCatalog.actions(for: urls, mode: mode).flatMap(\.flattened).first(where: { $0.matches(args[0]) }) else {
                fputs("Azione «\(args[0])» non disponibile per questi file.\n", stderr)
                return 1
            }
            return execute(action, urls)

        case "--render":
            guard args.count >= 2 else { return usage() }
            let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
            let actions = ActionCatalog.actions(for: urls, mode: mode)
            let hasGroups = actions.contains { if case .group = $0.work { return true } else { return false } }
            let ring = Settings.wheelStyle.showsRing && hasGroups ? (WheelController.size(for: actions.count) * 0.17).rounded() : 0
            let side = WheelController.size(for: actions.count) + 2 * ring
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            view.style = Settings.wheelStyle
            view.ringSpace = ring
            view.fileCount = urls.count
            view.filesHint = FileHints.line(forFiles: urls)
            view.mode = mode
            view.actions = actions
            // RONDELLE_HIGHLIGHT=3 draws segment 3 as if the pointer were over it.
            view.previewHighlight = ProcessInfo.processInfo.environment["RONDELLE_HIGHLIGHT"].flatMap { Int($0) }
            view.blank = ProcessInfo.processInfo.environment["RONDELLE_BLANK"] != nil
            // RONDELLE_GROUP=0 RONDELLE_CHILD=1: group 0 open on the second ring, its variant 1 under the pointer.
            if let g = ProcessInfo.processInfo.environment["RONDELLE_GROUP"].flatMap({ Int($0) }) {
                view.previewOpen(group: g, child: ProcessInfo.processInfo.environment["RONDELLE_CHILD"].flatMap { Int($0) })
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[0]))
            return 0

        case "--render-glass":
            // --render-glass OUT.png FILE…: the wheel on a colourful background, as the window server composes it
            // (cacheDisplay leaves the glass out). RONDELLE_NOGLASS=1: the same without glass.
            guard args.count >= 2 else { return usage() }
            let side: CGFloat = 420
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: side, height: side), styleMask: [.borderless], backing: .buffered, defer: false)
            let back = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            back.wantsLayer = true
            let colours = ProcessInfo.processInfo.environment["RONDELLE_BACK"] == "light"
                ? [NSColor.white.cgColor, NSColor(white: 0.85, alpha: 1).cgColor]
                : [NSColor.systemPink.cgColor, NSColor.systemYellow.cgColor, NSColor.systemTeal.cgColor, NSColor.systemIndigo.cgColor]
            let gradient = CAGradientLayer()
            gradient.frame = back.bounds
            gradient.colors = colours
            gradient.startPoint = .zero
            gradient.endPoint = CGPoint(x: 1, y: 1)
            back.layer?.addSublayer(gradient)
            for i in 0..<6 {   // sharp shapes: refraction shows on them
                let bar = CALayer()
                bar.frame = CGRect(x: 0, y: CGFloat(i) * 72 + 10, width: side, height: 16)
                bar.backgroundColor = NSColor(white: i % 2 == 0 ? 1 : 0, alpha: 0.75).cgColor
                back.layer?.addSublayer(bar)
            }
            window.contentView = back
            let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
            let view = WheelView(frame: back.bounds)
            view.fileCount = urls.count
            view.mode = mode
            view.actions = ActionCatalog.actions(for: urls, mode: mode)
            view.previewHighlight = ProcessInfo.processInfo.environment["RONDELLE_HIGHLIGHT"].flatMap { Int($0) }
            if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["RONDELLE_NOGLASS"] == nil {
                let glass = NSGlassEffectView(frame: WheelView.glassRect(in: back.bounds))
                glass.cornerRadius = glass.frame.width / 2
                let dark = WheelPalette.isDark
                glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                glass.tintColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(WheelPalette.glassTint)
                back.addSubview(glass)
                view.glassBackground = true
            }
            back.addSubview(view)
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let image = unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() else { return 1 }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[0]))
            return 0

        case "--render-settings":
            // Snapshot of the Settings window (all tabs stacked), for checking the layout.
            guard let path = args.first else { return usage() }
            return snapshot(SettingsSnapshot(), size: NSSize(width: 560, height: 1800), to: path, wait: 0.3)

        case "--test-main-block":
            // --test-main-block FILE…: what the main thread does with a dropped file (the check, the wheel's
            // actions, the hint), and how long it takes.
            let urls = args.map { URL(fileURLWithPath: $0) }
            let start = Date()
            var refused = false
            do { try SafeFile.refuseSpecial(urls) } catch { refused = true }
            let actions = ActionCatalog.actions(for: urls, mode: .tools).flatMap(\.flattened)
            if urls.count == 1 { for action in actions { _ = action.hintReader?(urls[0]) } }
            print(String(format: "%.1f ms, %@", Date().timeIntervalSince(start) * 1000, refused ? "rifiutato" : "accettato"))
            return 0

        case "--read-hint":
            // --read-hint FILE: the hint a protected ZIP or PDF carries, as the password question would show it.
            guard let path = args.first else { return usage() }
            let url = URL(fileURLWithPath: path)
            print((url.pathExtension.lowercased() == "pdf" ? PasswordHint.fromPDF(url) : PasswordHint.fromZip(url)) ?? "")
            return 0

        case "--show-password":
            // --show-password OUT.png [QUESTION_HINT]: the new-password dialog, or with an argument the one that shows a hint.
            guard let path = args.first else { return usage() }
            let form = args.count > 1
                ? Notice.passwordForm(PasswordHint.question(L("Password dello ZIP protetto:"), hint: args[1]), problem: nil, twice: false, withHint: false)
                : Notice.passwordForm(WheelAction.protectedZipQuestion, problem: nil, twice: true, withHint: true)
            let shot = snapshot(form.alert, to: path)
            // Without a window server capture (no screen recording permission): the fields alone.
            if !FileManager.default.fileExists(atPath: path), let fields = form.alert.accessoryView,
               let rep = fields.bitmapImageRepForCachingDisplay(in: fields.bounds) {
                fields.cacheDisplay(in: fields.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            return shot

        case "--test-tutorial":
            // --test-tutorial: the tutorial's practice scene with synthetic drags and keys.
            let problems = TutorialPracticeTest.run()
            problems.forEach { print("problema: \($0)") }
            print(problems.isEmpty ? "tutorial interattivo corretto" : "\(problems.count) problemi")
            return problems.isEmpty ? 0 : 1
        case "--tutorial-gif":
            // --tutorial-gif OUT.gif [dark]: the README's animation (RONDELLE_LANG=en for the English one).
            guard let path = args.first else { return usage() }
            // The wheel as it looks with the system in that mode («Automatico»), without Liquid Glass (see TutorialGIF).
            UserDefaults.standard.setVolatileDomain([Settings.Key.liquidGlass: false, Settings.Key.theme: WheelTheme.auto.rawValue],
                                                    forName: UserDefaults.argumentDomain)
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApp.appearance = NSAppearance(named: args.contains("dark") ? .darkAqua : .aqua)
            return TutorialGIF.write(to: URL(fileURLWithPath: path))

        case "--show-tutorial":
            // --show-tutorial OUT.png [PAGE] [STEP] [dark]: the tutorial's real round window, stopped on that step of that
            // page; transparent outside the circle.
            guard let path = args.first else { return usage() }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let numbers = args.dropFirst().compactMap { Int($0) }
            TutorialWindow.shared.show(page: numbers.first ?? 0, frozenStep: numbers.count > 1 ? numbers[1] : 3)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            // The wheel is an AppKit view: in a cached drawing it leaves its corners see-through, the window doesn't.
            // So the drawing goes on the disc's own colour, inside the circle only.
            let image = NSImage(size: view.bounds.size, flipped: false) { rect in
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
                rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                return true
            }
            try? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return 0

        case "--show-language":
            // --show-language OUT.png: the question when a file's language can't be recognized.
            guard let path = args.first else { return usage() }
            if #available(macOS 15.0, *) { return snapshot(Notice.languageAlert(of: "appunti.txt", guess: .italian), to: path) }
            return 1

        case "--show-zip-warning":
            // --show-zip-warning OUT.png [LENGTH] [aperto]: the warning for a short protected-ZIP password, as macOS
            // draws it (window server capture), with «Altro» open or closed.
            guard let path = args.first else { return usage() }
            let w = weakZipWarning(length: args.count > 1 ? Int(args[1]) ?? 5 : 5)
            let alert = Notice.detailsAlert(title: w.title, text: w.text, details: w.details, buttons: [w.button, w.change])
            NSApp.setActivationPolicy(.regular)
            let open = args.count > 2 && args[2] == "aperto"
            nonisolated(unsafe) var status: Int32 = 1
            // An alert draws only while it runs modally: open «Altro», capture, then end the modal session.
            let toggle = Timer(timeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated { if open { (alert.accessoryView as? DetailsDisclosure)?.flipFromCaption() } }
            }
            let shot = Timer(timeInterval: 1.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                       let image = unsafeBitCast(symbol, to: Capture.self)(.null, 8, UInt32(alert.window.windowNumber), 9)?.takeRetainedValue() {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        status = 0
                    } else if let frame = alert.window.contentView?.superview,
                              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                        // Fallback without the window server: the alert's own drawing (no shadow or glass).
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        status = 0
                    }
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(toggle, forMode: .modalPanel)
            RunLoop.main.add(shot, forMode: .modalPanel)
            NSApp.activate(ignoringOtherApps: true)
            _ = alert.runModal()
            return status

        case "--show-settings":
            // --show-settings OUT.png [PANE] [SCROLL] [svuota]: the real Settings window, title bar included, with the
            // pane scrolled down by SCROLL points (checks what the title bar looks like over scrolled content);
            // «svuota» clears the job history while the window is open, as the menu bar would.
            guard let path = args.first else { return usage() }
            let pane = args.count > 1 ? SettingsPane(rawValue: args[1]) ?? .appearance : .appearance
            let scroll = args.count > 2 ? Double(args[2]) ?? 0 : 0
            SettingsWindow.shared.show(pane: pane)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController is NSHostingController<SettingsView> }),
                  let frame = window.contentView?.superview else { return 1 }
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
            }
            // The detail column is the scroll view furthest to the right.
            if let detail = scrollViews(frame).max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) {
                detail.contentView.scroll(to: NSPoint(x: 0, y: scroll))
                detail.reflectScrolledClipView(detail.contentView)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            if args.count > 3, args[3] == "svuota" {
                JobHistory.clear()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            }
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return 1 }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // RONDELLE_REAL=1: the window as the window server composes it (glass included, which cacheDisplay
            // leaves out), saved next to OUT.png as OUT-reale.png. Own windows need no screen recording permission.
            if ProcessInfo.processInfo.environment["RONDELLE_REAL"] != nil {
                typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                    let capture = unsafeBitCast(symbol, to: Capture.self)
                    // .optionIncludingWindow = 8, .boundsIgnoreFraming | .bestResolution = 1 | 8
                    if let image = capture(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() {
                        let out = URL(fileURLWithPath: path).deletingPathExtension().path + "-reale.png"
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    } else { fputs("cattura reale non riuscita\n", stderr) }
                }
            }
            return 0

        case "--render-window":
            // --render-window layout|merge OUT.png FILE…: snapshot of the Layout or Merge window.
            if args.first == "settings", args.count >= 2 {
                // --render-window settings OUT.png [appearance|behaviour|wheel|conversions|privacy|about]
                let pane = args.count > 2 ? SettingsPane(rawValue: args[2]) ?? .appearance : .appearance
                let size = ProcessInfo.processInfo.environment["RONDELLE_SETTINGS_SIZE"] == "max" ? SettingsWindow.largest
                    : ProcessInfo.processInfo.environment["RONDELLE_SETTINGS_SIZE"] == "min" ? SettingsWindow.smallest : NSSize(width: 940, height: 620)
                return snapshot(SettingsView(pane: pane), size: size, to: args[1], wait: 1)
            }
            guard args.count >= 3 else { return usage() }
            let urls = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
            if args[0] == "editor" {
                // A few marks of every kind, drawn the way the mouse would, then the window as it looks.
                let model = EditorModel(url: urls[0])
                Task { @MainActor in
                    await model.load()
                    let w = model.pixelSize.width, h = model.pixelSize.height
                    let strokes: [(PhotoEditor.Tool, CGPoint, CGPoint)] = [
                        (.cover, CGPoint(x: w * 0.1, y: h * 0.1), CGPoint(x: w * 0.5, y: h * 0.2)),
                        (.box, CGPoint(x: w * 0.55, y: h * 0.3), CGPoint(x: w * 0.9, y: h * 0.5)),
                        (.arrow, CGPoint(x: w * 0.2, y: h * 0.8), CGPoint(x: w * 0.5, y: h * 0.55)),
                        (.pen, CGPoint(x: w * 0.1, y: h * 0.6), CGPoint(x: w * 0.4, y: h * 0.7)),
                        (.crop, CGPoint(x: w * 0.05, y: h * 0.05), CGPoint(x: w * 0.95, y: h * 0.95)),
                    ]
                    for (tool, a, b) in strokes {
                        model.tool = tool
                        model.begin(at: a)
                        model.drag(from: a, to: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                        model.drag(from: a, to: b)
                        model.end(at: b)
                    }
                    model.tool = .cover
                }
                return snapshot(EditorView(model: model).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 960, height: 720), to: args[1], wait: 3)
            }
            if args[0] == "scrivici" {
                // --render-window scrivici OUT.png FILE: the contact form.
                return snapshot(FeedbackWindow.preview().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 460, height: 430), to: args[1], wait: 0.5)
            }
            if args[0] == "oscura" {
                // --render-window oscura OUT.png FILE: the redaction window, with «visibile» found.
                _ = NSApplication.shared
                return RedactWindow.snapshot(urls[0], to: args[1], word: "visibile") ? 0 : 1
            }
            if args[0] == "options" || args[0] == "options-convert" {
                // --render-window options[-convert] OUT.png FILE…: the options panel of the first group on the Tools (Convert) wheel.
                guard let group = ActionCatalog.actions(for: urls, mode: args[0] == "options" ? .tools : .convert).first(where: { $0.flattened.count > 1 }) else { return 1 }
                return snapshot(OptionsView(title: group.title, actions: group.flattened, fileCount: urls.count) { _ in }
                    .background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 346, height: 300), to: args[1], wait: 0.5)
            }
            if args[0] == "adjust" {
                // --render-window adjust OUT.png FILE: the «Regola» panel with RONDELLE_ADJUST="exposure=40,…".
                let model = EditorModel(url: urls[0])
                Task { @MainActor in
                    await model.load()
                    model.tool = .adjust
                    model.adjustments = testAdjustments()
                }
                return snapshot(EditorView(model: model).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 1200, height: 780), to: args[1], wait: 3)
            }
            if args[0] == "layout" {
                return snapshot(LayoutView(model: LayoutModel(urls: urls)), size: NSSize(width: 900, height: 680),
                                to: args[1], wait: 4)
            }
            return snapshot(MergeView(model: MergeModel(urls: urls)), size: NSSize(width: 820, height: 640),
                            to: args[1], wait: 3)   // pages and thumbnails load in the background

        case "--trim":
            // --trim FILE START END (seconds): what the Trim window saves.
            guard args.count == 3, let start = Double(args[1]), let end = Double(args[2]) else { return usage() }
            let url = URL(fileURLWithPath: args[0])
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    end: CMTime(seconds: end, preferredTimescale: 600))
            return execute(.each("Taglia") { try await MediaOps.trim($0, range: range) }, [url])

        case "--test-pdf-page":
            // --test-pdf-page PDF TEXT: pages, whether page 1 has TEXT, and the colour in the middle of page 1 (r,g,b 0-255).
            // A DOCX with a full-page picture behind the text must stay one page with the text on the picture.
            guard args.count >= 2, let pdf = CGPDFDocument(URL(fileURLWithPath: args[0]) as CFURL), let first = pdf.page(at: 1) else { return usage() }
            let box = first.getBoxRect(.mediaBox)
            guard let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
            context.setFillColor(.white); context.fill(CGRect(origin: .zero, size: box.size))
            context.drawPDFPage(first)
            guard let image = context.makeImage(), let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB) else { return 1 }
            let found = PDFDocument(url: URL(fileURLWithPath: args[0]))?.page(at: 0)?.string?.contains(args[1]) ?? false
            print("pagine=\(pdf.numberOfPages) testo=\(found ? "si" : "no") colore=\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
            return 0

        case "--test-pages-text":
            // --test-pages-text FILE.pages TEXT: the body of the Pages file contains TEXT (si/no) and its length.
            guard args.count >= 2 else { return usage() }
            do {
                let body = try PagesWriter.bodyText(of: URL(fileURLWithPath: args[0]))
                print("testo=\(body.contains(args[1]) ? "si" : "no") lunghezza=\(body.utf16.count)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-pages-read":
            // --test-pages-read FILE.pages [TEXT]: paragraphs, bold runs, italic runs and bullets of what Rondelle reads from
            // the Pages file, and whether TEXT is in it.
            guard args.count >= 1 else { return usage() }
            do {
                let text = try PagesReader.read(URL(fileURLWithPath: args[0]))
                var bold = 0, italic = 0
                text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                    if traits.contains(.bold) { bold += 1 }
                    if traits.contains(.italic) { italic += 1 }
                }
                let paragraphs = text.string.split(separator: "\n", omittingEmptySubsequences: false).count - 1
                let bullets = text.string.components(separatedBy: "•\t").count - 1
                let found = args.count > 1 ? (text.string.contains(args[1]) ? "si" : "no") : "-"
                print("testo=\(found) paragrafi=\(paragraphs) grassetti=\(bold) corsivi=\(italic) puntini=\(bullets) lunghezza=\(text.length)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-pptx-text":
            // --test-pptx-text FILE.pptx TEXT: how many slides Rondelle reads, whether TEXT is in their text, and how many
            // pictures, tables and free-form outlines they hold (the slide's own, with the master's and the layout's).
            guard args.count >= 2 else { return usage() }
            do {
                let url = URL(fileURLWithPath: args[0])
                try PptxOps.check(url)
                let deck = try PptxReader.read(url)
                var pictures = 0, tables = 0, outlines = 0
                for slide in deck.slides {
                    for item in slide.items {
                        switch item.content {
                        case .picture: pictures += 1
                        case .table: tables += 1
                        case .shape(.custom, _, _, _, _): outlines += 1
                        default: break
                        }
                    }
                }
                print("diapositive=\(deck.slides.count) testo=\(PptxOps.text(deck).contains(args[1]) ? "si" : "no") immagini=\(pictures) tabelle=\(tables) larghezza=\(Int(deck.size.width)) libere=\(outlines)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-archive-size":
            // --test-archive-size ARCHIVE: the declared expanded size as Rondelle reads it (no limit).
            guard let path = args.first else { return usage() }
            do {
                let (total, entries) = try ArchiveOps.expandedSize(URL(fileURLWithPath: path), limit: .max)
                print("totale=\(total) voci=\(entries)")
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-shortcuts":
            // --test-shortcuts ACTION FILE…: runs the Shortcuts action body and reports what is left in tmp/Comandi.
            guard args.count >= 2 else { return usage() }
            let files = args.dropFirst().map { path -> IntentFile in
                let url = URL(fileURLWithPath: path)
                return IntentFile(fileURL: url, filename: url.lastPathComponent)
            }
            nonisolated(unsafe) var done = false
            Task.detached {
                do {
                    let results = try await ShortcutsWorkspace.run(files, action: args[0])
                    print("risultati: \(results.map(\.filename).joined(separator: ", "))")
                } catch {
                    print("rifiutato: \(error.localizedDescription)")
                }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Comandi")
                let originals = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?
                    .filter { $0.contains("originali/") } ?? []
                print("copie in originali/: \(originals.count)")
                await MainActor.run { done = true }
            }
            while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            return 0

        case "--test-cancel":
            // --test-cancel SECONDS [--tools] ACTION FILE: starts the action, cancels it after SECONDS,
            // reports how long it took to stop and what was left on disk.
            guard args.count >= 3, let delay = Double(args[0]) else { return usage() }
            let url = URL(fileURLWithPath: args[2])
            guard let action = ActionCatalog.actions(for: [url], mode: mode).flatMap(\.flattened).first(where: { $0.matches(args[1]) }),
                  case .perFile(let work) = action.work else { return usage() }
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
            let start = Date()
            let task = Task.detached { try await FileNaming.cleaningUpOnFailure { try await work(url) } }   // as JobRunner does
            nonisolated(unsafe) var outcome = ""
            nonisolated(unsafe) var done = false
            Task.detached {
                do { _ = try await task.value; outcome = "completata (annullamento ignorato)" }
                catch is CancellationError { outcome = "annullata" }
                catch { outcome = "errore: \(error.localizedDescription)" }
                await MainActor.run { done = true }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: delay))
            task.cancel()
            while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            let after = Set((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
            print(String(format: "%@ dopo %.1f s; nuovi elementi rimasti: %@", outcome, Date().timeIntervalSince(start),
                         after.subtracting(before).sorted().joined(separator: ", ")))
            return 0

        case "--test-main-stall":
            // --test-main-stall [--tools] ACTION FILE: runs the action while a 10 ms timer on the main thread
            // measures the longest moment the main thread (the app's interface) was blocked.
            guard args.count >= 2 else { return usage() }
            let url = URL(fileURLWithPath: args[1])
            guard let action = ActionCatalog.actions(for: [url], mode: mode).flatMap(\.flattened).first(where: { $0.matches(args[0]) }),
                  case .perFile(let work) = action.work else { return usage() }
            nonisolated(unsafe) var done = false
            nonisolated(unsafe) var outcome = ""
            var last = Date(), worst = 0.0
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                let now = Date(); worst = max(worst, now.timeIntervalSince(last)); last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            let start = Date()
            Task.detached { await Prompts.$allowed.withValue(false) {
                do { outcome = "ok: " + (try await work(url)).map(\.lastPathComponent).joined(separator: ", ") }
                catch { outcome = "rifiutato: \(error.localizedDescription)" }
                await MainActor.run { done = true }
            } }
            while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            timer.invalidate()
            print(String(format: "%@ | durata %.1f s | main thread bloccato al massimo %.2f s", outcome,
                         Date().timeIntervalSince(start), worst))
            return 0

        case "--test-merge-stall":
            // --test-merge-stall FILE: opens the Merge window's model and loads the ~20 visible thumbnails,
            // measuring the longest moment the main thread was blocked.
            guard let path = args.first else { return usage() }
            var last = Date(), worst = 0.0
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                let now = Date(); worst = max(worst, now.timeIntervalSince(last)); last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            let start = Date()
            let model = MergeModel(urls: [URL(fileURLWithPath: path)])
            Task { await model.load() }
            while model.loading { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            // Like SwiftUI laying out the ~20 visible cells in one pass.
            let visible = Array(model.pages.prefix(20))
            for page in visible { model.requestThumbnail(page) }
            while model.thumbnails.count < visible.count { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            timer.invalidate()
            print(String(format: "pagine %d | durata %.1f s | main thread bloccato al massimo %.2f s",
                         model.pages.count, Date().timeIntervalSince(start), worst))
            return 0

        case "--test-name-race":
            // --test-name-race DIR TARGET: Rondelle picks an output name in DIR; in the moment before it writes,
            // an "attacker" plants a link with that name pointing to TARGET; then a writer that opens the path
            // directly (like tar -czf or createFile) writes the output.
            guard args.count == 2 else { return usage() }
            let chosen = FileNaming.unique(URL(fileURLWithPath: args[0]).appendingPathComponent("risultato.zip"))
            let planted = (try? FileManager.default.createSymbolicLink(atPath: chosen.path, withDestinationPath: args[1])) != nil
            // A direct open, like tar -czf: it follows a link if one is there.
            let fd = open(chosen.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 { _ = "contenuto di Rondelle".withCString { write(fd, $0, strlen($0)) }; close(fd) }
            let leaked = FileManager.default.fileExists(atPath: args[1])
            print("nome scelto: \(chosen.lastPathComponent) | link piantato: \(planted ? "sì" : "no (nome già riservato)")"
                  + " | scritto fuori: \(leaked ? "SÌ" : "no")")
            return 0

        case "--test-covers":
            // --test-covers FOLDER TARGET: would a permission for FOLDER be kept when TARGET was requested?
            guard args.count == 2 else { return usage() }
            let ok = FolderAccess.covers(URL(fileURLWithPath: args[0]), URL(fileURLWithPath: args[1]))
            print(ok ? "salvato" : "non salvato")
            return 0

        case "--test-editor":
            // --test-editor PHOTO: covers the middle of the upright photo, writes a text, crops the right half,
            // saves like «Salva copia», then checks the result: covered pixels, size and metadata.
            guard args.count == 1, let (image, _, _) = try? ImageTools.load(URL(fileURLWithPath: args[0])) else { return usage() }
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let cover = CGRect(x: w * 0.55, y: h * 0.3, width: w * 0.3, height: h * 0.4)
            let red = PhotoEditor.RGBA(r: 1, g: 0, b: 0)
            let marks = [
                PhotoEditor.Mark(shape: .cover(cover), color: red, width: 4),
                PhotoEditor.Mark(shape: .text("Prova", CGPoint(x: w * 0.6, y: h * 0.05)), color: red, width: 8),
                PhotoEditor.Mark(shape: .arrow(CGPoint(x: w * 0.6, y: h * 0.9), CGPoint(x: w * 0.9, y: h * 0.8)), color: red, width: 4),
            ]
            let crop = CGRect(x: w / 2, y: 0, width: w / 2, height: h)
            do {
                let out = try PhotoEditor.save(URL(fileURLWithPath: args[0]), marks: marks, crop: crop)
                guard let source = CGImageSourceCreateWithURL(out as CFURL, nil),
                      let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("uscita illeggibile"); return 1 }
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
                // Centre of the covered area, in the cropped photo.
                let px = Int(cover.midX - crop.minX), py = Int(cover.midY)
                let ctx = CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
                let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
                let o = py * ctx.bytesPerRow + px * 4
                let black = bytes[o] < 8 && bytes[o + 1] < 8 && bytes[o + 2] < 8
                // An embedded EXIF thumbnail (a second JPEG inside the file) would still show the covered parts.
                let data = (try? Data(contentsOf: out)) ?? Data()
                let jpegStarts = (0..<max(data.count - 2, 0)).filter { data[$0] == 0xFF && data[$0 + 1] == 0xD8 && data[$0 + 2] == 0xFF }.count
                let thumb = jpegStarts > 1
                let comment = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] != nil
                print("uscita: \(out.lastPathComponent) | \(result.width)×\(result.height) | area coperta nera: \(black ? "sì" : "NO")"
                      + " | GPS: \(props[kCGImagePropertyGPSDictionary] == nil ? "assente" : "PRESENTE")"
                      + " | commento EXIF: \(comment ? "PRESENTE" : "assente") | miniatura incorporata: \(thumb ? "PRESENTE" : "assente")")
                return 0
            } catch {
                print("errore: \(error.localizedDescription)")
                return 1
            }

        case "--test-neutralize":
            // --test-neutralize PDF: the Producer/date clean-up of «Metadati» on a PDF as it is (normally PDFKit's
            // own output), to see the error path with layouts PDFKit doesn't produce today.
            guard args.count == 1, let doc = CGPDFDocument(URL(fileURLWithPath: args[0]) as CFURL) else { return usage() }
            do {
                try PDFOps.neutralizeInfo(URL(fileURLWithPath: args[0]), pages: doc.numberOfPages)
                print("neutralizzato")
            } catch {
                print("errore mostrato all'utente: \(error.localizedDescription)")
            }
            return 0

        case "--test-share-prepare":
            // --test-share-prepare FILE…: the copies the share wheel would send (Settings → Privacy option on).
            let urls = args.map { URL(fileURLWithPath: $0) }
            nonisolated(unsafe) var done = false
            Task { @MainActor in
                for url in await ShareOps.prepared(urls) ?? [] { print(url.path) }
                done = true
            }
            while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            return 0

        case "--test-adjust":
            // --test-adjust FILE: saves «Modifica» with only the adjustments in RONDELLE_ADJUST; prints the copy.
            guard let path = args.first else { return usage() }
            do {
                print(try PhotoEditor.save(URL(fileURLWithPath: path), marks: [], crop: nil, adjustments: testAdjustments()).path)
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-terminal-check":
            // --test-terminal-check DIR…: what would make «Terminale» ask first (nothing is opened or run).
            guard !args.isEmpty else { return usage() }
            for dir in args {
                let found = ShareOps.autoRunFindings(in: URL(fileURLWithPath: dir))
                print("\((dir as NSString).lastPathComponent): \(found.isEmpty ? "nessun avviso" : found.joined(separator: ", "))")
            }
            return 0

        case "--test-keys":
            // --test-keys: which wheel opens for each combination of held keys (current preferences).
            for combo in KeyCombo.all {
                print("\(combo.rawValue) → \(Settings.mode(for: combo.flags.union(.capsLock)).map { "\($0)" } ?? "nessuna")")
            }
            return 0

        case "--test-share-services":
            // --test-share-services FILE: the sharing services macOS offers for it (extensions of other apps too).
            for service in NSSharingService.sharingServices(forItems: [URL(fileURLWithPath: args.first ?? "/")]) {
                print(service.title)
            }
            for name in [NSSharingService.Name.sendViaAirDrop, .composeMessage, .composeEmail] {
                print("\(name.rawValue): \(NSSharingService(named: name)?.canPerform(withItems: [URL(fileURLWithPath: args.first ?? "/")]) ?? false)")
            }
            return 0

        case "--test-share-picker":
            // --test-share-picker FILE: opens «Altro…» as the wheel does, three times. Each time the anchor window must
            // exist, be visible and key (else Esc and clicks outside don't close the menu), and then go away with nothing of
            // the app left on screen: closed by Esc, by the menu ending without a choice (service nil), by the app losing focus.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let url = URL(fileURLWithPath: args.first ?? "/")
            func visible() -> [String] { app.windows.filter(\.isVisible).map { String(describing: type(of: $0)) } }
            /// Runs the loop and hands out events (Esc), as NSApp.run would.
            func pump(_ seconds: TimeInterval) {
                let end = Date(timeIntervalSinceNow: seconds)
                while Date() < end {
                    if let e = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
                        app.sendEvent(e)
                    }
                }
            }
            var ok = true
            let closers: [(String, () -> Void)] = [
                ("Esc", {
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: ShareOps.PickerSession.shared.anchor?.windowNumber ?? 0, context: nil,
                                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        app.postEvent(e, atStart: false)
                    }
                }),
                ("annullato", { ShareOps.PickerSession.shared.sharingServicePicker(NSSharingServicePicker(items: [url]), didChoose: nil) }),
                ("app non più attiva", { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app) }),
            ]
            for (name, close) in closers {
                ShareOps.showPicker([url])
                pump(1)
                let anchor = ShareOps.PickerSession.shared.anchor
                let opened = anchor != nil && anchor!.isVisible && anchor!.isKeyWindow
                print("\(name): appoggio \(anchor == nil ? "assente" : "presente"), visibile \(anchor?.isVisible ?? false), chiave \(anchor?.isKeyWindow ?? false) (app attiva \(app.isActive), chiave: \(app.keyWindow.map { String(describing: type(of: $0)) } ?? "nessuna")); finestre: \(visible())")
                close()
                pump(1)
                let left = visible()
                let closed = ShareOps.PickerSession.shared.anchor == nil && left.isEmpty
                print("\(name): \(opened && closed ? "PASS" : "FAIL") (dopo: appoggio \(ShareOps.PickerSession.shared.anchor == nil ? "chiuso" : "aperto"), finestre rimaste \(left))")
                ok = ok && opened && closed
            }
            return ok ? 0 : 1

        case "--test-crash-cleanup":
            // What the app does at launch after a crash: remove what unfinished jobs left behind.
            print("elementi rimossi: \(CrashJournal.cleanUp())")
            return 0

        case "--test-shortcuts-launch-cleanup":
            // What the app does at launch: empty tmp/Comandi.
            ShortcutsWorkspace.removeAll()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Comandi")
            print("elementi rimasti in Comandi/: \((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0)")
            return 0

        case "--animate":
            // --animate ring: plays the completion animation in the middle of the screen.
            guard let style = args.first.flatMap(CompletionStyle.init(rawValue:)) else { return usage() }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let screen = NSScreen.main?.frame ?? .zero
            CompletionAnimation.play(at: NSPoint(x: screen.midX, y: screen.midY), style: style)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.2))
            return 0

        case "--show-window":
            // --show-window KIND OUT.png FILE…: opens a real window (editor, merge, layout, feedback, metadata, redact,
            // settings, settings-nosidebar, about) and draws it from inside the app, title bar included: no screen capture permission needed.
            guard args.count >= 2 else { return usage() }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let files = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
            switch args[0] {
            case "editor": PhotoEditor.open(files)
            case "merge": MergeWindow.open(files)
            case "layout": LayoutWindow.open(files)
            case "feedback": FeedbackWindow.show()
            case "metadata": MetadataWindow.open(files)
            case "redact": RedactWindow.open(files)
            case "settings", "settings-nosidebar": SettingsWindow.shared.show(pane: .behaviour)
            case "about": AboutWindow.show()
            default: return usage()
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
            if args[0] == "settings-nosidebar" {
                NotificationCenter.default.post(name: Notification.Name("RondelleTestHideSidebar"), object: nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            }
            guard let window = app.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let frame = window.contentView?.superview ?? window.contentView,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return 1 }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            print("\(Int(window.frame.width))×\(Int(window.frame.height))")
            return 0

        case "--test-sidebar-motion":
            // --test-sidebar-motion: hides and shows the Settings sidebar with its button, sampling every frame. PASS when
            // the main thread never stops for more than 50 ms (it was 355–374 ms) and the detail column stays still on
            // screen (≤ 3 points). RONDELLE_SIDEBAR_TRACE=1 prints every frame, RONDELLE_SIDEBAR_FRAMES=FOLDER also saves a few mid-way,
            // RONDELLE_SIDEBAR_ROUNDS=N repeats it.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            SettingsWindow.shared.show(pane: .behaviour)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
            guard let window = app.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return 1 }
            func splitView(_ view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                return view.subviews.lazy.compactMap(splitView).first
            }
            /// Where the detail column starts on screen: it should not move while the sidebar goes.
            func detailLeft() -> CGFloat? {
                guard let split = window.contentView.flatMap(splitView), let detail = split.arrangedSubviews.last else { return nil }
                return window.convertToScreen(detail.convert(detail.bounds, to: nil)).minX
            }
            var ok = true
            let rounds = Int(ProcessInfo.processInfo.environment["RONDELLE_SIDEBAR_ROUNDS"] ?? "") ?? 1
            for step in Array(repeating: ["nascondi", "mostra"], count: max(rounds, 1)).joined() {
                let startLeft = detailLeft() ?? 0
                var gaps: [Double] = [], drift: CGFloat = 0
                var last = Date()
                let start = Date()
                NotificationCenter.default.post(name: Notification.Name("RondelleTestHideSidebar"), object: nil)
                gaps.append(Date().timeIntervalSince(start))
                while Date().timeIntervalSince(start) < 1.0 {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 120))
                    let now = Date()
                    gaps.append(now.timeIntervalSince(last))
                    last = now
                    if let left = detailLeft() {
                        drift = max(drift, abs(left - startLeft))
                        if ProcessInfo.processInfo.environment["RONDELLE_SIDEBAR_TRACE"] != nil {
                            let bar = window.contentView.flatMap(splitView)?.arrangedSubviews.first?.frame ?? .zero
                            if let folder = ProcessInfo.processInfo.environment["RONDELLE_SIDEBAR_FRAMES"], bar.width > 60, bar.width < 180,
                               let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                view.cacheDisplay(in: view.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(step)-\(Int(bar.width)).png"))
                            }
                            print(String(format: "  %.0f ms  (+%.0f)  finestra x %.0f w %.0f  pannello x %.1f  barra x %.0f w %.0f", now.timeIntervalSince(start) * 1000, (gaps.last ?? 0) * 1000, window.frame.minX, window.frame.width, left, bar.minX, bar.width))
                        }
                    }
                }
                let worst = (gaps.max() ?? 0) * 1000
                // Once there, the window resizes only within the limits of its new shape.
                let limits = step == "nascondi" ? (480.0, 940.0) : (720.0, 1180.0)
                let limited = window.contentMinSize.width == limits.0 && window.contentMaxSize.width == limits.1
                // Hidden, the sidebar stays outside the window even when the window is made wider by hand.
                var parked = true
                if step == "nascondi" {
                    let frame = window.frame
                    window.setContentSize(NSSize(width: 860, height: window.contentLayoutRect.height))
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                    parked = abs((detailLeft() ?? 0) - window.frame.minX) <= 1
                    window.setFrame(frame, display: true)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                }
                let pass = worst <= 50 && drift <= 3 && limited && parked
                ok = ok && pass
                if ProcessInfo.processInfo.environment["RONDELLE_SIDEBAR_TRACE"] != nil {
                    print(gaps.prefix(8).map { Int($0 * 1000) }, gaps.enumerated().max { $0.1 < $1.1 }.map { $0.0 } ?? -1)
                }
                print("\(step): pausa più lunga \(Int(worst)) ms, spostamento del pannello \(Int(drift)) punti, finestra \(Int(window.frame.width)) (\(Int(window.contentMinSize.width))–\(Int(window.contentMaxSize.width)))\(parked ? "" : ", barra rientrata allargando") → \(pass ? "PASS" : "FAIL")")
            }
            return ok ? 0 : 1

        case "--show-editor":
            // --show-editor SECONDS PHOTO: opens the real editor window for a while (to look at it on screen).
            guard args.count == 2, let seconds = Double(args[0]) else { return usage() }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            PhotoEditor.open([URL(fileURLWithPath: args[1])])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            return 0

        case "--layouts":
            // --layouts OUT_FOLDER ASPECT FILE…: renders every layout template, like the Layout window would save it.
            guard args.count >= 4, let aspect = LayoutAspect(rawValue: args[1]) else { return usage() }
            let folder = URL(fileURLWithPath: args[0], isDirectory: true)
            do {
                let photos = try args.dropFirst(2).map { try LayoutRenderer.loadPhoto(URL(fileURLWithPath: $0)) }
                for template in LayoutRenderer.templates(for: photos.count) {
                    guard let image = LayoutRenderer.render(photos, template: template, aspect: aspect, spacing: 0.012,
                                                            corner: 0.01, background: CGColor(gray: 1, alpha: 1),
                                                            longSide: 1080) else { return 1 }
                    let out = folder.appendingPathComponent("\(template.id).jpg")
                    try ImageOps.write(image, to: out, type: .jpeg, quality: 0.85)
                    print(out.path)
                }
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--animation-frames":
            // --animation-frames STYLE FOLDER: the completion animation with its clock stopped every 0.1 s, one PNG each
            // (to look at it without recording the screen).
            guard args.count == 2, let style = CompletionStyle(rawValue: args[0]), style != .none else { return usage() }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let side: CGFloat = 180
            let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            view.wantsLayer = true
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: side, height: side),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            let root = view.layer!
            root.speed = 0
            let duration = CompletionAnimation.draw(style, on: root, center: CGPoint(x: side / 2, y: side / 2), moving: true, start: 0)
            for tenth in 0...Int(duration * 10) {
                root.timeOffset = Double(tenth) / 10
                CATransaction.flush()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                let scale = 2
                guard let context = CGContext(data: nil, width: Int(side) * scale, height: Int(side) * scale, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                (root.presentation() ?? root).render(in: context)
                guard let image = context.makeImage() else { return 1 }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(args[1])/\(style.rawValue)-\(String(format: "%.1f", Double(tenth) / 10)).png"))
            }
            print("\(Int(duration * 10) + 1) fotogrammi")
            return 0

        case "--test-support-link":
            // --test-support-link: the «Buy me a coffee» URL is https, on buymeacoffee.com, with a plain profile name (no old Mandarino/random id).
            let u = SupportLink.coffee, name = u.path.dropFirst()
            let good = u.scheme == "https" && u.host == "buymeacoffee.com" && u.query == nil && u.fragment == nil
                && name == "jackb998" && !u.absoluteString.lowercased().contains("mandarino")
            print(good ? "PASS link caffè: \(u.absoluteString)" : "FAIL link caffè: \(u.absoluteString)")
            return good ? 0 : 1

        case "--test-wheel-hints":
            // --test-wheel-hints: every entry of every wheel (each kind of file, each mode, groups and what's inside them)
            // must have a line in the hub, short enough to show with the pizza shape (the smallest hub). Lists the others.
            let kinds: [(String, FileKind)] = [("immagini", .image), ("PDF", .pdf), ("video", .video), ("audio", .audio),
                                               ("documenti", .document), ("fogli", .spreadsheet), ("presentazioni", .presentation), ("sottotitoli", .subtitle),
                                               ("archivi", .archive), ("altro", .other)]
            var seen = Set<String>(), problems: [String] = []
            for (kindName, kind) in kinds {
                for (modeName, mode) in [("Converti", WheelMode.convert), ("Strumenti", .tools), ("Condividi", .share)] {
                    for action in ActionCatalog.allActions(for: kind, mode: mode) {
                        let entries = action.flattened.count > 1 || action.flattened.first?.key != action.key ? [action] + action.flattened : [action]
                        for entry in entries where seen.insert("\(entry.id)/\(entry.key)/\(FileHints.line(for: entry) ?? "")").inserted {
                            let place = "\(modeName) · \(kindName) · \(entry.title)"
                            guard let hint = FileHints.line(for: entry) else { problems.append("\(place): nessuna descrizione"); continue }
                            if ProcessInfo.processInfo.environment["RONDELLE_HINTS_LIST"] != nil { print("\(place): \(hint)") }
                            if !WheelView.hubFits(title: entry.title, hint: hint, inner: 165 * 0.31, unit: 1) {
                                problems.append("\(place): «\(hint)» non entra nel cerchio")
                            }
                        }
                    }
                }
            }
            problems.forEach { print($0) }
            print("\(seen.count) voci, \(problems.count) senza descrizione visibile")
            return problems.isEmpty ? 0 : 1

        case "--test-wheel-labels":
            // --test-wheel-labels: every name of every wheel (each kind of file, each mode, each shape) in the language of
            // RONDELLE_LANG must be drawn inside its piece under the pointer: on two lines if it has more than one word,
            // else smaller (down to 50%). The pill is only for a name that would still not fit: none must be left.
            // Lists the names on two lines and any on the pill.
            // One and two files of each kind (one PDF gets «Organizza e dividi», two get «Unisci e dividi»), and PDFs with images.
            let sets: [(String, [String])] = [("immagine", ["a.jpg"]), ("immagini", ["a.jpg", "b.jpg"]), ("PDF", ["a.pdf"]),
                                              ("PDF (2)", ["a.pdf", "b.pdf"]), ("PDF e immagini", ["a.pdf", "b.jpg"]),
                                              ("video", ["a.mov"]), ("audio", ["a.wav"]), ("documento", ["a.docx"]),
                                              ("foglio", ["a.xlsx"]), ("sottotitoli", ["a.srt"]), ("archivio", ["a.zip"]),
                                              ("altro", ["a.bin"])]
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            var twoLines = Set<String>(), pills: [String] = [], total = 0, multiWordPills = 0
            for shape in WheelShape.allCases {
                view.debugShape = shape
                for (kindName, files) in sets {
                    let urls = files.map { URL(fileURLWithPath: "/tmp/\($0)") }
                    for (modeName, mode) in [("Converti", WheelMode.convert), ("Strumenti", .tools), ("Condividi", .share)] {
                        let actions = WheelGroups.apply(ActionCatalog.allActions(for: urls, mode: mode), mode: mode)
                        guard !actions.isEmpty else { continue }
                        for item in view.labelReport(for: actions) {
                            total += 1
                            if item.pill {
                                pills.append("\(shape) · \(modeName) · \(kindName) · \(item.title) (\(actions.count) voci)")
                                if item.title.contains(" ") { multiWordPills += 1 }
                            } else if item.lines == 2 { twoLines.insert("\(item.title)") }
                        }
                    }
                }
            }
            twoLines.sorted().forEach { print("due righe: \($0)") }
            pills.forEach { print("PILLOLA: \($0)") }
            print("\(total) nomi, \(twoLines.count) su due righe, \(pills.count) con la pillola (\(multiWordPills) di più parole)")
            return pills.isEmpty ? 0 : 1

        case "--test-dock-icon":
            // --test-dock-icon [SECONDS]: follows the appearance as Settings does, forcing light and dark for SECONDS
            // each. PASS when the icon (Settings, «Informazioni su») has a light tile with a light Mac and a dark one with
            // a dark Mac, and the Dock gets the light one (dark: the bundle's own, which this test build doesn't have).
            NSApplication.shared.setActivationPolicy(.regular)
            DockIcon.follow()
            let hold = args.first.flatMap(Double.init) ?? 0.5
            func tile(_ image: NSImage) -> CGFloat {
                var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
                let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                let color = cg.flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: $0.width / 2, y: $0.height / 6 + 2)?.usingColorSpace(.sRGB) }
                return color?.brightnessComponent ?? -1
            }
            var ok = true
            for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                NSApp.appearance = NSAppearance(named: name)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: hold))
                let icon = tile(DockIcon.shared.image), dock = tile(NSApp.applicationIconImage)
                let pass = name == .aqua ? icon > 0.8 && dock > 0.8 : icon < 0.2
                ok = ok && pass
                print(String(format: "%@ icona %.2f, Dock %.2f → %@", name.rawValue, icon, dock, pass ? "PASS" : "FAIL"))
            }
            return ok ? 0 : 1

        case "--test-redact":
            // --test-redact FILE PAGE:X,Y,W,H… | «testo»: the redaction, with areas in page coordinates (pages from 1) or all of a word.
            guard args.count >= 2 else { return usage() }
            let url = URL(fileURLWithPath: args[0])
            do {
                var areas: [PDFRedact.Area] = []
                for spec in args.dropFirst() {
                    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                    let numbers = parts.count == 2 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
                    if numbers.count == 4, let page = Int(parts[0]) {
                        areas.append(PDFRedact.Area(page: page - 1, rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])))
                    } else {
                        areas += try PDFRedact.areas(of: spec, in: url)
                    }
                }
                try PDFRedact.apply(url, areas: areas).forEach { print($0.path) }
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-pixel":
            // --test-pixel FILE PAGE X Y: the brightness at a point from the top left of the page as shown, in points.
            guard args.count == 4, let page = CGPDFDocument(URL(fileURLWithPath: args[0]) as CFURL)?.page(at: Int(args[1]) ?? 1),
                  let x = Double(args[2]), let y = Double(args[3]), let image = PDFOps.render(page, dpi: 72) else { return usage() }
            let color = NSBitmapImageRep(cgImage: image).colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB)
            print(String(format: "%.2f", color?.brightnessComponent ?? -1))
            return 0

        case "--test-wheel-hit":
            // Tests/functional: the pointer picks the right piece in every shape.
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
            let problems = view.hitProblems()
            problems.prefix(10).forEach { print($0) }
            print(problems.isEmpty ? "aree corrette" : "\(problems.count) problemi")
            return problems.isEmpty ? 0 : 1

        case "--snapshot-metadata":
            // --snapshot-metadata OUT.png FILE…: the «Metadati → Leggi» window as drawn (light or dark as the system).
            guard args.count >= 2 else { return usage() }
            let model = MetadataModel(more: 0)
            nonisolated(unsafe) var read: [MetadataReader.Section]?
            let files = args.dropFirst().map { URL(fileURLWithPath: $0) }
            Task.detached { var all: [MetadataReader.Section] = []; for url in files { all.append(await MetadataReader.read(url)) }; read = all }
            while read == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            model.sections = read
            // RONDELLE_QUERY: the window with that text in the search field.
            model.query = ProcessInfo.processInfo.environment["RONDELLE_QUERY"] ?? ""
            return snapshot(MetadataView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                            size: NSSize(width: 520, height: 900), to: args[0], wait: 0.5)
        case "--test-metadata":
            // --test-metadata FILE…: what «Metadati → Leggi» shows; fails on an empty file list, a row too long
            // or with control characters, or more rows than the cap.
            var problems: [String] = []
            for url in args.map({ URL(fileURLWithPath: $0) }) {
                nonisolated(unsafe) var read: MetadataReader.Section?
                Task.detached { read = await MetadataReader.read(url) }
                while read == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                let section = read!
                let longest = section.rows.map { $0.value.count }.max() ?? 0
                print("\(section.name): \(section.rows.count) valori, il più lungo \(longest) caratteri")
                if section.rows.count < 2 { problems.append("\(section.name): niente metadati") }
                if longest > MetadataReader.maxValue + 1 { problems.append("\(section.name): valore troppo lungo") }
                if section.rows.count > MetadataReader.maxRows + 1 { problems.append("\(section.name): troppe righe") }
                if section.rows.contains(where: { ($0.key + $0.value).unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }) {
                    problems.append("\(section.name): caratteri di controllo")
                }
            }
            problems.forEach { print("problema: \($0)") }
            return problems.isEmpty ? 0 : 1
        case "--test-rotations":
            // --test-rotations: the five turns of «Ruota» on a 6×4 picture of all different pixels, pixel by pixel:
            // TIFF in each of the 8 EXIF orientations (only the orientation changes, nothing re-encoded) and PNG (the
            // pixels are redrawn). The result, shown upright, must be the source shown upright turned as expected.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rotazioni-" + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let (w, h) = (6, 4)
            func pixels(_ image: CGImage) -> (Int, Int, [UInt8]) {
                var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return (image.width, image.height, data)
            }
            var raw = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w { let i = (y * w + x) * 4; raw[i] = UInt8(x * 40 + 10); raw[i + 1] = UInt8(y * 60 + 10); raw[i + 2] = UInt8((x * 7 + y * 31) % 256) } }
            let source = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
            func expected(_ turn: ImageTools.Turn, _ u: (Int, Int, [UInt8])) -> (Int, Int, [UInt8]) {
                let (uw, uh, up) = u
                let (ew, eh) = turn.swapsSides ? (uh, uw) : (uw, uh)
                var out = [UInt8](repeating: 0, count: ew * eh * 4)
                for y in 0..<eh { for x in 0..<ew {
                    let (sx, sy): (Int, Int)
                    switch turn {
                    case .right: (sx, sy) = (y, uh - 1 - x)
                    case .left: (sx, sy) = (uw - 1 - y, x)
                    case .half: (sx, sy) = (uw - 1 - x, uh - 1 - y)
                    case .mirrorHorizontal: (sx, sy) = (uw - 1 - x, y)
                    case .mirrorVertical: (sx, sy) = (x, uh - 1 - y)
                    }
                    for c in 0..<4 { out[(y * ew + x) * 4 + c] = up[(sy * uw + sx) * 4 + c] }
                } }
                return (ew, eh, out)
            }
            var problems: [String] = [], checked = 0
            let cases: [(String, UTType, Int)] = (1...8).map { ("tiff", UTType.tiff, $0) } + [("png", .png, 1)]
            for (ext, type, orientation) in cases {
                let file = dir.appendingPathComponent("o\(orientation).\(ext)")
                guard let dest = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) else { return 1 }
                CGImageDestinationAddImage(dest, source, [kCGImagePropertyOrientation: orientation] as CFDictionary)
                guard CGImageDestinationFinalize(dest), let upright = try? ImageTools.load(file).image else { problems.append("\(file.lastPathComponent): non scritto"); continue }
                let u = pixels(upright)
                for turn in ImageTools.Turn.allCases {
                    guard let out = try? ImageTools.turn(file, turn).first, let result = try? ImageTools.load(out).image else {
                        problems.append("\(file.lastPathComponent) \(turn): non riuscita"); continue
                    }
                    let got = pixels(result), want = expected(turn, u)
                    let diff = got.0 == want.0 && got.1 == want.1 ? zip(got.2, want.2).map { abs(Int($0) - Int($1)) }.max() ?? 0 : 999
                    // TIFF: the copy must keep the pixels as they are, only the orientation changes.
                    if ext == "tiff", let src = CGImageSourceCreateWithURL(out as CFURL, nil),
                       let stored = CGImageSourceCreateImageAtIndex(src, 0, nil), pixels(stored).2 != pixels(source).2 {
                        problems.append("\(file.lastPathComponent) \(turn): pixel ridisegnati invece della sola orientazione")
                    }
                    if diff > 2 { problems.append("\(file.lastPathComponent) \(turn): differenza \(diff)") }
                    checked += 1
                    try? FileManager.default.removeItem(at: out)
                }
            }
            problems.forEach { print("problema: \($0)") }
            print("\(checked) rotazioni controllate pixel per pixel, \(problems.count) problemi")
            return problems.isEmpty && checked == 45 ? 0 : 1

        case "--test-office-metadata":
            // --test-office-metadata FILE…(DOCX, XLSX, PPTX): «Leggi» shows author, company, custom properties and the
            // download origin; «Rimuovi» writes a copy where none of them is left (also not the Spotlight attributes),
            // whose text, sheets or slides are byte for byte the original's and that still opens.
            var problems: [String] = []
            for url in args.map({ URL(fileURLWithPath: $0) }) {
                nonisolated(unsafe) var read: MetadataReader.Section?
                Task.detached { read = await MetadataReader.read(url) }
                while read == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                let before = read!.rows
                let office = before.filter { $0.key.hasPrefix("Office · ") }
                let name = url.lastPathComponent
                for wanted in ["Office · creator", "Office · lastModifiedBy", "Office · Company"] where !office.contains(where: { $0.key == wanted }) {
                    problems.append("\(name): manca \(wanted)")
                }
                if !before.contains(where: { $0.key.hasPrefix("Origine · ") }) { problems.append("\(name): manca la provenienza") }
                guard let out = try? OfficeMetadata.strip(url).first else { problems.append("\(name): Rimuovi non riuscito"); continue }
                defer { try? FileManager.default.removeItem(at: out) }
                let after = OfficeMetadata.read(out)
                if !after.isEmpty { problems.append("\(out.lastPathComponent): restano \(after.map(\.0).joined(separator: ", "))") }
                if ExtendedAttributes.names(out).contains(where: { $0.hasPrefix("com.apple.metadata:") }) { problems.append("\(out.lastPathComponent): restano attributi Spotlight") }
                let main = ["docx": "word/document.xml", "xlsx": "xl/worksheets/sheet1.xml", "pptx": "ppt/presentation.xml"][url.pathExtension.lowercased()] ?? ""
                let a = try? ArchiveOps.entryData(in: url, entry: main, maxBytes: 10_000_000), b = try? ArchiveOps.entryData(in: out, entry: main, maxBytes: 10_000_000)
                if a == nil || a != b { problems.append("\(out.lastPathComponent): \(main) cambiato") }
                switch url.pathExtension.lowercased() {
                case "docx":
                    let text = try? NSAttributedString(url: out, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
                    if text?.contains("Testo di prova") != true { problems.append("\(out.lastPathComponent): non si apre") }
                case "xlsx":
                    if (try? SheetOps.read(out))?.first?.rows.first?.contains("prova") != true { problems.append("\(out.lastPathComponent): non si apre") }
                default: break
                }
                print("\(name): \(office.count) valori Office prima, \(after.count) dopo")
            }
            if let other = args.first.map({ URL(fileURLWithPath: $0).deletingPathExtension().appendingPathExtension("txt") }) {
                FileManager.default.createFile(atPath: other.path, contents: Data("x".utf8))
                if (try? OfficeMetadata.strip(other)) != nil { problems.append("Rimuovi accetta un TXT") }
                try? FileManager.default.removeItem(at: other)
            }
            problems.forEach { print("problema: \($0)") }
            return problems.isEmpty && !args.isEmpty ? 0 : 1

        case "--test-metadata-search":
            // --test-metadata-search FILE…: the window's search field filters by name or value (case and accents
            // ignored), shows the message when nothing matches, and ⌘F puts the cursor in it.
            guard !args.isEmpty else { return usage() }
            NSApplication.shared.setActivationPolicy(.accessory)
            let model = MetadataModel(more: 0)
            nonisolated(unsafe) var read: [MetadataReader.Section]?
            let files = args.map { URL(fileURLWithPath: $0) }
            Task.detached { var all: [MetadataReader.Section] = []; for url in files { all.append(await MetadataReader.read(url)) }; read = all }
            while read == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            model.sections = read
            var problems: [String] = []
            let groups = read!.map { MetadataView.groups($0.rows) }
            func count(_ gs: [[MetadataView.Group]]) -> Int { gs.reduce(0) { $0 + $1.reduce(0) { $0 + $1.rows.count } } }
            let all = count(groups)
            for query in [L("Dimensione"), L("Dimensione").uppercased(), L("Modificato").lowercased(), "zzqqxx-nessuno"] {
                let shown = groups.map { MetadataView.filter($0, query) }
                let n = count(shown)
                let wrong = shown.flatMap { $0 }.filter { g in !MetadataView.contains(g.name, query) && g.rows.contains { !MetadataView.contains($0.key, query) && !MetadataView.contains($0.value, query) } }
                print("«\(query)»: \(n) di \(all) righe")
                if !wrong.isEmpty { problems.append("«\(query)»: righe che non corrispondono") }
                if query.hasPrefix("zzqq") ? n != 0 : n < files.count { problems.append("«\(query)»: \(n) righe") }
            }
            if count(groups.map { MetadataView.filter($0, "  ") }) != all { problems.append("una ricerca vuota nasconde righe") }
            let host = NSHostingController(rootView: MetadataView(model: model))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(NSSize(width: 520, height: 600))
            window.orderFrontRegardless()
            window.makeKey()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            guard let field = model.searchField else { print("problema: campo di ricerca assente"); return 1 }
            window.makeFirstResponder(nil)
            let press = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
            _ = window.performKeyEquivalent(with: press)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            let focused = (window.firstResponder as? NSText)?.delegate as? NSSearchField === field
            print(focused ? "⌘F: cursore nel campo di ricerca" : "⌘F: il campo non ha il cursore")
            if !focused { problems.append("⌘F non attiva la ricerca") }
            field.currentEditor()?.insertText("zzqqxx")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            if model.query != "zzqqxx" { problems.append("il testo scritto non arriva al filtro («\(model.query)»)") }
            window.close()
            problems.forEach { print("problema: \($0)") }
            return problems.isEmpty ? 0 : 1

        case "--test-wheel-behind":
            // --test-wheel-behind FILE: Settings open behind another app (Finder), then a drag's wheel opens and switches
            // with ⌥ and ⌃. PASS when Rondelle never becomes active, Settings never comes in front of the other apps' windows, and
            // both wheel panels are auxiliary for Stage Manager (without it, switching wheel brought back Rondelle's
            // stage, Settings included even when minimised to the Dock), and an activation during the drag (macOS does
            // it after a few seconds) hands focus back to the app in front.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            SettingsWindow.shared.show(pane: .behaviour)
            func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            wait(1.0)
            guard let settings = app.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return 1 }
            finder.activate()
            wait(1.0)
            /// Windows of other apps on screen above Settings (front to back), and whether Rondelle is active.
            func state() -> (above: Int, active: Bool) {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let me = ProcessInfo.processInfo.processIdentifier
                var above = 0
                for info in list {
                    if (info[kCGWindowNumber as String] as? Int) == settings.windowNumber { break }
                    if (info[kCGWindowOwnerPID as String] as? Int32) != me, (info[kCGWindowLayer as String] as? Int) == 0 { above += 1 }
                }
                return (above, app.isActive)
            }
            let before = state()
            UserDefaults.standard.set(false, forKey: Settings.Key.animate)
            let wheel = WheelController()
            wheel.debugParkAll = true
            var steps = [("prima", before)]
            wheel.show(urls: args.map { URL(fileURLWithPath: $0) }, mode: .convert)
            wait(0.5); steps.append(("ruota aperta", state()))
            let parkedOnOpen = !settings.isVisible
            wheel.setMode(.tools)
            wait(0.5); steps.append(("⌥ Strumenti", state()))
            wheel.setMode(.share)
            wait(0.5); steps.append(("⌃ Condividi", state()))
            // What macOS does a few seconds into the drag: Rondelle becomes active. The wheel must hand focus back.
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
            wait(0.5)
            let gaveBack = wheel.debugGaveBack == 1
            let stillParked = !settings.isVisible
            wheel.hide()
            wait(0.3)
            let parkedAfterDrag = !settings.isVisible
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
            wait(0.3)
            let leftAlone = wheel.debugGaveBack == 1   // closed: an activation is the user's own
            let restored = settings.isVisible && !settings.isMiniaturized
            settings.orderOut(nil)
            print("attivata durante il trascinamento: primo piano restituito \(gaveBack ? "sì → PASS" : "no → FAIL"); a ruota chiusa lasciata \(leftAlone ? "sì → PASS" : "no → FAIL")")
            print("Impostazioni non visibili tolte dallo schermo: all'apertura \(parkedOnOpen ? "sì" : "no"), all'attivazione \(stillParked ? "sì" : "no"), dopo la ruota \(parkedAfterDrag ? "sì" : "no"), di nuovo al ritorno su Rondelle \(restored ? "sì" : "no") → \(parkedOnOpen && stillParked && parkedAfterDrag && restored ? "PASS" : "FAIL")")
            var ok = !before.active && before.above > 0 && gaveBack && leftAlone && parkedOnOpen && stillParked && parkedAfterDrag && restored
            for (name, now) in steps {
                let pass = !now.active && now.above > 0   // other apps open and close windows: only "not in front" is stable
                ok = ok && pass
                print("\(name): finestre sopra le Impostazioni \(now.above), Rondelle attiva \(now.active ? "sì" : "no") → \(pass ? "PASS" : "FAIL")")
            }
            let auxiliary = wheel.debugBehaviors.allSatisfy { $0.contains(.auxiliary) }
            print("ruota fuori da Stage Manager: \(auxiliary ? "sì → PASS" : "no → FAIL")")
            return ok && auxiliary ? 0 : 1

        case "--test-wheel-switch":
            // --test-wheel-switch: with the wheel open, a key press switches wheel and letting keys go does not.
            let none: NSEvent.ModifierFlags = []
            var problems: [String] = []
            func expect(_ from: NSEvent.ModifierFlags, _ to: NSEvent.ModifierFlags, _ want: WheelMode?, _ what: String) {
                let got = Settings.switchMode(from: from, to: to)
                if got != want { problems.append("\(what): \(String(describing: got))") }
            }
            expect(.shift, none, nil, "lascio ⇧")
            expect(none, .option, .tools, "premo ⌥")
            expect(.option, none, nil, "lascio ⌥")
            expect(none, .control, .share, "premo ⌃")
            expect(none, .shift, .convert, "premo ⇧")
            expect(.shift, [.shift, .option], .tools, "aggiungo ⌥ a ⇧")
            expect([.shift, .option], .shift, nil, "lascio ⌥ e tengo ⇧")
            expect(none, .command, nil, "premo ⌘")
            expect(none, [.command, .shift], nil, "⌘⇧ della scorciatoia")
            let labels = [WheelMode.convert, .tools, .share].map { Settings.switchKey(for: $0).flags }
            if labels != [.shift, .option, .control] { problems.append("tasto singolo per ruota: \(labels.map(\.rawValue))") }
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            view.clickURLs = [URL(fileURLWithPath: "/tmp/x")]
            view.heldFlags = [.command, .shift]
            var set: [WheelMode] = []
            view.onSetMode = { set.append($0); view.mode = $0 }
            for flags in [NSEvent.ModifierFlags.shift, [], .option, [], .control, [], .shift] {
                let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
                view.flagsChanged(with: event)
            }
            if set != [.tools, .share, .convert] { problems.append("ruota aperta da tastiera: \(set)") }
            problems.forEach { print("problema: \($0)") }
            print(problems.isEmpty ? "cambio ruota corretto" : "\(problems.count) problemi")
            return problems.isEmpty ? 0 : 1
        case "--test-wheel-keys":
            // --test-wheel-keys FILE: the wheel opened from the Finder's services, used only from the keyboard.
            let urls = args.map { URL(fileURLWithPath: $0) }
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            view.style = .ring
            view.actions = ActionCatalog.actions(for: urls, mode: .tools)
            view.clickURLs = urls
            var picked: [String] = [], switched: [Bool] = [], cancelled = 0
            view.onDrop = { action, _ in picked.append(action.title) }
            view.onScrollMode = { switched.append($0) }
            view.onCancel = { cancelled += 1 }
            func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                view.keyDown(with: event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            let count = view.actions.count
            var problems: [String] = []
            func expect(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
            press(36); expect(picked.isEmpty, "Invio senza scelta")
            press(124); expect(view.debugHighlighted == 0, "→ parte dall'alto")
            press(123); expect(view.debugHighlighted == count - 1, "← torna all'ultima")
            press(124); press(124); expect(view.debugHighlighted == 1, "→ fa il giro")
            press(36)
            let first = view.actions[1]
            if case .group(let members) = first.work { expect(picked.last == members.first?.title, "Invio su un gruppo") }
            else { expect(picked.last == first.title, "Invio") }
            if let g = view.actions.firstIndex(where: { if case .group = $0.work { return true } else { return false } }),
               case .group(let members) = view.actions[g].work, members.count > 1 {
                for _ in 0..<((g - 1 + count) % count) { press(124) }
                expect(view.debugHighlighted == g, "fino al gruppo")
                press(125); press(125); expect(view.debugChild == 1, "↓ nelle varianti")
                press(125); press(125); press(125); expect(view.debugChild == members.count - 1 || members.count > 4, "↓ si ferma all'ultima")
                for _ in 0..<members.count { press(126) }
                expect(view.debugChild == nil, "↑ torna al gruppo")
                press(125); press(125); press(49); expect(picked.last == members[1].title, "Spazio sceglie la variante")
                print("gruppo \(view.actions[g].title): \(members.count) varianti")
            } else {
                problems.append("nessun gruppo con varianti")
            }
            press(48); press(48, .shift); expect(switched == [true, false], "Tab e ⇧Tab")
            press(53); expect(cancelled == 1, "Esc")
            print("\(count) voci, scelte: \(picked.joined(separator: ", "))")
            problems.forEach { print("problema: \($0)") }
            print(problems.isEmpty ? "tastiera corretta" : "\(problems.count) problemi")
            return problems.isEmpty ? 0 : 1

        case "--test-wheel-frame":
            // --test-wheel-frame FILE…: how long one frame of the wheel takes to draw, the pointer going round it.
            let urls = args.map { URL(fileURLWithPath: $0) }
            let actions = ActionCatalog.actions(for: urls, mode: mode)
            let side = WheelController.size(for: actions.count)
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            view.fileCount = urls.count
            view.actions = actions
            view.blank = ProcessInfo.processInfo.environment["RONDELLE_BLANK"] != nil   // only the shapes, no text
            guard !actions.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            var times: [Double] = []
            for frame in 0..<240 {
                view.previewHighlight = frame % 3 == 0 ? nil : (frame / 3) % actions.count
                let start = DispatchTime.now().uptimeNanoseconds
                view.cacheDisplay(in: view.bounds, to: rep)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            let sorted = times.dropFirst(10).sorted()
            print(String(format: "fotogramma %d×%d px: media %.2f ms, 95%% %.2f ms, max %.2f ms", rep.pixelsWide, rep.pixelsHigh,
                         sorted.reduce(0, +) / Double(sorted.count), sorted[sorted.count * 95 / 100], sorted.last ?? 0))
            return 0

        case "--test-feedback":
            // --test-feedback MESSAGE EMAIL: what the form's window would let you send (T3).
            guard args.count == 2 else { return usage() }
            print("messaggio \(Feedback.fits(args[0]) ? "si" : "no") email \(Feedback.isValidEmail(args[1]) ? "si" : "no")")
            return 0

        case "--test-version":
            // --test-version TAG CURRENT: whether TAG is newer than CURRENT (U1).
            guard args.count == 2 else { return usage() }
            print(Updates.isNewer(args[0], than: args[1]) ? "si" : "no")
            return 0

        case "--test-wheel-motion":
            // --test-wheel-motion FILE: the real panel opens, then a piece is chosen; the motion must run and then stop.
            UserDefaults.standard.set(true, forKey: Settings.Key.animate)
            let wheel = WheelController()
            wheel.show(urls: args.map { URL(fileURLWithPath: $0) }, mode: mode)
            func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            wait(0.7)
            if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
                // No frames come with the screen asleep: the opening must still end, so the wheel isn't left empty.
                print("schermo spento: apertura \(wheel.view.debugOpening ? "rimasta a metà" : "conclusa senza fotogrammi")")
                wheel.hide()
                return wheel.view.debugOpening ? 1 : 0
            }
            let opening = wheel.view.debugFrames, stillOpening = wheel.view.debugMoving
            wheel.view.previewHighlight = 1
            wait(0.08)
            let halfway = wheel.view.debugLift
            wait(0.5)
            let out = wheel.view.debugLift
            wheel.setMode(mode == .convert ? .tools : .convert)
            wait(0.5)
            print("apertura: \(opening) fotogrammi, ferma dopo: \(stillOpening ? "no" : "sì")")
            print(String(format: "spicchio: %.2f dopo 80 ms, %.2f alla fine", halfway, out))
            print("cambio ruota: \(wheel.view.debugFrames - opening) fotogrammi, fermo dopo: \(wheel.view.debugMoving ? "no" : "sì")")
            wheel.hide()
            return !stillOpening && opening > 15 && halfway > 0.3 && halfway < 0.99 && out == 1 && !wheel.view.debugMoving ? 0 : 1

        case "--test-settings-window":
            // --test-settings-window: the real window asked to be huge and tiny, and what it really became.
            _ = NSApplication.shared
            SettingsWindow.shared.show()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            guard let window = NSApp.windows.first(where: { $0.title == L("Impostazioni di Rondelle") }) else { return 1 }
            print("ridimensionabile \(window.styleMask.contains(.resizable)), a tutto schermo \(!window.collectionBehavior.contains(.fullScreenNone)), verde \(window.standardWindowButton(.zoomButton)?.isEnabled ?? false)")
            print("iniziale \(Int(window.contentLayoutRect.width))×\(Int(window.contentLayoutRect.height))")
            for (name, size) in [("molto grande", NSSize(width: 3_000, height: 3_000)), ("molto piccola", NSSize(width: 100, height: 100)), ("media", NSSize(width: 1_050, height: 700))] {
                // As a drag does: the window's limits apply to what is asked of it, then the content answers.
                let content = NSSize(width: min(max(size.width, window.contentMinSize.width), window.contentMaxSize.width),
                                     height: min(max(size.height, window.contentMinSize.height), window.contentMaxSize.height))
                window.setContentSize(content)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                print("\(name): chiesto \(Int(size.width))×\(Int(size.height)), finestra \(Int(window.contentView?.frame.width ?? 0))×\(Int(window.contentView?.frame.height ?? 0))")
            }
            return 0

        case "--test-sha256":
            // --test-sha256 FILE…: the text «SHA-256» puts on the clipboard (the clipboard itself isn't touched here).
            do {
                print(try Checksum.text(args.map { URL(fileURLWithPath: $0) }))
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        case "--test-paths":
            // --test-paths FILE…: the text «Copia percorso» puts on the clipboard (the clipboard itself isn't touched here).
            print(ShareOps.pathsText(args.map { URL(fileURLWithPath: $0) }))
            return 0

        case "--file-card":
            // --file-card FILE…: the line under the wheel for these files.
            nonisolated(unsafe) var text: String?
            nonisolated(unsafe) var done = false
            let urls = args.map { URL(fileURLWithPath: $0) }
            Task.detached {
                text = await FileHints.card(for: urls)
                await MainActor.run { done = true }
            }
            while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
            print(text ?? "")
            return 0

        case "--test-parallel":
            // --test-parallel [--tools] ACTION CANCEL_AFTER FILE…: one job per file through the real runner, as if dropped
            // one after the other; with CANCEL_AFTER > 0, «Annulla tutti» then. Prints how many ran together and what's left.
            guard args.count >= 3, let delay = Double(args[1]) else { return usage() }
            let urls = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
            guard let action = ActionCatalog.actions(for: [urls[0]], mode: mode).flatMap(\.flattened).first(where: { $0.matches(args[0]) }) else { return usage() }
            _ = NSApplication.shared
            let start = Date()
            for url in urls { JobRunner.run(action, urls: [url]) }
            if delay > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: delay)); JobCenter.cancelAll() }
            while !JobCenter.jobs.isEmpty { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
            print(String(format: "insieme %d su %d, %.1f s, in coda rimasti 0", JobCenter.mostRunning, JobCenter.maxRunning, Date().timeIntervalSince(start)))
            return 0

        case "--test-merge-open":
            // --test-merge-open FILE: what the Merge window does on opening a PDF: the check, then the first thumbnail.
            guard args.count == 1 else { return usage() }
            let url = URL(fileURLWithPath: args[0])
            nonisolated(unsafe) var warning: String?
            nonisolated(unsafe) var drawn = false
            nonisolated(unsafe) var done = false
            Task.detached {
                let store = PDFStore()
                let opened = await store.open([url], maxPages: 1)
                warning = opened.pages.isEmpty ? opened.warning : nil
                if let first = opened.pages.first { drawn = await store.thumbnail(first.0, page: first.1) != nil }
                await MainActor.run { done = true }
            }
            while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            if let warning { fputs("\(warning)\n", stderr); return 1 }
            print(drawn ? "miniatura disegnata" : "nessuna miniatura")
            return 0

        case "--assemble":
            // --assemble OUT.pdf FILE[#PAGE[@ROTATION]]…: what the Merge window saves (pages start at 1).
            guard args.count >= 2 else { return usage() }
            let refs: [PDFOps.PageRef] = args.dropFirst().map { spec in
                let parts = spec.split(separator: "#", maxSplits: 1).map(String.init)
                let pageAndRotation = parts.count > 1 ? parts[1].split(separator: "@").map(String.init) : []
                return PDFOps.PageRef(url: URL(fileURLWithPath: parts[0]),
                                      page: pageAndRotation.first.flatMap { Int($0) }.map { $0 - 1 },
                                      rotation: pageAndRotation.count > 1 ? Int(pageAndRotation[1]) ?? 0 : 0)
            }
            do {
                try PDFOps.assemble(refs, to: URL(fileURLWithPath: args[0]))
                print(args[0])
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }

        default:
            return usage()
        }
    }

    /// Lays out a SwiftUI view in an off-screen window, lets async work run for `wait` seconds, saves a PNG.
    /// RONDELLE_ADJUST="exposure=40,saturation=-20" → adjustments for the editor hooks.
    private static func testAdjustments() -> PhotoEditor.Adjustments {
        var adjustments = PhotoEditor.Adjustments()
        for pair in (ProcessInfo.processInfo.environment["RONDELLE_ADJUST"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let key = PhotoEditor.Adjustments.Key(rawValue: String(parts[0])), let value = Double(parts[1]) {
                adjustments[key] = value
            }
        }
        return adjustments
    }

    private static func snapshot<V: View>(_ view: V, size: NSSize, to path: String, wait: TimeInterval) -> Int32 {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return 0
    }

    /// An alert as macOS draws it (window server capture), for a look at its layout.
    private static func snapshot(_ alert: NSAlert, to path: String, before: (() -> Void)? = nil) -> Int32 {
        NSApp.setActivationPolicy(.regular)
        nonisolated(unsafe) var status: Int32 = 1
        let shot = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l\(alert.window.windowNumber)", path]
                try? capture.run()
                capture.waitUntilExit()
                if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: path) {
                    status = 0
                } else if let frame = alert.window.contentView?.superview,
                          let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    // The window's own background (glass) isn't in this drawing: put a dark one behind its white text.
                    let image = NSImage(size: frame.bounds.size, flipped: false) { rect in
                        NSColor(white: 0.18, alpha: 1).setFill()
                        rect.fill()
                        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        return true
                    }
                    try? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    status = 0
                }
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(shot, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
        return status
    }

    private static func execute(_ action: WheelAction, _ urls: [URL]) -> Int32 {
        do {   // as JobRunner.run
            try SafeFile.refuseSpecial(urls)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
        if case .window = action.work {
            fputs("«\(action.title)» apre una finestra: usala dall'app.\n", stderr)
            return 1
        }
        if case .share = action.work {
            fputs("«\(action.title)» condivide: usala dall'app (prova la preparazione con --test-share-prepare).\n", stderr)
            return 1
        }
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var status: Int32 = 0
        Task.detached { await Prompts.$allowed.withValue(false) {   // no dialogs on the command line: "no"
            var work = action.work
            if case .asking(_, let defaultValue, _, let ask) = work {
                let answer = ProcessInfo.processInfo.environment["RONDELLE_VALUE"] ?? defaultValue
                work = .perFile { try await ask($0, answer) }
            }
            if case .askingAll(_, _, let ask) = work {
                let answer = ProcessInfo.processInfo.environment["RONDELLE_VALUE"] ?? ""
                work = .batch { try await ask($0, answer) }
            }
            switch work {
            case .asking, .askingAll, .window, .share, .group:
                break
            case .perFile(let work):
                for url in urls {
                    do { try await FileNaming.cleaningUpOnFailure { try await work(url) }.forEach { print($0.path) } }
                    catch { fputs("\(url.lastPathComponent): \(error.localizedDescription)\n", stderr); status = 1 }
                }
            case .batch(let work):
                do { try await FileNaming.cleaningUpOnFailure { try await work(urls) }.forEach { print($0.path) } }
                catch { fputs("\(error.localizedDescription)\n", stderr); status = 1 }
            }
            await MainActor.run { finished = true }
        } }
        // Keep the main run loop turning: document conversion hops to the main thread.
        while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return status
    }

    private static func usage() -> Int32 {
        fputs("Uso: Rondelle --list|--run TITOLO|--render OUT.png [--tools] FILE…\n", stderr)
        return 2
    }
}
#endif
