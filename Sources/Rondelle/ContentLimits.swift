import Compression
import Foundation

/// What a file's size doesn't say: how much it unpacks to, and how much markup its importer will have to build.
/// Each of these is read from the file itself, never from what the file declares about its own contents.
enum ContentLimits {
    /// XML unpacked from one DOCX or ODT: importing takes ≈ 8–12 bytes per byte, so ≈ 400 MB at this size.
    /// Parts that barely compress (pictures) don't count: the 10 MB limit on the file already bounds them.
    static let maxPackedXML = 30_000_000
    static let barelyCompressedRatio = 3
    /// WebKit's importer builds ≈ 6–17 KB per element of a web archive: ≈ 430 MB at this count.
    static let maxWebArchiveElements = 25_000
    /// Plain HTML takes little memory but ≈ 30 µs per element, on the main thread: ≈ 3 s at this count.
    static let maxHTMLElements = 100_000
    /// Each table cell of an RTF takes ≈ 0.8 KB: ≈ 400 MB at this count.
    static let maxRTFCells = 500_000

    /// The checks for a document about to be imported. A file that can't be read is left to the importer, which says so.
    static func check(_ url: URL) throws {
        let tooComplex = OpError.unsupported(L("«%@» è troppo complesso da elaborare", url.lastPathComponent))
        switch url.pathExtension.lowercased() {
        case "docx", "odt":
            guard let data = mapped(url) else { return }
            if try packedXML(data) > maxPackedXML { throw tooComplex }
        case "html", "htm":
            guard let data = mapped(url) else { return }
            if elements(in: data) > maxHTMLElements { throw tooComplex }
        case "webarchive":
            guard let data = mapped(url) else { return }
            if webArchiveElements(data) > maxWebArchiveElements { throw tooComplex }
        case "rtf", "doc":
            guard let data = mapped(url) else { return }
            if rtfCells(data) > maxRTFCells { throw tooComplex }
            // The importer goes by what's inside: HTML named .doc takes the same time as HTML.
            if data.prefix(4096).contains(0x3C), elements(in: data) > maxHTMLElements, data.first != 0x7B { throw tooComplex }
        case "rtfd":
            guard let data = mapped(url.appendingPathComponent("TXT.rtf")) else { return }
            if rtfCells(data) > maxRTFCells { throw tooComplex }
        default:
            return
        }
    }

