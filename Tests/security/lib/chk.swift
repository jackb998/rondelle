import Foundation
import ImageIO
import AVFoundation
// For each file: where a position is still present (EXIF GPS, XMP GPS, IPTC/XMP place, ©xyz, ISO6709 mdta, raw tokens),
// plus whether date and camera survived.
func imageFields(_ data: Data) -> [String: Bool] {
    guard let s = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(s) > 0 else { return [:] }
    var r = ["exifGPS": false, "xmpGPS": false, "iptc": false, "xmpPlace": false, "date": false, "camera": false]
    for i in 0..<CGImageSourceGetCount(s) {
        let p = CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [CFString: Any] ?? [:]
        if let g = p[kCGImagePropertyGPSDictionary] as? [CFString: Any], !g.isEmpty { r["exifGPS"] = true }
        if let ip = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState].contains(where: { ip[$0] != nil }) { r["iptc"] = true }
        if (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] != nil { r["date"] = true }
        if (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] != nil { r["camera"] = true }
        if let md = CGImageSourceCopyMetadataAtIndex(s, i, nil), let tags = CGImageMetadataCopyTags(md) as? [CGImageMetadataTag] {
            for t in tags {
                let n = (CGImageMetadataTagCopyName(t) as String?) ?? ""
                let pre = (CGImageMetadataTagCopyPrefix(t) as String?) ?? ""
                if n.hasPrefix("GPS") && pre == "exif" { r["xmpGPS"] = true }
                if ["City", "Country", "State", "Location"].contains(n) && (pre == "photoshop" || pre == "Iptc4xmpCore") { r["xmpPlace"] = true }
            }
        }
    }
    return r
}
func has(_ d: Data, _ s: String) -> Bool { d.range(of: s.data(using: .utf8)!) != nil }
func v(_ b: Bool?) -> String { b == true ? "RESTA" : "tolto" }
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { print("\(url.lastPathComponent)\tILLEGGIBILE"); continue }
    let ext = url.pathExtension.lowercased()
    let raw = has(data, "Gpsvilla") || has(data, "Viagps") || has(data, "+45.4321") || has(data, "45,25.926")
    var cols: [String] = []
    if ["mov", "mp4", "m4v", "m4a"].contains(ext) {
        let a = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ids: [String] = []
        Task {
            var all: [AVMetadataItem] = []
            for f in (try? await a.load(.availableMetadataFormats)) ?? [] { all += (try? await a.loadMetadata(for: f)) ?? [] }
            ids = all.compactMap { $0.identifier?.rawValue }
            sem.signal()
        }
        sem.wait()
        let xyz = ids.contains { $0.contains("%A9xyz") || $0.contains("\u{A9}xyz") }
        let mdta = ids.contains { $0.contains("location.ISO6709") }
        let date = ids.contains { $0.lowercased().contains("creationdate") }
        let make = ids.contains { $0.lowercased().contains("make") }
        cols = ["©xyz=\(v(xyz))", "ISO6709=\(v(mdta))", "grezzo=\(v(raw))", "data=\(date ? "sì" : "no")", "marca=\(make ? "sì" : "no")"]
    } else if ext == "pdf" {
        // Images embedded as JPEG keep their own EXIF/XMP: check every JPEG start inside the PDF.
        var f: [String: Bool] = [:]
        var i = data.startIndex
        while let r = data.range(of: Data([0xFF, 0xD8, 0xFF]), in: i..<data.endIndex) {
            for (k, b) in imageFields(data.subdata(in: r.lowerBound..<data.endIndex)) where b { f[k] = true }
            i = r.upperBound
        }
        cols = ["EXIF GPS=\(v(f["exifGPS"]))", "XMP GPS=\(v(f["xmpGPS"]))", "IPTC=\(v(f["iptc"]))", "XMP luogo=\(v(f["xmpPlace"]))", "grezzo=\(v(raw))"]
    } else {
        let f = imageFields(data)
        if f.isEmpty { print("\(url.lastPathComponent)\tnon immagine"); continue }
        cols = ["EXIF GPS=\(v(f["exifGPS"]))", "XMP GPS=\(v(f["xmpGPS"]))", "IPTC=\(v(f["iptc"]))", "XMP luogo=\(v(f["xmpPlace"]))", "grezzo=\(v(raw))",
                "data=\(f["date"]! ? "sì" : "no")", "fotocamera=\(f["camera"]! ? "sì" : "no")"]
    }
    print("\(url.lastPathComponent)\t" + cols.joined(separator: "  "))
}
