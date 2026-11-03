import AppKit
import SwiftUI

/// Keeps the open tool windows (Layout, Merge) alive until they are closed.
@MainActor
enum ToolWindows {
    private static var open: [NSWindow] = []

    /// `title` names the window (Window menu, Mission Control); the header shows `tool`, `symbol` and `detail`.
    static func show<Content: View>(_ title: String, tool: String, symbol: String, detail: String, size: NSSize, _ content: Content) {
        let size = NSSize(width: size.width, height: size.height + headerHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.rondelleStyle()
        window.contentViewController = NSHostingController(rootView: VStack(spacing: 0) {
            RondelleHeader(symbol: symbol, title: tool, subtitle: detail)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            content
        })
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// What the header adds to a window's height.
    static let headerHeight: CGFloat = 62

    static func close(containing view: NSView?) {
        view?.window?.close()
    }
}

// MARK: Model

@MainActor
final class LayoutModel: ObservableObject {
    let sources: [URL]
    @Published private(set) var photos: [LayoutPhoto] = []
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published var templateID = "" { didSet { refresh() } }
    @Published var aspect = LayoutAspect.square { didSet { refresh() } }
    @Published var spacing = 0.012 { didSet { refresh() } }
    @Published var corner = 0.0 { didSet { refresh() } }
    @Published var background = Color.white { didSet { refresh() } }
    /// First photo picked for a swap.
    @Published var selected: Int?
    @Published private(set) var preview: NSImage?
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private(set) var templates: [LayoutTemplate] = []
    var template: LayoutTemplate? { templates.first { $0.id == templateID } }

    init(urls: [URL]) {
        sources = Array(FileNaming.sortedNaturally(urls).prefix(LayoutRenderer.maxPhotos))
        templates = LayoutRenderer.templates(for: sources.count)
        templateID = templates.first?.id ?? ""
    }

    func load() async {
        let urls = sources
        do {
            // Loading and face/subject detection are slow: off the main thread.
            photos = try await Task.detached(priority: .userInitiated) {
                try urls.map { try LayoutRenderer.loadPhoto($0) }
            }.value
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        refresh()
    }

    private var cgBackground: CGColor { NSColor(background).usingColorSpace(.sRGB)?.cgColor ?? .white }

    func refresh() {
        guard !photos.isEmpty, let template else { return }
        if let image = LayoutRenderer.render(photos, template: template, aspect: aspect, spacing: spacing,
                                             corner: corner, background: cgBackground, longSide: 900) {
            preview = NSImage(cgImage: image, size: .zero)
        }
        var thumbs: [String: NSImage] = [:]
        for t in templates {
            if let image = LayoutRenderer.render(photos, template: t, aspect: aspect, spacing: 0.02, corner: 0,
                                                 background: cgBackground, longSide: 120) {
                thumbs[t.id] = NSImage(cgImage: image, size: .zero)
            }
        }
        thumbnails = thumbs
    }

    /// Click on the preview: the first click picks a photo, the second swaps the two.
    func tap(atNormalized point: CGPoint) {
        guard let template, let index = template.cells.firstIndex(where: { $0.contains(point) }),
              index < photos.count else { return }
        if let first = selected {
            if first != index { photos.swapAt(first, index) }
            selected = nil
            refresh()
        } else {
            selected = index
        }
    }

    func shuffle() {
        photos.shuffle()
        selected = nil
        refresh()
    }

    func save() throws -> URL {
        guard let template,
              let image = LayoutRenderer.render(photos, template: template, aspect: aspect, spacing: spacing,
                                                corner: corner, background: cgBackground, longSide: 2160) else {
            throw OpError.failed(L("creazione del layout"))
        }
        let out = FileNaming.unique(FileNaming.directory(for: sources[0]).appendingPathComponent("Layout.jpg"))
        try ImageOps.write(image, to: out, type: .jpeg, quality: Settings.imageQuality)
        return out
    }
}

// MARK: View

struct LayoutView: View {
    @StateObject var model: LayoutModel
    @State private var hostView: NSView?

    private let backgrounds: [(String, Color)] = [(L("Bianco"), .white), (L("Nero"), .black),
                                                  (L("Crema"), Color(red: 1, green: 0.97, blue: 0.9))]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                previewArea
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                controls
                    .padding(14)
                    .frame(width: 270)
                    .rondellePanel()
            }
            .padding(16)
            Divider()
            templateStrip
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(WindowFinder(view: $hostView))
        .task { await model.load() }
    }

    @ViewBuilder private var previewArea: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if model.loading {
                    ProgressView(L("Analisi delle foto…"))
                } else if let error = model.error {
                    Text(error).foregroundStyle(.red).padding()
                } else if let preview = model.preview {
                    let fitted = fittedSize(preview.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: preview).resizable().frame(width: fitted.width, height: fitted.height)
                        if let i = model.selected, let cell = model.template?.cells[i] {
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 4)
                                .frame(width: cell.width * fitted.width, height: cell.height * fitted.height)
                                .offset(x: cell.minX * fitted.width, y: cell.minY * fitted.height)
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .shadow(radius: 6)
                    .onTapGesture(coordinateSpace: .local) { location in
                        model.tap(atNormalized: CGPoint(x: location.x / fitted.width, y: location.y / fitted.height))
                    }
                }
            }
        }
    }

    private var controls: some View {
        Form {
            Picker(L("Formato"), selection: $model.aspect) {
                ForEach(LayoutAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Slider(value: $model.spacing, in: 0...0.05) { Text(L("Bordi")) }
            Slider(value: $model.corner, in: 0...0.06) { Text(L("Angoli")) }
            LabeledContent(L("Colore bordi")) {
                HStack(spacing: 6) {
                    ForEach(backgrounds, id: \.0) { name, color in
                        Circle().fill(color).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                            .help(name)
                            .onTapGesture { model.background = color }
                    }
                    ColorPicker("", selection: $model.background, supportsOpacity: false).labelsHidden()
                }
            }
            Text(model.selected == nil
                 ? L("Clicca una foto e poi un'altra per scambiarle.")
                 : L("Ora clicca la foto con cui scambiarla."))
                .font(.caption).foregroundStyle(.secondary)
            Button { model.shuffle() } label: { Label(L("Mescola le foto"), systemImage: "shuffle") }
                .rondelleButton()
            Spacer(minLength: 12)
            HStack {
                Button(L("Annulla")) { ToolWindows.close(containing: hostView) }
                    .rondelleButton()
                Spacer()
                Button(L("Salva")) { save() }
                    .rondelleProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.preview == nil)
            }
        }
        .formStyle(.columns)
    }

    private var templateStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(model.templates) { t in
                    Group {
                        if let thumb = model.thumbnails[t.id] {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                        }
                    }
                    .frame(height: 84)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(t.id == model.templateID ? Color.accentColor : Color.clear, lineWidth: 3))
                    .onTapGesture { model.templateID = t.id }
                }
            }
            .padding(12)
        }
        .frame(height: 116)
    }

    private func save() {
        do {
            let out = try model.save()
            JobHistory.record("Layout", outputs: [out])
            Settings.reveal([out])
            if Settings.playSound { NSSound(named: "Glass")?.play() }
            CompletionAnimation.play()
            ToolWindows.close(containing: hostView)
        } catch {
            Notice.show(title: L("Layout non salvato"), text: error.localizedDescription)
        }
    }

    private func fittedSize(_ size: NSSize, in box: CGSize) -> CGSize {
        let scale = min((box.width - 24) / size.width, (box.height - 24) / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Gives SwiftUI a handle on its NSView, so buttons can close the window.
struct WindowFinder: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
enum LayoutWindow {
    static func open(_ urls: [URL]) {
        let images = urls.filter { FileKind($0) == .image }
        guard images.count >= 2 else { return }
        let note = images.count > LayoutRenderer.maxPhotos ? L(" (prime %@)", LayoutRenderer.maxPhotos) : ""
        ToolWindows.show(L("Layout — %@ foto", min(images.count, LayoutRenderer.maxPhotos)) + note,
                         tool: L("Layout"), symbol: "rectangle.split.2x2",
                         detail: L("%@ foto", min(images.count, LayoutRenderer.maxPhotos)) + note,
                         size: NSSize(width: 900, height: 680), LayoutView(model: LayoutModel(urls: images)))
    }
}
