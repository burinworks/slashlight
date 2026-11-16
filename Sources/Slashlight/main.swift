import AppKit
import SlashlightKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    /// The Dock icon appears only once the switch to `.regular` has gone through, and a badge set before that is
    /// dropped, so set it again until it sticks.
    private func showBadge() {
        for delay in [0, 0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSApp.dockTile.badgeLabel = BuildInfo.badge }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Local and test builds stay in the Dock with a badge, so it is always clear which build is running.
        if DevSuite.isActive {
            // Automated checks: no Dock icon, menu bar icon or update checks; see DevSuite.
            NSApp.setActivationPolicy(.accessory)
        } else if BuildInfo.isPreview {
            NSApp.setActivationPolicy(.regular)
            setUpMainMenu()
            showBadge()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        if !DevSuite.isActive {
            setUpStatusItem()
            Updater.shared.start(with: Host.shared.settings)
        }
        Task {
            await Host.shared.start()
            _ = Host.shared.panel // build the panel up-front so the first open is instant
            if CommandLine.arguments.contains("--list-windows") {
                for w in await WindowSwitcherExtension.scanAllSpaces() {
                    print(w.onCurrentSpace ? "here " : "other", w.minimized ? "min" : "   ", w.appName, "—", w.title)
                }
                exit(0)
            }
            if argument("--snapshot") != nil || CommandLine.arguments.contains("--dump") {
                await snapshot(to: argument("--snapshot"))
                return
            }
            if CommandLine.arguments.contains("--settings") {
                SettingsWindowController.shared.show(tab: argument("--tab").flatMap(SettingsTab.init(rawValue:)))
                if let path = argument("--snapshot-settings") {
                    if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    SettingsWindowController.shared.snapshot(to: path)
                    exit(0)
                }
                return
            }
            // Debug aid: `--onboarding [--step 1…6] [--snapshot-onboarding out.png] [--dark]` opens the welcome tour at a
            // step; with a path it renders that step with animations at rest and quits.
            if CommandLine.arguments.contains("--onboarding") {
                let step = argument("--step").flatMap(Int.init).flatMap { OnboardingStep(rawValue: $0 - 1) } ?? .welcome
                let path = argument("--snapshot-onboarding")
                if CommandLine.arguments.contains("--dark") || path != nil {
                    NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
                }
                if let path {
                    OnboardingWindowController.shared.show(step: step, still: true)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    OnboardingWindowController.shared.snapshot(to: path)
                    exit(0)
                }
                OnboardingWindowController.shared.show(step: step)
                return
            }
            if !DevSuite.isActive { Install.noteLaunch() }
            if !Host.shared.settings.onboardingCompleted && !DevSuite.isActive {
                OnboardingWindowController.shared.show()
                return
            }
            if !CommandLine.arguments.contains("--background") { Host.shared.show() }
        }
    }

    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Debug aid: `Slashlight --snapshot out.png [--query text] [--open ext-id] [--filter name] [--delay s] [--enter] [--dark]`
    /// renders the panel and quits.
    /// `--snapshot out.png` renders the panel; `--dump` prints its sections and rows (what the dev suite checks).
    private func snapshot(to path: String?) async {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let host = Host.shared
        host.show(extensionID: argument("--open"))
        if let q = argument("--query") { host.model.text = q }
        let delay = argument("--delay").flatMap(Double.init) ?? 1.5
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if let f = argument("--filter") {
            for _ in host.model.filters where host.model.activeFilter != f { host.model.cycleFilter(1) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if CommandLine.arguments.contains("--enter") {
            host.model.runPrimary()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if let session = TerminalManager.shared.sessions.last {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for line in session.view.visibleRowsText(0..<30) where !line.trimmingCharacters(in: .whitespaces).isEmpty { print("│ " + line) }
            print("state:", session.activity)
        }
        if CommandLine.arguments.contains("--dump") {
            for section in host.model.sections {
                print("## \(section.title)")
                for row in section.rows {
                    let mark = row.index == host.model.selection ? ">" : " "
                    print("\(mark) \(row.item.title)  [\(row.extensionID ?? "-")]")
                }
            }
            print("footer: " + host.model.hints.map { "\($0.keys) \($0.label)" }.joined(separator: " · "))
            fflush(stdout)
        }
        if let path {
            guard let view = host.panel.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    /// The menu bar icon: always there while Slashlight runs, so you can see it's running and reach Settings or
    /// Quit even though the app has no Dock icon. The tour and Uninstall stay out of beta and stable menus, as in
    /// Settings → About.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Slashlight"
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "\(BuildInfo.name) is running"
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(BuildInfo.name) is running", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let version = NSMenuItem(title: "Version \(BuildInfo.fullVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open \(BuildInfo.name)", action: #selector(open), keyEquivalent: "")
        open.target = self
        open.tag = Self.openItemTag
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Config Folder", action: #selector(config), keyEquivalent: "").target = self
        if BuildInfo.isPreview {
            menu.addItem(withTitle: "Show Welcome Tour", action: #selector(tour), keyEquivalent: "").target = self
        }
        if Updater.shared.isAvailable {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkForUpdates), keyEquivalent: "").target = Updater.shared
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Send Feedback…", action: #selector(feedback), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if BuildInfo.isPreview {
            menu.addItem(withTitle: "Uninstall \(BuildInfo.name)…", action: #selector(uninstall), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Quit \(BuildInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private static let openItemTag = 1

    /// Shows the current Open Slashlight key, which can change in Settings while the app runs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.item(withTag: Self.openItemTag) else { return }
        let key = Shortcut(string: Host.shared.settings.hotkey).map { "  (\($0.display))" } ?? ""
        item.title = "Open \(BuildInfo.name)\(key)"
    }

    /// Slashlight's mark for the menu bar: a rounded square with the slash cut out, as a template image so it
    /// follows the menu bar's colour.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let box = rect.insetBy(dx: 2, dy: 2)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3.6, yRadius: 3.6).fill()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: box.minX + box.width * 0.62, y: box.minY + box.height * 0.80))
            slash.line(to: NSPoint(x: box.minX + box.width * 0.38, y: box.minY + box.height * 0.20))
            slash.lineWidth = box.width * 0.15
            slash.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = BuildInfo.name
        return image
    }

    /// The menu bar of Dock builds: the app menu only, so the panel's own shortcuts keep working.
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Open \(BuildInfo.name)", action: #selector(open), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Show Welcome Tour", action: #selector(tour), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Uninstall \(BuildInfo.name)…", action: #selector(uninstall), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Quit \(BuildInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        let root = NSMenuItem()
        root.submenu = appMenu
        let main = NSMenu()
        main.addItem(root)
        NSApp.mainMenu = main
    }

    /// Clicking the Dock icon opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Host.shared.show() }
        return true
    }

    @objc private func uninstall() { Install.confirmUninstall() }

    @objc private func feedback() { NSWorkspace.shared.open(ProjectLinks.feedback) }

    @objc private func reportBug() { NSWorkspace.shared.open(ProjectLinks.issues) }

    @objc private func open() { Host.shared.show() }

    @objc private func settings() { SettingsWindowController.shared.show() }

    @objc private func tour() { OnboardingWindowController.shared.show() }

    @objc private func config() { NSWorkspace.shared.open(Paths.support) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
