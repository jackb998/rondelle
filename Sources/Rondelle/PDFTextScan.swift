import CoreGraphics
import Foundation

/// A1: PDFKit's text extraction takes ≈ 400 bytes per character of a page, and nothing stops it once it has started,
/// so what a PDF asks of it is counted first, walking the operators in a stream. Forms count each time they're drawn.
enum PDFTextScan {
    /// As much text as «Traduci» takes: ≈ 300 MB on ordinary pages, 390 MB in the worst split (four pages at the limit below).
    static let maxCharacters = 2_000_000
    /// No real page comes close; two pages of 1 million characters took 540 MB.
    static let maxCharactersPerPage = 500_000
    /// Empty or one-letter strings cost time like long ones (≈ 2 µs each to extract); a real page has one per word at most.
    static let maxTextOperators = 2_000_000
    static let maxTextOperatorsPerPage = 500_000
    static let maxFormDepth = 8
    static let maxFormCalls = 200_000
    /// Operators of any kind: drawing them takes ≈ 0.3 µs each, and nothing stops that either.
    static let maxOperators = 20_000_000

    /// CoreGraphics keeps a page's operands in memory until an operator comes (≈ 80 bytes each), with no way to stop it.
    static let maxOperandsInARow = 1_000_000
    /// One stream unpacked: more than any image Rondelle would accept.
    static let maxStreamBytes = 1_000_000_000
    /// Reading a ToUnicode map means unpacking it all at once, and which stream it is can't be told beforehand:
    /// so it is read only if no stream in the file is larger than this.
    static let maxBytesToReadMaps = 128_000_000
    /// T2: an encrypted stream is decrypted whole in memory before its filters: above this, the file is refused.
    static let maxEncryptedStreamBytes = 256 * 1024 * 1024
    /// Rewriting a PDF with PDFKit costs ≈ 5 µs per text operator and ≈ 0.1 µs per character, in one call nothing stops:
    /// with `maxTextOperators`, ≈ 20 s at worst, and far more than any book has (≈ 3,000 characters a page).
    static let maxCharactersRewritten = 100_000_000

    /// Refuses a PDF over the limits. A PDF that can't be opened or read is left to the caller, which already says so.
    /// Returns the size of its largest stream unpacked.
    @discardableResult
    static func check(_ url: URL) throws -> Int {
        guard let doc = CGPDFDocument(url as CFURL), !doc.isEncrypted || doc.isUnlocked else { return 0 }
        let largest = try checkStreams(url, encrypted: doc.isEncrypted, password: nil)
        let scan = Scan()
        scan.largestStream = largest
        scan.run(doc)
        switch scan.outcome {
        case .within: return largest
        case .cancelled: throw CancellationError()
        case .tooMuch: throw OpError.unsupported(L("«%@» ha troppo testo o è troppo complesso da leggere (al massimo %@ caratteri)", url.lastPathComponent, maxCharacters))
        }
    }

    /// N1: for the tools that draw every page rather than read the text. A long book is fine, as «Annulla» works between
    /// pages: here what can't be stopped is one page, so every limit applies to one page at a time.
    static func checkForDrawing(_ url: URL) throws {
        try checkPages(url, rewriting: false, password: nil)
    }

    /// N6: for what PDFKit writes back as one whole document, which «Annulla» can't stop: the same limits, plus some on
    /// the whole file. «Dividi» writes one page at a time, so `checkForDrawing` is the one for it.
    static func checkForRewriting(_ url: URL, password: String? = nil) throws {
        try checkPages(url, rewriting: true, password: password)
    }

    private static func checkPages(_ url: URL, rewriting: Bool, password: String?) throws {
        guard let doc = CGPDFDocument(url as CFURL) else { return }
        if let password { _ = doc.unlockWithPassword(password) }
        guard !doc.isEncrypted || doc.isUnlocked else { return }
        let tooComplex = OpError.unsupported(L("«%@» è troppo complesso da elaborare", url.lastPathComponent))
        do {
            _ = try checkStreams(url, encrypted: doc.isEncrypted, password: password)
        } catch is OpError {
            throw tooComplex
        }
        let scan = Scan()
        scan.perPage = true
        scan.wholeFile = rewriting
        scan.run(doc)
        switch scan.outcome {
        case .within: return
        case .cancelled: throw CancellationError()
        case .tooMuch: throw tooComplex
        }
    }

