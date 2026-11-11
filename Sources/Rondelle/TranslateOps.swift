import AppKit
import NaturalLanguage
import PDFKit
import SwiftUI
@_weakLinked import Translation

/// The languages Rondelle translates between.
enum TranslateLanguage: String, CaseIterable, Sendable {
    case italian = "it", english = "en", french = "fr"

    /// As the result's name and the messages say it: «documento (italiano).pdf», «è già in italiano».
    var name: String {
        switch self {
        case .italian: return L("italiano")
        case .english: return L("inglese")
        case .french: return L("francese")
        }
    }

    /// The variant under «Traduci» (the Italian title: WheelAction translates it).
    var wheelTitle: String {
        switch self {
        case .italian: return "In italiano"
        case .english: return "In inglese"
        case .french: return "In francese"
        }
    }

    var recognized: NLLanguage { NLLanguage(rawValue) }
    var locale: Locale.Language { Locale.Language(identifier: rawValue) }
}

/// «Traduci»: a copy of the file in another language, in the same format, translated by Apple's Translation framework,
/// which according to Apple works on the device (no network entitlement here; macOS itself downloads a missing language).
/// PDFs come back as plain text pages: their layout can't be rebuilt around text of another length.
@available(macOS 15.0, *)
enum TranslateOps {
    /// ≈ 700 pages of text; the system translates a few thousand characters per second.
    static let maxCharacters = 2_000_000

