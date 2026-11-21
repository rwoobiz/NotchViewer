// Draws the README's before/after illustration (not a real screenshot).
// Usage: swift scripts/make_illustration.swift assets/before-after.png
import AppKit

let W = 1600, H = 760
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

NSGradient(colors: [c(0.07, 0.08, 0.16), c(0.12, 0.10, 0.28)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)

func label(_ s: String, x: Double, y: Double, size: Double, weight: NSFont.Weight, color: NSColor, width: Double = 640, center: Bool = true) {
    let p = NSMutableParagraphStyle(); p.alignment = center ? .center : .left
    (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 1.6),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p])
}

/// A laptop screen. `merged` = remote menu bar shares the camera row.
func screen(x: Double, merged: Bool) {
    let f = NSRect(x: x, y: 150, width: 640, height: 420)
    let body = NSBezierPath(roundedRect: f, xRadius: 26, yRadius: 26)
    c(0.02, 0.02, 0.04).setFill(); body.fill()
    let inner = f.insetBy(dx: 12, dy: 12)
    let ip = NSBezierPath(roundedRect: inner, xRadius: 16, yRadius: 16)
    NSGradient(colors: [c(0.22, 0.33, 0.78), c(0.55, 0.32, 0.80)])!.draw(in: ip, angle: -40)
    NSGraphicsContext.saveGraphicsState(); ip.addClip()
    let rowH = 30.0, top = inner.maxY
    if merged {
        // remote menu bar runs along the very top, beside the notch
        c(0, 0, 0, 0.38).setFill(); NSBezierPath(rect: NSRect(x: inner.minX, y: top - rowH, width: inner.width, height: rowH)).fill()
        for i in 0..<4 { c(1, 1, 1, 0.85).setFill(); NSBezierPath(roundedRect: NSRect(x: inner.minX + 20 + Double(i) * 46, y: top - 19, width: i == 0 ? 14 : 32, height: 8), xRadius: 4, yRadius: 4).fill() }
        for i in 0..<3 { c(1, 1, 1, 0.85).setFill(); NSBezierPath(ovalIn: NSRect(x: inner.maxX - 30 - Double(i) * 22, y: top - 20, width: 10, height: 10)).fill() }
    } else {
        // black camera row with nothing in it, remote menu bar pushed down underneath
        NSColor.black.setFill(); NSBezierPath(rect: NSRect(x: inner.minX, y: top - rowH, width: inner.width, height: rowH)).fill()
        c(0, 0, 0, 0.38).setFill(); NSBezierPath(rect: NSRect(x: inner.minX, y: top - rowH * 2, width: inner.width, height: rowH)).fill()
        for i in 0..<4 { c(1, 1, 1, 0.85).setFill(); NSBezierPath(roundedRect: NSRect(x: inner.minX + 20 + Double(i) * 46, y: top - rowH - 19, width: i == 0 ? 14 : 32, height: 8), xRadius: 4, yRadius: 4).fill() }
    }
    // a few "windows" so it reads as a desktop
    c(1, 1, 1, 0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: inner.minX + 40, y: inner.minY + 50, width: 250, height: 190), xRadius: 14, yRadius: 14).fill()
    NSBezierPath(roundedRect: NSRect(x: inner.minX + 320, y: inner.minY + 90, width: 240, height: 150), xRadius: 14, yRadius: 14).fill()
    NSGraphicsContext.restoreGraphicsState()
    // the notch itself
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: f.midX - 62, y: f.maxY - 12 - 26, width: 124, height: 26), xRadius: 12, yRadius: 12).fill()
    c(0.2, 0.25, 0.4).setFill(); NSBezierPath(ovalIn: NSRect(x: f.midX - 4, y: f.maxY - 12 - 17, width: 8, height: 8)).fill()
    // base
    c(0.75, 0.77, 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: f.minX - 40, y: f.minY - 22, width: f.width + 80, height: 22), xRadius: 11, yRadius: 11).fill()
}

screen(x: 90, merged: false)
screen(x: 870, merged: true)

label("Apple Screen Sharing", x: 90, y: 640, size: 36, weight: .semibold, color: .white)
label("remote menu bar sits below the camera row", x: 90, y: 602, size: 21, weight: .regular, color: c(1, 1, 1, 0.65))
label("NotchViewer", x: 870, y: 640, size: 36, weight: .semibold, color: .white)
label("remote menu bar shares the camera row", x: 870, y: 602, size: 21, weight: .regular, color: c(1, 1, 1, 0.65))
label("Illustration, not a screenshot", x: 480, y: 56, size: 18, weight: .regular, color: c(1, 1, 1, 0.45), width: 640)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
