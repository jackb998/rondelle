import AVFoundation
import Foundation

enum WheelMode {
    /// Shift: output formats.
    case convert
    /// Option + Shift: tools for that kind of file.
    case tools
    /// Control + Shift: send the files to an app, a contact or the clipboard (ShareOps).
    case share
}

struct WheelAction {
    enum Work {
        /// Runs once per dropped file.
        case perFile(@Sendable (URL) async throws -> [URL])
        /// Runs once with all dropped files (merge, images → PDF, zip).
        case batch(@Sendable ([URL]) async throws -> [URL])
        /// Asks one question (e.g. a target size) before the job, then runs per file with the answer.
        case asking(question: String, defaultValue: String, answer: Answer = .text, @Sendable (URL, String) async throws -> [URL])
        /// Asks one question, then runs once with all the files (a password-protected ZIP of several files).
        case askingAll(question: String, answer: Answer, @Sendable ([URL], String) async throws -> [URL])
        /// Opens a window where the user finishes the job (Layout, Merge).
        case window(@MainActor ([URL]) -> Void)
        /// Hands the files to another app (share wheel): nothing is written next to the originals.
        case share(@MainActor ([URL]) -> Void)
        /// Several similar actions under one entry (WheelGroups): a second ring and/or an options panel.
        case group([WheelAction])
    }

    /// What kind of answer a question wants: passwords are typed in a hidden field.
    enum Answer {
        case text
        /// An existing password, typed once.
        case password
        /// A new password, typed twice so that a typo can't lock the file for good.
        case newPassword
    }

    /// Shown on the wheel, in the user's language.
    let title: String
    /// The Italian title: the key for the translations and for Shortcuts/CLI names.
    let key: String
    /// SF Symbol; nil draws the title large (format names on the convert wheel).
    let symbol: String?
    let work: Work
    /// Stable key for Settings → Ruota (a title can change, e.g. "Unisci" / "Organizza").
    private(set) var id: String
    /// Reads the hint a protected file carries: shown in the question that asks its password.
    private(set) var hintReader: (@Sendable (URL) -> String?)?

    init(title: String, symbol: String?, work: Work, id: String? = nil) {
        self.title = L(title)
        self.key = title
        self.symbol = symbol
        self.work = work
        self.id = id ?? title
    }

    /// A name typed in Shortcuts or the CLI: the Italian title, the id or a title in any language.
    func matches(_ name: String) -> Bool {
        name == id || name == title || Loc.everyTranslation(of: key).contains(name)
    }

    /// The actions themselves: a group's members, or the action alone.
    var flattened: [WheelAction] {
        if case .group(let members) = work { return members }
        return [self]
    }

    /// Tools whose point is a smaller file: their result shows how much was saved.
    static func makesSmaller(_ key: String) -> Bool {
        ["Comprimi", "Comprimi +", "Peso…", "1080p", "720p", "HEVC", "50%", "Misura…", "Metadati"].contains(key) || key.hasSuffix("px")
    }

    func withID(_ id: String) -> WheelAction {
        var copy = self
        copy.id = id
        return copy
    }

    func readingHint(_ reader: @escaping @Sendable (URL) -> String?) -> WheelAction {
        var copy = self
        copy.hintReader = reader
        return copy
    }

    static func each(_ title: String, _ symbol: String? = nil,
                     _ run: @escaping @Sendable (URL) async throws -> [URL]) -> WheelAction {
        WheelAction(title: title, symbol: symbol, work: .perFile(run))
    }

    static func all(_ title: String, _ symbol: String? = nil,
                    _ run: @escaping @Sendable ([URL]) async throws -> [URL]) -> WheelAction {
        WheelAction(title: title, symbol: symbol, work: .batch(run))
    }

    static func window(_ title: String, _ symbol: String, _ open: @escaping @MainActor ([URL]) -> Void) -> WheelAction {
        WheelAction(title: title, symbol: symbol, work: .window(open))
    }

    /// «Metadati»: «Rimuovi» writes a copy without them (id "Metadati", as before), «Leggi» only shows them.
    static func metadata(_ strip: @escaping @Sendable (URL) async throws -> [URL]) -> WheelAction {
        WheelAction(title: "Metadati", symbol: "info.circle", work: .group([
            WheelAction.each("Rimuovi", "eye.slash", strip).withID("Metadati"),
            .window("Leggi", "doc.text.magnifyingglass") { MetadataWindow.open($0) },
        ]), id: "group.metadati")
    }