    static func translate(_ url: URL, to target: TranslateLanguage) async throws -> [URL] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            let paragraphs = try pdfParagraphs(url)
            let translated = try await translated(paragraphs, of: url, to: target)
            let body = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
            body.paragraphSpacing = 8
            let text = NSAttributedString(string: translated.joined(separator: "\n"),
                                          attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: body])
            return [try DocumentOps.writeNow(text, from: url, to: .pdf, suffix: target.name)]

        case "txt", "md":
            try DocumentOps.checkSize(url)
            return [try await plainText(url, markdown: ext == "md", to: target)]

        case "srt", "vtt":
            return [try await SubtitleOps.translate(url, to: target.name) { try await translated($0, of: url, to: target) }]

        default:
            try DocumentOps.checkSize(url)
            return [try await attributedDocument(url, to: target)]
        }
    }

    // MARK: Formats

    private static func plainText(_ url: URL, markdown: Bool, to target: TranslateLanguage) async throws -> URL {
        var encoding = String.Encoding.utf8
        let raw = try (try? String(contentsOf: url, usedEncoding: &encoding)) ?? String(contentsOf: url, encoding: .isoLatin1)
        // Refused here too: going through the lines of a huge text takes seconds, for nothing.
        guard raw.utf16.count <= maxCharacters else {
            throw OpError.unsupported(L("«%@» è troppo lungo da tradurre (al massimo %@ caratteri)", url.lastPathComponent, maxCharacters))
        }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // What is translated: the words of a paragraph; list and heading marks and code blocks stay as they are.
        enum Part { case verbatim(String); case words(prefix: String, index: Int) }
        var parts: [Part] = []
        var texts: [String] = []
        var inCode = false
        for line in reflow(lines, wrappedAtMost: 120) {
            if markdown, line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                parts.append(.verbatim(line))
            } else if inCode {
                parts.append(.verbatim(line))
            } else {
                let mark = line.prefixMatch(of: #/\s*(?:(?:\#{1,6}|[-*+•]|\d+[.)]|>)\s+)*/#).map { String($0.0) } ?? ""
                parts.append(.words(prefix: mark, index: texts.count))
                texts.append(String(line.dropFirst(mark.count)))
            }
        }
        let translated = try await translated(texts, of: url, to: target)
        let result = parts.map { part -> String in
            switch part {
            case .verbatim(let line): return line
            case .words(let prefix, let index): return prefix + translated[index]
            }
        }.joined(separator: "\n")
        let out = FileNaming.output(for: url, ext: url.pathExtension.lowercased(), suffix: target.name)
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// RTF, Word, ODT, HTML: paragraph by paragraph, keeping each one's style, tables and images.
    private static func attributedDocument(_ url: URL, to target: TranslateLanguage) async throws -> URL {
        let imported = try await DocumentOps.imported(url)
        let document = NSMutableAttributedString(attributedString: imported)
        let whole = document.string as NSString
        var ranges: [NSRange] = []
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length), options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            // An image inside a paragraph splits it: what is around it is translated, the image stays.
            var start = paragraph.location
            let end = paragraph.upperBound
            while start < end {
                let image = whole.range(of: "\u{FFFC}", range: NSRange(location: start, length: end - start))
                let stop = image.location == NSNotFound ? end : image.location
                if stop > start { ranges.append(NSRange(location: start, length: stop - start)) }
                start = stop + 1
            }
        }
        let translated = try await translated(ranges.map { whole.substring(with: $0) }, of: url, to: target)
        // Backwards, so that the ranges still to replace don't move. Text of another length can't follow inline
        // styles word by word: the paragraph takes the style of most of its text.
        for (range, text) in zip(ranges, translated).reversed() {
            var attributes = longestRunAttributes(of: document, in: range)
            var covered = NSRange()
            if document.attribute(.link, at: range.location, effectiveRange: &covered) != nil, NSIntersectionRange(covered, range) != range {
                attributes[.link] = nil
            }
            document.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        }
        let ext = url.pathExtension.lowercased()
        let format: DocumentOps.Target
        switch ext {
        case "rtf", "rtfd": format = .rtf
        case "odt": format = .odt
        case "html", "htm", "webarchive": format = .html
        default: format = .docx   // .doc too: macOS has no reliable writer for the old Word format
        }
        return try DocumentOps.writeNow(document, from: url, to: format, suffix: target.name)
    }

    private static func longestRunAttributes(of text: NSAttributedString, in range: NSRange) -> [NSAttributedString.Key: Any] {
        var best: [NSAttributedString.Key: Any] = [:]
        var longest = 0
        text.enumerateAttributes(in: range) { attributes, run, _ in
            if run.length > longest { best = attributes; longest = run.length }
        }
        return best
    }

    /// The PDF's paragraphs: its own text if it has any, otherwise OCR of the pages (a scan).
    private static func pdfParagraphs(_ url: URL) throws -> [String] {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable(url) }
        guard !doc.isLocked else { throw OpError.unsupported(L("PDF protetto da password")) }
        try PDFOps.confirmPages(doc.pageCount, of: url)
        try PDFTextScan.check(url)
        try PDFTextScan.warnHiddenTextOnce()
        var paragraphs: [String] = []
        for i in 0..<doc.pageCount {
            try PDFOps.checkCancelled()
            autoreleasepool {
                guard let text = doc.page(at: i)?.string else { return }
                paragraphs += reflow(text.components(separatedBy: .newlines), wrappedAtMost: .max).filter { !$0.isEmpty }
            }
        }
        if paragraphs.isEmpty, let cg = CGPDFDocument(url as CFURL), cg.numberOfPages > 0 {
            for i in 1...cg.numberOfPages {
                try PDFOps.checkCancelled()
                guard let page = cg.page(at: i), let image = PDFOps.render(page, dpi: 200) else { continue }
                let lines = try TextRecognition.lines(in: image).map(\.text)
                paragraphs += reflow(lines, wrappedAtMost: .max).filter { !$0.isEmpty }
            }
        }
        guard !paragraphs.isEmpty else { throw OpError.failed(L("nessun testo trovato")) }
        return paragraphs
    }

    /// Joins the lines a text was wrapped at (a PDF's, a mail-like TXT), because sentences cut in two translate badly.
    /// A line continues on the next if it nearly reaches the widest one, doesn't end a sentence and the next
    /// isn't a list item. Lines wider than `wrappedAtMost` mean the text isn't wrapped: nothing is joined.
    static func reflow(_ lines: [String], wrappedAtMost limit: Int) -> [String] {
        let widest = lines.map(\.count).max() ?? 0
        guard widest >= 40, widest <= limit else { return lines }
        var result: [String] = []
        var joining = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if joining, !trimmed.isEmpty, trimmed.prefixMatch(of: #/(?:[-*+•]|\d+[.)])\s/#) == nil, var last = result.popLast() {
                if last.hasSuffix("-"), trimmed.first?.isLowercase == true { last.removeLast() } else { last += " " }
                result.append(last + trimmed)
            } else {
                result.append(line)
            }
            let end = trimmed.last.map { ".:;!?»\"”)".contains($0) } ?? true
            joining = !trimmed.isEmpty && !end && Double(line.count) >= 0.75 * Double(widest)
        }
        return result
    }

    // MARK: Language

    private static func translated(_ texts: [String], of url: URL, to target: TranslateLanguage) async throws -> [String] {
        let characters = texts.reduce(0) { $0 + $1.utf16.count }
        guard characters <= maxCharacters else {
            throw OpError.unsupported(L("«%@» è troppo lungo da tradurre (al massimo %@ caratteri)", url.lastPathComponent, maxCharacters))
        }
        let source = try await sourceLanguage(of: texts, url: url, target: target)
        return try await TranslationEngine.translate(texts, from: source, to: target)
    }

    enum Recognized: Equatable {
        case language(TranslateLanguage)
        /// Clearly a language Rondelle doesn't translate.
        case other(String)
        /// Too little text, or a mix: `guess` is the most likely of the three.
        case unsure(guess: TranslateLanguage?)
    }

    /// Looks across all languages, not just the three: Spanish must not pass for Italian.
    /// The system's recognizer decides on the first hundred characters or so, whatever follows: an English title on an
    /// Italian text made it all English. So every part of the document votes, in proportion to its length.
    static func recognize(_ texts: [String]) -> Recognized {
        var parts: [(text: String, letters: Int)] = []
        var part = ""
        var letters = 0
        for text in texts {
            let count = text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            guard count > 0 else { continue }
            part += text + "\n"
            letters += count
            if letters >= 150 {
                parts.append((part, letters))
                part = ""
                letters = 0
            }
        }
        if letters > 0 { parts.append((part, letters)) }
        guard parts.reduce(0, { $0 + $1.letters }) >= 25 else {
            return .unsure(guess: nil)
        }
        // 300 parts, spread over the document, are plenty.
        let step = max(1, parts.count / 300)
        var votes: [NLLanguage: Double] = [:]
        let recognizer = NLLanguageRecognizer()
        for index in stride(from: 0, to: parts.count, by: step) {
            recognizer.reset()
            recognizer.processString(parts[index].text)
            for (language, share) in recognizer.languageHypotheses(withMaximum: 4) {
                votes[language, default: 0] += share * Double(parts[index].letters)
            }
        }
        let total = votes.values.reduce(0, +)
        let hypotheses = votes.mapValues { $0 / max(total, 1) }
        let guess = TranslateLanguage.allCases.filter { hypotheses[$0.recognized] != nil }
            .max { hypotheses[$0.recognized]! < hypotheses[$1.recognized]! }
        guard let best = hypotheses.max(by: { $0.value < $1.value }), best.value >= 0.75 else { return .unsure(guess: guess) }
        if let known = TranslateLanguage.allCases.first(where: { $0.recognized == best.key }) { return .language(known) }
        let name = Locale(identifier: Loc.languageCode).localizedString(forLanguageCode: best.key.rawValue) ?? best.key.rawValue
        return .other(name)
    }

    private static func sourceLanguage(of texts: [String], url: URL, target: TranslateLanguage) async throws -> TranslateLanguage {
        guard texts.contains(where: { $0.contains(where: \.isLetter) }) else { throw OpError.failed(L("nessun testo trovato")) }
        let source: TranslateLanguage
        switch recognize(texts) {
        case .language(let language):
            source = language
        case .other(let name):
            throw OpError.unsupported(L("«%@» sembra in %@: Rondelle traduce solo italiano, inglese e francese", url.lastPathComponent, name))
        case .unsure(let guess):
            guard Prompts.allowed else {
                throw OpError.failed(L("non riesco a riconoscere la lingua di «%@»", url.lastPathComponent))
            }
            let name = url.lastPathComponent
            let chosen = await MainActor.run { Notice.askLanguage(of: name, guess: guess ?? (target == .english ? .italian : .english)) }
            guard let chosen else { throw CancellationError() }
            source = chosen
        }
        guard source != target else {
            throw OpError.unsupported(L("«%@» è già in %@", url.lastPathComponent, target.name))
        }
        return source
    }
}

