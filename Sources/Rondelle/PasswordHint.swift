import Foundation

/// The optional hint of a protected ZIP or PDF: a reminder for whoever created the password, stored IN CLEAR
/// beside the encrypted content (the dialog says so). Anyone can read or forge it, so what comes back from a
/// file is treated as hostile: read from a bounded tail, stripped of control characters, shown as plain text.
enum PasswordHint {
    static let maxCharacters = 100
    /// Bytes: keeps the PDF's end marker within the last kilobyte, where readers look for it.
    private static let maxBytes = 400
    private static let separator = "\u{1F}"
    /// Right after the separator: the user also wants the hint in the file's name.
    private static let inNameMarker = "\u{1E}"
    private static let zipMarker = "Rondelle hint: "
    private static let pdfMarker = "%RondelleHint:"

    // MARK: Through the job's single answer

    /// The new-password dialog's answer: password and hint, in the one string a job receives.
    static func answer(password: String, hint: String, inName: Bool = false) -> String {
        password + separator + (inName ? inNameMarker : "") + hint
    }

    /// Takes the answer apart. The hint is clean afterwards and never gives the password away.
    static func parse(_ answer: String) throws -> (password: String, hint: String?, inName: Bool) {
        guard let cut = answer.range(of: separator, options: .backwards) else { return (answer, nil, false) }
        let password = String(answer[..<cut.lowerBound])
        var rest = String(answer[cut.upperBound...])
        let inName = rest.hasPrefix(inNameMarker)
        if inName { rest.removeFirst() }
        let hint = clean(rest)
        if let problem = problem(hint: hint, password: password) { throw OpError.failed(String(problem.dropLast())) }  // the error adds its own full stop
        return (password, hint.isEmpty ? nil : hint, inName && !hint.isEmpty)
    }

    /// "protetto", or "protetto · suggerimento «…»" when asked: other apps (Preview, Acrobat, the Finder) don't
    /// show the hint stored in the file, but everyone sees the name, whoever gets the file too.
    static func nameSuffix(_ hint: String?, inName: Bool) -> String {
        guard inName, let hint, !hint.isEmpty else { return L("protetto") }
        var safe = hint.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while safe.utf8.count > 120 { safe.removeLast() }
        return L("protetto") + " · " + L("suggerimento «%@»", safe)
    }

    /// Why this hint can't be used; nil if it can.
    static func problem(hint: String, password: String) -> String? {
        guard !hint.isEmpty, !password.isEmpty else { return nil }
        let exposed = hint.caseInsensitiveCompare(password) == .orderedSame
            || (password.count >= 4 && hint.range(of: password, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        return exposed ? L("Il suggerimento non può contenere la password.") : nil
    }

    /// Whether a character can be shown as it is in a line of text written by someone else: not a control, invisible
    /// formatting (such as a right-to-left override, which could disguise the text), a line break, private or unassigned.
    /// Shared with what «Metadati → Leggi» shows.
    nonisolated static func isShown(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return false
        default: return true
        }
    }

    /// One short line: no control or invisible formatting characters (which could disguise the text), limited length.
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter(isShown)
        var line = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        if line.count > maxCharacters { line = String(line.prefix(maxCharacters)) }
        while line.utf8.count > maxBytes { line.removeLast() }
        return line
    }

    /// The second line of the question that asks a file's password, when the file carries a hint.
    static func question(_ question: String, hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return question }
        return question + "\n" + L("Suggerimento scritto da chi ha creato il file: «%@»", hint)
    }

    // MARK: ZIP: the archive comment (other apps, such as Keka and 7-Zip, show it too)

    /// `url` has just been written by bsdtar: its end record is the last 22 bytes, with no comment.
    static func writeToZip(_ url: URL, hint: String) throws {
        let comment = Data((zipMarker + hint).utf8)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw OpError.failed(L("scrittura del suggerimento")) }
        try handle.seek(toOffset: size - 22)
        let record = try handle.read(upToCount: 22) ?? Data()
        guard record.count == 22, record.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]), record[20] == 0, record[21] == 0 else {
            throw OpError.failed(L("scrittura del suggerimento"))
        }
        try handle.seek(toOffset: size - 2)
        try handle.write(contentsOf: Data([UInt8(comment.count & 0xFF), UInt8(comment.count >> 8)]) + comment)
    }

    static func fromZip(_ url: URL) -> String? {
        guard let tail = tail(of: url, bytes: 22 + 65_535) else { return nil }
        let signature = Data([0x50, 0x4B, 0x05, 0x06])
        var searchEnd = tail.endIndex
        // The last end record whose comment reaches exactly the end of the file: a signature inside a comment isn't one.
        while let found = tail.range(of: signature, options: .backwards, in: tail.startIndex..<searchEnd) {
            let start = found.lowerBound
            if start + 22 <= tail.endIndex {
                let length = Int(tail[start + 20]) | Int(tail[start + 21]) << 8
                if start + 22 + length == tail.endIndex {
                    guard let text = String(data: tail[(start + 22)...], encoding: .utf8), text.hasPrefix(zipMarker) else { return nil }
                    let hint = clean(String(text.dropFirst(zipMarker.count)))
                    return hint.isEmpty ? nil : hint
                }
            }
            searchEnd = found.upperBound - 1
        }
        return nil
    }

    // MARK: PDF: a comment line after the end of the file (only Rondelle reads it)

    static func writeToPDF(_ url: URL, hint: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n\(pdfMarker)\(Data(hint.utf8).base64EncodedString())\n".utf8))
    }

    static func fromPDF(_ url: URL) -> String? {
        guard let tail = tail(of: url, bytes: 1024), let marker = tail.range(of: Data(pdfMarker.utf8), options: .backwards) else { return nil }
        let rest = tail[marker.upperBound...]
        let line = rest.prefix { $0 != 0x0A && $0 != 0x0D }
        guard let encoded = String(data: line, encoding: .ascii), let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let hint = clean(text)
        return hint.isEmpty ? nil : hint
    }

    private static func tail(of url: URL, bytes: UInt64) -> Data? {
        guard let handle = try? SafeFile.openForReading(url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let length = min(size, bytes)
        guard (try? handle.seek(toOffset: size - length)) != nil else { return nil }
        return (try? handle.read(upToCount: Int(length))).flatMap { $0 }.map { Data($0) }
    }
}
