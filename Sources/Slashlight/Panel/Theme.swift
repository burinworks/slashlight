import AppKit
import SwiftUI
import SlashlightKit

/// Design tokens from the visual-design note. Every color has a light and a dark value.
enum Theme {
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
    static let footer = dynamic(light: 0xFAFAFA, dark: 0x19191B)
    static let text = dynamic(light: 0x1A1A1A, dark: 0xF2F2F3)
    static let secondary = dynamic(light: 0x8A8A8A, dark: 0x8E8E93)
    // Tints, not solid colors, so they read on the see-through background in both themes.
    static let selection = tint(light: 0.07, dark: 0.09)
    static let tile = tint(light: 0.05, dark: 0.07)
    static let divider = tint(light: 0.08, dark: 0.08)
    static let border = dynamic(light: 0xE4E4E7, dark: 0x3A3A3D)
    static let keycapBorder = dynamic(light: 0xDADADA, dark: 0x48484C)
    static let keycapFill = dynamic(light: 0xFFFFFF, dark: 0x262629)
    static let detail = dynamic(light: 0xF7F7F8, dark: 0x161618)

    static func pill(_ tint: Tint) -> (bg: Color, fg: Color) {
        switch tint {
        case .blue: return (dynamic(light: 0xEEF5FF, dark: 0x1D2A3E), dynamic(light: 0x1F5FBF, dark: 0x8AB4FF))
        case .green: return (dynamic(light: 0xEAF7EE, dark: 0x1B3022), dynamic(light: 0x1E7B3C, dark: 0x7BD69A))
        case .orange: return (dynamic(light: 0xFFF3E6, dark: 0x3A2A17), dynamic(light: 0xB25B00, dark: 0xFFB869))
        case .red: return (dynamic(light: 0xFDECEC, dark: 0x3B1D1D), dynamic(light: 0xB42323, dark: 0xFF8A8A))
        case .gray: return (tile, secondary)
        }
    }

    static let width: CGFloat = 720
    static let radius: CGFloat = 16
    static let maxListHeight: CGFloat = 430

    /// Black at `light` opacity in the light theme, white at `dark` opacity in the dark one.
    private static func tint(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The panel's background settings, published so the open panel follows the Settings window live.
@MainActor
final class PanelStyle: ObservableObject {
    static let shared = PanelStyle()
    /// 0.5 (see-through) to 1 (solid).
    @Published var opacity: Double = 0.85
    /// Blur what is behind the panel. Without it, a see-through panel shows the desktop sharp.
    @Published var blur = true
}

/// Blurred desktop with the theme's panel color on top, at the chosen opacity.
struct PanelBackground: View {
    @ObservedObject var style: PanelStyle
    /// `.withinWindow` blurs the window's own content; used by the preview in Settings.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        ZStack {
            if style.blur { VisualEffect(blending: blending) }
            Theme.panel.opacity(style.opacity)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = blending
        v.state = .active // the panel never becomes the active app's main window
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.blendingMode = blending }
}

/// Finder icons are slow-ish to look up; cache them by path.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        cache[path] = img
        return img
    }
}