    /// Only regular files get here: `SafeFile` has already refused the rest.
    static func mapped(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: .alwaysMapped)
    }

    // MARK: Packed documents

    /// Bytes unpacked from the parts of a ZIP that compress like text. Stops soon after the limit.
    static func packedXML(_ data: Data) throws -> Int {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
            func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
            // End of central directory: in the last 64 KB, read backwards.
            guard bytes.count >= 22 else { return 0 }
            var end = bytes.count - 22
            let lowest = max(0, bytes.count - 22 - 65_535)
            while end >= lowest, u32(end) != 0x0605_4B50 { end -= 1 }
            guard end >= lowest else { return 0 }
            var entry = u32(end + 16)
            var total = 0
            for _ in 0..<u16(end + 10) {
                guard entry >= 0, entry + 46 <= bytes.count, u32(entry) == 0x0201_4B50 else { break }
                let method = u16(entry + 10)
                let packed = u32(entry + 20)
                let local = u32(entry + 42)
                entry += 46 + u16(entry + 28) + u16(entry + 30) + u16(entry + 32)
                guard local + 30 <= bytes.count, u32(local) == 0x0403_4B50 else { continue }
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                guard start < bytes.count else { continue }
                var size = 0
                switch method {
                case 8:
                    let input = UnsafeRawBufferPointer(rebasing: bytes[start...])
                    _ = try inflate(input) { chunk in
                        size += chunk.count
                        return total + size <= maxPackedXML
                    }
                case 0:
                    size = 0   // stored: never larger than the file, whose size is limited
                default:
                    continue
                }
                if size > packed * barelyCompressedRatio { total += size }
                if total > maxPackedXML { return total }
            }
            return total
        }
    }

    /// Unpacks raw deflate data from the start of `input`, handing over each chunk; `consume` returns false to stop.
    /// Returns the input bytes used. Nothing is kept, so the memory taken is one buffer however much comes out.
    @discardableResult
    static func inflate(_ input: UnsafeRawBufferPointer, consume: (UnsafeBufferPointer<UInt8>) throws -> Bool) throws -> Int {
        guard let base = input.bindMemory(to: UInt8.self).baseAddress, !input.isEmpty else { return 0 }
        let capacity = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let holder = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { holder.deallocate() }
        guard compression_stream_init(holder, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return 0 }
        defer { compression_stream_destroy(holder) }
        holder.pointee.src_ptr = base
        holder.pointee.src_size = input.count
        while true {
            if Task.isCancelled { throw CancellationError() }
            holder.pointee.dst_ptr = buffer
            holder.pointee.dst_size = capacity
            let status = compression_stream_process(holder, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = capacity - holder.pointee.dst_size
            if produced > 0, try !consume(UnsafeBufferPointer(start: buffer, count: produced)) { break }
            if status != COMPRESSION_STATUS_OK { break }   // the end of the data, or data that isn't deflate
            if produced == 0, holder.pointee.src_size == 0 { break }
        }
        return input.count - holder.pointee.src_size
    }

    // MARK: Markup

    /// Elements in HTML: each «<» followed by a letter. Text containing that counts too, which only errs on the safe side.
    static func elements(in data: Data) -> Int {
        var count = 0
        var previousOpen = false
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                if previousOpen, (byte | 0x20) >= 0x61, (byte | 0x20) <= 0x7A { count += 1 }
                previousOpen = byte == 0x3C
            }
        }
        return count
    }

    /// Elements in every piece of markup of a web archive: the main page, its frames, what they include.
    static func webArchiveElements(_ data: Data) -> Int {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return 0 }
        func resource(_ item: Any?) -> Int {
            guard let item = item as? [String: Any], let body = item["WebResourceData"] as? Data else { return 0 }
            let type = (item["WebResourceMIMEType"] as? String ?? "").lowercased()
            return type.contains("html") || type.contains("xml") || type.contains("svg") ? elements(in: body) : 0
        }
        func walk(_ archive: [String: Any], depth: Int) -> Int {
            guard depth < 8 else { return maxWebArchiveElements + 1 }
            var count = resource(archive["WebMainResource"])
            for item in archive["WebSubresources"] as? [Any] ?? [] { count += resource(item) }
            for frame in archive["WebSubframeArchives"] as? [[String: Any]] ?? [] { count += walk(frame, depth: depth + 1) }
            return count
        }
        return walk(archive, depth: 0)
    }

    /// Table cells of an RTF, nested ones included. Other files named .doc aren't RTF and count nothing.
    static func rtfCells(_ data: Data) -> Int {
        guard data.starts(with: Data("{\\rtf".utf8)) else { return 0 }
        var count = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            // «\cell» and «\nestcell»: both end in «cell», after a backslash or «\nest».
            let word = Array("cell".utf8)
            guard bytes.count > 5 else { return }
            for i in 1..<(bytes.count - 4) where bytes[i] == word[0] {
                guard bytes[i + 1] == word[1], bytes[i + 2] == word[2], bytes[i + 3] == word[3] else { continue }
                if (bytes[i + 4] | 0x20) >= 0x61, (bytes[i + 4] | 0x20) <= 0x7A { continue }   // «\\cellx»: a column, not a cell
                if bytes[i - 1] == 0x5C || (i >= 5 && bytes[i - 1] == 0x74 && bytes[i - 5] == 0x5C && bytes[i - 4] == 0x6E) { count += 1 }
            }
        }
        return count
    }
}
