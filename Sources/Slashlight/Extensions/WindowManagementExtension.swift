import AppKit
import ApplicationServices
import SlashlightKit

/// Moves and resizes the focused window of the frontmost app (Accessibility API).
/// Works from the panel (`/left-half`, or the Window Layout screen) and via ⌃⌥ global hotkeys.
final class WindowManagementExtension: Extension {
    enum Layout: String, CaseIterable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
        case topLeft, topRight, bottomLeft, bottomRight
        case maximize, almostMaximize, maximizeHeight, center, restore
        case nextDisplay, previousDisplay

        var title: String {
            switch self {
            case .leftHalf: "Left Half"; case .rightHalf: "Right Half"; case .topHalf: "Top Half"; case .bottomHalf: "Bottom Half"
            case .leftThird: "Left Third"; case .centerThird: "Center Third"; case .rightThird: "Right Third"
            case .leftTwoThirds: "Left Two Thirds"; case .rightTwoThirds: "Right Two Thirds"
            case .topLeft: "Top Left Quarter"; case .topRight: "Top Right Quarter"
            case .bottomLeft: "Bottom Left Quarter"; case .bottomRight: "Bottom Right Quarter"
            case .maximize: "Maximize"; case .almostMaximize: "Almost Maximize"; case .maximizeHeight: "Maximize Height"
            case .center: "Center"; case .restore: "Restore"
            case .nextDisplay: "Next Display"; case .previousDisplay: "Previous Display"
            }
        }

        var group: String {
            switch self {
            case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Halves"
            case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: "Thirds"
            case .topLeft, .topRight, .bottomLeft, .bottomRight: "Quarters"
            case .maximize, .almostMaximize, .maximizeHeight, .center, .restore: "Size & Position"
            case .nextDisplay, .previousDisplay: "Displays"
            }
        }

        var slug: String { title.lowercased().replacingOccurrences(of: " ", with: "-") }

        var symbol: String {
            switch self {
            case .leftHalf: "rectangle.lefthalf.filled"; case .rightHalf: "rectangle.righthalf.filled"
            case .topHalf: "rectangle.tophalf.filled"; case .bottomHalf: "rectangle.bottomhalf.filled"
            case .leftThird, .leftTwoThirds: "rectangle.leadingthird.inset.filled"
            case .centerThird: "rectangle.center.inset.filled"
            case .rightThird, .rightTwoThirds: "rectangle.trailingthird.inset.filled"
            case .topLeft: "rectangle.inset.topleft.filled"; case .topRight: "rectangle.inset.topright.filled"
            case .bottomLeft: "rectangle.inset.bottomleft.filled"; case .bottomRight: "rectangle.inset.bottomright.filled"
            case .maximize: "arrow.up.left.and.arrow.down.right"; case .almostMaximize: "rectangle.inset.filled"
            case .maximizeHeight: "arrow.up.and.down"; case .center: "rectangle.center.inset.filled"
            case .restore: "arrow.uturn.backward"
            case .nextDisplay: "display.2"; case .previousDisplay: "display.2"
            }
        }

