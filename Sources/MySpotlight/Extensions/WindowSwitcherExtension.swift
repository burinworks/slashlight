import AppKit
import ScreenCaptureKit
import SpotlightKit

/// ⌘Tab alternative with live thumbnails. ⌥⇥ opens it; keep ⌥ held and press ⇥ to move, release to switch.
final class WindowSwitcherExtension: Extension {
    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let appName: String
        let title: String
        let bounds: CGRect
    }

    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var capturedAt: [CGWindowID: Date] = [:]

    override var manifest: Manifest {
        Manifest(id: "window-switcher", title: "Switch Window", subtitle: "Pick a window by its thumbnail", icon: .symbol("macwindow.on.rectangle"))
    }

    override var triggers: [Trigger] { [.command("switch")] }
    override var permissions: [Permission] { [.screenRecording, .accessibility] }

    override var globalHotkeys: [GlobalHotkey] {
        let s = Shortcut(string: Settings.load().windowSwitcherHotkey) ?? Shortcut("tab", .option)
        return [GlobalHotkey(s, title: "Switch Window") { [weak self] in self?.hotkeyPressed(s) }]
    }

    private func hotkeyPressed(_ s: Shortcut) {
        let host = Host.shared
        if host.isVisible, host.model.current.extensionID == manifest.id {
            host.model.move(1)
        } else {
            host.show(extensionID: manifest.id)
            host.model.holdModifier = s.modifiers
        }
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Filter windows…", layout: .grid(columns: 3),
                 initialSelection: 1) { [unowned self] q in try await self.search(q) }
    }

    override func search(_ query: Query) async throws -> [Section] {
        let windows = Self.listWindows().filter { Fuzzy.score(query.text, [$0.appName, $0.title]) != nil }
        captureThumbnails(windows.map(\.id))
        return [Section("Windows", windows.map(item))]
    }

    private func item(_ w: WindowInfo) -> Item {
        let app = NSRunningApplication(processIdentifier: w.pid)
        let icon: Icon = thumbnails[w.id].map { .image($0) } ?? app?.bundleURL.map { .file($0.path) } ?? .symbol("macwindow")
        return Item(
            id: "\(w.id)", title: w.title.isEmpty ? w.appName : w.title, subtitle: w.title.isEmpty ? nil : w.appName, icon: icon,
            primary: Action("Switch to Window", icon: .symbol("macwindow")) {
                Self.focus(w)
                return .close
            },
            secondary: Action("Show App's Windows", icon: .symbol("square.stack")) {
                app?.activate(options: [.activateAllWindows])
                return .close
            },
            more: [
                Action("Minimize Window", icon: .symbol("minus.square"), shortcut: Shortcut("m", .command)) {
                    if let ax = Self.axWindow(for: w) { AX.press(ax, button: kAXMinimizeButtonAttribute) }
                    return .stay
                },
                Action("Close Window", icon: .symbol("xmark.square"), shortcut: Shortcut("w", .command), destructive: true) {
                    if let ax = Self.axWindow(for: w) { AX.press(ax, button: kAXCloseButtonAttribute) }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    return .stay
                },
                Action("Quit App", icon: .symbol("xmark.circle"), shortcut: Shortcut("q", [.command, .option]), destructive: true) {
                    app?.terminate()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return .stay
                },
            ])
    }

    /// On-screen, normal-level windows of other apps, front to back.
    static func listWindows() -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  (d[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { return nil }
            let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard bounds.width > 80, bounds.height > 60 else { return nil }
            return WindowInfo(id: id, pid: pid, appName: d[kCGWindowOwnerName as String] as? String ?? "App",
                              title: d[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
    }

    static func axWindow(for w: WindowInfo) -> AXUIElement? {
        let candidates = AX.windows(pid: w.pid)
        return candidates.first { AX.title(of: $0) == w.title && AX.frame(of: $0) == w.bounds }
            ?? candidates.first { AX.frame(of: $0) == w.bounds }
            ?? candidates.first { AX.title(of: $0) == w.title }
    }

    static func focus(_ w: WindowInfo) {
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        if let ax = axWindow(for: w) { AX.raise(ax) }
    }

    private func captureThumbnails(_ ids: [CGWindowID]) {
        // Only stale ones: the refresh below re-runs search, which must not capture again.
        let ids = ids.filter { Date().timeIntervalSince(capturedAt[$0] ?? .distantPast) > 3 }
        guard !ids.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        ids.forEach { capturedAt[$0] = Date() }
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            var changed = false
            for id in ids.prefix(18) {
                guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1, 480 / max(scWindow.frame.width, 1))
                config.width = Int(scWindow.frame.width * scale * 2)
                config.height = Int(scWindow.frame.height * scale * 2)
                config.showsCursor = false
                guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                                            configuration: config) else { continue }
                self?.thumbnails[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                changed = true
            }
            if changed { self?.context.refresh() }
        }
    }
}
