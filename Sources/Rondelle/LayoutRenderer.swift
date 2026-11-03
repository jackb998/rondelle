import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A photo ready for a layout: a downscaled image plus the point to keep in frame when cropping.
struct LayoutPhoto {
    let url: URL
    let image: CGImage
    /// Normalised (0…1, origin bottom-left, like Core Graphics and Vision) centre of the subject.
    let focus: CGPoint
}

enum LayoutAspect: String, CaseIterable, Identifiable {
    case square = "1:1", portrait = "4:5", story = "9:16", landscape = "16:9", classic = "3:2"
    var id: String { rawValue }
    /// Width / height.
    var ratio: CGFloat {
        switch self {
        case .square: return 1
        case .portrait: return 4.0 / 5
        case .story: return 9.0 / 16
        case .landscape: return 16.0 / 9
        case .classic: return 3.0 / 2
        }
    }
}

/// Cells in a unit square, origin top-left (easier to author: rows go downwards).
struct LayoutTemplate: Identifiable, Equatable {
    let id: String
    let cells: [CGRect]
}

enum LayoutRenderer {
    static let maxPhotos = 9

    // MARK: Templates

    /// Every layout offered for `count` photos: grids, rows, columns and "one big + the rest".
    static func templates(for count: Int) -> [LayoutTemplate] {
        guard (2...maxPhotos).contains(count) else { return [] }
        var result: [LayoutTemplate] = []
        func add(_ t: LayoutTemplate?) {
            if let t, !result.contains(where: { $0.id == t.id }) { result.append(t) }
        }

        // Near-square grid: 4 → 2×2, 5 → 3+2, 7 → 3+2+2, 9 → 3×3.
        let perRow = Int(ceil(sqrt(Double(count))))
        let gridRows = Int(ceil(Double(count) / Double(perRow)))
        add(rows(balanced(count, parts: gridRows)))
        add(columns(balanced(count, parts: gridRows)))
        if count <= 4 {
            add(rows([count]))
            add(columns([count]))
        }
        if count <= 5 {
            add(featured(count, left: true))
            add(featured(count, left: false))
        }
        if count >= 4, count - 2 <= 4 {
            add(rows([2, count - 2]))
            add(rows([count - 2, 2]))
        }
        if count >= 5, count - 3 <= 4 {
            add(rows([3, count - 3]))
            add(columns([2, count - 2]))
        }
        // Three bands for larger sets: 6 → 2+2+2, 7 → 3+1+3, 8 → 2+4+2 and 3+2+3, 9 → 3+3+3.
        if count >= 6 {
            if count - 4 <= 4 { add(rows([2, count - 4, 2])); add(columns([2, count - 4, 2])) }
            if count - 6 >= 1 { add(rows([3, count - 6, 3])); add(columns([3, count - 6, 3])) }
            if count == 8 { add(rows([4, 4])) }
            if count == 9 { add(rows([4, 1, 4])); add(columns([4, 1, 4])); add(rows([2, 3, 4])) }
        }
        return result
    }

    /// Splits `count` into `parts` numbers as equal as possible, e.g. 7 in 3 → [3, 2, 2].
    private static func balanced(_ count: Int, parts: Int) -> [Int] {
        let parts = max(parts, 1)
        return (0..<parts).map { count / parts + ($0 < count % parts ? 1 : 0) }
    }

