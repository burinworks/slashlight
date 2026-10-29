import AppKit
import ApplicationServices
import ServiceManagement
import SpotlightKit

enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MySpotlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var extensions: URL { support.appendingPathComponent("Extensions", isDirectory: true) }
    static var settings: URL { support.appendingPathComponent("settings.json") }
}

enum Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .automation: return true // asked by macOS on first AppleScript call
        }
    }

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

/// `~/Library/Application Support/MySpotlight/settings.json`
struct Settings: Codable, Equatable {
    var hotkey: String = "opt+space"
    var windowSwitcherHotkey: String = "opt+tab"
    var windowManagementHotkeys: Bool = true
    /// "system" | "light" | "dark"
    var appearance: String = "system"
    /// Manifest ids of extensions that are turned off.
    var disabledExtensions: [String] = []

    init() {}

    // Missing keys keep their defaults, so older settings files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        windowSwitcherHotkey = try c.decodeIfPresent(String.self, forKey: .windowSwitcherHotkey) ?? d.windowSwitcherHotkey
        windowManagementHotkeys = try c.decodeIfPresent(Bool.self, forKey: .windowManagementHotkeys) ?? d.windowManagementHotkeys
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        disabledExtensions = try c.decodeIfPresent([String].self, forKey: .disabledExtensions) ?? d.disabledExtensions
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
        if let error { NSLog("MySpotlight: Terminal AppleScript failed: \(error)") }
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
