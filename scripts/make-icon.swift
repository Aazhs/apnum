// Draws apnum's app icon (a sunrise in the app's sky palette) and writes a 1024 px PNG.
//   swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

// macOS icon grid: 824 px rounded square centred in 1024, corner radius ~185.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x141B33)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Sky: night at the top, dusk violet, then dawn amber at the horizon.
let sky = CGGradient(colorsSpace: space, colors: [rgb(0x141B33), rgb(0x2B2D5C), rgb(0x8E5B9A), rgb(0xE48C7A), rgb(0xF6B26B)] as CFArray,
                     locations: [0, 0.35, 0.62, 0.82, 1])!
let horizonY = tile.minY + tile.height * 0.36
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: horizonY), options: [.drawsAfterEndLocation])

// Sun glow and disc, half risen.
let sunCenter = CGPoint(x: size / 2, y: horizonY)
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFE3B0, 0.75), rgb(0xFFE3B0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: 360, options: [])
ctx.setFillColor(rgb(0xFFF4E0))
ctx.addArc(center: sunCenter, radius: 168, startAngle: 0, endAngle: .pi, clockwise: false)
ctx.fillPath()

// Ground below the horizon: deep blue, like the night side of the ribbon.
let ground = CGGradient(colorsSpace: space, colors: [rgb(0x2B2D5C), rgb(0x141B33)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.clip(to: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: horizonY - tile.minY))
ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: horizonY), end: CGPoint(x: 0, y: tile.minY), options: [])
// Reflection of the sun on the ground.
for (i, w) in [300.0, 220, 150, 90].enumerated() {
    let y = horizonY - 46 - CGFloat(i) * 44
    ctx.setFillColor(rgb(0xF6B26B, 0.55 - CGFloat(i) * 0.11))
    ctx.addPath(CGPath(roundedRect: CGRect(x: size / 2 - w / 2, y: y, width: w, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()
}
ctx.restoreGState()

// Horizon line.
ctx.setFillColor(rgb(0xFFF4E0, 0.9))
ctx.fill(CGRect(x: tile.minX, y: horizonY - 3, width: tile.width, height: 6))

// Glass sheen on the upper half.
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.maxY - tile.height * 0.45), options: [])
ctx.restoreGState()

// Thin bright rim, like Liquid Glass edges.
ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(4); ctx.strokePath()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
