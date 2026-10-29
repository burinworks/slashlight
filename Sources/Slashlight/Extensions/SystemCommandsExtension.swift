import AppKit
import SlashlightKit

/// Lock, sleep, restart, empty the trash… as `/lock`, `/sleep` and so on, or by name in default search.
/// Everything goes through public tools: `pmset`, `defaults`, Finder / System Events AppleScript and NSRunningApplication.
final class SystemCommandsExtension: Extension {
    struct Command {
        /// Typed after `/`, e.g. "lock".
        var name: String
        var title: String
        var subtitle: String
        var symbol: String
        var keywords: [String] = []
        var destructive = false
        var run: @MainActor () async -> Outcome
    }

    override var manifest: Manifest {
        Manifest(id: "system", title: "System", subtitle: "Lock, sleep, restart, empty trash, dark mode…", icon: .symbol("power"))
    }

    override var triggers: [Trigger] { [.defaultSearch, .commands, .command("system")] }

    override var permissions: [Permission] { [.automation] }

    override func search(_ query: Query) async throws -> [Section] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if query.mode == .scoped && text.isEmpty { return [Section("System", Self.commands.map(item))] }
        // Plain typing only gets a strong match (a contiguous match of at least 3 characters), so "sl" does not offer Sleep.
        if query.mode == .default && text.count < 3 { return [] }
        if query.mode == .command && text.isEmpty { return [] }
        let minimum = query.mode == .default ? 900 : Int.min
        let matches = Self.commands
            .compactMap { c -> (Int, Command)? in
                guard let s = Fuzzy.score(text, [c.title, c.name] + c.keywords), s >= minimum else { return nil }
                return (s, c)
            }
            .sorted { $0.0 > $1.0 }
            .map { item($0.1) }
        return [Section("System", matches)]
    }

    private func item(_ c: Command) -> Item {
        Item(id: c.name, title: c.title, subtitle: c.subtitle, icon: .symbol(c.symbol), accessories: [.text("/\(c.name)")],
             primary: Action(c.title, icon: .symbol(c.symbol), destructive: c.destructive) { await c.run() })
    }

    // MARK: Commands

    private static let commands: [Command] = [
        Command(name: "lock", title: "Lock Screen", subtitle: "Show the login window", symbol: "lock", keywords: ["lock"]) {
            // ⌃⌘Q is the system Lock Screen shortcut; posting it needs only Accessibility.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pressKey(12, [.maskCommand, .maskControl]) }
            return .close
        },
        Command(name: "sleep", title: "Sleep", subtitle: "Put the Mac to sleep", symbol: "moon.zzz") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Task { _ = await Shell.run("/usr/bin/pmset sleepnow") } }
            return .close
        },
        Command(name: "sleep-displays", title: "Sleep Displays", subtitle: "Turn the screens off, keep the Mac running", symbol: "display",
                keywords: ["screen off", "monitor"]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Task { _ = await Shell.run("/usr/bin/pmset displaysleepnow") } }
            return .close
        },
        Command(name: "restart", title: "Restart", subtitle: "Restart the Mac; apps can ask to save", symbol: "restart", keywords: ["reboot"],
                destructive: true) {
            appleScript("tell application \"System Events\" to restart")
        },
        Command(name: "shutdown", title: "Shut Down", subtitle: "Turn the Mac off; apps can ask to save", symbol: "power",
                keywords: ["shutdown", "power off", "turn off"], destructive: true) {
            appleScript("tell application \"System Events\" to shut down")
        },
        Command(name: "logout", title: "Log Out", subtitle: "Log out of this user account", symbol: "rectangle.portrait.and.arrow.right",
                keywords: ["logout", "sign out"], destructive: true) {
            appleScript("tell application \"System Events\" to log out")
        },
        Command(name: "empty-trash", title: "Empty Trash", subtitle: "Permanently erase the items in the Trash", symbol: "trash.slash",
                keywords: ["bin", "delete"], destructive: true) {
            appleScript("tell application \"Finder\" to empty trash", done: "Trash emptied")
        },
        Command(name: "eject", title: "Eject All Disks", subtitle: "Unmount every external and disk-image volume", symbol: "eject",
                keywords: ["unmount", "drive", "usb"]) {
            appleScript("tell application \"Finder\" to eject (every disk whose ejectable is true)", done: "Disks ejected")
        },
        Command(name: "dark-mode", title: "Toggle Dark Mode", subtitle: "Switch between light and dark appearance", symbol: "circle.lefthalf.filled",
                keywords: ["appearance", "light mode", "theme"]) {
            appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode", done: nil)
        },
        Command(name: "hidden-files", title: "Toggle Hidden Files in Finder", subtitle: "Show or hide dotfiles (restarts Finder)", symbol: "eye",
                keywords: ["dotfiles", "show hidden", "invisible"]) {
            let current = await Shell.run("/usr/bin/defaults read com.apple.finder AppleShowAllFiles").output
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let show = !["1", "true", "yes"].contains(current)
            _ = await Shell.run("/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool \(show) && /usr/bin/killall Finder")
            return .hud(show ? "Hidden files shown" : "Hidden files hidden")
        },
        Command(name: "hide-all", title: "Hide All Apps", subtitle: "Hide the windows of every running app", symbol: "eye.slash",
                keywords: ["hide others", "clean"]) {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != .current { app.hide() }
            return .close
        },
        Command(name: "quit-all", title: "Quit All Apps", subtitle: "Quit every app except Finder and Slashlight; apps can ask to save",
                symbol: "xmark.app", keywords: ["close all", "quit apps"], destructive: true) {
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0 != .current && $0.bundleIdentifier != "com.apple.finder"
            }
            apps.forEach { $0.terminate() }
            return .hud("Quitting \(apps.count) app\(apps.count == 1 ? "" : "s")")
        },
        Command(name: "show-desktop", title: "Show Desktop", subtitle: "Move windows aside to reveal the desktop", symbol: "menubar.dock.rectangle",
                keywords: ["desktop"]) {
            // Launching Mission Control with argument 1 triggers its Show Desktop mode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
                p.arguments = ["1"]
                try? p.run()
            }
            return .close
        },
        Command(name: "open-trash", title: "Open Trash", subtitle: "Show the Trash in Finder", symbol: "trash", keywords: ["bin"]) {
            appleScript("tell application \"Finder\"\nopen trash\nactivate\nend tell", done: nil)
        },
    ]

    /// Runs AppleScript on the main thread; an error becomes the HUD, success closes (or shows `done`).
    private static func appleScript(_ source: String, done: String? = nil) -> Outcome {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { return .hud("Failed: \(error[NSAppleScript.errorMessage] ?? "AppleScript error")") }
        return done.map { .hud($0) } ?? .close
    }

    private static func pressKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