    /// Horizontal bands, `counts[i]` photos side by side in band i.
    private static func rows(_ counts: [Int]) -> LayoutTemplate? {
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }
        let h = 1 / CGFloat(counts.count)
        var cells: [CGRect] = []
        for (r, n) in counts.enumerated() {
            let w = 1 / CGFloat(n)
            for c in 0..<n { cells.append(CGRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w, height: h)) }
        }
        return LayoutTemplate(id: "r" + counts.map(String.init).joined(separator: "-"), cells: cells)
    }

    /// Vertical bands: the same as rows, transposed.
    private static func columns(_ counts: [Int]) -> LayoutTemplate? {
        guard let r = rows(counts) else { return nil }
        return LayoutTemplate(id: "c" + r.id.dropFirst(),
                              cells: r.cells.map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) })
    }

    /// One big photo (left or top, 62%) and the others stacked beside it.
    private static func featured(_ count: Int, left: Bool) -> LayoutTemplate {
        let big: CGFloat = 0.62
        let others = count - 1
        var cells = [left ? CGRect(x: 0, y: 0, width: big, height: 1) : CGRect(x: 0, y: 0, width: 1, height: big)]
        for i in 0..<others {
            let step = 1 / CGFloat(others)
            cells.append(left ? CGRect(x: big, y: CGFloat(i) * step, width: 1 - big, height: step)
                              : CGRect(x: CGFloat(i) * step, y: big, width: step, height: 1 - big))
        }
        return LayoutTemplate(id: left ? "fl\(count)" : "ft\(count)", cells: cells)
    }

    // MARK: Loading

    /// Loads a photo at most `maxPixel` wide (EXIF rotation applied) and finds its subject.
    static func loadPhoto(_ url: URL, maxPixel: Int = 2400) throws -> LayoutPhoto {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw OpError.unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        try ImageOps.checkPixelCount(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                     height: props[kCGImagePropertyPixelHeight] as? Int ?? 0, url: url)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OpError.unreadable(url)
        }
        return LayoutPhoto(url: url, image: image, focus: subjectCentre(of: image))
    }

    /// Smart crop: faces first, otherwise what Vision finds most eye-catching, otherwise the centre.
    static func subjectCentre(of image: CGImage) -> CGPoint {
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([faces, saliency])

        var boxes = (faces.results ?? []).map(\.boundingBox)
        if boxes.isEmpty { boxes = (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox) }
        guard let first = boxes.first else { return CGPoint(x: 0.5, y: 0.5) }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: union.midX, y: union.midY)
    }

    // MARK: Rendering

    /// - Parameters:
    ///   - spacing: gap between photos and around the edge, as a fraction of the long side.
    ///   - corner: corner radius of each photo, as a fraction of the long side.
    static func render(_ photos: [LayoutPhoto], template: LayoutTemplate, aspect: LayoutAspect,
                       spacing: CGFloat, corner: CGFloat, background: CGColor, longSide: Int) -> CGImage? {
        let width = aspect.ratio >= 1 ? longSide : Int(CGFloat(longSide) * aspect.ratio)
        let height = aspect.ratio >= 1 ? Int(CGFloat(longSide) / aspect.ratio) : longSide
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rects = cellRects(template, width: CGFloat(width), height: CGFloat(height),
                              gap: spacing * CGFloat(longSide))
        let radius = corner * CGFloat(longSide)
        for (rect, photo) in zip(rects, photos) where rect.width > 1 && rect.height > 1 {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2),
                               cornerHeight: min(radius, rect.height / 2), transform: nil))
            ctx.clip()
            ctx.draw(photo.image, in: fill(rect, with: photo))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Cell rectangles in Core Graphics pixels (origin bottom-left), with an even `gap` everywhere.
    static func cellRects(_ template: LayoutTemplate, width: CGFloat, height: CGFloat, gap: CGFloat) -> [CGRect] {
        let innerW = width - gap, innerH = height - gap
        return template.cells.map { cell in
            let x = gap / 2 + cell.minX * innerW
            let yTop = gap / 2 + cell.minY * innerH
            let rect = CGRect(x: x, y: height - yTop - cell.height * innerH,
                              width: cell.width * innerW, height: cell.height * innerH)
            return rect.insetBy(dx: gap / 2, dy: gap / 2)
        }
    }

    /// Aspect-fill `photo` into `cell`, sliding it so its subject is as central as the edges allow.
    private static func fill(_ cell: CGRect, with photo: LayoutPhoto) -> CGRect {
        let w = CGFloat(photo.image.width), h = CGFloat(photo.image.height)
        let scale = max(cell.width / w, cell.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        var x = cell.midX - photo.focus.x * size.width
        var y = cell.midY - photo.focus.y * size.height
        x = min(max(x, cell.maxX - size.width), cell.minX)
        y = min(max(y, cell.maxY - size.height), cell.minY)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
