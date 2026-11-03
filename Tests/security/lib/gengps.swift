import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
// Builds photos and videos carrying a position in every place we know: EXIF GPS, XMP GPS, IPTC location, QuickTime.
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let src = URL(fileURLWithPath: CommandLine.arguments[2])   // a sample photo
let clip = URL(fileURLWithPath: CommandLine.arguments[3])  // a sample video
let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 45.4321, kCGImagePropertyGPSLatitudeRef: "N",
                            kCGImagePropertyGPSLongitude: 12.3456, kCGImagePropertyGPSLongitudeRef: "E",
                            kCGImagePropertyGPSAltitude: 7.0]
let iptc: [CFString: Any] = [kCGImagePropertyIPTCCity: "Gpsvilla", kCGImagePropertyIPTCCountryPrimaryLocationName: "Gpslandia",
                             kCGImagePropertyIPTCSubLocation: "Viagps", kCGImagePropertyIPTCProvinceState: "Gpsprovincia"]
let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00"]
let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone Prova"]
let isrc = CGImageSourceCreateWithURL(src as CFURL, nil)!
let img = CGImageSourceCreateThumbnailAtIndex(isrc, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
func write(_ name: String, _ type: UTType, iptcOn: Bool = true) {
    let tmp = dir.appendingPathComponent("_" + name)
    let d = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil)!
    var p: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff]
    if iptcOn { p[kCGImagePropertyIPTCDictionary] = iptc }
    CGImageDestinationAddImage(d, img, p as CFDictionary); CGImageDestinationFinalize(d)
    // Second pass: XMP copies of the position (photoshop:City, Iptc4xmpCore:Location, exif:GPS*).
    let s2 = CGImageSourceCreateWithURL(tmp as CFURL, nil)!
    let md = CGImageMetadataCreateMutable()
    for (ns, pre) in [("http://ns.adobe.com/photoshop/1.0/", "photoshop"), ("http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/", "Iptc4xmpCore"), ("http://ns.adobe.com/exif/1.0/", "exif")] {
        CGImageMetadataRegisterNamespaceForPrefix(md, ns as CFString, pre as CFString, nil)
    }
    CGImageMetadataSetValueWithPath(md, nil, "photoshop:City" as CFString, "Gpsvilla" as CFString)
    CGImageMetadataSetValueWithPath(md, nil, "photoshop:Country" as CFString, "Gpslandia" as CFString)
    CGImageMetadataSetValueWithPath(md, nil, "Iptc4xmpCore:Location" as CFString, "Viagps" as CFString)
    CGImageMetadataSetValueWithPath(md, nil, "exif:GPSLatitude" as CFString, "45,25.926N" as CFString)
    CGImageMetadataSetValueWithPath(md, nil, "exif:GPSLongitude" as CFString, "12,20.736E" as CFString)
    let out = dir.appendingPathComponent(name)
    let d2 = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)!
    var err: Unmanaged<CFError>?
    let ok = CGImageDestinationCopyImageSource(d2, s2, [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: true] as CFDictionary, &err)
    if !ok { // formats without lossless copy: add image + metadata
        let d3 = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(d3, img, md, nil); CGImageDestinationFinalize(d3)
        print("\(name): copia senza perdita non riuscita, usato AddImageAndMetadata")
    }
    try? FileManager.default.removeItem(at: tmp)
}
write("gps.jpg", .jpeg); write("gps.heic", .heic); write("gps.tiff", .tiff); write("gps.png", .png, iptcOn: false)
// Videos: ©xyz (QuickTime user data) and mdta com.apple.quicktime.location.ISO6709.
let iso = "+45.4321+012.3456+007.000/"
func item(_ id: AVMetadataIdentifier) -> AVMetadataItem { let m = AVMutableMetadataItem(); m.identifier = id; m.value = iso as NSString; m.dataType = kCMMetadataBaseDataType_UTF8 as String; return m }
let sem = DispatchSemaphore(value: 0)
for (name, type) in [("gps.mov", AVFileType.mov), ("gps.mp4", .mp4), ("gps.m4v", .m4v)] {
    let out = dir.appendingPathComponent(name); try? FileManager.default.removeItem(at: out)
    let ex = AVAssetExportSession(asset: AVURLAsset(url: clip), presetName: AVAssetExportPresetPassthrough)!
    ex.outputURL = out; ex.outputFileType = type
    ex.metadata = [item(.quickTimeUserDataLocationISO6709), item(.quickTimeMetadataLocationISO6709),
                   { let m = AVMutableMetadataItem(); m.identifier = .quickTimeMetadataMake; m.value = "Apple" as NSString; return m }(),
                   { let m = AVMutableMetadataItem(); m.identifier = .quickTimeMetadataCreationDate; m.value = "2024-05-01T10:00:00+0200" as NSString; return m }()]
    ex.exportAsynchronously { sem.signal() }; sem.wait()
    print(name, ex.status == .completed ? "ok" : "ERR \(String(describing: ex.error))")
}
