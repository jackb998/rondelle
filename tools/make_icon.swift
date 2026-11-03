// Draws the Rondelle app icon and writes Resources/AppIcon.icns (black tile, the bundle's icon: Finder, Launchpad, and the
// Dock with a dark Mac) and Resources/AppIconLight.icns (the same, inverted: the Dock and Settings with a light Mac).
// The symbol is brand/symbol/rondelle-symbol-dark-bg.svg and -light-bg.svg: grid of 100, ring from radius 20 to
// 40, gap of 60° on 45°.
// Usage: swift tools/make_icon.swift
import AppKit

struct Palette {
    let tile: NSColor, ring: NSColor, dot: NSColor
}
func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let dark = Palette(tile: rgb(0x111214), ring: rgb(0xF5F2EA), dot: rgb(0x2BB673))
let light = Palette(tile: rgb(0xF5F2EA), ring: rgb(0x111214), dot: rgb(0x1F9D63))

func drawIcon(size: CGFloat, _ palette: Palette) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824×824 rounded square centred in 1024, with a soft shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    palette.tile.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let unit = 7.4 * s
    let center = NSPoint(x: 512 * s, y: 512 * s)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: 40 * unit, startAngle: 75, endAngle: 375, clockwise: false)
    ring.appendArc(withCenter: center, radius: 20 * unit, startAngle: 375, endAngle: 75, clockwise: true)
    ring.close()
    palette.ring.setFill()
    ring.fill()
    let dot = NSPoint(x: center.x + 28.284 * unit, y: center.y + 28.284 * unit)
    palette.dot.setFill()
    NSBezierPath(ovalIn: NSRect(x: dot.x - 10 * unit, y: dot.y - 10 * unit, width: 20 * unit, height: 20 * unit)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
for (name, palette) in [("AppIcon", dark), ("AppIconLight", light)] {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            let png = drawIcon(size: CGFloat(base * scale), palette).representation(using: .png, properties: [:])!
            try png.write(to: iconset.appendingPathComponent(file))
        }
    }
    try drawIcon(size: 1024, palette).representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("Resources/\(name).png"))

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/\(name).icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    print(iconutil.terminationStatus == 0 ? "Resources/\(name).icns created" : "iconutil failed")
}
