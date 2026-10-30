// Draws the app icon and writes Resources/AppIcon.icns. Run: swift scripts/icon/icon.swift
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: an 824-point rounded square centred in 1024, with room for the shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.17, blue: 0.42, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1)])!
        .draw(in: tile, angle: -90)
    // A soft light behind the slash.
    NSGradient(colors: [NSColor(red: 0.55, green: 0.62, blue: 1, alpha: 0.55), NSColor(red: 0.55, green: 0.62, blue: 1, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 420, options: [])

    // The slash.
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: 400, y: 260))
    slash.line(to: NSPoint(x: 624, y: 764))
    slash.lineWidth = 104
    slash.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(red: 0.6, green: 0.7, blue: 1, alpha: 0.9)
    glow.shadowBlurRadius = 60
    glow.set()
    NSColor.white.setStroke()
    slash.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! draw(points * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/images/icon.png"))
let resources = root.appendingPathComponent("Resources")
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! tool.run()
tool.waitUntilExit()
print("Wrote Resources/AppIcon.icns and docs/images/icon.png")
