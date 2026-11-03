import Foundation
import ImageIO
// pixchk cover FILE: the covered area of --test-editor (x 10–70 %, y 30–70 % of the output): darkest/brightest
//   channel, lowest alpha, pixels that are not opaque black.
// pixchk alpha FILE: pixels with alpha 0 and the largest R, G or B among them, as decoded (straight alpha when the
//   decoder gives it; premultiplied data can't show hidden colour and is reported as such).
let mode = CommandLine.arguments[1]
for p in CommandLine.arguments.dropFirst(2) {
    let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCache: true] as CFDictionary)!
    let W = img.width, H = img.height
    let info = img.alphaInfo
    let straight = info == .last || info == .first
    // Decode as stored when it is 8-bit RGBA with straight alpha; otherwise redraw as 8-bit RGBA premultiplied.
    var bytes: [UInt8]; var bpr: Int; var order = (r: 0, g: 1, b: 2, a: 3)
    if straight, img.bitsPerComponent == 8, img.bitsPerPixel == 32, let data = img.dataProvider?.data as Data? {
        bytes = Array(data); bpr = img.bytesPerRow
        if info == .first { order = (1, 2, 3, 0) }
    } else {
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: W * H * 4)); bpr = W * 4
    }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let o = y * bpr + x * 4
        return (Int(bytes[o + order.r]), Int(bytes[o + order.g]), Int(bytes[o + order.b]), Int(bytes[o + order.a]))
    }
    let name = p.split(separator: "/").last!
    if mode == "cover" {
        var maxC = 0, minA = 255, bad = 0, n = 0
        for y in Int(Double(H) * 0.3) + 3 ..< Int(Double(H) * 0.7) - 3 {
            for x in Int(Double(W) * 0.1) + 3 ..< Int(Double(W) * 0.7) - 3 {
                let (r, g, b, a) = px(x, y); n += 1
                maxC = max(maxC, r, g, b); minA = min(minA, a)
                if r > 2 || g > 2 || b > 2 || a < 255 { bad += 1 }
            }
        }
        print("\(name)\tarea coperta: \(n) pixel, max RGB \(maxC), alpha minima \(minA), non neri o non opachi: \(bad)")
    } else {
        var zero = 0, maxC = 0
        for y in 0..<H { for x in 0..<W { let (r, g, b, a) = px(x, y); if a == 0 { zero += 1; maxC = max(maxC, r, g, b) } } }
        print("\(name)\talpha \(straight ? "non premoltiplicato" : "premoltiplicato (\(info.rawValue))"): \(zero) pixel con alpha 0, max RGB fra questi \(maxC)")
    }
}
