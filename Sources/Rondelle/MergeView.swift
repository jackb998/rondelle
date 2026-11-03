import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// All PDFKit work of the Merge window, off the main thread and one call at a time
/// (PDFDocument is not safe to use from several threads at once).
final class PDFStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Rondelle.PDFStore")
    private var documents: [URL: PDFDocument] = [:]

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }

    /// Opens the PDFs; returns (url, page index) for every page — nil index for an image — and a warning.
    func open(_ urls: [URL], maxPages: Int) async -> (pages: [(URL, Int?)], warning: String?) {
        await onQueue {
            var pages: [(URL, Int?)] = []
            var warning: String?
            for url in urls {
                guard FileKind(url) == .pdf else { pages.append((url, nil)); continue }
                // Before any thumbnail is drawn: neither those nor saving can be stopped halfway.
                do { try PDFTextScan.checkForRewriting(url) } catch { warning = error.localizedDescription; continue }
                guard let doc = PDFDocument(url: url) else { warning = L("Impossibile leggere «%@»", url.lastPathComponent); continue }
                if doc.isLocked { warning = L("«%@» è protetto da password", url.lastPathComponent); continue }
                self.documents[url] = doc
                for i in 0..<doc.pageCount where pages.count < maxPages { pages.append((url, i)) }
            }
            if pages.count >= maxPages { warning = L("Mostrate le prime %@ pagine", maxPages) }
            return (pages, warning)
        }
    }

    func thumbnail(_ url: URL, page index: Int?) async -> NSImage? {
        guard let index else {
            return (try? LayoutRenderer.loadPhoto(url, maxPixel: 300)).map { NSImage(cgImage: $0.image, size: .zero) }
        }
        return await onQueue {
            self.documents[url]?.page(at: index)?.thumbnail(of: NSSize(width: 220, height: 220), for: .cropBox)
        }
    }
}

/// Merge several PDFs (and images) or reorganise one PDF: reorder, rotate and delete pages, then save.
@MainActor
final class MergeModel: ObservableObject {
    struct Page: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// nil for an image, which becomes one page.
        let index: Int?
        var rotation = 0

        var label: String {
            let name = url.deletingPathExtension().lastPathComponent
            return index.map { L("%@ · p. %@", name, $0 + 1) } ?? name
        }
    }

    static let maxPages = 2000

    let sources: [URL]
    @Published var pages: [Page] = []
    @Published var name: String
    @Published var dragging: Page?
    @Published private(set) var warning: String?
    @Published private(set) var loading = true
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    private let store = PDFStore()
    private var requested = Set<UUID>()

    init(urls: [URL]) {
        sources = FileNaming.sortedNaturally(urls)
        // Named after the first PDF (not a photo that sorts earlier).
        let named = sources.first { FileKind($0) == .pdf } ?? sources.first
        let first = named?.deletingPathExtension().lastPathComponent ?? L("Documento")
        name = sources.count == 1 ? L("%@ (riorganizzato)", first) : L("%@ (unito)", first)
    }

    /// B3: the PDFs are opened in the background; the window shows a spinner meanwhile.
    func load() async {
        let (found, warning) = await store.open(sources, maxPages: Self.maxPages)
        pages = found.map { Page(url: $0.0, index: $0.1) }
        self.warning = warning
        loading = false
    }

    /// Asks for a page's thumbnail; it's drawn in the background and shows up when ready.
    func requestThumbnail(_ page: Page) {
        guard requested.insert(page.id).inserted else { return }
        Task {
            let image = await store.thumbnail(page.url, page: page.index)
            thumbnails[page.id] = image
        }
    }

    func rotate(_ page: Page) {
        guard let i = pages.firstIndex(of: page) else { return }
        pages[i].rotation = (pages[i].rotation + 90) % 360
    }

    func remove(_ page: Page) { pages.removeAll { $0 == page } }
    func reverse() { pages.reverse() }

    /// Moves `dragging` to where `target` is (live, while dragging).
    func move(onto target: Page) {
        guard let dragging, dragging != target,
              let from = pages.firstIndex(of: dragging), let to = pages.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func save() throws -> URL {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.isEmpty || base.hasPrefix(".") { base = L("Documento") + base }
        if base.lowercased().hasSuffix(".pdf") { base = String(base.dropLast(4)) }
        let out = FileNaming.unique(FileNaming.directory(for: sources[0]).appendingPathComponent(base + ".pdf"))
        try PDFOps.assemble(pages.map { PDFOps.PageRef(url: $0.url, page: $0.index, rotation: $0.rotation) }, to: out)
        return out
    }
}

