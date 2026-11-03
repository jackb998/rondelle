import Foundation
import ImageIO
import CoreGraphics
// pdfcmp PDF PHOTO: page 1 size vs the photo shown upright, and the mean per-channel difference (0–255)
// between the page rendered at 1000 px and the upright photo at the same size.
let pdfURL = URL(fileURLWithPath: CommandLine.arguments[1]), photo = URL(fileURLWithPath: CommandLine.arguments[2])
let doc = CGPDFDocument(pdfURL as CFURL)!, page = doc.page(at: 1)!
let box = page.getBoxRect(.mediaBox)
let rot = page.rotationAngle
let pw = rot % 180 == 0 ? box.width : box.height, ph = rot % 180 == 0 ? box.height : box.width
let src = CGImageSourceCreateWithURL(photo as CFURL, nil)!
let up = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1000,
                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
let W = up.width, H = up.height
func bitmap(_ draw: (CGContext) -> Void) -> [UInt8] {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    draw(ctx)
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: W * H * 4))
}
let a = bitmap { $0.interpolationQuality = .high; $0.draw(up, in: CGRect(x: 0, y: 0, width: W, height: H)) }
let b = bitmap { ctx in
    ctx.interpolationQuality = .high
    ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: W, height: H), rotate: 0, preserveAspectRatio: false))
    ctx.drawPDFPage(page)
}
var sum = 0.0
for i in 0..<(W * H) { for c in 0..<3 { sum += abs(Double(a[i * 4 + c]) - Double(b[i * 4 + c])) } }
let upright = (pw > ph) == (W > H)
print(String(format: "pagina %.0f×%.0f pt (rotazione %d)  foto dritta %d×%d  verso giusto: %@  differenza media %.2f/255",
             pw, ph, rot, W, H, upright ? "sì" : "NO", sum / Double(W * H * 3)))