    /// N2: every stream in the file's bytes, unpacked through its filters and thrown away as it comes, before CoreGraphics
    /// sees any. Returns the largest. The streams of an encrypted PDF are decrypted first: one that opens with no password
    /// asks nothing of the user, so if this code can't read its encryption the file is refused rather than trusted.
    private static func checkStreams(_ url: URL, encrypted: Bool, password: String?) throws -> Int {
        let tooMuch = OpError.unsupported(L("«%@» ha troppo testo o è troppo complesso da leggere (al massimo %@ caratteri)", url.lastPathComponent, maxCharacters))
        guard let data = ContentLimits.mapped(url) else { return 0 }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            let crypt = encrypted ? PDFStandardCrypt(file: bytes, password: password) : nil
            if Task.isCancelled { throw CancellationError() }
            // P1: also with a password typed, a cipher this code can't read would leave the streams unchecked.
            let unknownCipher = OpError.unsupported(L("«%@» usa una cifratura che Rondelle non sa controllare", url.lastPathComponent))
            if encrypted, crypt == nil { throw unknownCipher }
            let keyword = Array("stream".utf8), finish = Array("endstream".utf8)
            var largest = 0
            var position = 0
            var searchBudget = 2_000_000_000   // looking back for dictionaries: a file full of the word «stream» can't spend more
            while position < bytes.count, let found = memmem(base + position, bytes.count - position, keyword, keyword.count) {
                let at = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                position = at + keyword.count
                if at >= 3, bytes[at - 3] == 0x65, bytes[at - 2] == 0x6E, bytes[at - 1] == 0x64 { continue }   // «endstream»
                var start = position
                if start < bytes.count, bytes[start] == 0x0D { start += 1 }
                if start < bytes.count, bytes[start] == 0x0A { start += 1 }
                guard start + 2 < bytes.count else { continue }
                // Only this stream's own dictionary: before it, in the same bytes, may be another object's.
                var from = max(0, at - (searchBudget > 0 ? 64_000 : 512))
                var back = at - 3
                while back >= from {
                    searchBudget -= 1
                    if bytes[back] == 0x6F, bytes[back + 1] == 0x62, bytes[back + 2] == 0x6A, back > 0, bytes[back - 1] != 0x64 { from = back; break }   // «obj», not «endobj»
                    back -= 1
                }
                let dictionary = UnsafeRawBufferPointer(rebasing: bytes[from..<at])
                guard var chain = filters(in: dictionary, file: UnsafeRawBufferPointer(rebasing: bytes[0...])) else { throw tooMuch }
                let compressing: Set<String> = ["FlateDecode", "Fl", "LZWDecode", "LZW", "RunLengthDecode", "RL"]
                let images: Set<String> = ["DCTDecode", "DCT", "JPXDecode", "CCITTFaxDecode", "CCF", "JBIG2Decode"]
                // A compression on top of another has no use, and multiplies what the check below can see.
                if chain.filter(compressing.contains).count > 1 || chain.count > 4 { throw tooMuch }
                var end = bytes.count
                if let stop = memmem(base + start, bytes.count - start, finish, finish.count) {
                    end = base.distance(to: stop.assumingMemoryBound(to: UInt8.self))
                }
                // CoreGraphics believes /Length if it can: a false «endstream» inside the stream doesn't end it.
                if let declared = streamLength(dictionary), declared > end - start, start + declared <= bytes.count { end = start + declared }
                var text: Data?   // what decryption and the ASCII filters have made so far
                // P1: a /Crypt filter of the stream's own: in clear (Identity, None), the usual cipher, or one not followed here.
                var clear = false
                if let crypt, chain.contains("Crypt") {
                    guard let inClear = crypt.streamInClear(dictionary) else { throw unknownCipher }
                    clear = inClear
                }
                if let crypt, !clear {
                    guard let (object, generation) = objectNumber(bytes, at: from) else { continue }
                    let decrypt = { (to: Int) in
                        crypt.decrypt(UnsafeRawBufferPointer(rebasing: bytes[start..<to]), object: object, generation: generation, dictionary: dictionary)
                    }
                    // T2: an image holds pixels, nothing to check: not decrypted. A stream with no filter is looked at
                    // only if its first bytes, decrypted alone, say it is compressed after all.
                    if chain.contains(where: images.contains) { position = max(position, end); continue }
                    if chain.isEmpty {
                        let head = decrypt(min(end, start + 32))
                        guard let a = head.first, let b = head.dropFirst().first, a & 0x0F == 8, (Int(a) * 256 + Int(b)) % 31 == 0 else {
                            position = max(position, end)
                            continue
                        }
                    }
                    // Decrypting means a copy in memory as large as the stream (the end of line before «endstream» isn't part of it).
                    var stop = end
                    if stop > start, bytes[stop - 1] == 0x0A { stop -= 1 }
                    if stop > start, bytes[stop - 1] == 0x0D { stop -= 1 }
                    guard stop - start <= maxEncryptedStreamBytes else {
                        throw OpError.unsupported(L("«%@» ha un flusso cifrato troppo grande da controllare (oltre 256 MB)", url.lastPathComponent))
                    }
                    text = decrypt(end)
                }
                let first = text.map { ($0.first ?? 0, $0.dropFirst().first ?? 0) } ?? (bytes[start], bytes[start + 1])
                let looksFlate = first.0 & 0x0F == 8 && (Int(first.0) * 256 + Int(first.1)) % 31 == 0
                if chain.isEmpty {
                    guard looksFlate else { continue }   // an uncompressed stream costs no more than its size in the file
                    chain = ["FlateDecode"]
                }
                var size = 0
                var tokens = OperandRun()
                var within = true
                let count: (UnsafeBufferPointer<UInt8>) -> Bool = { chunk in
                    size += chunk.count
                    within = size <= maxStreamBytes && tokens.feed(chunk)
                    return within
                }
                var consumed = end
                var done = false
                for filter in chain where !done {
                    let input = text.map { _ in UnsafeRawBufferPointer(start: nil, count: 0) } ?? UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                    let run = { (body: (UnsafeRawBufferPointer) throws -> Void) throws in
                        if let text { try text.withUnsafeBytes(body) } else { try body(input) }
                    }
                    switch filter {
                    case "ASCII85Decode", "A85":
                        try run { text = decodeA85($0) }
                    case "ASCIIHexDecode", "AHx":
                        try run { text = decodeHex($0) }
                    case "FlateDecode", "Fl":
                        try run { source in
                            let header = source.count > 2 && source[0] & 0x0F == 8 && (Int(source[0]) * 256 + Int(source[1])) % 31 == 0
                            guard header else { return }   // encrypted, or not what it says: CoreGraphics will refuse it
                            let used = try ContentLimits.inflate(UnsafeRawBufferPointer(rebasing: source[2...]), consume: count)
                            if text == nil { consumed = start + 2 + used }
                        }
                        done = true
                    case "LZWDecode", "LZW":
                        let early = dictionary.occurrences(of: "/EarlyChange 0") > 0 ? 0 : 1
                        try run { try inflateLZW($0, early: early, sink: count) }
                        done = true
                    case "RunLengthDecode", "RL":
                        try run { source in
                            var at = 0
                            while at < source.count, within {
                                let length = Int(source[at])
                                if length == 128 { break }
                                if length < 128 {
                                    let stop = min(source.count, at + 2 + length)
                                    _ = count(UnsafeRawBufferPointer(rebasing: source[(at + 1)..<stop]).bindMemory(to: UInt8.self))
                                    at = stop
                                } else if at + 1 < source.count {
                                    let repeated = [UInt8](repeating: source[at + 1], count: 257 - length)
                                    _ = repeated.withUnsafeBufferPointer(count)
                                    at += 2
                                } else { break }
                            }
                        }
                        done = true
                    case "Crypt":
                        break
                    default:   // images: what they hold is pixels, not operands
                        text = nil
                        done = true
                    }
                }
                // Only ASCII filters: the text itself is what CoreGraphics will read.
                if !done, let text, !chain.isEmpty { text.withUnsafeBytes { _ = count($0.bindMemory(to: UInt8.self)) } }
                guard within else { throw tooMuch }
                largest = max(largest, size)
                position = max(position, consumed)
            }
            return largest
        }
    }

    // MARK: Filters of a stream

    /// /Length, if it is written here and not in another object.
    private static func streamLength(_ dictionary: UnsafeRawBufferPointer) -> Int? {
        let key = Array("/Length".utf8)
        guard let base = dictionary.baseAddress, !dictionary.isEmpty else { return nil }
        var from = 0
        while from < dictionary.count, let hit = memmem(base + from, dictionary.count - from, key, key.count) {
            var at = base.distance(to: UnsafeRawPointer(hit)) + key.count
            from = at
            guard at < dictionary.count, dictionary[at] == 0x20 || dictionary[at] == 0x0A || dictionary[at] == 0x0D else { continue }   // not /Length1
            while at < dictionary.count, dictionary[at] == 0x20 || dictionary[at] == 0x0A || dictionary[at] == 0x0D { at += 1 }
            var value = 0, digits = 0
            while at < dictionary.count, (0x30...0x39).contains(dictionary[at]), digits < 12 {
                value = value * 10 + Int(dictionary[at] - 0x30)
                digits += 1
                at += 1
            }
            guard digits > 0 else { return nil }
            var after = at
            while after < dictionary.count, dictionary[after] == 0x20 { after += 1 }
            if after < dictionary.count, (0x30...0x39).contains(dictionary[after]) { return nil }   // «12 0 R»
            return value
        }
        return nil
    }

    /// The numbers of «12 0 obj», given where «obj» starts.
    private static func objectNumber(_ bytes: UnsafeRawBufferPointer, at obj: Int) -> (Int, Int)? {
        var at = obj - 1
        func skipSpaces() { while at >= 0, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D { at -= 1 } }
        func number() -> Int? {
            var value = 0, place = 1, seen = 0
            while at >= 0, (0x30...0x39).contains(bytes[at]), seen < 10 {
                value += Int(bytes[at] - 0x30) * place
                place *= 10
                seen += 1
                at -= 1
            }
            return seen > 0 ? value : nil
        }
        skipSpaces()
        guard let generation = number() else { return nil }
        skipSpaces()
        guard let object = number() else { return nil }
        return (object, generation)
    }

    /// The filters of the stream whose dictionary is `dictionary`, decode order first, with their short names and any
    /// #xx in them resolved. A filter held in another object is looked for in the file's bytes.
    private static func filters(in dictionary: UnsafeRawBufferPointer, file: UnsafeRawBufferPointer) -> [String]? {
        let key = Array("/Filter".utf8)
        guard let base = dictionary.baseAddress, !dictionary.isEmpty,
              let hit = memmem(base, dictionary.count, key, key.count) else { return [] }
        var at = base.distance(to: UnsafeRawPointer(hit)) + key.count
        return parseFilters(dictionary, &at, file: file, depth: 0)
    }

    private static func parseFilters(_ text: UnsafeRawBufferPointer, _ at: inout Int, file: UnsafeRawBufferPointer, depth: Int) -> [String]? {
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0 }
        func skip() { while at < text.count, isSpace(text[at]) { at += 1 } }
        func name() -> String {
            at += 1   // the slash
            var bytes: [UInt8] = []
            while at < text.count, !isSpace(text[at]), !"/[]<>()".utf8.contains(text[at]) {
                if text[at] == 0x23, at + 2 < text.count,
                   let value = UInt8(String(decoding: [text[at + 1], text[at + 2]], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    at += 3
                } else {
                    bytes.append(text[at])
                    at += 1
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        func reference() -> [String]? {
            var digits: [UInt8] = []
            while at < text.count, (0x30...0x39).contains(text[at]) { digits.append(text[at]); at += 1 }
            skip()
            while at < text.count, (0x30...0x39).contains(text[at]) { at += 1 }
            skip()
            guard at < text.count, text[at] == 0x52, depth < 4 else { return nil }   // «R»
            at += 1
            let wanted = digits + Array(" 0 obj".utf8)
            guard let filebase = file.baseAddress else { return nil }
            var from = 0
            while from < file.count, let hit = memmem(filebase + from, file.count - from, wanted, wanted.count) {
                let found = filebase.distance(to: UnsafeRawPointer(hit))
                from = found + wanted.count
                if found > 0, (0x30...0x39).contains(file[found - 1]) { continue }   // 12 0 obj is not 2 0 obj
                let rest = UnsafeRawBufferPointer(rebasing: file[from..<min(file.count, from + 4096)])
                var inner = 0
                return parseFilters(rest, &inner, file: file, depth: depth + 1)
            }
            return nil   // in a compressed object: what it says can't be seen here
        }
        skip()
        guard at < text.count else { return [] }
        if text[at] == 0x2F { return [name()] }
        if (0x30...0x39).contains(text[at]) { return reference() }
        guard text[at] == 0x5B else { return [] }
        at += 1
        var all: [String] = []
        while true {
            skip()
            guard at < text.count else { return all }
            if text[at] == 0x5D { return all }
            if text[at] == 0x2F {
                all.append(name())
            } else if (0x30...0x39).contains(text[at]), let inner = reference() {
                all += inner
            } else {
                return nil
            }
        }
    }

    /// ASCII85: stops at its end mark or at the first thing that isn't part of it (an encrypted stream, say).
    private static func decodeA85(_ input: UnsafeRawBufferPointer) -> Data {
        var output = Data()
        output.reserveCapacity(input.count)
        var group: UInt32 = 0
        var count = 0
        for byte in input {
            switch byte {
            case 0x20, 0x0A, 0x0D, 0x09, 0x0C, 0: continue
            case 0x7E: break
            case 0x7A where count == 0:
                output.append(contentsOf: [0, 0, 0, 0])
                continue
            case 0x21...0x75:
                group = group &* 85 &+ UInt32(byte - 0x21)
                count += 1
                if count == 5 {
                    output.append(contentsOf: [UInt8(group >> 24), UInt8(group >> 16 & 255), UInt8(group >> 8 & 255), UInt8(group & 255)])
                    group = 0
                    count = 0
                }
                continue
            default: break
            }
            break
        }
        if count > 1 {
            for _ in count..<5 { group = group &* 85 &+ 84 }
            let last = [UInt8(group >> 24), UInt8(group >> 16 & 255), UInt8(group >> 8 & 255)]
            output.append(contentsOf: last.prefix(count - 1))
        }
        return output
    }

    private static func decodeHex(_ input: UnsafeRawBufferPointer) -> Data {
        var output = Data()
        output.reserveCapacity(input.count / 2)
        var high: UInt8?
        for byte in input {
            let value: UInt8
            switch byte {
            case 0x30...0x39: value = byte - 0x30
            case 0x41...0x46: value = byte - 0x41 + 10
            case 0x61...0x66: value = byte - 0x61 + 10
            case 0x20, 0x0A, 0x0D, 0x09, 0x0C, 0: continue
            default:
                if let high { output.append(high << 4) }
                return output
            }
            if let current = high { output.append(current << 4 | value); high = nil } else { high = value }
        }
        return output
    }

    /// PDF's LZW, a buffer at a time; `early` is /EarlyChange. `sink` returns false to stop.
    private static func inflateLZW(_ input: UnsafeRawBufferPointer, early: Int, sink: (UnsafeBufferPointer<UInt8>) throws -> Bool) rethrows {
        var prefix = [Int32](repeating: -1, count: 4096), suffix = [UInt8](repeating: 0, count: 4096), length = [Int32](repeating: 1, count: 4096)
        for i in 0..<256 { suffix[i] = UInt8(i) }
        var next = 258, width = 9, previous = -1
        var bits: UInt32 = 0, available = 0
        var out = [UInt8](repeating: 0, count: 1 << 16)
        var used = 0
        func flush() throws -> Bool {
            let more = try out.withUnsafeBufferPointer { try sink(UnsafeBufferPointer(rebasing: $0[0..<used])) }
            used = 0
            return more
        }
        for byte in input {
            bits = bits << 8 | UInt32(byte)
            available += 8
            guard available >= width else { continue }
            available -= width
            let code = Int(bits >> UInt32(available)) & ((1 << width) - 1)
            bits &= (1 << UInt32(available)) - 1
            if code == 257 { break }
            if code == 256 { next = 258; width = 9; previous = -1; continue }
            guard code < next || (code == next && previous >= 0) else { break }   // not LZW after all
            let isNew = code == next
            let entry = isNew ? previous : code
            let size = Int(length[entry]) + (isNew ? 1 : 0)
            if used + size > out.count {
                guard try flush() else { return }
                if size > out.count { return }
            }
            var position = used + Int(length[entry]) - 1, walk = entry
            while walk >= 0 {
                out[position] = suffix[walk]
                position -= 1
                walk = Int(prefix[walk])
            }
            let first = out[used]
            if isNew { out[used + size - 1] = first }
            used += size
            if previous >= 0, next < 4096 {
                prefix[next] = Int32(previous)
                suffix[next] = first
                length[next] = length[previous] + 1
                next += 1
            }
            previous = code
            if next + early >= 1 << width, width < 12 { width += 1 }
        }
        _ = try flush()
    }

    /// The longest run of operands with no operator after them. Only a real operator empties CoreGraphics's stack, not
    /// just any word or byte. Tokens with bytes that aren't text don't count: in an image or a font they are nearly all
    /// of them, and the few that look like text would take ≈ 750 MB of random bytes to reach the limit.
    private struct OperandRun {
        static let operators: Set<UInt32> = Set(["b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EI", "EMC", "ET", "EX",
            "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri", "s", "S", "SC", "sc", "SCN", "scn", "sh",
            "T*", "Tc", "Td", "TD", "Tf", "Tj", "TJ", "Tm", "Tr", "Ts", "Tw", "Tz", "TL", "v", "w", "W", "W*", "y", "'", "\""].map { $0.utf8.reduce(0) { $0 << 8 | UInt32($1) } })
        var run = 0
        var token: UInt32 = 0
        var length = 0
        var binary = false
        var previous: UInt8 = 0

        private mutating func endToken() {
            guard length > 0 else { return }
            if !binary {
                if length <= 3, Self.operators.contains(token) { run = 0 } else { run += 1 }
            }
            length = 0
            token = 0
            binary = false
        }

        mutating func feed(_ chunk: UnsafeBufferPointer<UInt8>) -> Bool {
            for byte in chunk {
                switch byte {
                case 0, 9, 10, 12, 13, 32:
                    endToken()
                case 0x28, 0x29, 0x2F, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x25:   // ( ) / < > [ ] { } %
                    endToken()
                    // Delimiters mostly say nothing here: what's between them is a token. But «()» has nothing between.
                    if (byte == 0x29 && previous == 0x28) || (byte == 0x5D && previous == 0x5B) || (byte == 0x3E && previous == 0x3C) { run += 1 }
                default:
                    if byte >= 0x80 || byte < 0x20 { binary = true }
                    if length < 4 { token = token << 8 | UInt32(byte) }
                    length += 1
                }
                previous = byte
                if run > maxOperandsInARow { return false }
            }
            return true
        }
    }

    private enum Outcome { case within, cancelled, tooMuch }

    /// What the scanner's callbacks share. They run on this thread, one scanner inside another for forms.
    private final class Scan {
        var outcome = Outcome.within
        var characters = 0
        var pageCharacters = 0
        var textOperators = 0
        var pageTextOperators = 0
        var operators = 0
        var formCalls = 0
        var depth = 0
        var perPage = false
        /// With `perPage`: text is also counted across the pages, up to `maxCharactersRewritten`.
        var wholeFile = false
        var largestStream = 0
        /// Current font: the bytes of one character, what ToUnicode makes of it, the operators of one Type 3 glyph.
        var font = Font()
        var fonts: [Int: Font] = [:]
        lazy var table = Scan.operatorTable()

        struct Font { var bytes = 1; var expansion = 1; var glyphOperators = 0 }

        func run(_ doc: CGPDFDocument) {
            guard doc.numberOfPages > 0 else { return }
            for i in 1...doc.numberOfPages where outcome == .within {
                if Task.isCancelled { outcome = .cancelled; return }
                guard let page = doc.page(at: i) else { continue }
                pageCharacters = 0
                pageTextOperators = 0
                if perPage {
                    if !wholeFile {
                        characters = 0
                        textOperators = 0
                    }
                    operators = 0
                    formCalls = 0
                }
                font = Font()
                let stream = CGPDFContentStreamCreateWithPage(page)
                scan(stream)
            }
        }

        func scan(_ stream: CGPDFContentStreamRef) {
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
        }

        /// Every operator. False once the scan should stop.
        func tick(_ scanner: CGPDFScannerRef) -> Bool {
            operators += 1
            if operators > PDFTextScan.maxOperators { outcome = .tooMuch }
            if operators & 4095 == 0, Task.isCancelled { outcome = .cancelled }
            if outcome != .within { CGPDFScannerStop(scanner); return false }
            return true
        }

        func show(_ string: CGPDFStringRef?, _ scanner: CGPDFScannerRef) {
            guard let string else { return }
            let glyphs = CGPDFStringGetLength(string) / font.bytes
            let shown = glyphs * font.expansion
            characters += shown
            pageCharacters += shown
            operators += glyphs * font.glyphOperators
            if characters > (wholeFile ? PDFTextScan.maxCharactersRewritten : PDFTextScan.maxCharacters) || pageCharacters > PDFTextScan.maxCharactersPerPage || operators > PDFTextScan.maxOperators {
                outcome = .tooMuch
                CGPDFScannerStop(scanner)
            }
        }

        func textOperator(_ scanner: CGPDFScannerRef) -> Bool {
            guard tick(scanner) else { return false }
            textOperators += 1
            pageTextOperators += 1
            if textOperators > PDFTextScan.maxTextOperators || pageTextOperators > PDFTextScan.maxTextOperatorsPerPage {
                outcome = .tooMuch
                CGPDFScannerStop(scanner)
                return false
            }
            return true
        }

        func setFont(_ scanner: CGPDFScannerRef) {
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name) else { font = Font(); return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { font = Font(); return }
            let key = unsafeBitCast(dictionary, to: Int.self)
            if let known = fonts[key] { font = known; return }
            fonts[key] = Font()   // a glyph may select its own font
            font = measure(dictionary, scanner)
            fonts[key] = font
        }

        private func measure(_ dictionary: CGPDFDictionaryRef, _ scanner: CGPDFScannerRef) -> Font {
            var result = Font()
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype {
                if strcmp(subtype, "Type0") == 0 { result.bytes = 2 }
                if strcmp(subtype, "Type3") == 0 { result.glyphOperators = glyphCost(dictionary, scanner) }
            }
            var map: CGPDFStreamRef?
            if !perPage, CGPDFDictionaryGetStream(dictionary, "ToUnicode", &map), let map {   // drawing doesn't use it
                if largestStream <= PDFTextScan.maxBytesToReadMaps, let expansion = expansion(of: map) {
                    result.expansion = expansion
                } else {
                    outcome = .tooMuch
                    CGPDFScannerStop(scanner)
                }
            }
            return result
        }

        /// The dearest glyph of a Type 3 font: each one is a little page, drawn every time the character is.
        private func glyphCost(_ dictionary: CGPDFDictionaryRef, _ scanner: CGPDFScannerRef) -> Int {
            var procedures: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "CharProcs", &procedures), let procedures else { return 0 }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let saved = font
            font = Font()
            var dearest = 0
            CGPDFDictionaryApplyBlock(procedures, { _, object, _ in
                var glyph: CGPDFStreamRef?
                guard self.outcome == .within, CGPDFObjectGetValue(object, .stream, &glyph), let glyph else { return self.outcome == .within }
                let before = self.operators
                self.nested(glyph, resources, scanner)
                dearest = max(dearest, self.operators - before)
                return self.outcome == .within
            }, nil)
            font = saved
            return dearest
        }

        /// What a ToUnicode map makes of one code, at worst: it may turn it into hundreds of characters.
        /// Ligatures and the like are up to 8; those count as one, or any font with an «ffi» would count threefold.
        /// The scanner can't read a map, which isn't a page's operators, and reading it means unpacking it all at once:
        /// up to 256 KB and one filter that is ≈ 260 MB at worst. A real map is well within that.
        private func expansion(of map: CGPDFStreamRef) -> Int? {
            let dictionary = CGPDFStreamGetDictionary(map)
            var length: CGPDFInteger = 0
            var filters: CGPDFArrayRef?
            if let dictionary {
                guard CGPDFDictionaryGetInteger(dictionary, "Length", &length), length <= 256_000 else { return nil }
                if CGPDFDictionaryGetArray(dictionary, "Filter", &filters), let filters, CGPDFArrayGetCount(filters) > 1 { return nil }
            }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(map, &format) as Data? else { return 1 }
            var longest = 0
            var run = 0
            for byte in data {
                let hex = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
                run = hex ? run + 1 : 0
                longest = max(longest, run)
            }
            let characters = longest / 4
            return characters <= 8 ? 1 : characters
        }

        func drawObject(_ scanner: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            var dictionary: CGPDFDictionaryRef?
            var form: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &form), let form else { return }
            dictionary = CGPDFStreamGetDictionary(form)
            guard let dictionary, CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, strcmp(subtype, "Form") == 0 else { return }
            formCalls += 1
            guard formCalls <= PDFTextScan.maxFormCalls else {
                outcome = .tooMuch
                CGPDFScannerStop(scanner)
                return
            }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let saved = font
            nested(form, resources, scanner)
            font = saved
            if outcome != .within { CGPDFScannerStop(scanner) }
        }

        private func nested(_ inner: CGPDFStreamRef, _ resources: CGPDFDictionaryRef?, _ scanner: CGPDFScannerRef) {
            guard depth < PDFTextScan.maxFormDepth else {
                outcome = .tooMuch
                return
            }
            depth += 1
            // Without resources of its own, the stream's dictionary has none to offer and lookups go on to the parent.
            scan(CGPDFContentStreamCreateWithStream(inner, resources ?? CGPDFStreamGetDictionary(inner)!, CGPDFScannerGetContentStream(scanner)))
            depth -= 1
        }

        private static func operatorTable() -> CGPDFOperatorTableRef {
            let table = CGPDFOperatorTableCreate()!
            // Callbacks can't capture: each one finds the scan again from `info`.
            let plain: CGPDFOperatorCallback = { scanner, info in
                _ = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue().tick(scanner)
            }
            for name in ["b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "DP", "EI", "EMC", "ET", "EX",
                         "f", "F", "f*", "G", "g", "gs", "h", "i", "j", "J", "K", "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri",
                         "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tm", "Tr", "Ts", "Tw", "Tz", "TL", "v", "w", "W", "W*", "y"] {
                CGPDFOperatorTableSetCallback(table, name, plain)
            }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
                if scan.tick(scanner) { scan.setFont(scanner) }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
                if scan.tick(scanner) { scan.drawObject(scanner) }
            }
            let showString: CGPDFOperatorCallback = { scanner, info in
                let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
                guard scan.textOperator(scanner) else { return }
                var string: CGPDFStringRef?
                if CGPDFScannerPopString(scanner, &string) { scan.show(string, scanner) }
            }
            for name in ["Tj", "'", "\""] { CGPDFOperatorTableSetCallback(table, name, showString) }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
                guard scan.textOperator(scanner) else { return }
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else { return }
                for i in 0..<CGPDFArrayGetCount(array) where scan.outcome == .within {
                    var string: CGPDFStringRef?
                    if CGPDFArrayGetString(array, i, &string) { scan.show(string, scanner) }
                }
            }
            return table
        }
    }
}