    /// «Metadati» where the file has nothing inside to remove (or Rondelle can't remove it): only the window.
    static let readMetadata = WheelAction.window("Metadati", "info.circle") { MetadataWindow.open($0) }.withID("Leggi")

    /// The «Metadati» entry for documents, spreadsheets and any other file: the group where «Rimuovi» can work
    /// (DOCX, XLSX, PPTX), the window alone elsewhere.
    static func metadata(for urls: [URL]) -> WheelAction {
        OfficeMetadata.canStrip(urls) ? .metadata { try OfficeMetadata.strip($0) } : readMetadata
    }

    /// "Dimensione…": asks for a size in MB, then calls `fit` with the byte count.
    static func targetSize(_ fit: @escaping @Sendable (URL, Int) async throws -> [URL]) -> WheelAction {
        WheelAction(title: "Peso…", symbol: "scalemass", work: .asking(
            question: L("Dimensione massima del file (MB):"), defaultValue: Settings.targetMB
        ) { url, answer in
            guard let bytes = parseMegabytes(answer) else { throw OpError.failed(L("«%@» non è una dimensione valida", answer)) }
            return try await fit(url, bytes)
        })
    }

    static func asking(_ title: String, _ symbol: String, question: String, defaultValue: String = "", answer: Answer = .text,
                       _ run: @escaping @Sendable (URL, String) async throws -> [URL]) -> WheelAction {
        WheelAction(title: title, symbol: symbol, work: .asking(question: question, defaultValue: defaultValue, answer: answer, run))
    }

    /// "ZIP protetto": one AES-256 archive of every dropped file, with a password typed twice.
    static let protectedZipQuestion = L("Password per lo ZIP protetto (consigliati almeno %@ caratteri):", ArchiveOps.recommendedPasswordLength)
        + "\n" + L("Si apre con Keka, The Unarchiver o 7-Zip (anche su Windows), non con il Finder né con Utility Archivio: dillo a chi lo riceve.")

    static let protectedZip = WheelAction(title: "ZIP protetto", symbol: "lock.doc", work: .askingAll(
        question: protectedZipQuestion,
        answer: .newPassword
    ) { urls, typed in
        // AES-256 is only as strong as the password: a short one gets a second thought (0.8.2, choice d); under 8
        // characters it is allowed (0.8.8) but the warning says plainly that the ZIP is barely protected, and why,
        // and offers to type another one (0.8.9).
        var (password, hint, inName) = try PasswordHint.parse(typed)
        while !password.isEmpty, password.count < ArchiveOps.weakPasswordLength {
            let warning = weakZipWarning(length: password.count)
            switch Notice.warn(title: warning.title, text: warning.text, details: warning.details,
                               proceed: warning.button, change: warning.change) {
            case .proceed: break
            case .change:
                guard let other = Notice.askPasswordFromJob(protectedZipQuestion, twice: true, withHint: true) else { throw CancellationError() }
                (password, hint, inName) = try PasswordHint.parse(other)
                continue
            case .cancel: throw CancellationError()
            }
            break
        }
        guard !password.isEmpty else { throw OpError.failed(L("la password non può essere vuota")) }
        if password.count >= ArchiveOps.weakPasswordLength, password.count < ArchiveOps.recommendedPasswordLength,
           !Notice.confirm(title: L("Password corta: con la protezione AES-256 la sicurezza dipende dalla password. Continuare?"),
                           text: L("Consigliati almeno %@ caratteri, meglio una frase.", ArchiveOps.recommendedPasswordLength),
                           button: L("Continua")) {
            throw CancellationError()
        }
        return try ArchiveOps.protectedZip(urls, password: password, hint: hint, hintInName: inName)
    })
}

