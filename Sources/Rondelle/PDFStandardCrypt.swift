import CommonCrypto
import Foundation

/// N2: what the Standard security handler needs to read a stream of an encrypted PDF (RC4, AES-128, AES-256), so that
/// `PDFTextScan` can look inside it before CoreGraphics does. Only reads: nothing here protects or changes a file.
struct PDFStandardCrypt {
    private enum Method { case rc4, aes128, aes256, none }
    private let key: Data
    private let method: Method
    private let metadataInClear: Bool
    /// The /Encrypt dictionary, to look up a crypt filter a stream names for itself.
    private let dictionary: Data

    private static let padding = Data([0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
                                       0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A])

    /// nil: no handler this code understands, or the password doesn't open the file.
    init?(file: UnsafeRawBufferPointer, password: String?) {
        guard let region = Self.encryptDictionary(in: file), region.string("/Filter", name: true) == "Standard",
              let v = region.integer("/V"), let r = region.integer("/R"),
              let o = region.string8("/O"), let u = region.string8("/U") else { return nil }
        let inClear = region.keyword("/EncryptMetadata") == "false"
        metadataInClear = inClear
        let text = password ?? ""
        dictionary = Data(region.bytes)

        switch v {
        case 1, 2, 3: method = .rc4
        case 4, 5:
            guard let name = region.string("/StmF", name: true), let found = Self.method(named: name, in: region) else { return nil }
            method = found
        default: return nil
        }

        if r >= 5 {
            guard u.count >= 48, o.count >= 48, let ue = region.string8("/UE"), let oe = region.string8("/OE"),
                  ue.count >= 32, oe.count >= 32 else { return nil }
            let word = Data(text.utf8.prefix(127))
            let hash = { (salt: Data, extra: Data) in r == 5 ? Self.sha256(word + salt + extra) : Self.hash2B(word, salt: salt, extra: extra) }
            let userEntry = u.prefix(48)
            if hash(u.subdata(in: 32..<40), Data()) == u.prefix(32) {
                guard let file = Self.aes(hash(u.subdata(in: 40..<48), Data()), iv: Data(count: 16), ue.prefix(32), encrypt: false) else { return nil }
                key = file
            } else if hash(o.subdata(in: 32..<40), userEntry) == o.prefix(32) {
                guard let file = Self.aes(hash(o.subdata(in: 40..<48), userEntry), iv: Data(count: 16), oe.prefix(32), encrypt: false) else { return nil }
                key = file
            } else {
                return nil
            }
            return
        }

        guard o.count >= 32, u.count >= 16, let p = region.integer("/P") else { return nil }
        let bits = v == 1 ? 40 : v == 4 ? 128 : (region.integer("/Length") ?? 40)
        let bytes = r == 2 ? 5 : min(16, max(5, bits / 8))
        // T1: the /ID is taken from a few candidates, the trailer first; the right one is the one that opens the file.
        let ids = Self.idCandidates(in: file)
        let derive = { (word: Data, id: Data) -> Data in
            var input = (word + Self.padding).prefix(32) + o.prefix(32)
            let value = UInt32(truncatingIfNeeded: p)
            input.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8 & 255), UInt8(value >> 16 & 255), UInt8(value >> 24)])
            input.append(id)
            if r >= 4, inClear { input.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) }
            var digest = Self.md5(input)
            if r >= 3 { for _ in 0..<50 { digest = Self.md5(digest.prefix(bytes)) } }
            return Data(digest.prefix(bytes))
        }
        let opens = { (candidate: Data, id: Data) -> Bool in
            if r == 2 { return Self.rc4(candidate, Self.padding) == u.prefix(32) }
            var value = Self.rc4(candidate, Self.md5(Self.padding + id))
            for round in 1...19 { value = Self.rc4(Data(candidate.map { $0 ^ UInt8(round) }), value) }
            return value.prefix(16) == u.prefix(16)
        }
        let word = Data(text.utf8)
        for id in ids {
            let asUser = derive(word, id)
            if opens(asUser, id) {
                key = asUser
                return
            }
        }
        // The owner's password holds the user's, encrypted.
        var digest = Self.md5((word + Self.padding).prefix(32))
        if r >= 3 { for _ in 0..<50 { digest = Self.md5(digest) } }
        let ownerKey = Data(digest.prefix(bytes))
        var user = o.prefix(32)
        if r == 2 {
            user = Self.rc4(ownerKey, user)
        } else {
            for round in stride(from: 19, through: 0, by: -1) { user = Self.rc4(Data(ownerKey.map { $0 ^ UInt8(round) }), user) }
        }
        guard let asOwner = ids.lazy.map({ (derive(Data(user), $0), $0) }).first(where: { opens($0.0, $0.1) })?.0 else { return nil }
        key = asOwner
    }

    /// The bytes of a stream, as they were before encryption. XRef streams, and metadata when the file says so, never are.
    func decrypt(_ raw: UnsafeRawBufferPointer, object: Int, generation: Int, dictionary: UnsafeRawBufferPointer) -> Data {
        if method == .none || dictionary.occurrences(of: "/XRef") > 0 || (metadataInClear && dictionary.occurrences(of: "/Metadata") > 0) {
            return Data(raw)
        }
        if method == .aes256 { return Self.aesStream(key, raw) }
        var material = key
        material.append(contentsOf: [UInt8(object & 255), UInt8(object >> 8 & 255), UInt8(object >> 16 & 255),
                                     UInt8(generation & 255), UInt8(generation >> 8 & 255)])
        if method == .aes128 { material.append(contentsOf: Array("sAlT".utf8)) }
        let objectKey = Data(Self.md5(material).prefix(min(key.count + 5, 16)))
        return method == .rc4 ? Self.rc4(objectKey, raw) : Self.aesStream(objectKey, raw)
    }

    /// The cipher of a crypt filter, by name: Identity, or one in /CF (nil for one this code doesn't know).
    private static func method(named name: String, in region: Region) -> Method? {
        if name == "Identity" { return Method.none }
        guard let filters = region.after("/CF"), let filter = filters.after("/" + name),
              let kind = filter.string("/CFM", name: true) else { return nil }
        switch kind {
        case "V2": return .rc4
        case "AESV2": return .aes128
        case "AESV3": return .aes256
        case "None": return Method.none
        default: return nil
        }
    }

    /// P1: a stream with a /Crypt filter of its own (its /Name in /DecodeParms; none means Identity). The Standard
    /// handler has one key for all, so only the cipher matters: true if the stream is in clear, false if it is
    /// encrypted like the others, nil if its cipher is another one.
    func streamInClear(_ stream: UnsafeRawBufferPointer) -> Bool? {
        let name = Region(stream).string("/Name", name: true) ?? "Identity"
        let own = dictionary.withUnsafeBytes { Self.method(named: name, in: Region($0)) }
        if own == Method.none { return true }
        return own == method ? false : nil
    }

    // MARK: Reading the file

    private static func encryptDictionary(in file: UnsafeRawBufferPointer) -> Region? {
        guard let base = file.baseAddress else { return nil }
        let word = Array("/Encrypt".utf8)
        var from = 0
        var last: Int?
        while from < file.count, let hit = memmem(base + from, file.count - from, word, word.count) {
            let at = base.distance(to: UnsafeRawPointer(hit))
            from = at + word.count
            if from < file.count, !Region.isRegular(file[from]) { last = from }
        }
        guard var at = last else { return nil }
        while at < file.count, !Region.isRegular(file[at]), file[at] != 0x3C { at += 1 }
        guard at < file.count else { return nil }
        if file[at] == 0x3C { return Region(UnsafeRawBufferPointer(rebasing: file[at..<min(file.count, at + 16_000)])) }
        var digits: [UInt8] = []
        while at < file.count, (0x30...0x39).contains(file[at]), digits.count < 10 { digits.append(file[at]); at += 1 }
        guard !digits.isEmpty else { return nil }
        let wanted = digits + Array(" 0 obj".utf8)
        from = 0
        while from < file.count, let hit = memmem(base + from, file.count - from, wanted, wanted.count) {
            let found = base.distance(to: UnsafeRawPointer(hit))
            from = found + wanted.count
            if found > 0, (0x30...0x39).contains(file[found - 1]) { continue }
            return Region(UnsafeRawBufferPointer(rebasing: file[from..<min(file.count, from + 16_000)]))
        }
        return nil
    }

    /// At most 16 values of /ID, the likeliest first: the trailer that startxref points to (a table or an xref stream),
    /// then the last «/ID [» in the file. A file full of «/ID [» costs one pass, not one reading for each.
    /// Empty if the job is cancelled; just an empty ID if there is none.
    private static func idCandidates(in file: UnsafeRawBufferPointer) -> [Data] {
        guard let base = file.baseAddress else { return [Data()] }
        var found: [Data] = []
        func add(_ id: Data?) { if let id, !found.contains(id), found.count < 16 { found.append(id) } }
        func value(at start: Int) -> Data? {
            // «/ID», spaces, «[», then the first string of the array.
            var at = start
            while at < file.count, at < start + 16, !Region.isRegular(file[at]), file[at] != 0x5B { at += 1 }
            guard at < file.count, file[at] == 0x5B else { return nil }
            return Region(UnsafeRawBufferPointer(rebasing: file[(at + 1)..<min(file.count, at + 600)])).stringValue(at: 0)
        }
        // The trailer: the last «startxref» in the final 64 KB, and the offset written after it.
        let word = Array("startxref".utf8), tail = max(0, file.count - 65_536)
        var from = tail, last: Int?
        while from < file.count, let hit = memmem(base + from, file.count - from, word, word.count) {
            last = base.distance(to: UnsafeRawPointer(hit)) + word.count
            from = last!
        }
        if let last {
            var at = last, offset = 0, digits = 0
            while at < file.count, !Region.isRegular(file[at]) { at += 1 }
            while at < file.count, (0x30...0x39).contains(file[at]), digits < 12 { offset = offset * 10 + Int(file[at] - 0x30); digits += 1; at += 1 }
            if digits > 0, offset < file.count {
                var dictionary = offset
                let table = Array("xref".utf8), trailer = Array("trailer".utf8)
                if file.count - offset >= 4, memcmp(base + offset, table, 4) == 0,
                   let hit = memmem(base + offset, file.count - offset, trailer, trailer.count) {
                    dictionary = base.distance(to: UnsafeRawPointer(hit)) + trailer.count
                }
                let region = Region(UnsafeRawBufferPointer(rebasing: file[dictionary..<min(file.count, dictionary + 4096)]))
                if let after = region.after("/ID"), let id = after.bytes.baseAddress.flatMap({ start -> Data? in
                    value(at: base.distance(to: start))
                }) { add(id) }
            }
        }
        // The last 15 «/ID» of the file, in one pass that only remembers where they are.
        let key = Array("/ID".utf8)
        var recent: [Int] = []
        var checked = 0
        from = 0
        while from < file.count, let hit = memmem(base + from, file.count - from, key, key.count) {
            let at = base.distance(to: UnsafeRawPointer(hit)) + key.count
            from = at
            if at - checked >= 65_536 {
                checked = at
                if Task.isCancelled { return [] }
            }
            guard at < file.count, !Region.isRegular(file[at]) else { continue }
            recent.append(at)
            if recent.count > 15 { recent.removeFirst(recent.count - 15) }
        }
        for at in recent.reversed() { add(value(at: at)) }
        return found.isEmpty ? [Data()] : found
    }

    /// A piece of the file holding a dictionary: enough of a reader for the handful of keys used here.
    private struct Region {
        let bytes: UnsafeRawBufferPointer
        init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        static func isRegular(_ c: UInt8) -> Bool {
            !(c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 || "/[]<>()%{}".utf8.contains(c))
        }

        private func offset(_ key: String) -> Int? {
            let word = Array(key.utf8)
            guard let base = bytes.baseAddress else { return nil }
            var from = 0
            while from < bytes.count, let hit = memmem(base + from, bytes.count - from, word, word.count) {
                let at = base.distance(to: UnsafeRawPointer(hit)) + word.count
                if at >= bytes.count || !Self.isRegular(bytes[at]) { return at }
                from = at
            }
            return nil
        }

        func after(_ key: String) -> Region? {
            offset(key).map { Region(UnsafeRawBufferPointer(rebasing: bytes[$0...])) }
        }

        private func skip(_ start: Int) -> Int {
            var at = start
            while at < bytes.count, bytes[at] == 0 || bytes[at] == 9 || bytes[at] == 10 || bytes[at] == 12 || bytes[at] == 13 || bytes[at] == 32 { at += 1 }
            return at
        }

        func integer(_ key: String) -> Int? {
            guard let start = offset(key) else { return nil }
            var at = skip(start), negative = false, value = 0, seen = false
            if at < bytes.count, bytes[at] == 0x2D { negative = true; at += 1 }
            while at < bytes.count, (0x30...0x39).contains(bytes[at]), value < 1 << 40 {
                value = value * 10 + Int(bytes[at] - 0x30)
                seen = true
                at += 1
            }
            return seen ? (negative ? -value : value) : nil
        }

        func keyword(_ key: String) -> String? {
            guard let start = offset(key) else { return nil }
            var at = skip(start)
            var word: [UInt8] = []
            while at < bytes.count, Self.isRegular(bytes[at]) { word.append(bytes[at]); at += 1 }
            return String(decoding: word, as: UTF8.self)
        }

        func string(_ key: String, name: Bool) -> String? {
            guard let start = offset(key) else { return nil }
            var at = skip(start)
            guard at < bytes.count, bytes[at] == 0x2F else { return nil }
            at += 1
            var word: [UInt8] = []
            while at < bytes.count, Self.isRegular(bytes[at]) { word.append(bytes[at]); at += 1 }
            return String(decoding: word, as: UTF8.self)
        }

        func string8(_ key: String) -> Data? {
            offset(key).flatMap { stringValue(at: $0) }
        }

        func stringValue(at start: Int) -> Data? {
            var at = skip(start)
            guard at < bytes.count else { return nil }
            var out = Data()
            if bytes[at] == 0x3C {
                at += 1
                var high: UInt8?
                while at < bytes.count, bytes[at] != 0x3E {
                    let c = bytes[at]
                    let digit: UInt8? = (0x30...0x39).contains(c) ? c - 0x30 : (0x41...0x46).contains(c) ? c - 0x37
                        : (0x61...0x66).contains(c) ? c - 0x57 : nil
                    if let digit {
                        if let current = high { out.append(current << 4 | digit); high = nil } else { high = digit }
                    }
                    at += 1
                }
                if let high { out.append(high << 4) }
                return out
            }
            guard bytes[at] == 0x28 else { return nil }
            at += 1
            var depth = 1
            while at < bytes.count {
                let c = bytes[at]
                at += 1
                switch c {
                case 0x5C:
                    guard at < bytes.count else { return out }
                    let next = bytes[at]
                    at += 1
                    switch next {
                    case 0x6E: out.append(10)
                    case 0x72: out.append(13)
                    case 0x74: out.append(9)
                    case 0x62: out.append(8)
                    case 0x66: out.append(12)
                    case 0x0A: break
                    case 0x0D: if at < bytes.count, bytes[at] == 0x0A { at += 1 }
                    case 0x30...0x37:
                        var value = Int(next - 0x30), digits = 1
                        while digits < 3, at < bytes.count, (0x30...0x37).contains(bytes[at]) {
                            value = value * 8 + Int(bytes[at] - 0x30)
                            at += 1
                            digits += 1
                        }
                        out.append(UInt8(value & 255))
                    default: out.append(next)
                    }
                case 0x28: depth += 1; out.append(c)
                case 0x29:
                    depth -= 1
                    if depth == 0 { return out }
                    out.append(c)
                default: out.append(c)
                }
            }
            return out
        }
    }

    // MARK: Primitives

    private static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    private static func sha384(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA384($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    private static func sha512(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    private static func rc4(_ key: Data, _ data: Data) -> Data {
        data.withUnsafeBytes { rc4(key, $0) }
    }

    private static func rc4(_ key: Data, _ data: UnsafeRawBufferPointer) -> Data {
        crypt(CCAlgorithm(kCCAlgorithmRC4), options: 0, key: key, iv: nil, data, operation: CCOperation(kCCDecrypt)) ?? Data()
    }

    /// CBC without padding: the check on streams doesn't mind the padding left at the end.
    private static func aes(_ key: Data, iv: Data, _ data: Data, encrypt: Bool) -> Data? {
        data.withUnsafeBytes {
            crypt(CCAlgorithm(kCCAlgorithmAES), options: 0, key: key, iv: iv, $0, operation: CCOperation(encrypt ? kCCEncrypt : kCCDecrypt))
        }
    }

    private static func aesStream(_ key: Data, _ raw: UnsafeRawBufferPointer) -> Data {
        guard raw.count >= 32 else { return Data() }
        let blocks = (raw.count - 16) / 16 * 16
        return crypt(CCAlgorithm(kCCAlgorithmAES), options: 0, key: key, iv: Data(raw[0..<16]),
                     UnsafeRawBufferPointer(rebasing: raw[16..<(16 + blocks)]), operation: CCOperation(kCCDecrypt)) ?? Data()
    }

    private static func crypt(_ algorithm: CCAlgorithm, options: CCOptions, key: Data, iv: Data?, _ input: UnsafeRawBufferPointer, operation: CCOperation) -> Data? {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { k in
                (iv ?? Data()).withUnsafeBytes { v in
                    CCCrypt(operation, algorithm, options, k.baseAddress, key.count, iv == nil ? nil : v.baseAddress,
                            input.baseAddress, input.count, out.baseAddress, capacity, &written)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        output.count = written
        return output
    }

    /// Revision 6: the hash of ISO 32000-2, algorithm 2.B.
    private static func hash2B(_ word: Data, salt: Data, extra: Data) -> Data {
        var k = sha256(word + salt + extra)
        var round = 0
        while true {
            var block = Data(capacity: (word.count + k.count + extra.count) * 64)
            let once = word + k + extra
            for _ in 0..<64 { block.append(once) }
            guard let e = aes(Data(k.prefix(16)), iv: Data(k.subdata(in: 16..<32)), block, encrypt: true) else { return Data(k.prefix(32)) }
            let remainder = e.prefix(16).reduce(0) { $0 + Int($1) } % 3
            k = remainder == 0 ? sha256(e) : remainder == 1 ? sha384(e) : sha512(e)
            round += 1
            if round >= 64, Int(e[e.count - 1]) <= round - 32 { break }
        }
        return Data(k.prefix(32))
    }
}