extension Notice {
    /// When the language can't be recognized: which one is the file in? Nil if cancelled.
    static func askLanguage(of name: String, guess: TranslateLanguage) -> TranslateLanguage? {
        let alert = languageAlert(of: name, guess: guess)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, let menu = alert.accessoryView as? NSPopUpButton else { return nil }
        return TranslateLanguage.allCases[menu.indexOfSelectedItem]
    }

    static func languageAlert(of name: String, guess: TranslateLanguage) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("In che lingua è «%@»?", name)
        alert.informativeText = L("Rondelle non è riuscito a riconoscerla: c'è poco testo, o sono più lingue insieme.")
        alert.addButton(withTitle: L("Traduci"))
        alert.addButton(withTitle: L("Annulla"))
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        menu.addItems(withTitles: TranslateLanguage.allCases.map { $0.name.capitalized })
        menu.selectItem(at: TranslateLanguage.allCases.firstIndex(of: guess) ?? 0)
        alert.accessoryView = menu
        return alert
    }
}

// MARK: - The system's translator

@available(macOS 15.0, *)
private enum TranslationEngine {
    /// What goes to the translator in one call: «Annulla» is checked between calls.
    private static let batchCharacters = 6_000
    private static let batchTexts = 40
    /// A paragraph longer than this goes sentence by sentence.
    private static let longestText = 4_000

