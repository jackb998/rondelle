import Foundation
import ImageIO
import UniformTypeIdentifiers
// A photo with a unique canary in every place a location can hide: EXIF GPS (also its text fields), IPTC,
// XMP photoshop/Iptc4xmpCore/Iptc4xmpExt (nested LocationCreated / LocationShown with coordinates), XMP exif:GPS*.
// Date, camera and author are set too: they must survive.
// Usage: gencan OUT SOURCE MAXPIXELS(0 = as is; >source: upscaled) ORIENTATION GPS(1/0) [TYPE jpeg|heic|png|tiff]
let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1]), src = URL(fileURLWithPath: a[2])
let maxPixels = Int(a[3])!, orientation = Int(a[4])!, withGPS = a[5] == "1"
let type: UTType = a.count > 6 ? [ "heic": .heic, "png": .png, "tiff": .tiff ][a[6]] ?? .jpeg : .jpeg
let s = CGImageSourceCreateWithURL(src as CFURL, nil)!
var img = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: 4000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
if maxPixels > 0 {   // resample to the requested long side (upscaling allowed)
    let scale = Double(maxPixels) / Double(max(img.width, img.height))
    let wide = ProcessInfo.processInfo.environment["WIDE"] != nil   // 4:3 landscape, centre crop
    let w = Int(Double(img.width) * scale), h = wide ? w * 3 / 4 : Int(Double(img.height) * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: (h - Int(Double(img.height) * scale)) / 2, width: w, height: Int(Double(img.height) * scale)))
    img = ctx.makeImage()!
}
var props: [CFString: Any] = [
    kCGImagePropertyOrientation: orientation,
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00"],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone Prova",
                                     kCGImagePropertyTIFFArtist: "Autore Prova", kCGImagePropertyTIFFOrientation: orientation],
    kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "CNRYIPTCCITY", kCGImagePropertyIPTCProvinceState: "CNRYIPTCPROV",
                                     kCGImagePropertyIPTCCountryPrimaryLocationName: "CNRYIPTCCOUNTRY",
                                     kCGImagePropertyIPTCCountryPrimaryLocationCode: "CNRYIPTCCC",
                                     kCGImagePropertyIPTCSubLocation: "CNRYIPTCSUB", kCGImagePropertyIPTCByline: ["Autore Prova"]],
]
if withGPS {
    props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 45.4321, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 12.3456, kCGImagePropertyGPSLongitudeRef: "E", kCGImagePropertyGPSAltitude: 7.0,
        kCGImagePropertyGPSAreaInformation: "CNRYGPSAREA", kCGImagePropertyGPSProcessingMethod: "CNRYGPSPROC",
        kCGImagePropertyGPSDestLatitude: 11.1111, kCGImagePropertyGPSDestLatitudeRef: "N",
        kCGImagePropertyGPSDestLongitude: 22.2222, kCGImagePropertyGPSDestLongitudeRef: "E"]
}
let iimOnly = ProcessInfo.processInfo.environment["IIM"] != nil   // IPTC/EXIF only: XMP would overwrite the IIM values
let tmp = iimOnly ? out : out.deletingLastPathComponent().appendingPathComponent("_" + out.lastPathComponent)
let d = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, img, props as CFDictionary)
precondition(CGImageDestinationFinalize(d))
if iimOnly { print(out.lastPathComponent, "solo IIM/EXIF"); exit(0) }
// XMP location fields, nested ones included.
let gpsXMP = withGPS ? """
 exif:GPSLatitude="45,25.9261N" exif:GPSLongitude="12,20.7362E" exif:GPSAreaInformation="CNRYXMPGPSAREA"
""" : ""
let xmp = """
<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
 xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
 xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
 photoshop:City="CNRYXMPCITY" photoshop:State="CNRYXMPSTATE" photoshop:Country="CNRYXMPCOUNTRY"
 Iptc4xmpCore:Location="CNRYXMPLOCATION" Iptc4xmpCore:CountryCode="CNRYXMPCC"\(gpsXMP)>
<dc:creator><rdf:Seq><rdf:li>Autore Prova</rdf:li></rdf:Seq></dc:creator>
<Iptc4xmpExt:LocationCreated><rdf:Bag><rdf:li rdf:parseType="Resource">
 <Iptc4xmpExt:City>CNRYLCCITY</Iptc4xmpExt:City><Iptc4xmpExt:Sublocation>CNRYLCSUB</Iptc4xmpExt:Sublocation>
 <exif:GPSLatitude>45,25.9262N</exif:GPSLatitude><exif:GPSLongitude>12,20.7363E</exif:GPSLongitude>
</rdf:li></rdf:Bag></Iptc4xmpExt:LocationCreated>
<Iptc4xmpExt:LocationShown><rdf:Bag><rdf:li rdf:parseType="Resource">
 <Iptc4xmpExt:City>CNRYLSCITY</Iptc4xmpExt:City><Iptc4xmpExt:CountryName>CNRYLSCOUNTRY</Iptc4xmpExt:CountryName>
 <exif:GPSLatitude>45,25.9263N</exif:GPSLatitude><exif:GPSLongitude>12,20.7364E</exif:GPSLongitude>
</rdf:li></rdf:Bag></Iptc4xmpExt:LocationShown>
</rdf:Description></rdf:RDF></x:xmpmeta>
"""
let md = CGImageMetadataCreateFromXMPData(xmp.data(using: .utf8)! as CFData)!
let s2 = CGImageSourceCreateWithURL(tmp as CFURL, nil)!
let d2 = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)!
var err: Unmanaged<CFError>?
if !CGImageDestinationCopyImageSource(d2, s2, [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: true] as CFDictionary, &err) {
    print("copia non riuscita: \(String(describing: err?.takeRetainedValue()))"); exit(1)
}
try? FileManager.default.removeItem(at: tmp)
print(out.lastPathComponent, img.width, "×", img.height, "orientamento", orientation)
