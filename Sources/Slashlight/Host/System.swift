import AppKit
import ApplicationServices
import ServiceManagement
import SlashlightKit

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Slashlight", isDirectory: true)
        // The app was called My Spotlight before; carry its settings, commands and snippets over once.
        let old = base.appendingPathComponent("MySpotlight", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var extensions: URL { support.appendingPathComponent("Extensions", isDirectory: true) }
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var recentExtensions: URL { support.appendingPathComponent("recent-extensions.json") }
    static var recents: URL { support.appendingPathComponent("recents.json") }
}

/// Extension ids, most recently used first. Used to sort the home screen.
/// What the user used, newest first: extensions they opened and items they ran.
/// Drives the home screen's Recent section and the order of `/` commands.
struct RecentsList: Equatable {
    struct Entry: Codable, Equatable {
        var ext: String
        /// Nil when the extension itself was opened.
        var item: String?
        var title: String?
        var date: Date
    }

    enum Pick: Equatable {
        case wholeExtension(String)
        case item(ext: String, id: String, title: String)
    }

    static let limit = 60
    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) { self.entries = entries }

    mutating func record(_ entry: Entry) {
        entries.removeAll { $0.ext == entry.ext && $0.item == entry.item }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func lastUsed(ext: String, item: String) -> Date? {
        entries.first { $0.ext == ext && $0.item == item }?.date
    }

    /// The home screen's Recent rows, newest first. Each extension decides whether its items or the extension itself appear.
    func home(limit: Int, mode: (String) -> RecentsMode?) -> [Pick] {
        var out: [Pick] = []
        for e in entries where out.count < limit {
            switch mode(e.ext) {
            case .wholeExtension?:
                let pick = Pick.wholeExtension(e.ext)
                if !out.contains(pick) { out.append(pick) }
            case .actions?:
                if let id = e.item { out.append(.item(ext: e.ext, id: id, title: e.title ?? id)) }
            case .hidden?, nil:
                continue
            }
        }
        return out
    }
}

/// The saved `RecentsList`.
@MainActor
enum Recents {
    private(set) static var list: RecentsList = load()

    /// Only an extension in `.actions` mode keeps item titles: other items are content (clipboard text) and are not written to disk.
    static func record(ext: String, item: (id: String, title: String)?, mode: RecentsMode) {
        guard mode != .hidden else { return }
        let keep = mode == .actions ? item : nil
        list.record(.init(ext: ext, item: keep?.id, title: keep?.title, date: Date()))
        try? JSONEncoder().encode(list.entries).write(to: Paths.recents, options: .atomic)
    }

    private static func load() -> RecentsList {
        if let data = try? Data(contentsOf: Paths.recents), let entries = try? JSONDecoder().decode([RecentsList.Entry].self, from: data) {
            return RecentsList(entries: entries)
        }
        // Before 0.4: a list of extension ids, newest first.
        let ids = (try? Data(contentsOf: Paths.recentExtensions)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let now = Date()
        return RecentsList(entries: ids.enumerated().map { .init(ext: $1, date: now.addingTimeInterval(-Double($0))) })
    }
}

enum Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess() || canReadOtherWindowTitles()
        case .automation: return true // asked by macOS on first AppleScript call
        }
    }

    /// `CGPreflightScreenCaptureAccess` keeps its first answer until the app restarts. Other apps' window titles
    /// become readable as soon as Screen Recording is granted, so they show the change live.
    private static func canReadOtherWindowTitles() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let owner = w[kCGWindowOwnerName as String] as? String, !["Window Server", "Dock"].contains(owner),
                  let name = w[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }

    /// For a switch that is on in System Settings but does nothing: that entry belongs to an earlier copy of
    /// Slashlight (macOS matches the exact build). Removes Slashlight's entry, then asks again for this copy.
    static func reset(_ p: Permission) {
        let service: String
        switch p {
        case .accessibility: service = "Accessibility"
        case .screenRecording: service = "ScreenCapture"
        case .automation: service = "AppleEvents"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "dev.slashlight.app"]
        try? task.run()
        task.waitUntilExit()
        request(p)
    }

    /// What to tell someone whose switch is on but not taking effect.
    static let staleHint = "Already on in System Settings? That switch can belong to an earlier copy of Slashlight. Reset removes it and asks again for this copy."

    static func request(_ p: Permission) {
        switch p {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            openPane("Privacy_Accessibility")
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
        case .automation:
            openPane("Privacy_Automation")
        }
    }

    static func title(_ p: Permission) -> String {
        switch p {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        }
    }

    static func reason(_ p: Permission) -> String {
        switch p {
        case .accessibility: return "Needed to move windows and paste into other apps"
        case .screenRecording: return "Needed for window titles and thumbnails"
        case .automation: return "Needed to open commands in Terminal"
        }
    }

    private static func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// `~/Library/Application Support/Slashlight/settings.json`
struct Settings: Codable, Equatable {
    var hotkey: String = "opt+space"
    var windowSwitcherHotkey: String = "opt+tab"
    var windowManagementHotkeys: Bool = true
    /// "system" | "light" | "dark"
    var appearance: String = "system"
    /// Panel background: 0.5 (see-through) to 1 (solid), and whether what shows through is blurred.
    var panelOpacity: Double = 0.85
    var panelBlur: Bool = true
    /// Manifest ids of extensions that are turned off.
    var disabledExtensions: [String] = []
    /// Download and install updates in the background (Sparkle's automatic updates).
    var autoInstallUpdates: Bool = true
    /// Offer beta builds as well as stable ones.
    var betaUpdates: Bool = false
    /// False until the welcome tour has been finished or closed once.
    var onboardingCompleted: Bool = false

    init() {}

    // Missing keys keep their defaults, so older settings files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        windowSwitcherHotkey = try c.decodeIfPresent(String.self, forKey: .windowSwitcherHotkey) ?? d.windowSwitcherHotkey
        windowManagementHotkeys = try c.decodeIfPresent(Bool.self, forKey: .windowManagementHotkeys) ?? d.windowManagementHotkeys
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        panelOpacity = min(1, max(0.5, try c.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? d.panelOpacity))
        panelBlur = try c.decodeIfPresent(Bool.self, forKey: .panelBlur) ?? d.panelBlur
        disabledExtensions = try c.decodeIfPresent([String].self, forKey: .disabledExtensions) ?? d.disabledExtensions
        autoInstallUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? d.autoInstallUpdates
        betaUpdates = try c.decodeIfPresent(Bool.self, forKey: .betaUpdates) ?? d.betaUpdates
        // A settings file from before the tour existed belongs to someone who has already set the app up.
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
    }

    static func load() -> Settings {
        if let data = try? Data(contentsOf: Paths.settings), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            return s
        }
        let s = Settings()
        s.save()
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Paths.settings)
    }

    @MainActor
    func applyAppearance() {
        PanelStyle.shared.opacity = panelOpacity
        PanelStyle.shared.blur = panelBlur
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

enum Shell {
    /// Runs `command` through the user's login shell and returns combined output.
    static func run(_ command: String, timeout: TimeInterval = 30) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                p.arguments = ["-lc", command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func openInTerminal(_ command: String) {
        let source = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(command))
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Slashlight: Terminal AppleScript failed: \(error)") }
    }
}

enum Keyboard {
    /// Posts ⌘V to whatever app is frontmost.
    static func pressPaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() throws {
        if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