    /// One translation per text, in the same order. Spaces around a text and texts without letters stay as they are.
    static func translate(_ texts: [String], from source: TranslateLanguage, to target: TranslateLanguage) async throws -> [String] {
        // Each text → its pieces (a long paragraph: several), each piece → one request.
        var pieces: [String] = []
        var owners: [Int] = []
        var output = texts
        for (i, text) in texts.enumerated() where text.contains(where: \.isLetter) {
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for piece in split(core) {
                pieces.append(piece)
                owners.append(i)
            }
        }
        guard !pieces.isEmpty else { return output }

        // Just after the system's service starts, an installed language can read as «to download» for a moment.
        var status = await LanguageAvailability().status(from: source.locale, to: target.locale)
        for _ in 0..<3 where status == .supported {
            try await Task.sleep(nanoseconds: 700_000_000)
            status = await LanguageAvailability().status(from: source.locale, to: target.locale)
        }
        guard status != .unsupported else {
            throw OpError.unsupported(L("macOS non sa tradurre da %@ a %@", source.name, target.name))
        }
        let translated: [String]
        #if DEBUG
        let forceWindow = ProcessInfo.processInfo.environment["RONDELLE_TRANSLATION_WINDOW"] != nil
        #else
        let forceWindow = false
        #endif
        if #available(macOS 26.0, *), status == .installed, !forceWindow {
            // Nothing to download: no window needed, and it also works where nobody can answer (Shortcuts).
            translated = try await withSecondAttempt {
                try await run(TranslationSession(installedSource: source.locale, target: target.locale), pieces) { Task.isCancelled }
            }
        } else if Prompts.allowed || forceWindow {
            translated = try await TranslationHost.translate(pieces, from: source, to: target)
        } else {
            throw OpError.failed(L("mancano le lingue %@ e %@: scaricale in Impostazioni di Sistema → Generali → Lingua e Zona → Lingue per la traduzione", source.name, target.name))
        }

        // Back together, with the spaces each text had around it.
        var joined: [Int: [String]] = [:]
        for (piece, owner) in zip(translated, owners) { joined[owner, default: []].append(piece) }
        for (i, parts) in joined {
            let text = texts[i]
            let lead = text.prefix { $0.isWhitespace || $0.isNewline }
            let trail = String(text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
            output[i] = String(lead) + parts.joined(separator: " ") + trail
        }
        return output
    }