/// The words of the warning for a protected ZIP with a password under 8 characters (also used by its snapshot).
func weakZipWarning(length: Int) -> (title: String, text: String, details: String, button: String, change: String) {
    (L("ZIP poco protetto"),
     L("Con una password di %@ caratteri lo ZIP si apre senza troppa fatica. Usarla lo stesso?", length),
     L("La cifratura (AES-256) è robusta, ma la chiave viene ricavata dalla password. Chi ha il file può provare password a ripetizione sul proprio computer, senza limiti di tentativi e senza che tu lo sappia (attacco a forza bruta o a dizionario). Sotto gli 8 caratteri le combinazioni sono poche: una scheda grafica le prova tutte in ore o minuti, e parole comuni o date in pochi secondi. Una frase di 4–5 parole, o almeno 12 caratteri misti, rende l'attacco impraticabile."),
     L("Usa questa password"),
     L("Modifica password"))
}

enum ActionCatalog {
    static func kind(of urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(FileKind.init))
        return kinds.count == 1 ? kinds.first! : .other
    }

    static func actions(for urls: [URL], mode: WheelMode) -> [WheelAction] {
        var all = allActions(for: urls, mode: mode)
        if mode == .convert { all = withoutSourceFormat(all, urls) }
        all = WheelGroups.apply(all, mode: mode)
        // Settings → Ruota: hidden actions and custom order (PDFs mixed with images aren't configurable).
        if Set(urls.map(FileKind.init)) != [.pdf, .image] {
            all = WheelConfig.apply(all, kind: kind(of: urls), mode: mode)
        }
        return all
    }

    /// Every action a wheel can show for `kind`, before customisation (for Settings → Ruota).
    static func allActions(for kind: FileKind, mode: WheelMode) -> [WheelAction] {
        let samples: [String]
        switch kind {
        case .image: samples = ["a.jpg", "b.jpg"]      // two, so that "Layout" is listed too
        case .pdf: samples = ["a.pdf", "b.pdf"]
        case .video: samples = ["a.mov"]
        case .audio: samples = ["a.wav"]
        case .document: samples = ["a.docx"]
        case .spreadsheet: samples = ["a.xlsx"]
        case .presentation: samples = ["a.pptx"]
        case .subtitle: samples = ["a.srt"]
        case .archive: samples = ["a.zip"]
        case .folder, .other: samples = ["a.bin"]
        }
        var actions = allActions(for: samples.map { URL(fileURLWithPath: "/tmp/\($0)") }, mode: mode)
        if kind == .presentation {   // a Keynote file has its own targets (PPTX): the list holds both kinds'
            let keynote = allActions(for: [URL(fileURLWithPath: "/tmp/a.key")], mode: mode)
            actions += keynote.filter { extra in !actions.contains { $0.key == extra.key } }
        }
        return WheelGroups.apply(actions, mode: mode)
    }

    /// Shortcuts: every action for these files, ignoring Settings → Ruota (formats first, then tools).
    static func actionsForShortcuts(_ urls: [URL]) -> [WheelAction] {
        allActions(for: urls, mode: .convert) + allActions(for: urls, mode: .tools)
    }

    /// Settings → Formati: the formats a file with this extension converts to (convert wheel, before customisation).
    static func convertTargets(forExtension ext: String) -> [String] {
        let url = [URL(fileURLWithPath: "/tmp/a.\(ext)")]
        return withoutSourceFormat(allActions(for: url, mode: .convert), url).filter { $0.symbol == nil }.map(\.key)
    }

    /// «Apri in Pages / Numbers» when every file is one the app opens and the app is installed.
    /// A Pages file made by Rondelle (it needs the installed Pages for its empty template, see PagesWriter).
    private static var pagesFile: [WheelAction] {
        IWorkOps.App.pages.installed == nil ? [] : [.each("Pages") { try await DocumentOps.convert($0, to: .pages) }]
    }

    /// A Keynote file made by Rondelle from a PowerPoint one (it needs the installed Keynote for its empty template, see
    /// KeynoteWriter). Not offered for a Keynote file itself.
    private static func keynoteFile(_ urls: [URL]) -> [WheelAction] {
        guard IWorkOps.App.keynote.installed != nil, urls.allSatisfy({ $0.pathExtension.lowercased() == "pptx" }) else { return [] }
        return [.each("Keynote") { try PptxOps.toKeynote($0) }]
    }

    /// A PowerPoint file made from a Keynote one (a picture per slide, with the slide's text as alternative text).
    private static func pptxFromKeynote(_ urls: [URL]) -> [WheelAction] {
        urls.allSatisfy({ $0.pathExtension.lowercased() == "key" }) ? [.each("PPTX") { try PptxOps.fromKeynote($0) }] : []
    }

    /// A Numbers file made by Rondelle from a table (it needs the installed Numbers for its empty template, see NumbersWriter).
    private static func numbersFile(_ urls: [URL]) -> [WheelAction] {
        guard IWorkOps.App.numbers.installed != nil, urls.allSatisfy({ ["xlsx", "ods", "csv", "tsv"].contains($0.pathExtension.lowercased()) }) else { return [] }
        return [.each("Numbers") { try await SheetOps.convert($0, to: .numbers) }]
    }

    private static func iWork(_ app: IWorkOps.App, _ urls: [URL]) -> [WheelAction] {
        let inputs = app == .pages ? IWorkOps.pagesInputs : IWorkOps.numbersInputs
        guard urls.allSatisfy({ inputs.contains($0.pathExtension.lowercased()) }), let action = IWorkOps.action(app) else { return [] }
        return [action]
    }

    /// Hides e.g. "HEIC" on the convert wheel when every dropped file is already HEIC.
    private static func withoutSourceFormat(_ actions: [WheelAction], _ urls: [URL]) -> [WheelAction] {
        let aliases = ["jpeg": "jpg", "tif": "tiff", "aif": "aiff", "htm": "html"]
        func normalized(_ s: String) -> String { aliases[s.lowercased()] ?? s.lowercased() }
        let exts = Set(urls.map { normalized($0.pathExtension) })
        guard exts.count == 1, let ext = exts.first else { return actions }
        return actions.filter { normalized($0.key) != ext }
    }

    static func allActions(for urls: [URL], mode: WheelMode) -> [WheelAction] {
        if mode == .share { return ShareOps.actions() }
        let zip = WheelAction.all("ZIP", "archivebox") { try ArchiveOps.zip($0) }
        let protectedZip = WheelAction.protectedZip
        // On the Macs that have the system's translator (macOS 15 and later).
        var translations: [WheelAction] = []
        if #available(macOS 15.0, *) {
            translations = TranslateLanguage.allCases.map { language in
                .each(language.wheelTitle, "character.bubble") { try await TranslateOps.translate($0, to: language) }
            }
        }
        // What is said in a video or an audio file, on the Macs that can transcribe (macOS 26 and later).
        var subtitles: [WheelAction] = []
        if #available(macOS 26.0, *) {
            subtitles = [("SRT italiano", TranslateLanguage.italian), ("SRT inglese", .english), ("SRT francese", .french)].map { title, language in
                .each(title, "captions.bubble") { try await Transcription.subtitles($0, language: language) }
            }
        }

        // PDFs mixed with images: they can be merged into one PDF.
        if Set(urls.map(FileKind.init)) == [.pdf, .image] {
            return mode == .tools
                ? [.window("Unisci", "doc.on.doc") { MergeWindow.open($0) }, zip, protectedZip]
                : [.window("PDF", "doc.on.doc") { MergeWindow.open($0) }, zip]
        }

        switch (kind(of: urls), mode) {
        case (.image, .convert):
            return ImageOps.targets.map { target in
                // The id stays «JPEG»: custom wheels, Shortcuts and scripts refer to it by that name.
                WheelAction.each(target.name) {
                    let options = FormatSettings.image(target.name)   // Settings → Conversioni → <format>
                    return try ImageOps.process($0, to: target.type, maxPixel: options.maxSide, quality: options.quality,
                                                stripMetadata: !options.keepMetadata)
                }.withID(target.name == "JPG" ? "JPEG" : target.name)
            } + [
                .all("PDF") { try PDFOps.fromImages($0) },
                .all("PPTX") { try PptxOps.fromImages($0) },
                .each("ICNS") { try IconMaker.icns($0) },
                .each("ICO") { try IconMaker.ico($0) },
            ]

        case (.image, .tools):
            var tools: [WheelAction] = [
                .each("Comprimi", "arrow.down.circle") { try ImageOps.compress($0) },
                .targetSize { try ImageTools.fit($0, maxBytes: $1) },
                .each("50%", "arrow.down.right.and.arrow.up.left") { try ImageOps.process($0, scale: 0.5, quality: Settings.imageQuality, suffix: "50%") },
            ]
            // Resize presets come from Settings → Conversioni.
            tools += Settings.imageSizes.map { px in
                .each("\(px)px", "rectangle.arrowtriangle.2.inward") {
                    try ImageOps.process($0, maxPixel: px, quality: Settings.imageQuality, suffix: "\(px)px")
                }
            }
            // Any size, asked each time (the presets above are the quick ones).
            tools.append(.asking("Misura…", "ruler", question: L("Lato lungo in pixel:"), defaultValue: "1920") { url, answer in
                guard let px = Int(answer.trimmingCharacters(in: .whitespaces)), (16...30_000).contains(px) else {
                    throw OpError.failed(L("«%@» non è una misura valida (da 16 a 30000 pixel)", answer))
                }
                return try ImageOps.process(url, maxPixel: px, quality: Settings.imageQuality, suffix: "\(px)px")
            })
            // «Ruota»: the ids «Ruota» and «Specchio» stay those of 1.0.3, for Shortcuts, scripts and Settings → Ruota.
            tools.append(WheelAction(title: "Ruota", symbol: "rotate.right", work: .group([
                WheelAction.each("A destra", "rotate.right") { try ImageTools.turn($0, .right) }.withID("Ruota"),
                WheelAction.each("A sinistra", "rotate.left") { try ImageTools.turn($0, .left) }.withID("Ruota sinistra"),
                WheelAction.each("180°", "arrow.clockwise") { try ImageTools.turn($0, .half) }.withID("Ruota 180"),
                WheelAction.each("Specchio orizzontale", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    try ImageTools.turn($0, .mirrorHorizontal)
                }.withID("Specchio"),
                WheelAction.each("Specchio verticale", "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    try ImageTools.turn($0, .mirrorVertical)
                }.withID("Specchio verticale"),
            ]), id: "group.rotate"))
            if #available(macOS 14.0, *) {
                tools.append(.each("Sfondo", "person.crop.square") { try ImageTools.removeBackground($0) })
            }
            tools += [
                .each("Testo", "text.viewfinder") { try await TextRecognition.imageToText($0) },
                .all("Copia testo", "doc.on.clipboard") { try await TextRecognition.copyImagesText($0) },
                .each("QR", "qrcode.viewfinder") { try await ImageTools.readCodes($0) },
                .metadata { try ImageOps.process($0, quality: 0.95, stripMetadata: true, suffix: L("senza metadati")) },
                .window("Modifica", "pencil.tip.crop.circle") { PhotoEditor.open($0) },
            ]
            if urls.count >= 2 {
                tools.append(.window("Layout", "rectangle.split.2x2") { LayoutWindow.open($0) })
            }
            tools += [zip, protectedZip]
            return tools

        case (.pdf, .convert):
            return [
                .each("PNG") { try PDFOps.toImages($0, type: .png, dpi: FormatSettings.pdfImagesDPI) },
                WheelAction.each("JPG") { try PDFOps.toImages($0, type: .jpeg, dpi: FormatSettings.pdfImagesDPI) }.withID("JPEG"),
                .each("TXT") { try TextRecognition.pdfToText($0) },
                .each("PPTX") { try PptxOps.fromPDF($0) },
                WheelAction(title: "DOCX", symbol: nil, work: .group([
                    WheelAction.each("Con formattazione", "doc.richtext") { try await DocumentOps.fromPDF($0, to: .docx) }.withID("DOCX"),
                    .each("Senza formattazione", "doc.plaintext") { try await DocumentOps.fromPDF($0, to: .docx, plain: true) },
                ]), id: "group.docx"),
                .each("RTF") { try await DocumentOps.fromPDF($0, to: .rtf) },
            ]

        case (.pdf, .tools):
            return [
                .each("Comprimi", "arrow.down.doc") { try PDFOps.compress($0, dpi: 150, quality: 0.7, suffix: "compresso") },
                .each("Comprimi +", "arrow.down.doc.fill") { try PDFOps.compress($0, dpi: 100, quality: 0.5, suffix: L("molto compresso")) },
                .targetSize { try PDFOps.fit($0, maxBytes: $1) },
                WheelAction.window(urls.count == 1 ? "Organizza" : "Unisci",
                                   urls.count == 1 ? "square.grid.3x3.square" : "doc.on.doc") { MergeWindow.open($0) }
                    .withID("merge"),
                .each("Dividi", "scissors") { try PDFOps.split($0) },
                .each("OCR", "text.viewfinder") { try TextRecognition.searchablePDF($0) },
                .metadata { try PDFOps.stripMetadata($0) },
                .asking("Password", "lock", question: L("Password per aprire il PDF (almeno %@ caratteri):", PDFTools.minPasswordLength) + "\n"
                            + L("Protezione debole (RC4): per dati riservati usa «ZIP protetto»."),
                        answer: .newPassword) {
                    let typed = try PasswordHint.parse($1)
                    return try PDFTools.protect($0, password: typed.password, hint: typed.hint, hintInName: typed.inName)
                },
                WheelAction.asking("Sblocca", "lock.open", question: L("Password attuale del PDF:"), answer: .password) {
                    try PDFTools.unlock($0, password: $1)
                }.readingHint { PasswordHint.fromPDF($0) },
                .each("Ruota a destra", "rotate.right") { try PDFTools.rotate($0, degrees: 90, suffix: "ruotato") },
                .each("Ruota a sinistra", "rotate.left") { try PDFTools.rotate($0, degrees: 270, suffix: "ruotato") },
                .each("Capovolgi", "arrow.up.and.down") { try PDFTools.rotate($0, degrees: 180, suffix: "capovolto") },
                WheelAction.each("Numera pagine", "number") { try PDFTools.pageNumbers($0) }.withID("Numeri"),
                .window("Oscura", "rectangle.inset.filled") { RedactWindow.open($0) },
                .asking("Filigrana", "seal", question: L("Testo della filigrana:"), defaultValue: "RISERVATO") {
                    try PDFTools.watermark($0, text: $1)
                },
            ] + translations + [
                zip,
                protectedZip,
            ]

        case (.video, .convert):
            return [
                .each("MP4") { try await MediaOps.convertVideo($0, to: .mp4, ext: "mp4") },
                .each("MOV") { try await MediaOps.convertVideo($0, to: .mov, ext: "mov") },
                .each("M4V") { try await MediaOps.convertVideo($0, to: .m4v, ext: "m4v") },
                .each("GIF") { try await MediaOps.gif($0) },
                .each("M4A") { try await MediaOps.extractAudio($0) },
            ]

        case (.video, .tools):
            return [
                .window("Taglia", "timeline.selection") { TrimWindow.open($0) },
                .each("1080p", "film") { try await MediaOps.compressVideo($0, preset: AVAssetExportPreset1920x1080, suffix: "1080p") },
                .each("720p", "film") { try await MediaOps.compressVideo($0, preset: AVAssetExportPreset1280x720, suffix: "720p") },
                .targetSize { try await VideoFit.fit($0, maxBytes: $1) },
                .each("HEVC", "arrow.down.circle") { try await MediaOps.compressVideo($0, preset: AVAssetExportPresetHEVCHighestQuality, suffix: "HEVC") },
                .each("2×", "hare") { try await MediaOps.changeSpeed($0, factor: 2, suffix: "2x") },
                .each("0,5×", "tortoise") { try await MediaOps.changeSpeed($0, factor: 0.5, suffix: "0,5x") },
                .all("Unisci", "rectangle.stack") { try await MediaOps.join($0) },
                .each("Fotogramma", "camera") { try await MediaOps.snapshot($0) },
                .each("Muto", "speaker.slash") { try await MediaOps.removeAudio($0) },
                .metadata { try await MediaOps.stripMetadata($0) },
                .each("Solo audio", "music.note") { try await MediaOps.extractAudio($0) },
            ] + subtitles + [
                zip,
                protectedZip,
            ]

        case (.audio, .convert):
            return [
                .each("M4A") { try await MediaOps.toM4A($0) },
                .each("WAV") { try MediaOps.convertAudio($0, to: .wav) },
                .each("AIFF") { try MediaOps.convertAudio($0, to: .aiff) },
                .each("FLAC") { try MediaOps.convertAudio($0, to: .flac) },
                .each("MP3") { try MP3Encoder.convert($0) },
            ]

        case (.audio, .tools):
            return [
                .window("Taglia", "timeline.selection") { TrimWindow.open($0) },
                .each("Normalizza", "waveform.badge.plus") { try MediaOps.normalize($0) },
                .metadata { try await MediaOps.stripAudioMetadata($0) },
                .each("Mono", "speaker.wave.1") { try MediaOps.mono($0) },
                .each("Comprimi", "arrow.down.circle") { try await MediaOps.toM4A($0, suffix: "compresso") },
            ] + subtitles + [
                zip,
                protectedZip,
            ]

        case (.document, .convert):
            return [
                .each("PDF") { try await DocumentOps.convert($0, to: .pdf) },
                .each("DOCX") { try await DocumentOps.convert($0, to: .docx) },
                .each("RTF") { try await DocumentOps.convert($0, to: .rtf) },
                .each("ODT") { try await DocumentOps.convert($0, to: .odt) },
                .each("HTML") { try await DocumentOps.convert($0, to: .html) },
                .each("TXT") { try await DocumentOps.convert($0, to: .txt) },
            ] + pagesFile + iWork(.pages, urls)

        case (.spreadsheet, .convert):
            return [
                .each("XLSX") { try await SheetOps.convert($0, to: .xlsx) },
                .each("ODS") { try await SheetOps.convert($0, to: .ods) },
                .each("CSV") { try await SheetOps.convert($0, to: .csv) },
                .each("TSV") { try await SheetOps.convert($0, to: .tsv) },
                .each("HTML") { try await SheetOps.convert($0, to: .html) },
                .each("PDF") { try await SheetOps.convert($0, to: .pdf) },
            ] + numbersFile(urls) + iWork(.numbers, urls)

        case (.presentation, .convert):
            return [
                .each("PDF") { try PptxOps.toPDF($0) },
                WheelAction.each("PNG") { try PptxOps.toImages($0, type: .png, dpi: FormatSettings.pdfImagesDPI) },
                WheelAction.each("JPG") { try PptxOps.toImages($0, type: .jpeg, dpi: FormatSettings.pdfImagesDPI) }.withID("JPEG"),
                .each("TXT") { try PptxOps.toText($0) },
            ] + keynoteFile(urls) + pptxFromKeynote(urls)

        case (.presentation, .tools) where urls.allSatisfy({ $0.pathExtension.lowercased() == "key" }):
            return [zip, protectedZip]   // Keynote files: Rondelle reads the slides, not the file's other properties

        case (.presentation, .tools):
            return [.metadata(for: urls), zip, protectedZip]

        case (.subtitle, .convert):
            return [
                .each("SRT") { try SubtitleOps.convert($0, to: "srt") },
                .each("VTT") { try SubtitleOps.convert($0, to: "vtt") },
                .each("TXT") { try SubtitleOps.convert($0, to: "txt") },
            ]

        case (.document, .tools) where urls.allSatisfy({ $0.pathExtension.lowercased() == "pages" }):
            // Pages files are read by Rondelle (the body's text); what reads other properties of Word files stays out.
            return translations + [zip, protectedZip]

        case (.document, .tools) where urls.allSatisfy({ $0.pathExtension.lowercased() != "pages" }),
             (.subtitle, .tools):
            return translations + [.metadata(for: urls), zip, protectedZip]

        case (.archive, _):
            // Metadata on the tools wheel only: the archive's own, not its contents' (nothing is extracted to read them).
            let metadata: [WheelAction] = mode == .tools ? [.readMetadata] : []
            // A protected ZIP asks for its password once; ZIP-ing an archive again gains nothing, protecting it does.
            if urls.contains(where: ArchiveOps.isEncryptedZip) {
                return [WheelAction.asking("Sblocca ed estrai", "lock.open", question: L("Password dello ZIP protetto:"), answer: .password) {
                    try ArchiveOps.extract($0, password: $1)
                }.readingHint { PasswordHint.fromZip($0) }] + metadata + [protectedZip]
            }
            return [.each("Estrai", "shippingbox") { try ArchiveOps.extract($0) }] + metadata + [protectedZip]

        case (.folder, .convert), (.other, .convert):
            return [zip, protectedZip, .all("TAR.GZ", "archivebox.fill") { try ArchiveOps.tarGz($0) }]

        case (_, .tools):
            // Pages documents, spreadsheets, folders and anything else (also a mix of kinds).
            return [.metadata(for: urls), zip, protectedZip]

        default:
            return [zip, protectedZip]
        }
    }
}
