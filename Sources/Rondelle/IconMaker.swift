import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as an app icon: ICNS for the Mac, ICO for Windows and websites. Several sizes in one file, square, transparent
/// around a picture that isn't. Smaller sizes are made from the source; a size larger than it isn't made up.
enum IconMaker {
    private static let macSizes = [16, 32, 64, 128, 256, 512, 1024]
    private static let windowsSizes = [16, 24, 32, 48, 64, 128, 256]

    static func icns(_ url: URL) throws -> [URL] {
        let (image, sizes) = try source(url, sizes: macSizes)
        let out = FileNaming.output(for: url, ext: "icns")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, "com.apple.icns" as CFString, sizes.count, nil) else {
            throw OpError.unsupported("ICNS")
        }
        for side in sizes {
            try PDFOps.checkCancelled()
            guard let icon = square(image, side: side) else { throw OpError.failed(L("creazione dell'icona")) }
            CGImageDestinationAddImage(destination, icon, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw OpError.failed(L("creazione dell'icona")) }
        return [out]
    }

    /// PNG pictures in the ICO container, as Windows has read them since Vista: ImageIO would keep only one size.
    static func ico(_ url: URL) throws -> [URL] {
        let (image, sizes) = try source(url, sizes: windowsSizes)
        var pictures: [Data] = []
        for side in sizes {
            try PDFOps.checkCancelled()
            guard let icon = square(image, side: side), let data = png(icon) else { throw OpError.failed(L("creazione dell'icona")) }
            pictures.append(data)
        }
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8 & 255)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16(value >> 16) }
        var file = Data(le16(0) + le16(1) + le16(sizes.count))
        var offset = 6 + 16 * sizes.count
        for (side, picture) in zip(sizes, pictures) {
            let byte = UInt8(side >= 256 ? 0 : side)   // 0 means 256
            file.append(contentsOf: [byte, byte, 0, 0] + le16(1) + le16(32) + le32(picture.count) + le32(offset))
            offset += picture.count
        }
        pictures.forEach { file.append($0) }
        let out = FileNaming.output(for: url, ext: "ico")
        try file.write(to: out)
        return [out]
    }

    private static func source(_ url: URL, sizes: [Int]) throws -> (CGImage, [Int]) {
        let image = try ImageTools.load(url).image
        let long = max(image.width, image.height)
        let fitting = sizes.filter { $0 <= long }
        guard !fitting.isEmpty else { throw OpError.failed(L("immagine troppo piccola per un'icona (almeno %@ pixel)", sizes[0])) }
        return (image, fitting)
    }

    private static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let k = CGFloat(side) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * k, height = CGFloat(image.height) * k
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// SHA-256 of files, to the clipboard: the fingerprint that tells whether a file is the one it should be.
enum Checksum {
    /// Read a piece at a time, so a large file takes one buffer and «Annulla» works.
    static func sha256(_ url: URL) throws -> String {
        let handle = try SafeFile.openForReading(url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try PDFOps.checkCancelled()
            let more = try autoreleasepool { () -> Bool in
                guard let piece = try handle.read(upToCount: 4_000_000), !piece.isEmpty else { return false }
                hash.update(data: piece)
                return true
            }
            if !more { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One file: the fingerprint alone. Several: one line each, «fingerprint  name», as `shasum` prints them.
    static func text(_ urls: [URL]) throws -> String {
        let files = FileNaming.sortedNaturally(urls)
        if files.count == 1 { return try sha256(files[0]) }
        return try files.map { "\(try sha256($0))  \($0.lastPathComponent)" }.joined(separator: "\n")
    }

    static func copy(_ urls: [URL]) async throws -> [URL] {
        let text = try text(urls)
        await MainActor.run { Clipboard.copyLocally(text) }
        return []
    }
}
