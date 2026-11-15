// Draws the Mac2Seven app icon and writes every size into the asset catalog.
// Run from the repo root:  swift Tools/make-icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "Mac2Seven/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Draws the icon into a 1024×1024 coordinate space.
func drawIcon() {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor.clear.setFill()
    canvas.fill()

    // macOS icon grid: an 824pt rounded square centred on the canvas, with a soft drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.05, 0.18, 0.33).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Deep blue-teal glass background.
    NSGradient(colors: [color(0.16, 0.50, 0.70), color(0.06, 0.24, 0.45), color(0.02, 0.09, 0.22)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -60)
    // Soft light from the top.
    NSGradient(colors: [color(1, 1, 1, 0.28), color(1, 1, 1, 0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Four glassy orbs in a 2×2 grid.
    let orbSize: CGFloat = 230
    let gap: CGFloat = 52
    let start = (1024 - (orbSize * 2 + gap)) / 2
    for row in 0..<2 {
        for col in 0..<2 {
            let rect = NSRect(x: start + CGFloat(col) * (orbSize + gap),
                              y: start + CGFloat(row) * (orbSize + gap),
                              width: orbSize, height: orbSize)
            drawOrb(in: rect)
        }
    }

    // Thin bright rim around the tile.
    NSGraphicsContext.saveGraphicsState()
    color(1, 1, 1, 0.22).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawOrb(in rect: NSRect) {
    let orb = NSBezierPath(ovalIn: rect)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0.05, 0.15, 0.55)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0.75, 0.92, 1).setFill()
    orb.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    orb.addClip()
    // Body: bright at the top, deeper blue at the bottom.
    NSGradient(colors: [color(0.93, 0.98, 1), color(0.62, 0.86, 1), color(0.30, 0.62, 0.92)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: rect, angle: -90)
    // Glossy highlight across the upper half.
    let gloss = NSRect(x: rect.minX + rect.width * 0.14, y: rect.midY - rect.height * 0.02,
                       width: rect.width * 0.72, height: rect.height * 0.46)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: gloss).addClip()
    NSGradient(colors: [color(1, 1, 1, 0.95), color(1, 1, 1, 0.15)])!.draw(in: gloss, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Light bouncing up from below.
    NSGradient(colors: [color(0.7, 0.95, 1, 0.55), color(0.7, 0.95, 1, 0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.35), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    color(1, 1, 1, 0.55).setStroke()
    let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
    edge.lineWidth = 3
    edge.stroke()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let scale = CGFloat(pixels) / 1024
    ctx.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// (point size, scale) pairs that macOS asks for.
let specs: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (size, scale) in specs {
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try png(pixels: size * scale).write(to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))

let catalog = outDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: catalog, atomically: true, encoding: .utf8)
}
print("Wrote \(specs.count) icon sizes to \(outDir.path)")