        /// Rectangle-style ⌃⌥ hotkeys.
        var hotkey: Shortcut? {
            let m: Shortcut.Modifiers = [.control, .option]
            switch self {
            case .leftHalf: return Shortcut("left", m); case .rightHalf: return Shortcut("right", m)
            case .topHalf: return Shortcut("up", m); case .bottomHalf: return Shortcut("down", m)
            case .leftThird: return Shortcut("d", m); case .centerThird: return Shortcut("f", m); case .rightThird: return Shortcut("g", m)
            case .leftTwoThirds: return Shortcut("e", m); case .rightTwoThirds: return Shortcut("t", m)
            case .topLeft: return Shortcut("u", m); case .topRight: return Shortcut("i", m)
            case .bottomLeft: return Shortcut("j", m); case .bottomRight: return Shortcut("k", m)
            case .maximize: return Shortcut("return", m); case .center: return Shortcut("c", m)
            case .restore: return Shortcut("delete", m)
            case .nextDisplay: return Shortcut("right", [.control, .option, .command])
            case .previousDisplay: return Shortcut("left", [.control, .option, .command])
            case .almostMaximize, .maximizeHeight: return nil
            }
        }
    }

    private var previousFrames: [String: CGRect] = [:]

    override var manifest: Manifest {
        Manifest(id: "window-management", title: "Window Layout", subtitle: "Halves, thirds, quarters, maximize, displays", icon: .symbol("rectangle.split.2x1"))
    }

    override var triggers: [Trigger] { [.commands, .command("windows")] }
    override var permissions: [Permission] { [.accessibility] }

    override var globalHotkeys: [GlobalHotkey] {
        Layout.allCases.compactMap { layout in
            layout.hotkey.map { GlobalHotkey($0, title: layout.title) { [weak self] in self?.apply(layout, to: NSWorkspace.shared.frontmostApplication) } }
        }
    }

    override func search(_ query: Query) async throws -> [Section] {
        if query.mode == .command && query.isEmpty { return [] }
        let matches = Layout.allCases.filter { Fuzzy.score(query.text, [$0.title, $0.slug]) != nil }
        if query.mode == .command {
            return [Section("Window Layout", matches.map(item))]
        }
        var groups: [String: [Item]] = [:]
        var order: [String] = []
        for layout in matches {
            if groups[layout.group] == nil { order.append(layout.group) }
            groups[layout.group, default: []].append(item(layout))
        }
        return order.map { Section($0, groups[$0]!) }
    }

    private func item(_ layout: Layout) -> Item {
        let target = context.frontmostApplication?.localizedName
        return Item(id: layout.rawValue, title: layout.title, subtitle: target.map { "Focused window of \($0)" },
                    icon: .symbol(layout.symbol), accessories: layout.hotkey.map { [.keycap($0)] } ?? [],
                    primary: Action("Apply Layout") { [weak self] in
                        guard let self else { return .close }
                        let app = self.context.frontmostApplication
                        self.context.close()
                        return self.apply(layout, to: app) ? .close : .hud("No window to move")
                    })
    }

    @discardableResult
    func apply(_ layout: Layout, to app: NSRunningApplication?) -> Bool {
        guard AXIsProcessTrusted() else {
            Permissions.request(.accessibility)
            return false
        }
        guard let app, let window = AX.focusedWindow(pid: app.processIdentifier), let frame = AX.frame(of: window) else { return false }
        let key = "\(app.processIdentifier)-\(AX.title(of: window) ?? "")"

        if layout == .restore {
            guard let old = previousFrames[key] else { return false }
            AX.setFrame(window, old)
            return true
        }

        let screens = NSScreen.screens.map { AX.convert($0.visibleFrame) }
        guard !screens.isEmpty else { return false }
        let current = screens.indices.max { screens[$0].intersection(frame).area < screens[$1].intersection(frame).area } ?? 0
        var s = screens[current]

        let target: CGRect
        switch layout {
        case .leftHalf: target = CGRect(x: s.minX, y: s.minY, width: s.width / 2, height: s.height)
        case .rightHalf: target = CGRect(x: s.midX, y: s.minY, width: s.width / 2, height: s.height)
        case .topHalf: target = CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height / 2)
        case .bottomHalf: target = CGRect(x: s.minX, y: s.midY, width: s.width, height: s.height / 2)
        case .leftThird: target = CGRect(x: s.minX, y: s.minY, width: s.width / 3, height: s.height)
        case .centerThird: target = CGRect(x: s.minX + s.width / 3, y: s.minY, width: s.width / 3, height: s.height)
        case .rightThird: target = CGRect(x: s.minX + 2 * s.width / 3, y: s.minY, width: s.width / 3, height: s.height)
        case .leftTwoThirds: target = CGRect(x: s.minX, y: s.minY, width: 2 * s.width / 3, height: s.height)
        case .rightTwoThirds: target = CGRect(x: s.minX + s.width / 3, y: s.minY, width: 2 * s.width / 3, height: s.height)
        case .topLeft: target = CGRect(x: s.minX, y: s.minY, width: s.width / 2, height: s.height / 2)
        case .topRight: target = CGRect(x: s.midX, y: s.minY, width: s.width / 2, height: s.height / 2)
        case .bottomLeft: target = CGRect(x: s.minX, y: s.midY, width: s.width / 2, height: s.height / 2)
        case .bottomRight: target = CGRect(x: s.midX, y: s.midY, width: s.width / 2, height: s.height / 2)
        case .maximize: target = s
        case .almostMaximize: target = s.insetBy(dx: s.width * 0.05, dy: s.height * 0.05)
        case .maximizeHeight: target = CGRect(x: frame.minX, y: s.minY, width: frame.width, height: s.height)
        case .center: target = CGRect(x: s.midX - frame.width / 2, y: s.midY - frame.height / 2, width: frame.width, height: frame.height)
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return false }
            let from = s
            s = screens[(current + (layout == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
            // Keep the window's relative position and size on the new display.
            let rx = (frame.minX - from.minX) / from.width, ry = (frame.minY - from.minY) / from.height
            let rw = frame.width / from.width, rh = frame.height / from.height
            target = CGRect(x: s.minX + rx * s.width, y: s.minY + ry * s.height, width: rw * s.width, height: rh * s.height)
        case .restore: return false
        }
        previousFrames[key] = frame
        AX.setFrame(window, target.integral)
        return true
    }
}

/// Thin wrappers over the Accessibility C API. AX coordinates have a top-left origin on the primary display.
enum AX {
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    static func title(of w: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    static func frame(of w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        let size = AXValueCreate(.cgSize, &s)!, pos = AXValueCreate(.cgPoint, &p)!
        // Size, move, size again: some apps clamp size against the old screen edge.
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
    }

    static func raise(_ w: AXUIElement) {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func press(_ w: AXUIElement, button attribute: String) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, attribute as CFString, &value) == .success else { return }
        AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString)
    }

    /// Cocoa screen rect (bottom-left origin) → AX rect (top-left origin).
    static func convert(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
