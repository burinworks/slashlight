import AppKit
import ScreenCaptureKit
import SpotlightKit

/// ⌘Tab alternative with live thumbnails. ⌥⇥ opens it; keep ⌥ held and press ⇥ to move, release to switch.
/// ⌘Tab alternative with live thumbnails. ⌥⇥ opens it; keep ⌥ held and press ⇥ to move, release to switch.
/// Lists windows on every Space and display, not only the visible ones.
final class WindowSwitcherExtension: Extension {
    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let appName: String
        let title: String
        let bounds: CGRect
        /// nil when found through CGWindowList only (no Accessibility permission).
        var ax: AXUIElement? = nil
        var onCurrentSpace = true
        var minimized = false
    }

    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var capturedAt: [CGWindowID: Date] = [:]
    private var cached: [WindowInfo] = []
    private var scannedAt = Date.distantPast
    private var scanning = false

    override var manifest: Manifest {
        Manifest(id: "window-switcher", title: "Switch Window", subtitle: "Pick a window by its thumbnail, across Spaces", icon: .symbol("macwindow.on.rectangle"))
    }

    override var triggers: [Trigger] { [.command("switch")] }
    override var permissions: [Permission] { [.screenRecording, .accessibility] }

    override var globalHotkeys: [GlobalHotkey] {
        let s = Shortcut(string: Settings.load().windowSwitcherHotkey) ?? Shortcut("tab", .option)
        return [GlobalHotkey(s, title: "Switch Window") { [weak self] in self?.hotkeyPressed(s) }]
    }

    override func activate(context: ExtensionContext) async {
        if AXIsProcessTrusted() { cached = await Self.scanAllSpaces(); scannedAt = Date() }
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
        let all: [WindowInfo]
        if AXIsProcessTrusted() {
            // Scanning every Space takes ~200 ms, so answer from the cache and rescan in the background.
            if cached.isEmpty { cached = await Self.scanAllSpaces(); scannedAt = Date() } else { rescanIfStale() }
            all = cached
        } else {
            all = Self.listVisibleWindows()
        }
        let windows = all.filter { Fuzzy.score(query.text, [$0.appName, $0.title]) != nil }
        captureThumbnails(windows.map(\.id))
        return [Section("Windows", windows.map(item))]
    }

    private func rescanIfStale() {
        guard !scanning, Date().timeIntervalSince(scannedAt) > 1 else { return }
        scanning = true
        Task { [weak self] in
            let fresh = await Self.scanAllSpaces()
            guard let self else { return }
            self.scanning = false
            self.scannedAt = Date()
            let changed = fresh.map { "\($0.id)|\($0.title)|\($0.minimized)|\($0.onCurrentSpace)" }
                != self.cached.map { "\($0.id)|\($0.title)|\($0.minimized)|\($0.onCurrentSpace)" }
            self.cached = fresh
            if changed { self.context.refresh() }
        }
    }

    private func item(_ w: WindowInfo) -> Item {
        let app = NSRunningApplication(processIdentifier: w.pid)
        let icon: Icon = thumbnails[w.id].map { .image($0) } ?? app?.bundleURL.map { .file($0.path) } ?? .symbol("macwindow")
        var accessories: [Accessory] = []
        if w.minimized { accessories.append(.pill("Minimized", .gray)) } else if !w.onCurrentSpace { accessories.append(.pill("Other Space", .blue)) }
        return Item(
            id: "\(w.id)", title: w.title.isEmpty ? w.appName : w.title, subtitle: w.title.isEmpty ? nil : w.appName, icon: icon,
            accessories: accessories,
            primary: Action("Switch to Window", icon: .symbol("macwindow")) {
                Self.focus(w)
                return .close
            },
            secondary: Action("Show App's Windows", icon: .symbol("square.stack")) {
                app?.activate(options: [.activateAllWindows])
                return .close
            },
            more: [
                Action("Minimize Window", icon: .symbol("minus.square"), shortcut: Shortcut("m", .command)) { [weak self] in
                    if let ax = Self.axWindow(for: w) { AX.press(ax, button: kAXMinimizeButtonAttribute) }
                    self?.scannedAt = .distantPast
                    return .stay
                },
                Action("Close Window", icon: .symbol("xmark.square"), shortcut: Shortcut("w", .command), destructive: true) { [weak self] in
                    if let ax = Self.axWindow(for: w) { AX.press(ax, button: kAXCloseButtonAttribute) }
                    self?.cached.removeAll { $0.id == w.id }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    return .stay
                },
                Action("Quit App", icon: .symbol("xmark.circle"), shortcut: Shortcut("q", [.command, .option]), destructive: true) { [weak self] in
                    app?.terminate()
                    self?.cached.removeAll { $0.pid == w.pid }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return .stay
                },
            ])
    }

    // MARK: Window discovery

    /// CGWindowList entries for normal-level windows, front to back.
    private static func cgWindows(onScreenOnly: Bool) -> [[String: Any]] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private static func bounds(_ d: [String: Any]) -> CGRect {
        let b = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    /// Fallback without Accessibility: only windows on the visible Spaces.
    static func listVisibleWindows() -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        return cgWindows(onScreenOnly: true).compactMap { d in
            guard let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  (d[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { return nil }
            let bounds = bounds(d)
            guard bounds.width > 80, bounds.height > 60 else { return nil }
            return WindowInfo(id: id, pid: pid, appName: d[kCGWindowOwnerName as String] as? String ?? "App",
                              title: d[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
    }

    /// Real windows of every regular app on every Space, most recently used first.
    /// The Accessibility API only reports windows on the current Space, so other Spaces are found by
    /// enumerating the app's AX element tokens (the technique AltTab uses).
    static func scanAllSpaces() async -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "App") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let all = cgWindows(onScreenOnly: false)
                var zOrder: [CGWindowID: Int] = [:], cgInfo: [CGWindowID: [String: Any]] = [:]
                for (i, d) in all.enumerated() {
                    if let id = d[kCGWindowNumber as String] as? CGWindowID { zOrder[id] = i; cgInfo[id] = d }
                }
                let lock = NSLock()
                var found: [WindowInfo] = []
                DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                    let app = apps[i]
                    let windows = AXRemote.windows(pid: app.pid).compactMap { ax -> WindowInfo? in
                        guard let id = AXRemote.windowID(ax), let d = cgInfo[id] else { return nil }
                        let minimized = (AXRemote.attribute(ax, kAXMinimizedAttribute) as? Bool) ?? false
                        let onScreen = d[kCGWindowIsOnscreen as String] as? Bool ?? false
                        let title = AXRemote.attribute(ax, kAXTitleAttribute) as? String ?? ""
                        // Untitled windows that are neither visible nor minimized are hidden helpers, not user windows.
                        if title.isEmpty && !onScreen && !minimized { return nil }
                        return WindowInfo(id: id, pid: app.pid, appName: app.name, title: title, bounds: bounds(d), ax: ax,
                                          onCurrentSpace: onScreen, minimized: minimized)
                    }
                    lock.lock(); found += windows; lock.unlock()
                }
                cont.resume(returning: found.sorted { (zOrder[$0.id] ?? .max, $0.id) < (zOrder[$1.id] ?? .max, $1.id) })
            }
        }
    }

    static func axWindow(for w: WindowInfo) -> AXUIElement? {
        if let ax = w.ax { return ax }
        let candidates = AX.windows(pid: w.pid)
        return candidates.first { AXRemote.windowID($0) == w.id }
            ?? candidates.first { AX.title(of: $0) == w.title && AX.frame(of: $0) == w.bounds }
            ?? candidates.first { AX.frame(of: $0) == w.bounds }
    }

    static func focus(_ w: WindowInfo) {
        let ax = axWindow(for: w)
        if let ax, w.minimized { AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        // Raise first: activating then switches to the Space that holds the now-main window.
        if let ax { AX.raise(ax) }
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        if let ax { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { AX.raise(ax) } }
    }

    private func captureThumbnails(_ ids: [CGWindowID]) {
        // Only stale ones: the refresh below re-runs search, which must not capture again.
        let ids = ids.filter { Date().timeIntervalSince(capturedAt[$0] ?? .distantPast) > 3 }
        guard !ids.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        ids.forEach { capturedAt[$0] = Date() }
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
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

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Accessibility helpers that reach windows on other Spaces. Uses two private but long-stable AX calls.
enum AXRemote {
    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(e, name as CFString, &value)
        return value
    }

    static func windowID(_ e: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
    }

    /// Standard windows and dialogs of `pid` on all Spaces, deduplicated by window id.
    static func windows(pid: pid_t, budget: TimeInterval = 0.15) -> [AXUIElement] {
        var result: [CGWindowID: AXUIElement] = [:]
        let isWindow = { (e: AXUIElement) -> Bool in
            let sub = attribute(e, kAXSubroleAttribute) as? String
            return sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole
        }
        for e in AX.windows(pid: pid) where isWindow(e) {
            if let id = windowID(e) { result[id] = e }
        }
        // Token layout: pid (4 bytes), 0 (4), "coco" (4), element id (8).
        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: UInt32(0x636f636f)) { token.replaceSubrange(8..<12, with: $0) }
        let start = Date()
        for elementID: UInt64 in 0..<1000 {
            withUnsafeBytes(of: elementID) { token.replaceSubrange(12..<20, with: $0) }
            if let e = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(), isWindow(e),
               let id = windowID(e), result[id] == nil {
                result[id] = e
            }
            if Date().timeIntervalSince(start) > budget { break }
        }
        return Array(result.values)
    }
}