struct MergeView: View {
    @StateObject var model: MergeModel
    @State private var hostView: NSView?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("Nome del file"), text: $model.name).textFieldStyle(.roundedBorder).frame(width: 280)
                Text(".pdf").foregroundStyle(.secondary)
                Spacer()
                Button { model.reverse() } label: { Label(L("Inverti ordine"), systemImage: "arrow.up.arrow.down") }
                    .rondelleButton()
                Text(L("%@ pagine", model.pages.count)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(12)
            if let warning = model.warning {
                Text(warning).font(.caption).foregroundStyle(.orange).padding(.bottom, 6)
            }
            Divider()
            if model.loading {
                ProgressView(L("Lettura delle pagine…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 16) {
                    ForEach(model.pages) { page in
                        PageCell(model: model, page: page)
                            .opacity(model.dragging == page ? 0.4 : 1)
                            .onDrag {
                                model.dragging = page
                                return NSItemProvider(object: page.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDelegate(model: model, target: page))
                    }
                }
                .padding(16)
            }
            }
            Divider()
            HStack {
                Text(L("Trascina le pagine per riordinarle.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Annulla")) { ToolWindows.close(containing: hostView) }
                    .rondelleButton()
                Button(model.sources.count == 1 ? L("Salva PDF") : L("Unisci")) { save() }
                    .rondelleProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pages.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(WindowFinder(view: $hostView))
        .task { await model.load() }
    }

    private func save() {
        do {
            let out = try model.save()
            JobHistory.record(model.sources.count == 1 ? L("Organizza") : L("Unisci"), outputs: [out])
            Settings.reveal([out])
            if Settings.playSound { NSSound(named: "Glass")?.play() }
            CompletionAnimation.play()
            ToolWindows.close(containing: hostView)
        } catch {
            Notice.show(title: L("PDF non salvato"), text: error.localizedDescription)
        }
    }
}

private struct PageCell: View {
    @ObservedObject var model: MergeModel
    let page: MergeModel.Page

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = model.thumbnails[page.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .task { model.requestThumbnail(page) }
            .rotationEffect(.degrees(Double(page.rotation)))
            .frame(width: 120, height: 140)
            .background(Color.white.opacity(0.0001))
            .shadow(radius: 2)

            Text(page.label).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 130)
            HStack(spacing: 14) {
                Button { model.rotate(page) } label: { Image(systemName: "rotate.right") }.help(L("Ruota di 90°"))
                Button { model.remove(page) } label: { Image(systemName: "trash") }.help(L("Elimina pagina"))
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct ReorderDelegate: DropDelegate {
    let model: MergeModel
    let target: MergeModel.Page

    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { model.move(onto: target) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.dragging = nil }
        return true
    }
}

@MainActor
enum MergeWindow {
    static func open(_ urls: [URL]) {
        let files = urls.filter { [.pdf, .image].contains(FileKind($0)) }
        guard !files.isEmpty else { return }
        let title = files.count == 1 ? L("Organizza — %@", files[0].lastPathComponent) : L("Unisci — %@ file", files.count)
        ToolWindows.show(title, tool: files.count == 1 ? L("Organizza") : L("Unisci"), symbol: "doc.on.doc",
                         detail: files.count == 1 ? files[0].lastPathComponent : L("%@ file", files.count),
                         size: NSSize(width: 820, height: 640), MergeView(model: MergeModel(urls: files)))
    }
}
