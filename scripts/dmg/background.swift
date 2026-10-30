// Draws the DMG window background (660×400 points) at 1x and 2x, then merges them into scripts/dmg/background.tiff
// so Finder picks the sharp one on Retina screens. Run: swift scripts/dmg/background.swift
import AppKit

let size = NSSize(width: 660, height: 400)
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/dmg")

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.93, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Arrow between the app icon (x 170) and the Applications link (x 490), at icon height (y 200 from the top).
    let y = size.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 268, y: y))
    arrow.line(to: NSPoint(x: 384, y: y))
    arrow.move(to: NSPoint(x: 370, y: y + 13))
    arrow.line(to: NSPoint(x: 388, y: y))
    arrow.line(to: NSPoint(x: 370, y: y - 13))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 0.62, alpha: 1).setStroke()
    arrow.stroke()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    func text(_ s: String, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            .draw(in: NSRect(x: 0, y: y, width: size.width, height: 30))
    }
    text("Drag Slashlight to Applications to install", 62, .systemFont(ofSize: 15, weight: .medium), NSColor(white: 0.25, alpha: 1))
    text("First launch: run  xattr -dr com.apple.quarantine /Applications/Slashlight.app", 36,
         .monospacedSystemFont(ofSize: 11, weight: .regular), NSColor(white: 0.45, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tool.arguments = ["-cathidpicheck", "background.png", "background@2x.png", "-out", "background.tiff"]
tool.currentDirectoryURL = out
try! tool.run()
tool.waitUntilExit()
for name in ["background.png", "background@2x.png"] { try? FileManager.default.removeItem(at: out.appendingPathComponent(name)) }
print("Wrote \(out.path)/background.tiff")
