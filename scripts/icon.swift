// Renders Flick's icon: a stack of fanned window cards on an indigo squircle.
// usage: icon <pixel size> <output.png>
import AppKit

let pixels = Int(CommandLine.arguments[1])!
let output = URL(fileURLWithPath: CommandLine.arguments[2])

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: 1024, height: 1024)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// macOS icon grid: an 824-pt squircle centred on a 1024-pt canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
drop.shadowOffset = NSSize(width: 0, height: -10)
drop.shadowBlurRadius = 24
drop.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.30, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.56, green: 0.29, blue: 0.93, alpha: 1),
])!.draw(in: squircle, angle: -60)

func card(_ rect: NSRect, fill: NSColor, chrome: Bool) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 30
    shadow.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard chrome else { return }
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 44 + CGFloat(index) * 52, y: rect.maxY - 76, width: 34, height: 34)).fill()
    }
    NSColor(srgbRed: 0.45, green: 0.38, blue: 0.95, alpha: 0.22).setFill()
    for (row, width) in [0.62, 0.44, 0.54].enumerated() {
        let bar = NSRect(x: rect.minX + 46, y: rect.maxY - 150 - CGFloat(row) * 58, width: (rect.width - 92) * width, height: 28)
        NSBezierPath(roundedRect: bar, xRadius: 14, yRadius: 14).fill()
    }
}

card(NSRect(x: 214, y: 470, width: 470, height: 330), fill: NSColor.white.withAlphaComponent(0.35), chrome: false)
card(NSRect(x: 277, y: 392, width: 470, height: 330), fill: NSColor.white.withAlphaComponent(0.6), chrome: false)
card(NSRect(x: 340, y: 236, width: 470, height: 360), fill: .white, chrome: true)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
