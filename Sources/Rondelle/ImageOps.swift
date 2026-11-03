import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageOps {
    /// What ImageIO can write on this Mac, plus WebP through the bundled libwebp.
    static let writableTypes: Set<String> =
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).union([UTType.webP.identifier])

    /// WebP goes through libwebp unless ImageIO learns to write it.
    static func needsWebPEncoder(_ type: UTType) -> Bool {
        type.conforms(to: .webP) && !((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(UTType.webP.identifier)
    }

    /// Output formats offered on the convert wheel, filtered by what ImageIO can write on this Mac.
    static let targets: [(name: String, type: UTType)] = [
        ("JPG", .jpeg), ("PNG", .png), ("HEIC", .heic), ("WebP", .webP),
        ("TIFF", .tiff), ("GIF", .gif), ("BMP", .bmp),
    ].filter { writableTypes.contains($0.1.identifier) }

    /// Re-encodes an image, optionally converting format, resizing and stripping metadata.
    /// The format a tool writes when it keeps the source's: the same if it can be written, JPG for a camera RAW
    /// (a photo, which as PNG would be several times larger), otherwise PNG.
    static func keptType(_ source: UTType?) -> UTType {
        guard let source else { return .png }
        if writableTypes.contains(source.identifier) { return source }
        return source.conforms(to: .rawImage) ? .jpeg : .png
    }

    /// - Parameters:
    ///   - type: output format; nil keeps the source format.
    ///   - maxPixel: longest side in pixels (never upscales).
    ///   - scale: factor applied to the longest side.
    static func process(_ url: URL, to type: UTType? = nil, maxPixel: Int? = nil, scale: CGFloat? = nil,
                        quality: CGFloat = 0.9, stripMetadata: Bool = false, suffix: String? = nil) throws -> [URL] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw OpError.unreadable(url) }

        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        var outType = type ?? keptType(sourceType)
        if !writableTypes.contains(outType.identifier) { outType = .png }
        guard let ext = fileExtension(for: outType) else { throw OpError.unsupported(outType.identifier) }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        try checkPixelCount(width: width, height: height, url: url)
        var longest = max(width, height, 1)
        if let scale { longest = Int(CGFloat(longest) * scale) }
        if let maxPixel { longest = min(longest, maxPixel) }

        // Full size into a format that stores the EXIF orientation: the image is decoded piece by piece while
        // it is encoded (one copy of the pixels in memory instead of three) and the rotation stays a tag.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let keepsOrientation = [UTType.jpeg, .heic, .tiff].contains { outType.conforms(to: $0) } || needsWebPEncoder(outType)
        let needsFlatten = (props[kCGImagePropertyHasAlpha] as? Bool ?? false) && !supportsAlpha(outType)
        if longest >= max(width, height), !needsFlatten, orientation == 1 || keepsOrientation,
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
            var kept = props
            kept.removeValue(forKey: kCGImagePropertyPixelWidth)
            kept.removeValue(forKey: kCGImagePropertyPixelHeight)
            let out = FileNaming.output(for: url, ext: ext, suffix: suffix)
            try write(image, to: out, type: outType, quality: quality,
                      properties: stripMetadata ? [kCGImagePropertyOrientation: orientation] : kept)
            return [out]
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longest, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OpError.unreadable(url)
        }
        if !supportsAlpha(outType), hasAlpha(image), let flat = flatten(image) { image = flat }

        let out = FileNaming.output(for: url, ext: ext, suffix: suffix)
        try write(image, to: out, type: outType, quality: quality,
                  properties: stripMetadata ? [:] : orientedProperties(props))
        return [out]
    }

    /// Pixel-bomb check on every image in the file (a multi-page TIFF can hide a huge page after a tiny one).
    static func checkPixelCount(of url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw OpError.unreadable(url)
        }
        for index in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            try checkPixelCount(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                height: props[kCGImagePropertyPixelHeight] as? Int ?? 0, url: url)
        }
    }

    /// The first image, upright, as a page-sized NSImage (points from the file's DPI), decoded only after
    /// `checkPixelCount(of:)`: a PDF page is built from exactly the image that was checked.
    static func verifiedPageImage(_ url: URL) throws -> NSImage {
        try checkPixelCount(of: url)
        var (image, type, props) = try ImageTools.load(url)
        // PDFKit embeds a JPEG as it is, EXIF, GPS and XMP included: give it a fresh copy without them (0.8.2-G1).
        if type.conforms(to: .jpeg) { image = try reencodedWithoutMetadata(image, url) }
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return NSImage(cgImage: image, size: NSSize(width: Double(image.width) * 72 / dpi,
                                                    height: Double(image.height) * 72 / dpi))
    }

    /// The same pixels as a new high-quality JPEG with only its colour profile: no EXIF, GPS, IPTC or XMP.
    private static func reencodedWithoutMetadata(_ image: CGImage, _ url: URL) throws -> CGImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw OpError.unreadable(url) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let source = CGImageSourceCreateWithData(data, nil),
              let clean = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw OpError.unreadable(url) }
        return clean
    }

    /// IPTC fields that name the place: with the GPS they are where the photo was taken (0.8.2-G2).
    static let iptcLocationKeys = [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCSubLocation,
                                   kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode]

    /// `props` without the position: the GPS dictionary (coordinates, area, processing method, destination) and the
    /// IPTC place fields; XMP is only written from these dictionaries. Date, camera and author stay.
    static func withoutLocation(_ props: [CFString: Any]) -> [CFString: Any] {
        var p = props
        p.removeValue(forKey: kCGImagePropertyGPSDictionary)
        if var iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in iptcLocationKeys { iptc.removeValue(forKey: key) }
            p[kCGImagePropertyIPTCDictionary] = iptc
        }
        return p
    }

    /// XMP properties that hold a place or coordinates, nested structures included.
    private static let xmpLocationTags: [String: Set<String>] = [
        "http://ns.adobe.com/photoshop/1.0/": ["City", "State", "Country"],
        "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/": ["Location", "CountryCode"],
        "http://iptc.org/std/Iptc4xmpExt/2008-02-29/": ["LocationCreated", "LocationShown"],
    ]

    /// Whether the image carries a position anywhere a byte-for-byte copy would keep it: GPS, IPTC place, XMP.
    static func hasLocation(_ source: CGImageSource, _ props: [CFString: Any]) -> Bool {
        if props[kCGImagePropertyGPSDictionary] != nil { return true }
        if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any], iptcLocationKeys.contains(where: { iptc[$0] != nil }) { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return false }
        return tags.contains { tag in
            let ns = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            return xmpLocationTags[ns]?.contains(name) == true || (ns == "http://ns.adobe.com/exif/1.0/" && name.hasPrefix("GPS"))
        }
    }

    private static var auxiliaryTypes: [CFString] {
        var types = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                     kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeHDRGainMap,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
                     kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte]
        if #available(macOS 15, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return types
    }

    /// Whether a byte-for-byte copy would carry more than the picture: auxiliary images, or for a JPEG a second
    /// image anywhere in the file (EXIF thumbnail, MPF) or bytes after its end.
    static func hasHiddenExtras(_ source: CGImageSource, _ url: URL) -> Bool {
        if auxiliaryTypes.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }) { return true }
        guard let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .jpeg) == true else { return false }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return true }
        let start = Data([0xFF, 0xD8, 0xFF])
        if let first = data.range(of: start), data.range(of: start, in: first.upperBound..<data.endIndex) != nil { return true }
        guard let end = data.range(of: Data([0xFF, 0xD9]), options: .backwards) else { return true }
        return data[end.upperBound...].contains { $0 != 0 }   // a few padding zeros are harmless
    }

    /// Refuses "decompression bombs": tiny files that declare gigantic dimensions.
    static func checkPixelCount(width: Int, height: Int, url: URL) throws {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= Limits.maxImagePixels else {
            throw OpError.unsupported(L("«%@» è troppo grande (%@ × %@ pixel)", url.lastPathComponent, width, height))
        }
    }

    /// "jpg" rather than UTType's "jpeg", which is what people expect to see.
    static func fileExtension(for type: UTType) -> String? {
        type.conforms(to: .jpeg) ? "jpg" : type.preferredFilenameExtension
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: CGFloat = 0.9,
                      properties: [CFString: Any] = [:]) throws {
        if needsWebPEncoder(type) {   // libwebp writes no metadata: the orientation is applied to the pixels
            let orientation = CGImagePropertyOrientation(rawValue: UInt32(properties[kCGImagePropertyOrientation] as? Int ?? 1)) ?? .up
            do { try WebPEncoder.data(image, quality: quality, orientation: orientation).write(to: url) } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw OpError.unsupported(type.preferredFilenameExtension ?? type.identifier)
        }
        var props = properties
        if Settings.removeLocation { props = withoutLocation(props) }   // 0.8-C2, 0.8.2-G2
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw OpError.failed(L("scrittura di %@", url.lastPathComponent))
        }
    }

    /// The thumbnail API already applied the EXIF rotation, so the copied metadata must say "upright".
    private static func orientedProperties(_ props: [CFString: Any]) -> [CFString: Any] {
        var p = props
        p.removeValue(forKey: kCGImagePropertyPixelWidth)
        p.removeValue(forKey: kCGImagePropertyPixelHeight)
        p[kCGImagePropertyOrientation] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        return p
    }

    static func supportsAlpha(_ type: UTType) -> Bool {
        !(type.conforms(to: .jpeg) || type.conforms(to: .bmp))
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Draws the image on white, for formats without transparency.
    static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Smaller file: lossy formats keep their type at lower quality, the rest become JPEG.
    static func compress(_ url: URL) throws -> [URL] {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let lossy: [UTType] = [.jpeg, .heic, .webP]
        let keep = type.map { t in lossy.contains { t.conforms(to: $0) } } ?? false
        let outs = try process(url, to: keep ? type : .jpeg, quality: 0.6, suffix: "compressa")
        if let out = outs.first, keep, FileNaming.fileSize(out) >= FileNaming.fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw OpError.notSmaller
        }
        return outs
    }
}