    /// Right after the system's service starts, the first request can fail: at most two attempts, each with a new
    /// session, then the error is reported.
    private static func withSecondAttempt(_ attempt: () async throws -> [String]) async throws -> [String] {
        for number in 1...2 {
            do {
                #if DEBUG
                if let failing = ProcessInfo.processInfo.environment["RONDELLE_TRANSLATION_FAIL"].flatMap({ Int($0) }), number <= failing {
                    throw OpError.failed("errore simulato")
                }
                #endif
                return try await attempt()
            } catch is CancellationError {
                throw CancellationError()
            } catch where number == 1 {
                #if DEBUG
                if ProcessInfo.processInfo.environment["RONDELLE_TRANSLATION_TRACE"] != nil { fputs("secondo tentativo: \(error.localizedDescription)\n", stderr) }
                #endif
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                throw OpError.failed(L("la traduzione non è riuscita (%@)", reason))
            }
        }
        throw OpError.failed(L("traduzione incompleta"))
    }

    /// Asks in batches; `cancelled` is looked at between them.
    static func run(_ session: TranslationSession, _ pieces: [String], cancelled: () -> Bool) async throws -> [String] {
        var result = [String?](repeating: nil, count: pieces.count)
        var start = 0
        while start < pieces.count {
            if cancelled() { throw CancellationError() }
            var end = start, size = 0
            while end < pieces.count, end - start < batchTexts, size + pieces[end].utf16.count <= batchCharacters || end == start {
                size += pieces[end].utf16.count
                end += 1
            }
            let requests = (start..<end).map { TranslationSession.Request(sourceText: pieces[$0], clientIdentifier: String($0)) }
            for response in try await session.translations(from: requests) {
                if let id = response.clientIdentifier.flatMap({ Int($0) }), result.indices.contains(id) { result[id] = response.targetText }
            }
            start = end
        }
        // A missing piece must not become a gap in the document nobody notices.
        let complete = result.compactMap { $0 }
        guard complete.count == pieces.count else { throw OpError.failed(L("traduzione incompleta")) }
        return complete
    }

    private static func split(_ text: String) -> [String] {
        guard text.utf16.count > longestText else { return [text] }
        var pieces: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if current.utf16.count + sentence.utf16.count > longestText, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.flatMap { piece -> [String] in
            // A «sentence» that long has no full stops: cut it, rather than ask the translator for all of it at once.
            guard piece.utf16.count > longestText else { return [piece.trimmingCharacters(in: .whitespacesAndNewlines)] }
            return stride(from: 0, to: piece.count, by: longestText).map {
                let from = piece.index(piece.startIndex, offsetBy: $0)
                return String(piece[from..<(piece.index(from, offsetBy: longestText, limitedBy: piece.endIndex) ?? piece.endIndex)])
            }
        }
    }
}

/// Before macOS 26, and when a language has to be downloaded, a translation session exists only inside a SwiftUI
/// view: a small window hosts it, and macOS shows its own download question there.
@available(macOS 15.0, *)
@MainActor
private enum TranslationHost {
    /// Resumes the job once: with the translation, the error, or «Annulla» from the progress card.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String], Error>?
        private var isCancelled = false
        var cancelled: Bool { lock.withLock { isCancelled } }

        func start(_ continuation: CheckedContinuation<[String], Error>) { lock.withLock { self.continuation = continuation } }

        func finish(_ result: Result<[String], Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<[String], Error>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }

        func cancel() {
            lock.withLock { isCancelled = true }
            finish(.failure(CancellationError()))
        }
    }

    private struct Host: View {
        let configuration: TranslationSession.Configuration
        let work: @Sendable (TranslationSession) async -> Void
        @State private var active: TranslationSession.Configuration?

        var body: some View {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("Traduzione in corso…"))
            }
            .frame(width: 280, height: 64)
            .translationTask(active) { session in await work(session) }
            .onAppear { active = configuration }
        }
    }

    static func translate(_ pieces: [String], from source: TranslateLanguage, to target: TranslateLanguage) async throws -> [String] {
        let outcome = Outcome()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L("Rondelle")
        window.level = .floating
        window.contentView = NSHostingView(rootView: Host(
            configuration: .init(source: source.locale, target: target.locale),
            work: { session in
                do {
                    try await session.prepareTranslation()   // the download question, if a language is missing
                    outcome.finish(.success(try await TranslationEngine.run(session, pieces) { outcome.cancelled }))
                } catch {
                    outcome.finish(.failure(error))
                }
            }))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.start(continuation)
                if Task.isCancelled { outcome.cancel() }
            }
        } onCancel: {
            outcome.cancel()
        }
    }
}
