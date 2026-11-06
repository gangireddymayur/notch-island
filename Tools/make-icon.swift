// Draws the Notch Island app icon and writes Resources/AppIcon.icns
// plus docs/icon.png. Run: swift Tools/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024  // design on a 1024 grid
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // macOS icon grid: 824×824 body, 100pt margin, with a soft drop shadow.
    let body = r(100, 100, 824, 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    color(0x101830).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Sunset wallpaper.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0xF4A261), color(0xE76F7A), color(0x6B4FA8), color(0x1E2A5A), color(0x0E1430)],
               atLocations: [0, 0.22, 0.5, 0.78, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: 90)
    // Soft sun glow near the bottom.
    NSGradient(colors: [color(0xFFD29A, 0.55), color(0xFFD29A, 0)])!
        .draw(fromCenter: NSPoint(x: 512 * s, y: 190 * s), radius: 0,
              toCenter: NSPoint(x: 512 * s, y: 190 * s), radius: 420 * s, options: [])

    // Island glow.
    NSGradient(colors: [color(0x9B8CFF, 0.45), color(0x9B8CFF, 0)])!
        .draw(fromCenter: NSPoint(x: 512 * s, y: 690 * s), radius: 0,
              toCenter: NSPoint(x: 512 * s, y: 690 * s), radius: 360 * s, options: [])

    // The island.
    let island = r(232, 615, 560, 150)
    NSGraphicsContext.saveGraphicsState()
    let ishadow = NSShadow()
    ishadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    ishadow.shadowBlurRadius = 30 * s
    ishadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    ishadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: 75 * s, yRadius: 75 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    // Subtle top highlight on the island edge.
    color(0xFFFFFF, 0.08).setStroke()
    let edge = NSBezierPath(roundedRect: island.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 73 * s, yRadius: 73 * s)
    edge.lineWidth = 3 * s
    edge.stroke()

    // Album art dot.
    let art = r(282, 645, 90, 90)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: art, xRadius: 26 * s, yRadius: 26 * s).addClip()
    NSGradient(colors: [color(0xFF5F8F), color(0xFFB347)])!.draw(in: art, angle: 45)
    NSGraphicsContext.restoreGraphicsState()

    // Equalizer bars.
    let heights: [CGFloat] = [46, 86, 62, 100, 54]
    for (i, h) in heights.enumerated() {
        let x = 600 + CGFloat(i) * 30
        color(0x30D158).setFill()
        NSBezierPath(roundedRect: r(x, 690 - h / 2, 16, h), xRadius: 8 * s, yRadius: 8 * s).fill()
    }

    // Glassy top sheen on the whole icon.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: r(100, 600, 824, 324), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline border.
    color(0xFFFFFF, 0.12).setStroke()
    squircle.lineWidth = 2 * s
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