extension UnsafeRawBufferPointer {
    func occurrences(of text: String) -> Int {
        let word = Array(text.utf8)
        guard count >= word.count else { return 0 }
        return (0...(count - word.count)).reduce(0) { total, i in
            total + (self[i] == word[0] && word.indices.allSatisfy { self[i + $0] == word[$0] } ? 1 : 0)
        }
    }
}

extension PDFTextScan {
    private static let hiddenTextWarned = "didWarnPDFHiddenText"

    /// The first time a PDF's own text is read («Testo» → TXT, «Traduci»): the hidden text (white, tiny, covered)
    /// is read too and lands in the result. Asked once; without dialogs (command line, Shortcuts) it goes ahead.
    static func warnHiddenTextOnce() throws {
        guard Prompts.allowed, !UserDefaults.standard.bool(forKey: hiddenTextWarned) else { return }
        UserDefaults.standard.set(true, forKey: hiddenTextWarned)
        guard Notice.confirm(title: L("Anche il testo nascosto finisce nel risultato"),
                             text: L("Rondelle legge tutto il testo del PDF, anche quello bianco, minuscolo o coperto. Per oscurare davvero, trasforma la pagina in immagine e usa «Copri» in «Modifica»."),
                             button: L("Continua")) else { throw CancellationError() }
    }
}
