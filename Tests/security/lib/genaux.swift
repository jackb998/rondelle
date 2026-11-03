import Foundation
import ImageIO
import CoreVideo
import UniformTypeIdentifiers
// genaux OUT SOURCE TYPE(jpeg|heic): the photo with a depth map (disparity) and an HDR gain map attached.
let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1]), src = URL(fileURLWithPath: a[2])
let type: UTType = a[3] == "heic" ? .heic : .jpeg
let s = CGImageSourceCreateWithURL(src as CFURL, nil)!
let img = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
let d = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, img, nil)
func aux(_ w: Int, _ h: Int, bytesPerPixel: Int, format: OSType, fill: (Int, Int) -> [UInt8]) -> (Data, [CFString: Any]) {
    var data = Data(capacity: w * h * bytesPerPixel)
    for y in 0..<h { for x in 0..<w { data.append(contentsOf: fill(x, y)) } }
    return (data, [kCGImagePropertyWidth: w, kCGImagePropertyHeight: h, kCGImagePropertyBytesPerRow: w * bytesPerPixel,
                   kCGImagePropertyPixelFormat: format])
}
// Disparity: a recognisable gradient of float16 values.
let (disp, dispDesc) = aux(320, 240, bytesPerPixel: 2, format: kCVPixelFormatType_DisparityFloat16) { x, _ in
    let v = Float16(Float(x) / 320 + 0.1); return withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
let depthInfo: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: disp, kCGImageAuxiliaryDataInfoDataDescription: dispDesc]
CGImageDestinationAddAuxiliaryDataInfo(d, kCGImageAuxiliaryDataTypeDisparity, depthInfo as CFDictionary)
// Gain map: one 8-bit component, a checkerboard.
let (gain, gainDesc) = aux(400, 400, bytesPerPixel: 1, format: kCVPixelFormatType_OneComponent8) { x, y in [((x / 20 + y / 20) % 2 == 0) ? 255 : 30] }
let meta = CGImageMetadataCreateMutable()
CGImageMetadataRegisterNamespaceForPrefix(meta, "http://ns.apple.com/HDRGainMap/1.0/" as CFString, "HDRGainMap" as CFString, nil)
CGImageMetadataSetValueWithPath(meta, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 65536 as CFNumber)
let gainInfo: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: gain, kCGImageAuxiliaryDataInfoDataDescription: gainDesc,
                                 kCGImageAuxiliaryDataInfoMetadata: meta]
CGImageDestinationAddAuxiliaryDataInfo(d, kCGImageAuxiliaryDataTypeHDRGainMap, gainInfo as CFDictionary)
precondition(CGImageDestinationFinalize(d))
print(out.lastPathComponent, "ok")
