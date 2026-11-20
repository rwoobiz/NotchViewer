// Renders the app icon: a glassy display with a notch and a menu bar running beside it.
// Usage: swift scripts/make_icon.swift out.png
import AppKit

let S = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

// macOS icon tile
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0.1, 0.1, 0.3).setFill(); tilePath.fill()
ctx.restoreGState()
tilePath.addClip()
NSGradient(colors: [color(0.43, 0.30, 0.95), color(0.12, 0.45, 1.0), color(0.0, 0.78, 0.95)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -50)

// the "screen": a frosted pane
let screen = NSRect(x: 190, y: 300, width: 644, height: 430)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 46, yRadius: 46)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor.black.withAlphaComponent(0.30).cgColor)
color(1, 1, 1, 0.20).setFill(); screenPath.fill()
ctx.restoreGState()
NSGradient(colors: [color(1, 1, 1, 0.42), color(1, 1, 1, 0.10)])!.draw(in: screenPath, angle: -90)
color(1, 1, 1, 0.65).setStroke(); screenPath.lineWidth = 4; screenPath.stroke()

// menu bar strip along the very top of the screen
ctx.saveGState()
screenPath.addClip()
let bar = NSRect(x: screen.minX, y: screen.maxY - 62, width: screen.width, height: 62)
color(1, 1, 1, 0.30).setFill(); NSBezierPath(rect: bar).fill()
// menu items on the left, status dots on the right
for i in 0..<4 {
    color(1, 1, 1, i == 0 ? 0.95 : 0.7).setFill()
    NSBezierPath(roundedRect: NSRect(x: screen.minX + 40 + Double(i) * 74, y: bar.midY - 8, width: i == 0 ? 26 : 52, height: 16), xRadius: 8, yRadius: 8).fill()
}
for i in 0..<3 {
    color(1, 1, 1, 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: screen.maxX - 52 - Double(i) * 38, y: bar.midY - 9, width: 18, height: 18)).fill()
}
ctx.restoreGState()

// the notch, sitting in the same row as the menu bar
let notch = NSBezierPath(roundedRect: NSRect(x: screen.midX - 78, y: screen.maxY - 64, width: 156, height: 66), xRadius: 26, yRadius: 26)
NSColor.black.setFill(); notch.fill()
color(0.25, 0.3, 0.45).setFill()
NSBezierPath(ovalIn: NSRect(x: screen.midX - 10, y: screen.maxY - 40, width: 20, height: 20)).fill()

// stand
let stand = NSBezierPath(roundedRect: NSRect(x: 392, y: 252, width: 240, height: 24), xRadius: 12, yRadius: 12)
color(1, 1, 1, 0.55).setFill(); stand.fill()

// gloss across the top-left of the tile
ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [color(1, 1, 1, 0.30), color(1, 1, 1, 0)])!.draw(in: NSRect(x: 100, y: 500, width: 824, height: 424), angle: -90)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
