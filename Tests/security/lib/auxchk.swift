import Foundation
import ImageIO
// auxchk FILE…: what an image carries besides its picture — auxiliary images (depth, disparity, matte, gain map),
// an EXIF thumbnail, a second JPEG anywhere in the bytes, data after the last end-of-image, the canaries.
let auxTypes: [(String, CFString)] = [("depth", kCGImageAuxiliaryDataTypeDepth), ("disparity", kCGImageAuxiliaryDataTypeDisparity),
                                      ("matte", kCGImageAuxiliaryDataTypePortraitEffectsMatte), ("gainmap", kCGImageAuxiliaryDataTypeHDRGainMap),
                                      ("isogainmap", kCGImageAuxiliaryDataTypeISOGainMap)]
func count(_ d: Data, _ pattern: [UInt8]) -> Int {
    var n = 0, i = d.startIndex
    while let r = d.range(of: Data(pattern), in: i..<d.endIndex) { n += 1; i = r.upperBound }
    return n
}
for p in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: p)
    guard let data = try? Data(contentsOf: url), let s = CGImageSourceCreateWithData(data as CFData, nil) else { print("\(url.lastPathComponent)\tILLEGGIBILE"); continue }
    let aux = auxTypes.filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, $0.1) != nil }.map(\.0)
    let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
    // ImageIO reports an EXIF thumbnail through the "ThumbnailImages" key of the source properties for some formats;
    // the reliable test is in the bytes: a second JPEG start (FFD8FF) or the thumbnail's own canary.
    let jpegStarts = count(data, [0xFF, 0xD8, 0xFF])
    let isJPEG = data.starts(with: [0xFF, 0xD8])
    var afterEOI = 0
    if isJPEG, let last = data.range(of: Data([0xFF, 0xD9]), options: .backwards) { afterEOI = data.endIndex - last.upperBound }
    let canaries = ["CNRYTHUMB", "CNRYMOTION", "CNRYAUX"].filter { data.range(of: $0.data(using: .utf8)!) != nil }
    let images = CGImageSourceGetCount(s)
    _ = props
    print("\(url.lastPathComponent)\tausiliarie=[\(aux.joined(separator: ","))]\timmagini=\(images)\tinizi JPEG=\(jpegStarts)\tdopo EOI=\(afterEOI) B\tcanarini=[\(canaries.joined(separator: ","))]")
}
